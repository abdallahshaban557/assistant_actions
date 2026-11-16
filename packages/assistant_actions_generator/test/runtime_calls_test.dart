import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/interaction.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/reader.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

final _runtimeRoot = p.normalize(p.join(Directory.current.path, '..', 'assistant_actions'));
final _lib = Uri.parse('package:app/assistant_actions.dart');
final _models = Uri.parse('package:app/models.dart');

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File(p.join(_runtimeRoot, 'lib', 'src', 'catalog', '$domain.json')).readAsStringSync()) as Map)
        .cast());

final _recipe = EntityModel(
  className: 'Recipe',
  library: _models,
  title: 'Recipe',
  idField: 'id',
  titleGetter: 'name',
  fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
);

final _meal = AppEnumModel(
  className: 'Meal',
  library: _models,
  title: 'Meal',
  cases: const [
    AppEnumCase(name: 'dinner', title: 'Dinner'),
    AppEnumCase(name: 'lunch', title: 'Lunch'),
  ],
);

String _block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: 'Missing block: $start');
  final end = swift.indexOf('\n}\n', i);
  return end == -1 ? swift.substring(i) : swift.substring(i, end + 2);
}

/// Minimal [BuildStep] backed by the real `packages/assistant_actions` files,
/// so [ModelReader] can read `generator_api.json` and schema catalogs.
final class _FakeBuildStep implements BuildStep {
  @override
  Future<bool> canRead(AssetId id) async {
    if (id.package == 'assistant_actions') {
      return File(p.join(_runtimeRoot, id.path)).existsSync();
    }
    return false;
  }

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async {
    if (id.package == 'assistant_actions') {
      return File(p.join(_runtimeRoot, id.path)).readAsStringSync(encoding: encoding);
    }
    throw AssetNotFoundException(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Resolves [source] as `package:test_app/assistant_actions.dart` against the
/// real `package:assistant_actions` library and runs [ModelReader.read].
Future<AppModel?> _readSource(String source) async {
  final dir = await Directory.systemTemp.createTemp('reader_undo_test');
  try {
    final dartTool = Directory(p.join(dir.path, '.dart_tool'))..createSync();
    File(p.join(dartTool.path, 'package_config.json')).writeAsStringSync(jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'test_app',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        },
        {
          'name': 'assistant_actions',
          'rootUri': Directory(_runtimeRoot).uri.toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        },
      ],
    }));
    final libDir = Directory(p.join(dir.path, 'lib'))..createSync();
    final mainPath = p.normalize(p.join(libDir.path, 'assistant_actions.dart'));
    File(mainPath).writeAsStringSync(source);

    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    final context = collection.contextFor(mainPath);
    final resolved = await context.currentSession.getResolvedLibrary(mainPath);
    if (resolved is! ResolvedLibraryResult) {
      throw StateError('Failed to resolve test library: $resolved');
    }
    final LibraryElement element = resolved.element;
    return await ModelReader(_FakeBuildStep()).read(element);
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  group('ModelReader checks for @AssistantAction(undo: ...)', () {
    test('accepts matching params, subset params, and typed result parameters', () async {
      final model = await _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;

import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/reminders.dart';

@AssistantEntity(title: 'Recipe')
class Recipe {
  Recipe(this.id, this.name);
  @EntityId()
  final String id;
  @DisplayTitle()
  final String name;
}

@RemindersReminder(
  list: FixedRemindersList(id: 'default', name: 'Default'),
  createReminder: true,
)
class TaskItem {
  TaskItem(this.id, this.title);
  @EntityId()
  final String id;
  @ReminderFields.title
  final String title;
}

@AssistantAction(title: 'Log Water', undo: undoLogWater)
Future<void> logWater(int ml, {String note = 'tap'}) async {}
Future<void> undoLogWater(int ml, {String note = 'tap'}) async {}

@AssistantAction(title: 'Create Recipe', runs: Runs.withFlutter, undo: undoCreateRecipe)
Future<Recipe> createRecipe(String title, {int? minutes}) async => Recipe('1', title);
Future<void> undoCreateRecipe({Recipe? result}) async {}

@AssistantAction(title: 'Pick Recipe', runs: Runs.withFlutter, undo: undoPickRecipe)
Future<AssistantReply<Recipe>> pickRecipe(String query) async => AssistantReply.spoken('ok');
void undoPickRecipe(String query, Recipe? result) {}

@AssistantAction(title: 'Quick Task', runs: Runs.withFlutter, undo: undoQuickTask)
Future<TaskItem> quickTask(String title) async => TaskItem('t1', title);
Future<void> undoQuickTask(String title, {String? result}) async {}
''');
      expect(model, isNotNull);
      final byName = {for (final a in model!.actions) a.functionName: a};
      expect(byName['logWater']!.undo!.functionName, 'undoLogWater');
      expect(byName['logWater']!.undo!.takesResult, isFalse);

      expect(byName['createRecipe']!.undo!.functionName, 'undoCreateRecipe');
      expect(byName['createRecipe']!.undo!.takesResult, isTrue);
      expect(byName['createRecipe']!.undo!.params.single.named, isTrue);

      expect(byName['pickRecipe']!.undo!.takesResult, isTrue);
      expect(byName['pickRecipe']!.undo!.params.last.named, isFalse);

      expect(byName['quickTask']!.undo!.takesResult, isTrue);
    });

    test('rejects invalid undo declarations with clear build errors', () async {
      // 1. Static method instead of top-level function.
      await expectLater(
        _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;
import 'package:assistant_actions/assistant_actions.dart';

class Helpers {
  static Future<void> undoIt() async {}
}

@AssistantAction(title: 'Run', undo: Helpers.undoIt)
Future<void> runIt() async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>()
            .having((e) => e.message, 'message', contains('undo must be a top-level function'))),
      );

      // 2. SnapshotAnswer variable cannot have undo.
      await expectLater(
        _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;
import 'package:assistant_actions/assistant_actions.dart';

@AssistantEntity(title: 'Item')
class Item {
  Item(this.id, this.title);
  @EntityId()
  final String id;
  @DisplayTitle()
  final String title;
}

Future<void> undoCount() async {}

@AssistantAction(title: 'Count', undo: undoCount)
const countItems = SnapshotAnswer<Item>(item: '{title}', dialog: '{count}', empty: 'None');
'''),
        throwsA(isA<InvalidGenerationSourceError>()
            .having((e) => e.message, 'message', contains('SnapshotAnswer changes nothing'))),
      );

      // 3. result parameter on a void action.
      await expectLater(
        _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;
import 'package:assistant_actions/assistant_actions.dart';

Future<void> undoPing({String? result}) async {}

@AssistantAction(title: 'Ping', runs: Runs.withFlutter, undo: undoPing)
Future<void> ping() async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>()
            .having((e) => e.message, 'message', contains('returns no value to undo'))),
      );

      // 4. Mismatched parameter type.
      await expectLater(
        _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;
import 'package:assistant_actions/assistant_actions.dart';

Future<void> undoAdd(String wrongType) async {}

@AssistantAction(title: 'Add', undo: undoAdd)
Future<void> addCount(int count) async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>()
            .having((e) => e.message, 'message', contains('expected int'))),
      );

      // 5. Non-nullable result on AssistantReply<T>.
      await expectLater(
        _readSource('''
@AssistantActionsApp(name: 'TestApp')
library;
import 'package:assistant_actions/assistant_actions.dart';

Future<void> undoMake({required int result}) async {}

@AssistantAction(title: 'Make', runs: Runs.withFlutter, undo: undoMake)
Future<AssistantReply<int>> makeNumber() async => AssistantReply.spoken('hi');
'''),
        throwsA(isA<InvalidGenerationSourceError>()
            .having((e) => e.message, 'message', contains('must be nullable'))),
      );
    });
  });

  group('Mid-execution conversational prompts (AssistantPromptingIntent & decoders)', () {
    test('live plain actions register requestValue and requestDisambiguation per parameter, including Swift keywords',
        () {
      final locate = ActionModel(
        functionName: 'locateSpot',
        library: _lib,
        title: 'Locate Spot',
        runs: RunsModel.withFlutter,
        returnsString: true,
        params: [
          ParamModel(name: 'recipe', title: 'Recipe', named: false, entity: _recipe, entityNullable: true),
          ParamModel(
              name: 'meal',
              title: 'Meal',
              named: true,
              value: const ValueType(ValueKind.enumeration, nullable: true, appEnum: 'Meal')),
          ParamModel(
              name: 'where',
              title: 'Where',
              named: true,
              value: const ValueType(ValueKind.place, nullable: true)),
        ],
      );
      final deferred = ActionModel(
        functionName: 'queueNote',
        library: _lib,
        title: 'Queue Note',
        runs: RunsModel.deferred,
        returnsString: false,
        params: [
          ParamModel(name: 'text', title: 'Text', named: false, value: const ValueType(ValueKind.string)),
        ],
      );
      final app = AppModel(
        appName: 'Mira',
        actions: [locate, deferred],
        entities: [_recipe],
        schemaEntities: const [],
        appEnums: {'Meal': _meal},
      );

      final swift = SwiftWriter(app).write();
      expect(swift, isNot(contains('extension QueueNoteAction: AssistantPromptingIntent')));
      final ext = _block(swift, 'extension LocateSpotAction: AssistantPromptingIntent {');
      expect(ext, contains('public func registerPrompts(on call: AssistantLiveCall)'));
      expect(ext, contains(r'let recipeParam = self.$recipe'));
      expect(ext, contains('let found = try await RecipeEntityQuery().entities(for: ids)'));
      expect(ext, contains(r'let mealParam = self.$meal'));
      expect(ext, contains('MealEnum.init(rawValue:)'));
      // Swift keyword `where` must use `self.$where` (no backticks on `$where`).
      expect(ext, contains(r'let whereParam = self.$where'));
      expect(ext, isNot(contains(r'$`where`')));

      final dart = writeDart(app);
      expect(dart, contains('decoders: {'));
      expect(dart, contains('a1.Recipe: (v) => v is String ? findRecipe(v) : null,'));
      expect(dart, contains('List<a1.Recipe>: (v) async => ['));
      expect(dart, contains('Meal: (v) => AssistantValue.enumeration(Meal.values, v),'));
      expect(dart, contains('List<Meal>: (v) => AssistantValue.list('));
    });

    test('live schema call intents register AssistantPromptingIntent for criteria, enums, and file entities', () {
      final system = _load('system');
      final camera = _load('camera');
      final files = _load('files');
      final fileSchema = files.entities['files.file']!;
      final searchInApp = system.intents['system.searchInApp']!;
      final startCapture = camera.intents['camera.startCapture']!;
      final openFile = files.intents['files.openFile']!;

      final fileModel = SchemaEntityModel(
        className: 'DocFile',
        library: _models,
        catalog: files,
        schema: fileSchema,
        idField: 'path',
        mapping: const {},
        intents: [(openFile, IntentKind.call)],
        containers: const {},
      );
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: [fileModel],
        schemaDomains: [
          SchemaDomainModel(className: 'SystemHandler', catalog: system, intents: [searchInApp]),
          SchemaDomainModel(className: 'CameraHandler', catalog: camera, intents: [startCapture]),
        ],
        catalogs: {'system': system, 'camera': camera, 'files': files},
        openEnums: {
          'camera.captureMode': OpenEnumModel(
            schema: 'camera.captureMode',
            className: 'CaptureMode',
            library: _models,
            cases: const ['photo', 'video'],
          ),
        },
      );

      final swift = SwiftWriter(app).write();
      final searchPrompt = _block(swift, 'extension SystemSearchInAppIntent: AssistantPromptingIntent {');
      expect(searchPrompt, contains('StringSearchCriteria.init(term:)'));
      expect(searchPrompt, contains('return resolved.term'));

      final capturePrompt = _block(swift, 'extension CameraStartCaptureIntent: AssistantPromptingIntent {');
      expect(capturePrompt, contains('CameraCaptureModeEnum.init(rawValue:)'));

      final filePrompt = _block(swift, 'extension DocFileOpenFileIntent: AssistantPromptingIntent {');
      expect(filePrompt, contains('return resolved.dartID'));
      expect(filePrompt, contains('DocFileEntityQuery().entities(dartIDs: ids)'));

      final dart = writeDart(app);
      expect(dart, contains('CaptureMode: (v) => AssistantValue.enumeration(CaptureMode.values, v),'));
      expect(dart, contains('List<CaptureMode>: (v) => AssistantValue.list('));
    });
  });

  group('Schema intent donations (AssistantDonations & donateAction)', () {
    test('generates typed donations for create, update, append, delete, record, and call intents with collision safety',
        () {
      final reminders = _load('reminders');
      final notes = _load('notes');
      final journal = _load('journal');
      final camera = _load('camera');
      final assistant = _load('assistant');

      final task = SchemaEntityModel(
        className: 'TaskItem',
        library: _models,
        catalog: reminders,
        schema: reminders.entities['reminders.reminder']!,
        idField: 'id',
        mapping: const {
          'title': FieldModel('title', ValueType(ValueKind.string)),
          'dueDate': FieldModel('dueDate', ValueType(ValueKind.dateTime, nullable: true)),
          'tags': FieldModel('tags', ValueType(ValueKind.string, list: true)),
        },
        intents: [
          (reminders.intents['reminders.createReminder']!, IntentKind.create),
          (reminders.intents['reminders.updateReminder']!, IntentKind.update),
          (reminders.intents['reminders.deleteReminders']!, IntentKind.delete),
        ],
        containers: const {
          'list': FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
        },
      );

      final note = SchemaEntityModel(
        className: 'NoteItem',
        library: _models,
        catalog: notes,
        schema: notes.entities['notes.note']!,
        idField: 'id',
        mapping: const {
          'title': FieldModel('title', ValueType(ValueKind.string, nullable: true)),
          'body': FieldModel('body', ValueType(ValueKind.string, nullable: true)),
        },
        intents: [
          (notes.intents['notes.appendText']!, IntentKind.append),
        ],
        containers: const {},
      );

      final entry = SchemaEntityModel(
        className: 'JournalItem',
        library: _models,
        catalog: journal,
        schema: journal.entities['journal.entry']!,
        idField: 'id',
        mapping: const {
          'title': FieldModel('title', ValueType(ValueKind.string, nullable: true)),
          'message': FieldModel('body', ValueType(ValueKind.string)),
          'entryDate': FieldModel('date', ValueType(ValueKind.dateTime, nullable: true)),
        },
        intents: [
          (journal.intents['journal.createAudioEntry']!, IntentKind.record),
        ],
        containers: const {},
      );

      final cameraDomain = SchemaDomainModel(
        className: 'CameraHandler',
        catalog: camera,
        intents: [camera.intents['camera.startCapture']!],
      );

      final assistantDomain = SchemaDomainModel(
        className: 'AssistantHandler',
        catalog: assistant,
        intents: [assistant.intents['assistant.activate']!],
      );

      // Plain action intentionally named `createReminder` to verify collision handling!
      final collidingPlain = ActionModel(
        functionName: 'createReminder',
        library: _lib,
        title: 'Custom Create Reminder',
        runs: RunsModel.deferred,
        returnsString: false,
        params: [ParamModel(name: 'text', title: 'Text', named: false, value: const ValueType(ValueKind.string))],
      );

      final app = AppModel(
        appName: 'Mira',
        actions: [collidingPlain],
        entities: const [],
        schemaEntities: [task, note, entry],
        schemaDomains: [cameraDomain, assistantDomain],
        catalogs: {
          'reminders': reminders,
          'notes': notes,
          'journal': journal,
          'camera': camera,
          'assistant': assistant,
        },
        openEnums: {
          'camera.captureMode': OpenEnumModel(
              schema: 'camera.captureMode', className: 'CaptureMode', library: _models, cases: const ['photo', 'video']),
          'camera.captureDevice': OpenEnumModel(
              schema: 'camera.captureDevice', className: 'CaptureDevice', library: _models, cases: const ['back']),
          'camera.captureDuration': OpenEnumModel(
              schema: 'camera.captureDuration', className: 'CaptureTimer', library: _models, cases: const ['off']),
          'assistant.activationTarget': OpenEnumModel(
              schema: 'assistant.activationTarget', className: 'AssistantTarget', library: _models, cases: const ['chat']),
        },
      );

      final dart = writeDart(app);
      // Plain action keeps `createReminder`, schema create intent disambiguates to `taskItemCreateReminder`.
      expect(dart, contains('static Future<bool> createReminder(String text) =>'));
      expect(dart, contains('static Future<bool> taskItemCreateReminder(TaskItemValues values) =>'));
      expect(dart, contains("AssistantActions.donateAction('TaskItem.createReminder', values._toJson());"));
      expect(dart, contains('static Future<bool> updateReminder(String id, TaskItemValues changes) =>'));
      expect(dart,
          contains("AssistantActions.donateAction('TaskItem.updateReminder', {'id': id, 'fields': changes._toJson()});"));
      expect(dart, contains('static Future<bool> deleteReminders(String id) =>'));
      expect(dart, contains("AssistantActions.donateAction('TaskItem.deleteReminders', {'id': id});"));
      expect(dart, contains('static Future<bool> appendText(String id, NoteItemValues changes) =>'));
      expect(dart, contains('static Future<bool> startAudioEntry() =>'));
      expect(dart, contains("AssistantActions.donateAction('JournalItem.startAudioEntry', const {});"));
      expect(dart, contains('static Future<bool> startCapture({required CaptureMode captureMode'));
      expect(dart, contains("AssistantActions.donateAction('camera.startCapture'"));
      expect(dart, contains('static Future<bool> activate('));

      final swift = SwiftWriter(app).write();
      expect(swift, contains('AssistantHostCalls.register("donate.action") { args in donateAction(args) }'));
      final donate = _block(swift, '  private static func donateAction(');
      expect(donate, contains('case "TaskItem.createReminder":'));
      expect(donate, contains('let intent = TaskItemCreateReminderIntent()'));
      expect(donate, contains('case "TaskItem.updateReminder":'));
      expect(donate, contains('intent.target = TaskItemEntity.reference(id, resolve: true)'));
      expect(donate, contains('case "TaskItem.deleteReminders":'));
      expect(donate, contains('intent.entities = [TaskItemEntity.reference(id, resolve: true)]'));
      expect(donate, contains('case "NoteItem.appendText":'));
      expect(donate, contains('case "JournalItem.startAudioEntry":'));
      expect(donate, contains('let intent = JournalItemCreateAudioEntryIntent()'));
      expect(donate, contains('case "camera.startCapture":'));
      expect(donate, contains('let intent = CameraStartCaptureIntent()'));
      // Single-OS `assistant.activate` must guard with `#if os(iOS)`.
      expect(donate, contains('case "assistant.activate":\n      #if os(iOS)'));
    });
  });

  group('Plain @AssistantAction undo (UndoableIntent)', () {
    test('generates UndoableIntent, UndoManager registration, result forwarding, and registry .undo entries', () {
      final titleParam = ParamModel(
        name: 'title',
        title: 'Title',
        named: false,
        value: const ValueType(ValueKind.string),
      );
      final deferredAction = ActionModel(
        functionName: 'archiveRecipe',
        library: _lib,
        title: 'Archive Recipe',
        runs: RunsModel.deferred,
        returnsString: false,
        params: [titleParam],
        undo: ActionUndoModel(
          functionName: 'undoArchiveRecipe',
          library: _lib,
          params: [ActionUndoParam(name: 'title', named: false, nullable: false, sourceParam: titleParam)],
        ),
      );

      // Live action returning Recipe (entity NOT in input params -> findRecipe must still be required!).
      final createRecipe = ActionModel(
        functionName: 'createRecipe',
        library: _lib,
        title: 'Create Recipe',
        runs: RunsModel.withFlutter,
        returnsString: false,
        params: [ParamModel(name: 'name', title: 'Name', named: false, value: const ValueType(ValueKind.string))],
        result: ResultModel(entity: _recipe),
        undo: ActionUndoModel(
          functionName: 'undoCreateRecipe',
          library: _lib,
          params: const [ActionUndoParam(name: 'result', named: true, nullable: true, isResult: true)],
        ),
      );

      // Live action returning AssistantReply<Recipe> (e.g. AssistantReply.choose) -> passes chosen value.id!
      final chooseRecipe = ActionModel(
        functionName: 'chooseRecipe',
        library: _lib,
        title: 'Choose Recipe',
        runs: RunsModel.withFlutter,
        returnsString: false,
        returnsReply: true,
        params: const [],
        result: ResultModel(entity: _recipe),
        undo: ActionUndoModel(
          functionName: 'undoChooseRecipe',
          library: _lib,
          params: const [ActionUndoParam(name: 'result', named: true, nullable: true, isResult: true)],
        ),
      );

      final app = AppModel(
        appName: 'Mira',
        actions: [deferredAction, createRecipe, chooseRecipe],
        entities: [_recipe],
        schemaEntities: const [],
      );

      final dart = writeDart(app);
      expect(dart, contains('required FutureOr<a1.Recipe?> Function(String id) findRecipe,'));
      expect(dart, contains("'archiveRecipe.undo': (args) async {"));
      expect(dart, contains('await a0.undoArchiveRecipe(_u0);'));
      expect(dart, contains("'createRecipe.undo': (args) async {"));
      expect(dart, contains("args['result'] is String ? await findRecipe(args['result'] as String) : null;"));
      expect(dart, contains('await a0.undoCreateRecipe(result: _u0);'));
      expect(dart, contains("'chooseRecipe.undo': (args) async {"));

      final swift = SwiftWriter(app).write();
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension ArchiveRecipeAction: UndoableIntent {}'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension CreateRecipeAction: UndoableIntent {}'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension ChooseRecipeAction: UndoableIntent {}'));

      final archiveBlock = _block(swift, 'public struct ArchiveRecipeAction');
      expect(archiveBlock, contains('AssistantUndo.call("archiveRecipe", args: args)'));

      final createBlock = _block(swift, 'public struct CreateRecipeAction');
      expect(createBlock, contains('undoArgs["result"] = result.value ?? NSNull()'));
      expect(createBlock, contains('AssistantUndo.call("createRecipe", args: undoArgs)'));

      final chooseBlock = _block(swift, 'public struct ChooseRecipeAction');
      expect(chooseBlock, contains('undoArgs["result"] = value.id'));
      expect(chooseBlock, contains('AssistantUndo.call("chooseRecipe", args: undoArgs)'));
    });
  });

  group('Generated Swift typechecks with xcrun swiftc', () {
    test('compiles generated Swift for all 4 features on macOS and iOS Simulator SDKs', () async {
      final reminders = _load('reminders');
      final camera = _load('camera');
      final assistant = _load('assistant');

      final task = SchemaEntityModel(
        className: 'TaskItem',
        library: _models,
        catalog: reminders,
        schema: reminders.entities['reminders.reminder']!,
        idField: 'id',
        undoable: true,
        mapping: const {
          'title': FieldModel('title', ValueType(ValueKind.string)),
          'dueDate': FieldModel('dueDate', ValueType(ValueKind.dateTime, nullable: true)),
          'tags': FieldModel('tags', ValueType(ValueKind.string, list: true)),
        },
        intents: [
          (reminders.intents['reminders.createReminder']!, IntentKind.create),
          (reminders.intents['reminders.updateReminder']!, IntentKind.update),
          (reminders.intents['reminders.deleteReminders']!, IntentKind.delete),
        ],
        containers: const {
          'list': FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
        },
      );

      final whereParam = ParamModel(
        name: 'where',
        title: 'Where',
        named: true,
        value: const ValueType(ValueKind.place, nullable: true),
      );
      final recipeParam = ParamModel(
        name: 'recipe',
        title: 'Recipe',
        named: false,
        entity: _recipe,
      );
      final mealParam = ParamModel(
        name: 'meal',
        title: 'Meal',
        named: true,
        value: const ValueType(ValueKind.enumeration, appEnum: 'Meal'),
        swiftDefault: '.dinner',
        defaultDart: 'Meal.dinner',
      );

      final cookAction = ActionModel(
        functionName: 'cookMeal',
        library: _lib,
        title: 'Cook Meal',
        runs: RunsModel.withFlutter,
        returnsString: false,
        returnsReply: true,
        params: [recipeParam, mealParam, whereParam],
        result: ResultModel(entity: _recipe),
        undo: ActionUndoModel(
          functionName: 'undoCookMeal',
          library: _lib,
          params: [
            ActionUndoParam(name: 'recipe', named: false, nullable: false, sourceParam: recipeParam),
            const ActionUndoParam(name: 'result', named: true, nullable: true, isResult: true),
          ],
        ),
      );

      final logAction = ActionModel(
        functionName: 'logNote',
        library: _lib,
        title: 'Log Note',
        runs: RunsModel.deferred,
        returnsString: false,
        params: [ParamModel(name: 'text', title: 'Text', named: false, value: const ValueType(ValueKind.string))],
        undo: ActionUndoModel(functionName: 'undoLogNote', library: _lib, params: const []),
      );

      final app = AppModel(
        appName: 'Mira',
        actions: [cookAction, logAction],
        entities: [_recipe],
        schemaEntities: [task],
        schemaDomains: [
          SchemaDomainModel(
            className: 'CameraHandler',
            catalog: camera,
            intents: [camera.intents['camera.startCapture']!],
            interactions: const Interactions(replies: {'startCapture'}),
          ),
          SchemaDomainModel(
            className: 'AssistantHandler',
            catalog: assistant,
            intents: [assistant.intents['assistant.activate']!],
          ),
        ],
        catalogs: {'reminders': reminders, 'camera': camera, 'assistant': assistant},
        appEnums: {'Meal': _meal},
        openEnums: {
          'camera.captureMode': OpenEnumModel(
              schema: 'camera.captureMode', className: 'CaptureMode', library: _models, cases: const ['photo', 'video']),
          'camera.captureDevice': OpenEnumModel(
              schema: 'camera.captureDevice', className: 'CaptureDevice', library: _models, cases: const ['back']),
          'camera.captureDuration': OpenEnumModel(
              schema: 'camera.captureDuration', className: 'CaptureTimer', library: _models, cases: const ['off']),
          'assistant.activationTarget': OpenEnumModel(
              schema: 'assistant.activationTarget', className: 'AssistantTarget', library: _models, cases: const ['chat']),
        },
      );

      final swift = SwiftWriter(app).write().replaceFirst('import assistant_actions\n', '');
      final dir = await Directory.systemTemp.createTemp('runtime_calls_swiftc');
      try {
        final generated = File(p.join(dir.path, 'AssistantActions.g.swift'))..writeAsStringSync(swift);
        final stub = File(p.join(dir.path, 'BridgeStub.swift'))
          ..writeAsStringSync('''
import AppIntents
import Foundation

@MainActor
public final class AssistantBridge {
  public static let shared = AssistantBridge()
  public static let userErrorCode = "assistant_actions.user_error"
  public static let cancelledErrorCode = "assistant_actions.cancelled"
  public var isReady: Bool { false }
  public func perform(_ action: String, args: [String: Any]) async throws -> String? { nil }
  public func waitUntilReady(timeout: TimeInterval) async -> Bool { false }
  public func inboxChanged() {}
}

public enum AssistantActionError: Error, CustomLocalizedStringResourceConvertible, Equatable {
  case notRunning
  case failed(String)
  case userFacing(String)

  public var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notRunning: return "Open the app once to finish setting up Siri."
    case .failed(let message): return "Something went wrong: \\(message)"
    case .userFacing(let message): return "\\(message)"
    }
  }
}

@MainActor
public final class AssistantBackground {
  public static let shared = AssistantBackground()
  public func prepare(timeout: TimeInterval = 15) async -> Bool { false }
  public func applyInbox(timeout: TimeInterval = 10) async {}
}
''');
        final sources = p.join(_runtimeRoot, 'darwin', 'assistant_actions', 'Sources', 'assistant_actions');
        final runtimeFiles = [
          for (final f in [
            'AssistantAppGroup',
            'AssistantValues',
            'AssistantInbox',
            'AssistantSnapshot',
            'AssistantQuery',
            'AssistantSpotlight',
            'AssistantMatch',
            'AssistantComparison',
            'AssistantRichValues',
            'AssistantHostCalls',
            'AssistantReply',
            'AssistantDialog',
            'AssistantInteraction',
            'AssistantCardView',
            'AssistantCardStore',
            'AssistantLiveCall',
            'AssistantLiveIntents',
            'AssistantFileIDs',
            'AssistantUndo',
            'AssistantContext',
            'AssistantVisualIntelligence',
            'AssistantPlatformViews',
          ])
            p.join(sources, '$f.swift'),
        ];

        for (final (sdkName, target) in [
          ('macosx', 'arm64-apple-macos14.0'),
          ('iphonesimulator', 'arm64-apple-ios17.0-simulator'),
        ]) {
          final sdk = (await Process.run('xcrun', ['--sdk', sdkName, '--show-sdk-path'])).stdout.toString().trim();
          final res = await Process.run('xcrun', [
            'swiftc',
            '-sdk',
            sdk,
            '-target',
            target,
            '-typecheck',
            generated.path,
            stub.path,
            ...runtimeFiles,
          ]);
          expect(res.exitCode, 0, reason: 'swiftc ($sdkName) failed:\n${res.stdout}\n${res.stderr}');
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
