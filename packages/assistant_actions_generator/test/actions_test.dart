// Plain actions, App Enums, results and App Shortcuts, built from models
// directly (plus full ModelReader + swiftc -typecheck end-to-end tests).
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/reader.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

final _lib = Uri.parse('package:app/assistant_actions.dart');
final _models = Uri.parse('package:app/models.dart');

final _recipe = EntityModel(
  className: 'Recipe',
  library: _models,
  title: 'Recipe',
  idField: 'id',
  titleGetter: 'name',
  fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
);

final _meal = AppEnumModel(className: 'Meal', library: _models, title: 'Meal', cases: const [
  AppEnumCase(name: 'dinner', title: 'Dinner'),
  AppEnumCase(name: 'snack', title: 'Late-night snack', synonyms: ['snack']),
]);

const _mealType = ValueType(ValueKind.enumeration, appEnum: 'Meal');

ActionModel _action(
  String name, {
  List<ParamModel> params = const [],
  ResultModel? result,
  RunsModel runs = RunsModel.withFlutter,
  String? dialog,
  ShortcutModel? shortcut,
  List<String> keywords = const [],
  bool discoverable = true,
  bool reply = false,
  String? confirm,
  bool liveActivity = false,
  FocusFilterModel? focusFilter,
}) =>
    ActionModel(
      functionName: name,
      library: _lib,
      title: name,
      runs: runs,
      params: params,
      returnsString: false,
      result: result,
      dialog: dialog,
      shortcut: shortcut,
      searchKeywords: keywords,
      isDiscoverable: discoverable,
      returnsReply: reply,
      confirm: confirm,
      liveActivity: liveActivity,
      focusFilter: focusFilter,
    );

/// "Plan {meal} with {recipe}", a deferred action taking an entity and an
/// App Enum with a default.
ActionModel _plan() => _action(
      'planMeal',
      runs: RunsModel.deferred,
      dialog: 'Planned {recipe} for {meal}.',
      keywords: const ['menu'],
      params: [
        ParamModel(name: 'recipe', title: 'Recipe', named: false, entity: _recipe),
        ParamModel(
            name: 'meal', title: 'Meal', named: true, value: _mealType, swiftDefault: '.dinner', defaultDart: 'Meal.dinner'),
      ],
      shortcut: const ShortcutModel(
          phrases: ['Cook {recipe} for {meal} in {app}'], shortTitle: 'Plan', systemImage: 'fork.knife'),
    );

AppModel _app({
  List<ActionModel> actions = const [],
  List<SnapshotActionModel> snapshotActions = const [],
  List<SchemaEntityModel> schemaEntities = const [],
  List<SchemaDomainModel> domains = const [],
  List<IntentShortcutModel> intentShortcuts = const [],
  Map<String, DomainCatalog> catalogs = const {},
  String? tileColor,
}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      snapshotActions: snapshotActions,
      entities: [_recipe],
      schemaEntities: schemaEntities,
      schemaDomains: domains,
      catalogs: catalogs,
      appEnums: {'Meal': _meal},
      intentShortcuts: intentShortcuts,
      shortcutTileColor: tileColor,
    );

/// Mira's tasks as `reminders.reminder`.
SchemaEntityModel _tasks() {
  final reminders = _load('reminders');
  final schema = reminders.entities['reminders.reminder']!;
  return SchemaEntityModel(
    className: 'TaskItem',
    library: _models,
    catalog: reminders,
    schema: schema,
    idField: 'id',
    mapping: const {'title': FieldModel('title', ValueType(ValueKind.string))},
    intents: const [],
    containers: {
      'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
    },
  );
}

SchemaDomainModel _camera() {
  final camera = _load('camera');
  return SchemaDomainModel(className: 'CameraHandler', catalog: camera, intents: camera.domainIntents);
}

Map<String, OpenEnumModel> get _cameraEnums => {
      for (final (id, name) in [
        ('camera.captureMode', 'Mode'),
        ('camera.captureDevice', 'Lens'),
        ('camera.captureDuration', 'Delay'),
      ])
        id: OpenEnumModel(schema: id, className: name, library: _models, cases: const ['photo', 'video']),
    };

String block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

void main() {
  group('App Enums', () {
    test('become public AppEnums with titles and synonyms', () {
      final swift = SwiftWriter(_app()).write();
      final e = block(swift, 'public enum MealEnum: String, AppEnum {');
      expect(e, contains('  case dinner\n  case snack\n'));
      expect(e, contains('public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"'));
      expect(e, contains('.dinner: "Dinner",'));
      expect(e, contains('.snack: DisplayRepresentation(title: "Late-night snack", synonyms: ["snack"]),'));
    });

    test('parameters default to a case, and Dart falls back to the same default', () {
      final app = _app(actions: [_plan()]);
      final action = block(SwiftWriter(app).write(), 'public struct PlanMealAction');
      expect(action, contains('@Parameter(title: "Meal", default: .dinner)\n  public var meal: MealEnum\n'));
      expect(action, contains('"meal": AssistantValues.encode(meal),'));
      expect(action, contains(r'for \(String(localized: meal.localizedStringResource)).'),
          reason: 'dialogs say the case title');
      final dart = writeDart(app);
      expect(dart, contains("import 'package:app/models.dart' show Meal;"));
      expect(dart, contains("final _meal = AssistantValue.enumeration(Meal.values, args['meal']) ?? Meal.dinner;"));
    });

    test('schema enums are declared, public and raise availability', () {
      final app = AppModel(
        appName: 'Mira',
        actions: [
          _action('setState', params: [
            ParamModel(
                name: 'state', title: 'State', named: true, value: const ValueType(ValueKind.enumeration, enumRef: 'clock.timerState')),
          ]),
        ],
        entities: const [],
        schemaEntities: const [],
        catalogs: {'clock': _load('clock')},
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@AppEnum(schema: .clock.timerState)\npublic enum ClockTimerStateEnum: String {'));
      expect(swift, contains('  public static let caseDisplayRepresentations: [ClockTimerStateEnum'));
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\npublic struct SetStateAction'));
      expect(writeDart(app), contains("import 'package:assistant_actions/schemas/clock.dart' show ClockTimerState;"));
    });
  });

  group('parameters', () {
    test('lists, durations, people, files and places', () {
      final app = _app(actions: [
        _action('share', params: [
          ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
          ParamModel(name: 'tags', title: 'Tags', named: true, value: const ValueType(ValueKind.string, list: true)),
          ParamModel(name: 'length', title: 'Length', named: true, value: const ValueType(ValueKind.duration, nullable: true)),
          ParamModel(name: 'who', title: 'Who', named: true, value: const ValueType(ValueKind.person, nullable: true)),
          ParamModel(name: 'photos', title: 'Photos', named: true, value: const ValueType(ValueKind.file, list: true)),
          ParamModel(name: 'where', title: 'Where', named: true, value: const ValueType(ValueKind.place)),
        ]),
      ]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('import GeoToolbox'));
      final action = block(swift, 'public struct ShareAction');
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\npublic struct ShareAction'),
          reason: 'PlaceDescriptor is iOS 26');
      expect(action, contains('public var recipes: [RecipeEntity]'));
      expect(action, contains('public var tags: [String]'));
      expect(action, contains('public var length: Measurement<UnitDuration>?'),
          reason: 'Duration only works as a parameter from iOS 26');
      expect(action, contains('public var who: IntentPerson?'));
      expect(action, contains('public var photos: [IntentFile]'));
      expect(action, contains('public var `where`: PlaceDescriptor'));
      expect(action, contains(r'"recipes": recipes.map(\.id),'));
      expect(action, contains(r'"tags": tags.map { AssistantValues.encode($0) },'));
      expect(action, contains('"where": AssistantValues.encode(`where`),'));
      final dart = writeDart(app);
      expect(dart, contains("final _recipes = [for (final id in AssistantValue.list(args['recipes'], "
          'AssistantValue.string) ?? const <String>[]) if (await findRecipe(id) case final e?) e];'));
      expect(dart, contains("AssistantValue.list(args['tags'], (v) => AssistantValue.string(v))"));
      expect(dart, contains("final _length = AssistantValue.duration(args['length']);"));
      expect(dart, contains("AssistantValue.list(args['photos'], (v) => AssistantValue.file(v))"));
    });

    test('a default Swift can\'t state makes the Swift parameter optional', () {
      final app = _app(actions: [
        _action('wait', params: [
          ParamModel(
              name: 'length',
              title: 'Length',
              named: true,
              value: const ValueType(ValueKind.duration),
              defaultDart: 'const Duration(microseconds: 300000000)'),
        ]),
      ]);
      expect(SwiftWriter(app).write(), contains('public var length: Measurement<UnitDuration>?\n'));
      expect(writeDart(app),
          contains("final _length = AssistantValue.duration(args['length']) ?? const Duration(microseconds: 300000000);"));
    });

    test('search keywords and hidden actions', () {
      final swift = SwiftWriter(_app(actions: [_plan(), _action('secret', discoverable: false)])).write();
      expect(swift, contains('IntentDescription("planMeal", searchKeywords: ["menu"])'),
          reason: 'keywords without a description describe it with the title');
      expect(block(swift, 'public struct SecretAction'), contains('public static let isDiscoverable = false'));
      expect(block(swift, 'public struct PlanMealAction'), isNot(contains('isDiscoverable')));
    });
  });

  group('results', () {
    test('values return through ReturnsValue, with the dialog Dart gives', () {
      final app = _app(actions: [
        _action('count', result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
        _action('names', result: const ResultModel(value: ValueType(ValueKind.string, list: true))),
      ]);
      final swift = SwiftWriter(app).write();
      final count = block(swift, 'public struct CountAction');
      expect(count, contains('some IntentResult & ReturnsValue<Int> & ProvidesDialog'));
      expect(count, contains('let result = AssistantValues.result(reply)'));
      expect(count, contains('guard let value = AssistantValues.int(result.value) else {'));
      expect(count, contains('return .result(value: value, dialog: IntentDialog(stringLiteral: result.dialog ?? "Done."))'));
      final names = block(swift, 'public struct NamesAction');
      expect(names, contains('ReturnsValue<[String]>'));
      expect(names, contains(r'(AssistantValues.items(result.value) ?? []).compactMap { AssistantValues.string($0) }'));
      final dart = writeDart(app);
      expect(dart, contains('final result = await a0.count();\n      return AssistantValue.encodeResult(result.value, dialog: result.dialog);'));
      expect(dart, contains('return AssistantValue.encodeResult(result);'));
    });

    test('entities return by id and are looked up in the snapshot, in order', () {
      final app = _app(actions: [
        _action('quickest', result: ResultModel(entity: _recipe, nullable: true, wrapped: true)),
        _action('all', result: ResultModel(entity: _recipe, list: true)),
      ]);
      final swift = SwiftWriter(app).write();
      final quickest = block(swift, 'public struct QuickestAction');
      expect(quickest, contains('ReturnsValue<RecipeEntity?>'));
      expect(quickest, contains('let value = try await RecipeEntityQuery().entities(for: ids).first'));
      final all = block(swift, 'public struct AllAction');
      expect(all, contains(r'let value = ids.compactMap { id in found.first { $0.id == id } }'));
      final dart = writeDart(app);
      expect(dart, contains('AssistantValue.encodeResult(result.value?.id, dialog: result.dialog)'));
      expect(dart, contains('AssistantValue.encodeResult([for (final e in result) e.id])'));
    });

    test('schema entities make the action, the entity and what it reaches public', () {
      final tasks = _tasks();
      final app = _app(
        actions: [_action('nextTask', result: ResultModel(schemaEntity: tasks, nullable: true))],
        schemaEntities: [tasks],
        catalogs: {'reminders': tasks.catalog},
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\npublic struct NextTaskAction'));
      expect(swift, contains('@AppEntity(schema: .reminders.reminder)\npublic struct TaskItemEntity {'));
      expect(block(swift, 'public struct TaskItemEntity {'), contains('  public static let defaultQuery'));
      final query = block(swift, 'public struct TaskItemEntityQuery');
      expect(query, contains('  public init() {}'));
      expect(query, contains('  public func entities(for identifiers: [String])'));
      expect(query, contains('  private func all()'), reason: 'private members stay private');
      expect(swift, contains('public struct RemindersListEntity {'), reason: 'members reach the list');
    });
  });

  group('App Shortcuts', () {
    test('phrases name entity and enum parameters; entity phrases refresh on publish', () {
      final shortcuts = writeShortcuts(_app(actions: [_plan()], tileColor: 'grape'));
      expect(shortcuts, contains(r'phrases: ["Cook \(\.$recipe) for \(\.$meal) in \(.applicationName)"],'));
      expect(shortcuts, contains('static var shortcutTileColor: ShortcutTileColor { .grape }'));
      expect(shortcuts, contains('@objc(AssistantActionsAppShortcuts)'));
      expect(shortcuts, contains('AssistantShortcuts.updateAppShortcutParameters()'));
    });

    test('without entity phrases there is nothing to refresh', () {
      final shortcuts = writeShortcuts(_app(actions: [
        _action('count',
            shortcut: const ShortcutModel(phrases: ['Count in {app}'], shortTitle: 'Count', systemImage: 'number')),
      ]));
      expect(shortcuts, isNot(contains('AssistantActionsAppShortcuts')));
      expect(shortcuts, isNot(contains('shortcutTileColor')));
      expect(shortcuts, isNot(contains('import Foundation')));
    });

    test('schema intents are shortcuts behind #available, made public for the Runner', () {
      final camera = _camera();
      final start = camera.intents.firstWhere((i) => i.id == 'camera.startCapture');
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [camera],
        catalogs: {'camera': camera.catalog},
        openEnums: _cameraEnums,
        intentShortcuts: [
          IntentShortcutModel(
            className: 'CameraHandler',
            intent: start,
            shortcut: const ShortcutModel(
                phrases: ['Take a {captureMode} with {app}'], shortTitle: 'Camera', systemImage: 'camera'),
          ),
        ],
      );
      final shortcuts = writeShortcuts(app);
      expect(shortcuts, contains('iOS 17.4 / macOS 14.4'));
      expect(shortcuts, contains('    if #available(iOS 18.0, macOS 15.0, *) {\n      AppShortcut(\n'
          '        intent: CameraStartCaptureIntent(),\n'
          r'        phrases: ["Take a \(\.$captureMode) with \(.applicationName)"],'));
      final swift = SwiftWriter(app).write();
      final intent = block(swift, 'public struct CameraStartCaptureIntent');
      expect(intent, contains('  public init() {}'));
      expect(intent, contains('  public var captureMode: CameraCaptureModeEnum'));
      expect(intent, contains('  public func perform()'));
      expect(swift, contains('public enum CameraCaptureModeEnum: String {'));
      expect(swift, contains('  public static let caseDisplayRepresentations: [CameraCaptureModeEnum'));
      expect(swift, contains('\nstruct CameraStopCaptureIntent {'), reason: 'other intents stay internal');
    });

    test('an entity intent makes the entity it returns public', () {
      final tasks = _tasks();
      final create = tasks.catalog.intentsFor(tasks.schema).firstWhere((e) => e.$1.id == 'reminders.createReminder');
      final owner = SchemaEntityModel(
        className: tasks.className,
        library: tasks.library,
        catalog: tasks.catalog,
        schema: tasks.schema,
        idField: 'id',
        mapping: tasks.mapping,
        intents: [create],
        containers: tasks.containers,
      );
      final app = _app(schemaEntities: [owner], catalogs: {'reminders': tasks.catalog}, intentShortcuts: [
        IntentShortcutModel(
          className: 'TaskItem',
          intent: create.$1,
          owner: owner,
          shortcut: const ShortcutModel(phrases: ['Add a task in {app}'], shortTitle: 'New', systemImage: 'plus'),
        ),
      ]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('public struct TaskItemCreateReminderIntent {\n  public init() {}'));
      expect(swift, contains('public struct TaskItemEntity {'));
    });

    test('public unions are Sendable, as the public types holding them must be', () {
      final audio = _load('audio');
      final add = audio.domainIntents.firstWhere((i) => i.id == 'audio.addToLibrary');
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [SchemaDomainModel(className: 'AudioHandler', catalog: audio, intents: [add])],
        catalogs: {'audio': audio},
        openEnums: {
          for (final e in audio.enums.values)
            if (e.cases.isEmpty) e.id: OpenEnumModel(schema: e.id, className: 'E', library: _models, cases: const ['one']),
        },
        intentShortcuts: [
          IntentShortcutModel(
            className: 'AudioHandler',
            intent: add,
            shortcut: const ShortcutModel(phrases: ['Save in {app}'], shortTitle: 'Save', systemImage: 'plus'),
          ),
        ],
      );
      expect(SwiftWriter(app).write(), contains('@UnionValue\npublic enum AudioAudioItemUnion: Sendable {'));
    });

    test('iOS-only intents are left out on macOS', () {
      final assistant = _load('assistant');
      final domain = SchemaDomainModel(className: 'AssistantHandler', catalog: assistant, intents: assistant.domainIntents);
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [domain],
        catalogs: {'assistant': assistant},
        intentShortcuts: [
          IntentShortcutModel(
            className: 'AssistantHandler',
            intent: domain.intents.firstWhere((i) => i.id == 'assistant.activate'),
            shortcut: const ShortcutModel(phrases: ['Start {app}'], shortTitle: 'Start', systemImage: 'play'),
          ),
        ],
      );
      expect(writeShortcuts(app), contains('    #if os(iOS)\n      if #available(iOS 26.2, *) {\n'));
    });

    test('system.open shortcuts open one entity class', () {
      final system = _load('system');
      final domain = SchemaDomainModel(
          className: 'SystemHandler', catalog: system, intents: [system.domainIntents.firstWhere((i) => i.id == 'system.open')]);
      final app = _app(domains: [domain], catalogs: {'system': system}, intentShortcuts: [
        IntentShortcutModel(
          className: 'Recipe',
          intent: domain.intents.single,
          openClass: 'Recipe',
          shortcut: const ShortcutModel(phrases: ['Open {target} in {app}'], shortTitle: 'Open', systemImage: 'book'),
        ),
      ]);
      final shortcuts = writeShortcuts(app);
      expect(shortcuts, contains('intent: OpenRecipeIntent(),'));
      expect(shortcuts, contains(r'"Open \(\.$target) in \(.applicationName)"'));
      expect(shortcuts, contains('@objc(AssistantActionsAppShortcuts)'));
      expect(SwiftWriter(app).write(), contains('public struct OpenRecipeIntent: ForegroundContinuableIntent {\n  public init() {}'));
    });
  });

  group('with Siri interaction and system surfaces', () {
    test('an AssistantReply<T> returns T to Shortcuts and shows its card', () {
      final app = _app(actions: [
        _action('pick', reply: true, result: ResultModel(entity: _recipe, wrapped: true)),
        _action('count', reply: true, result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
      ]);
      final swift = SwiftWriter(app).write();
      final pick = block(swift, 'public struct PickAction');
      expect(pick, contains('some IntentResult & ReturnsValue<RecipeEntity> & ProvidesDialog & ShowsSnippetView'));
      expect(pick, contains('let reply = AssistantReply(json: try await callDart("pick", args: args))'));
      expect(pick, contains('let candidates = try await RecipeEntityQuery().entities(for: reply.ids)'));
      expect(pick, contains('guard let value = try await assistantChoose(among: candidates, prompt: reply.prompt) else {'),
          reason: 'AssistantReply.choose asks which item');
      expect(pick, contains('return .result(value: value, dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), '
          'view: AssistantCardView(reply.card))'));
      final count = block(swift, 'public struct CountAction');
      expect(count, contains('ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView'));
      expect(count, contains('guard let value = AssistantValues.int(reply.value) else {'));
      final dart = writeDart(app);
      expect(dart, contains('final reply = await a0.pick();\n      return AssistantReply.encodeValue(reply, reply.value?.id);'));
      expect(dart, contains('return AssistantReply.encodeValue(reply, reply.value);'));
    });

    test('an AssistantReply<void> keeps its dialog and card only', () {
      final swift = SwiftWriter(_app(actions: [_action('show', reply: true)])).write();
      final show = block(swift, 'public struct ShowAction');
      expect(show, contains('some IntentResult & ProvidesDialog & ShowsSnippetView {'));
      expect(show, isNot(contains('ReturnsValue')));
      expect(writeDart(_app(actions: [_action('show', reply: true)])), contains('return AssistantReply.encode(await a0.show());'));
    });

    test('confirmations say the new parameter types', () {
      final app = _app(actions: [
        _action('plan',
            runs: RunsModel.deferred,
            confirm: 'Plan {recipes} for {meal}?',
            params: [
              ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
              ParamModel(name: 'meal', title: 'Meal', named: true, value: _mealType),
            ]),
      ]);
      final plan = block(SwiftWriter(app).write(), 'public struct PlanAction');
      expect(plan, contains(r'try await assistantConfirm("Plan \(recipes.map(\.title).formatted()) for '
          r'\(String(localized: meal.localizedStringResource))?")'));
      expect(plan.indexOf('assistantConfirm'), lessThan(plan.indexOf('AssistantInbox.call')),
          reason: 'asked before anything is queued');
    });

    test('Live Activity actions keep their perform and conformance', () {
      final swift = SwiftWriter(_app(actions: [_action('stop', liveActivity: true, runs: RunsModel.deferred)])).write();
      expect(swift, contains('if AssistantBridge.shared.isReady {'));
      expect(swift, contains('extension StopAction: LiveActivityIntent {}'));
    });

    test('Focus filters take App Enums and say them in their summary', () {
      final app = _app(actions: [
        _action('applyFocus',
            runs: RunsModel.deferred,
            focusFilter: const FocusFilterModel(summary: 'Meals: {meal}'),
            params: [
              ParamModel(name: 'meal', title: 'Meal', named: true, value: _mealType, swiftDefault: '.dinner', defaultDart: 'Meal.dinner'),
            ]),
      ]);
      final filter = block(SwiftWriter(app).write(), 'public struct ApplyFocusFocusFilter: SetFocusFilterIntent');
      expect(filter, contains('@Parameter(title: "Meal", default: .dinner)\n  public var meal: MealEnum\n'));
      expect(filter, contains(r'let summary: String = "Meals: \(String(localized: meal.localizedStringResource))"'));
      expect(filter, contains('"meal": AssistantValues.encode(meal),'));
    });
  });

  group('donations and predictions', () {
    final share = _action('share', params: [
      ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
      ParamModel(name: 'tags', title: 'Tags', named: true, value: const ValueType(ValueKind.string, list: true)),
      ParamModel(name: 'length', title: 'Length', named: true, value: const ValueType(ValueKind.duration, nullable: true)),
      ParamModel(name: 'who', title: 'Who', named: true, value: const ValueType(ValueKind.person, nullable: true)),
      ParamModel(name: 'where', title: 'Where', named: true, value: const ValueType(ValueKind.place)),
    ]);

    test('donated values decode into every parameter type', () {
      final swift = SwiftWriter(_app(actions: [_plan(), share])).write();
      final donate = block(swift, '  private static func donateAction(');
      expect(donate, contains(
          '      if let value = AssistantValues.string(values["meal"]).flatMap(MealEnum.init(rawValue:)) { intent.meal = value }'));
      expect(donate, contains('    case "share":\n      guard #available(iOS 26.0, macOS 26.0, *) else { return false }'),
          reason: 'PlaceDescriptor is iOS 26, like the action');
      expect(donate, contains(r'guard let recipesValue = AssistantValues.strings(values["recipes"])?.compactMap({ id in '
          r'AssistantSnapshot.records("Recipe").first(where: { $0.id == id }).map(RecipeEntity.init(record:)) })'));
      expect(donate, contains(r'guard let tagsValue = AssistantValues.items(values["tags"])?.compactMap({ AssistantValues.string($0) })'));
      expect(donate, contains(
          r'intent.length = AssistantValues.double(values["length"]).map({ Measurement(value: $0, unit: UnitDuration.seconds) })'));
      expect(donate, contains('intent.who = AssistantValues.person(values["who"])'));
      expect(donate, contains('guard let whereValue = AssistantValues.place(values["where"]) else { return false }'));
      final prediction = block(swift, 'extension ShareAction: PredictableIntent {');
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension ShareAction: PredictableIntent {'));
      expect(prediction, contains(r'recipes.map(\.title).joined(separator: ", "), tags.map { $0 }.joined(separator: ", "), '
          r'length.map { $0.formatted() } ?? ""'));
    });

    test('AssistantDonations mirrors each function, defaults included', () {
      final dart = writeDart(_app(actions: [_plan(), share]));
      expect(dart, contains('static Future<bool> planMeal(a1.Recipe recipe, {Meal meal = Meal.dinner}) =>'));
      expect(dart, contains("AssistantActions.donateAction('planMeal', {'recipe': recipe.id, 'meal': AssistantValue.encodeEnum(meal)});"));
      expect(dart, contains('static Future<bool> share({required List<a1.Recipe> recipes, required List<String> tags, '
          'Duration? length, AssistantPerson? who, required AssistantPlace where}) =>'));
      expect(dart, contains("'recipes': [for (final e in recipes) e.id],"));
      expect(dart, contains("'length': AssistantValue.encodeDuration(length),"));
    });

    test('Focus filters are set by the system, so are neither donated nor predicted', () {
      final filter = _action('applyFocus', focusFilter: const FocusFilterModel(), params: [
        ParamModel(name: 'quiet', title: 'Quiet', named: true, value: const ValueType(ValueKind.boolean)),
      ]);
      final app = _app(actions: [filter]);
      expect(SwiftWriter(app).write(), isNot(contains('PredictableIntent')));
      expect(writeDart(app), isNot(contains('AssistantDonations')));
    });
  });

  group('schema entity parameters, rich @Param constraints, measurements and DynamicOptionsProvider', () {
    test('schema entity parameters work on plain actions, shortcuts, predictions and donations (including files.file)', () {
      final tasks = _tasks();
      final filesCatalog = _load('files');
      final doc = SchemaEntityModel(
        className: 'DocFile',
        library: _models,
        catalog: filesCatalog,
        schema: filesCatalog.entities['files.file']!,
        idField: 'path',
        mapping: const {},
        intents: const [],
        containers: const {},
      );
      final triage = _action(
        'triageTasks',
        dialog: 'Triaged {primary}, {optionalTask} and {docs}.',
        shortcut: const ShortcutModel(
          phrases: ['Triage {primary} in {app}'],
          shortTitle: 'Triage',
          systemImage: 'checklist',
        ),
        params: [
          ParamModel(name: 'primary', title: 'Primary', named: false, schemaEntity: tasks),
          ParamModel(name: 'optionalTask', title: 'Optional', named: true, schemaEntity: tasks, entityNullable: true),
          ParamModel(name: 'batch', title: 'Batch', named: true, schemaEntity: tasks, entityList: true),
          ParamModel(name: 'docs', title: 'Docs', named: true, schemaEntity: doc, entityList: true),
        ],
      );
      final app = _app(actions: [triage], schemaEntities: [tasks, doc]);
      final swift = SwiftWriter(app).write();
      final action = block(swift, 'public struct TriageTasksAction');
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\npublic struct TriageTasksAction'));
      expect(action, contains('public var primary: TaskItemEntity'));
      expect(action, contains('public var optionalTask: TaskItemEntity?'));
      expect(action, contains('public var batch: [TaskItemEntity]'));
      expect(action, contains('public var docs: [DocFileEntity]'));
      expect(action, contains('"primary": primary.id,'));
      expect(action, contains('"optionalTask": AssistantValues.encode(optionalTask?.id),'));
      expect(action, contains(r'"batch": batch.map(\.id),'));
      expect(action, contains(r'"docs": docs.map(\.dartID),'));
      expect(action, contains(r'\(String(localized: primary.displayRepresentation.title))'));
      expect(swift, contains('public struct TaskItemEntity {'));
      expect(swift, contains('public struct DocFileEntity {'));

      final shortcuts = writeAppShortcuts(app);
      expect(shortcuts, contains('final class AssistantActionsAppShortcuts: NSObject'));

      final dart = writeDart(app);
      expect(dart, contains('required FutureOr<a1.TaskItem?> Function(String id) findTaskItem,'));
      expect(dart, contains('required FutureOr<a1.DocFile?> Function(String id) findDocFile,'));
      expect(dart, contains("static Future<bool> triageTasks(a1.TaskItem primary, {a1.TaskItem? optionalTask, "
          'required List<a1.TaskItem> batch, required List<a1.DocFile> docs}) =>'));
      expect(dart, contains("'docs': [for (final e in docs) e.path]}"));
    });

    test('numeric ranges, controlStyle, String.IntentInputOptions and UTType file filters emit valid @Parameter', () {
      final upload = _action(
        'uploadReceipt',
        params: [
          ParamModel(
            name: 'copies',
            title: 'Copies',
            named: true,
            value: const ValueType(ValueKind.integer),
            swiftDefault: '1',
            defaultDart: '1',
            min: 1,
            max: 10,
            controlStyle: ControlStyleModel.stepper,
          ),
          ParamModel(
            name: 'opacity',
            title: 'Opacity',
            named: true,
            value: const ValueType(ValueKind.decimal),
            min: 0,
            max: 1,
            controlStyle: ControlStyleModel.slider,
          ),
          ParamModel(
            name: 'note',
            title: 'Note',
            named: true,
            value: const ValueType(ValueKind.string),
            multiline: true,
            capitalization: CapitalizationModel.sentences,
            keyboardType: KeyboardTypeModel.url,
          ),
          ParamModel(
            name: 'attachments',
            title: 'Attachments',
            named: true,
            value: const ValueType(ValueKind.file, list: true),
            supportedContentTypes: const ['public.image', 'com.adobe.pdf'],
          ),
        ],
      );
      final swift = SwiftWriter(_app(actions: [upload])).write();
      expect(swift, contains('import UniformTypeIdentifiers\n'));
      expect(swift, contains('@available(iOS 18.0, macOS 15.0, *)\npublic struct UploadReceiptAction'));
      final body = block(swift, 'public struct UploadReceiptAction');
      expect(
          body,
          contains('@Parameter(title: "Copies", default: 1, controlStyle: .stepper, inclusiveRange: (1, 10))\n'
              '  public var copies: Int'));
      expect(
          body,
          contains('@Parameter(title: "Opacity", controlStyle: .slider, inclusiveRange: (0.0, 1.0))\n'
              '  public var opacity: Double'));
      expect(
          body,
          contains('@Parameter(title: "Note", inputOptions: String.IntentInputOptions('
              'keyboardType: .URL, capitalizationType: .sentences, multiline: true))\n'
              '  public var note: String'));
      expect(
          body,
          contains('@Parameter(title: "Attachments", supportedContentTypes: ['
              'UTType("public.image") ?? .item, UTType("com.adobe.pdf") ?? .item])\n'
              '  public var attachments: [IntentFile]'));
    });

    test('currency and all 6 Measurement wrappers work across parameters, results, dialogs, predictions and donations', () {
      final logWorkout = _action(
        'logWorkout',
        dialog: 'Logged {distance} for {cost}.',
        result: const ResultModel(value: ValueType(ValueKind.currency), wrapped: true),
        params: [
          ParamModel(name: 'cost', title: 'Cost', named: true, value: const ValueType(ValueKind.currency)),
          ParamModel(name: 'distance', title: 'Distance', named: true, value: const ValueType(ValueKind.length)),
          ParamModel(name: 'weight', title: 'Weight', named: true, value: const ValueType(ValueKind.mass)),
          ParamModel(name: 'temp', title: 'Temp', named: true, value: const ValueType(ValueKind.temperature)),
          ParamModel(name: 'water', title: 'Water', named: true, value: const ValueType(ValueKind.volume)),
          ParamModel(name: 'pace', title: 'Pace', named: true, value: const ValueType(ValueKind.speed)),
          ParamModel(name: 'burn', title: 'Burn', named: true, value: const ValueType(ValueKind.energy)),
        ],
      );
      final app = _app(actions: [logWorkout]);
      final swift = SwiftWriter(app).write();
      final body = block(swift, 'public struct LogWorkoutAction');
      expect(body, contains('ReturnsValue<IntentCurrencyAmount>'));
      expect(body, contains('public var cost: IntentCurrencyAmount'));
      expect(body, contains('public var distance: Measurement<UnitLength>'));
      expect(body, contains('public var weight: Measurement<UnitMass>'));
      expect(body, contains('public var temp: Measurement<UnitTemperature>'));
      expect(body, contains('public var water: Measurement<UnitVolume>'));
      expect(body, contains('public var pace: Measurement<UnitSpeed>'));
      expect(body, contains('public var burn: Measurement<UnitEnergy>'));
      expect(body, contains(r'Logged \(distance.formatted()) for \(cost.amount.formatted(.currency(code: cost.currencyCode))).'));
      expect(body, contains('guard let value = AssistantValues.currency(result.value) else'));

      final dart = writeDart(app);
      expect(dart, contains("AssistantValue.currency(args['cost'])"));
      expect(dart, contains("AssistantValue.length(args['distance'])"));
      expect(dart, contains("AssistantValue.mass(args['weight'])"));
      expect(dart, contains("AssistantValue.temperature(args['temp'])"));
      expect(dart, contains("AssistantValue.volume(args['water'])"));
      expect(dart, contains("AssistantValue.speed(args['pace'])"));
      expect(dart, contains("AssistantValue.energy(args['burn'])"));
      expect(dart, contains("'cost': AssistantValue.encodeCurrency(cost)"));
      expect(dart, contains("'burn': AssistantValue.encodeEnergy(burn)"));
    });

    test('DynamicOptionsProvider wires Dart options functions, dependencies, defaultResult and snapshot fallbacks', () {
      final pick = _action(
        'pickDish',
        params: [
          ParamModel(name: 'cuisine', title: 'Cuisine', named: true, value: const ValueType(ValueKind.string)),
          ParamModel(
            name: 'tag',
            title: 'Tag',
            named: true,
            value: const ValueType(ValueKind.string),
            swiftDefault: '"quick"',
            defaultDart: "'quick'",
            options: ParamOptionsModel(
              functionName: 'suggestTags',
              library: _lib,
              dependencies: const [OptionsDependency(name: 'cuisine', named: false)],
              snapshotCollection: 'Recipe',
              snapshotField: 'title',
            ),
          ),
          ParamModel(
            name: 'dish',
            title: 'Dish',
            named: true,
            entity: _recipe,
            options: ParamOptionsModel(
              functionName: 'suggestDishes',
              library: _lib,
              dependencies: const [OptionsDependency(name: 'cuisine', named: true, nullable: true)],
            ),
          ),
        ],
      );
      final app = _app(actions: [pick]);
      final swift = SwiftWriter(app).write();
      final action = block(swift, 'public struct PickDishAction');
      expect(action, contains('@Parameter(title: "Tag", optionsProvider: PickDishActionTagOptionsProvider())\n  public var tag: String'));
      expect(action, isNot(contains('default: "quick"')), reason: 'default moves onto DynamicOptionsProvider.defaultResult()');

      final tagProvider = block(swift, 'public struct PickDishActionTagOptionsProvider: DynamicOptionsProvider');
      expect(tagProvider, contains(r'@IntentParameterDependency<PickDishAction>(\.$cuisine)'));
      expect(tagProvider, contains('public func defaultResult() async -> String? { "quick" }'));
      expect(tagProvider, contains('if let v = intent?.cuisine { args["cuisine"] = AssistantValues.encode(v) }'));
      expect(tagProvider, contains('perform("options.pickDish.tag", args: args)'));
      expect(tagProvider, contains('for record in AssistantSnapshot.records("Recipe")'));

      final dishProvider = block(swift, 'public struct PickDishActionDishOptionsProvider: DynamicOptionsProvider');
      expect(dishProvider, contains('return AssistantSnapshot.records("Recipe").map(RecipeEntity.init(record:))'));

      // Donating an action requires guard-decoding parameters backed by a DynamicOptionsProvider.
      final donate = block(swift, '  private static func donateAction(');
      expect(donate, contains('guard let tagValue = AssistantValues.string(values["tag"]) else { return false }'));
      expect(donate, contains('intent.tag = tagValue'));

      final dart = writeDart(app);
      expect(dart, contains("'options.pickDish.tag': (args) async {"));
      expect(dart, contains('jsonEncode((await a0.suggestTags(_cuisine)).toList())'));
      expect(dart, contains("'options.pickDish.dish': (args) async {"));
      expect(dart, contains('[for (final e in await a0.suggestDishes(cuisine: _cuisine)) e.id]'));
    });
  });

  group('ModelReader end-to-end & xcrun swiftc -typecheck', () {
    test('reads all 5 new features from Dart source and typechecks generated Dart & Swift', () async {
      final (dart, swift, shortcuts) = await _readAndGenerate(analyzeGenerated: true, '''
@AssistantActionsApp(name: 'Mira')
library;

import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/journal.dart';

@AssistantEnum(title: 'Brew Size')
enum BrewSize {
  @CaseTitle('Small')
  small,
  @CaseTitle('Large')
  large,
}

@AssistantEntity(title: 'Recipe')
class Recipe {
  const Recipe({required this.id, required this.name, this.featured = false});
  @EntityId()
  final String id;
  @DisplayTitle()
  final String name;
  final bool featured;
}

@JournalEntry()
class TaskItem {
  const TaskItem({required this.id, required this.title, required this.text, this.done = false});
  @EntityId()
  final String id;
  @JournalEntryField.title
  final String? title;
  @JournalEntryField.message
  final String text;
  final bool done;
}

Future<List<String>> loadTags(String category) async => [category];
Future<List<TaskItem>> loadOpenTasks({String? category}) async => const [];
Future<List<Recipe>> loadFeaturedRecipes() async => const [];

@AssistantBackground()
Future<AssistantActionsRegistry> initBackground() async => throw UnimplementedError();

@AssistantAction(
  title: 'Smart Brew',
  runs: Runs.withFlutter,
  cardButtons: true,
  summaries: [
    SummaryWhen('iced', value: true, then: 'Brew iced {category} ({size})'),
    SummaryWhen(
      'shots',
      comparison: SummaryComparison.greaterThan,
      value: 2,
      then: 'Brew strong {category} ({size})',
      otherwise: 'Brew hot {category} ({size})',
    ),
  ],
)
Future<AssistantReply> smartBrew({
  required TaskItem task,
  List<TaskItem> extraTasks = const [],
  List<Recipe> extraRecipes = const [],
  @Param(multiline: true, capitalization: TextCapitalizationMode.sentences, keyboardType: ParamKeyboardType.url)
  required String category,
  @Param(options: loadTags, snapshotField: 'Recipe.title')
  String tag = 'morning',
  @Param(options: loadOpenTasks)
  TaskItem? linkedTask,
  @Param(options: loadFeaturedRecipes, snapshotField: 'featured')
  Recipe? recipe,
  @Param(min: 1, max: 5, controlStyle: ParamControlStyle.stepper)
  int shots = 2,
  @Param(min: 0.0, max: 1.0, controlStyle: ParamControlStyle.slider)
  double strength = 0.5,
  @Param(supportedContentTypes: ['public.image', 'com.adobe.pdf'])
  AssistantFile? attachment,
  AssistantCurrency budget = const AssistantCurrency(amount: 4.5, currencyCode: 'USD'),
  AssistantLength distance = const AssistantLength.kilometers(1.5),
  AssistantMass beans = const AssistantMass.grams(18),
  AssistantTemperature waterTemp = const AssistantTemperature.celsius(93),
  AssistantVolume cupVolume = const AssistantVolume.milliliters(250),
  AssistantSpeed pourSpeed = const AssistantSpeed(value: 1.2, unit: SpeedUnit.metersPerSecond),
  AssistantEnergy calories = const AssistantEnergy.kilocalories(15),
  BrewSize size = BrewSize.small,
  bool iced = false,
}) async => const AssistantReply(
  dialog: 'Brewed.',
  card: AssistantCard(
    title: 'Brew Ready',
    imageUrl: 'https://example.com/coffee.png',
    toggles: [AssistantCardToggle(label: 'Done', value: false, actionId: 'smartBrew')],
  ),
);

@AssistantAction(
  title: 'Size Switch',
  runs: Runs.withFlutter,
  shortcut: AppShortcut(
    phrases: ['Quick brew {task} in {app}'],
    shortTitle: 'Quick Brew',
    systemImage: 'cup.and.saucer',
  ),
  summaries: [
    SummaryWhen('iced', value: true, then: 'Iced brew {size} for {task}'),
    SummarySwitch(
      'size',
      cases: {BrewSize.large: 'Brew a large cup for {task}'},
      defaultSummary: 'Brew {size} for {task}',
    ),
  ],
)
Future<AssistantCurrency> quickBrew(TaskItem task, {BrewSize size = BrewSize.small, bool iced = false}) async =>
    const AssistantCurrency(amount: 3.0, currencyCode: 'USD');

@AssistantAction(
  title: 'Exhaustive Size Switch',
  runs: Runs.withFlutter,
  summaries: [
    SummarySwitch(
      'size',
      cases: {
        BrewSize.small: 'Brew a small cup for {task}',
        BrewSize.large: 'Brew a large cup for {task}',
      },
    ),
  ],
)
Future<void> brewBySize(TaskItem task, {BrewSize size = BrewSize.small}) async {}

@AssistantFocusFilter(title: 'Task Focus', summary: 'Focus on {tasks}')
Future<void> applyTaskFocus({List<TaskItem> tasks = const []}) async {}
''');

      expect(dart, contains('List<a0.TaskItem> extraTasks = const []'));
      expect(dart, contains("const AssistantCurrency(amount: 4.5, currencyCode: 'USD')"));
      expect(dart, contains('const AssistantLength(value: 1.5, unit: LengthUnit.kilometers)'));
      expect(dart, contains("'options.smartBrew.tag': (args) async {"));
      expect(dart, contains("'options.smartBrew.linkedTask': (args) async {"));
      expect(swift, contains(r'When(\Self.$iced, .equalTo, true, {'));
      expect(swift, contains(r'When(\Self.$shots, .greaterThan, 2, {'));
      expect(swift, contains(r'Switch(\.$size) {'));
      expect(swift, contains('DefaultCase {'));
      expect(swift, contains(r'AssistantCardButtonIntent($0, card: id)'));

      if (Platform.isMacOS) {
        _typecheckSwift(swift, shortcuts);
      }
    });

    test('ModelReader rejects invalid @Param constraints, option cycles and invalid conditional summaries', () async {
      Future<void> expectInvalid(String body, String messagePart) async {
        await expectLater(
          () => _readAndGenerate('''
import 'package:assistant_actions/assistant_actions.dart';
@AssistantActionsApp(name: 'Mira')
library;
$body
'''),
          throwsA(isA<InvalidGenerationSourceError>().having((e) => e.message, 'message', contains(messagePart))),
        );
      }

      await expectInvalid('''
@AssistantAction(title: 'Bad')
Future<void> bad(@Param(controlStyle: ParamControlStyle.slider) int count) async {}
''', 'ParamControlStyle.slider is only supported on double');

      await expectInvalid('''
@AssistantAction(title: 'Bad')
Future<void> bad(@Param(min: 10, max: 5) int count) async {}
''', 'min (10) must be <= max (5)');

      await expectInvalid('''
@AssistantAction(title: 'Bad')
Future<void> bad({@Param(min: 1, max: 5) int count = 9}) async {}
''', 'outside [1, 5]');

      await expectInvalid('''
@AssistantAction(title: 'Bad')
Future<void> bad(@Param(multiline: true) int count) async {}
''', 'only supported on String');

      await expectInvalid('''
@AssistantAction(title: 'Bad')
Future<void> bad(@Param(supportedContentTypes: ['public.image']) String path) async {}
''', 'only supported on AssistantFile');

      await expectInvalid('''
Future<List<String>> optA(String b) async => [b];
Future<List<String>> optB(String a) async => [a];
@AssistantAction(title: 'Bad')
Future<void> bad(@Param(options: optA) String a, @Param(options: optB) String b) async {}
''', 'circular @Param(options:) parameter dependency');

      await expectInvalid('''
@AssistantAction(
  title: 'Bad',
  summary: 'Do {x}',
  summaries: [SummaryWhen('x', comparison: SummaryComparison.hasAnyValue, then: 'Do {x}', otherwise: 'Do')],
)
Future<void> bad(String? x) async {}
''', 'set either summary or SummaryWhen.otherwise, not both');

      await expectInvalid('''
@AssistantAction(
  title: 'Bad',
  summaries: [SummarySwitch('x', cases: {})],
)
Future<void> bad(String x) async {}
''', 'requires an enum parameter');

      await expectInvalid('''
@AssistantEnum(title: 'Mode')
enum Mode {
  @CaseTitle('Fast')
  fast,
  @CaseTitle('Slow')
  slow,
}
@AssistantAction(
  title: 'Bad',
  summaries: [SummarySwitch('x', cases: {Mode.fast: 'Fast', Mode.slow: 'Slow'})],
)
Future<void> bad(Mode? x) async {}
''', 'omits cases of Mode?');
    });
  });

  group('FoundationModels.Tool bridging', () {
    test('generates @Generable Arguments, @Guide descriptions, enum wrappers and entity lookup', () {
      final customPrompt = _action(
        'tagRecipes',
        params: [
          ParamModel(name: 'recipes', title: 'Recipes', prompt: 'Which recipes to tag', named: true, entity: _recipe, entityList: true),
          ParamModel(name: 'tags', title: 'Tags', named: true, value: const ValueType(ValueKind.string, list: true)),
          ParamModel(name: 'servings', title: 'Servings', named: true, value: const ValueType(ValueKind.integer, nullable: true)),
        ],
      );
      final swift = SwiftWriter(_app(actions: [_plan(), customPrompt])).write();
      expect(swift, contains('#if canImport(FoundationModels)\n  import FoundationModels\n#endif'));
      expect(swift, contains('#if canImport(FoundationModels)\n@available(iOS 26.0, macOS 26.0, *)\n@Generable\n'
          'public enum MealEnumToolValue: String, Sendable {\n  case dinner\n  case snack\n}'));
      expect(swift, contains('private func assistantResolveEntity<E>('));

      final planTool = block(swift, 'public struct PlanMealActionTool: FoundationModels.Tool');
      expect(planTool, contains('public let name = "planMeal"'));
      expect(planTool, contains('public let description = "planMeal"'));
      expect(planTool, contains('@Generable\n  public struct Arguments: Sendable {'));
      expect(planTool, contains('@Guide(description: "Recipe (ID or title)")\n    public var recipe: String'));
      expect(planTool, contains('@Guide(description: "Meal")\n    public var meal: MealEnumToolValue?'));
      expect(planTool, contains(
          'let recipe = try assistantResolveEntity(toolArguments.recipe, collection: "Recipe", '
          'typeWords: RecipeEntityQuery.typeWords, make: RecipeEntity.init(record:))'));
      expect(planTool, contains('let meal: MealEnum = toolArguments.meal.flatMap { MealEnum(rawValue: \$0.rawValue) } ?? .dinner'));
      expect(planTool, contains('AssistantInbox.call("planMeal", args: toolPayload)'));
      expect(planTool, contains('return fallbackDialog'));

      final tagTool = block(swift, 'public struct TagRecipesActionTool: FoundationModels.Tool');
      expect(tagTool, contains('@Guide(description: "Which recipes to tag")\n    public var recipes: [String]'));
      expect(tagTool, contains('@Guide(description: "Tags")\n    public var tags: [String]'));
      expect(tagTool, contains('@Guide(description: "Servings")\n    public var servings: Int?'));
    });

    test('formats scalar results, entity results and AssistantReply cards as clean Strings', () {
      final app = _app(actions: [
        _action('count', result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
        _action('quickest', result: ResultModel(entity: _recipe, nullable: true)),
        _action('pick', reply: true, result: ResultModel(entity: _recipe, wrapped: true)),
      ]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('private func assistantDescribeToolValue(_ value: Any?) -> String?'));
      final countTool = block(swift, 'public struct CountActionTool: FoundationModels.Tool');
      expect(countTool, contains('let valueText = assistantDescribeToolValue(result.value)'));
      final quickestTool = block(swift, 'public struct QuickestActionTool: FoundationModels.Tool');
      expect(quickestTool, contains('let value = try await RecipeEntityQuery().entities(for: ids).first'));
      expect(quickestTool, contains('let valueText: String? = value.map { String(localized: \$0.displayRepresentation.title) }'));
      final pickTool = block(swift, 'public struct PickActionTool: FoundationModels.Tool');
      expect(pickTool, contains('let reply = AssistantReply(json: rawReply)'));
      expect(pickTool, contains('if let card = reply.card {'));
      expect(pickTool, contains(r'for row in card.rows { parts.append("\(row.label): \(row.value)") }'));
    });

    test('bridges SnapshotAnswer actions and registers discoverable tools in AssistantFoundationTools.all', () {
      final showTasks = SnapshotActionModel(
        name: 'showTasks',
        title: 'Show Tasks',
        description: 'Lists open tasks.',
        collection: 'Recipe',
        fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
        where: const {},
        filters: const [SnapshotFilterModel('minutes', SnapshotFilterOp.lessOrEqual, '30')],
        limit: 5,
        item: '{title}',
        dialog: 'You have {count} quick recipes.',
        empty: 'No quick recipes.',
        separator: ', ',
      );
      final inlineItems = SnapshotActionModel(
        name: 'inlineTasks',
        title: 'Inline Tasks',
        collection: 'Recipe',
        fields: const [],
        where: const {},
        limit: 5,
        item: '{title}',
        dialog: 'Recipes: {items}.',
        empty: 'None.',
        separator: ', ',
      );
      final hiddenSnapshot = SnapshotActionModel(
        name: 'secretSnapshot',
        title: 'Secret Snapshot',
        isDiscoverable: false,
        collection: 'Recipe',
        fields: const [],
        where: const {},
        limit: 5,
        item: '{title}',
        dialog: '{items}',
        empty: 'None.',
        separator: ', ',
      );
      final app = _app(
        actions: [
          _plan(),
          _action('secret', discoverable: false),
          _action('focus', focusFilter: const FocusFilterModel(), params: [
            ParamModel(name: 'quiet', title: 'Quiet', named: true, value: const ValueType(ValueKind.boolean)),
          ]),
          _action('locate', params: [
            ParamModel(name: 'where', title: 'Where', named: true, value: const ValueType(ValueKind.place)),
          ]),
          _action('schedule', params: [
            ParamModel(name: 'when', title: 'When', named: true, value: const ValueType(ValueKind.dateTime)),
          ]),
        ],
        snapshotActions: [showTasks, inlineItems, hiddenSnapshot],
      );
      final swift = SwiftWriter(app).write();
      final showTool = block(swift, 'public struct ShowTasksActionTool: FoundationModels.Tool');
      expect(showTool, contains('public let name = "showTasks"'));
      expect(showTool, contains('public let description = "Lists open tasks."'));
      expect(showTool, contains('@Generable\n  public struct Arguments: Sendable {\n    public init() {}\n  }'));
      expect(showTool, contains('filters: [.lessOrEqual("minutes", 30)]'));
      expect(showTool,
          contains(r'return answer.items.isEmpty ? answer.dialog : ([answer.dialog] + answer.items).joined(separator: "\n")'));

      final inlineTool = block(swift, 'public struct InlineTasksActionTool: FoundationModels.Tool');
      expect(inlineTool, contains('return answer.dialog'));

      expect(swift, isNot(contains('SecretActionTool')));
      expect(swift, isNot(contains('FocusFocusFilterTool')));
      expect(swift, isNot(contains('LocateActionTool')));
      expect(swift, isNot(contains('ScheduleActionTool')));
      expect(swift, isNot(contains('SecretSnapshotActionTool')));

      final catalog = block(swift, 'public enum AssistantFoundationTools');
      expect(catalog, contains('PlanMealActionTool(),'));
      expect(catalog, contains('ShowTasksActionTool(),'));
      expect(catalog, contains('InlineTasksActionTool(),'));
    });
  });
}

class _FakeBuildStep implements BuildStep {
  @override
  Future<bool> canRead(AssetId id) async =>
      id.package == 'assistant_actions' && File('../assistant_actions/${id.path}').existsSync();

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async =>
      File('../assistant_actions/${id.path}').readAsStringSync(encoding: encoding);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(String dart, String swift, String shortcuts)> _readAndGenerate(String source, {bool analyzeGenerated = false}) async {
  final dir = Directory.systemTemp.createTempSync('assistant_actions_reader_test_');
  try {
    final pkgConfig = jsonDecode(File('../assistant_actions/.dart_tool/package_config.json').readAsStringSync())
        as Map<String, Object?>;
    final packages = (pkgConfig['packages'] as List).cast<Map<String, Object?>>().map((p) {
      if (p['name'] == 'assistant_actions') {
        return {
          ...p,
          'rootUri': Directory('../assistant_actions').absolute.uri.toString(),
        };
      }
      return p;
    }).toList()
      ..add({
        'name': 'app',
        'rootUri': dir.absolute.uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.6',
      });
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: app\nenvironment:\n  sdk: ^3.6.0\n');
    final dartTool = Directory('${dir.path}/.dart_tool')..createSync(recursive: true);
    File('${dartTool.path}/package_config.json').writeAsStringSync(jsonEncode({...pkgConfig, 'packages': packages}));
    final libDir = Directory('${dir.path}/lib')..createSync(recursive: true);
    final entry = File('${libDir.path}/assistant_actions.dart')..writeAsStringSync(source);

    final collection = AnalysisContextCollection(includedPaths: [dir.absolute.path]);
    final context = collection.contextFor(entry.absolute.path);
    final resolved = await context.currentSession.getResolvedLibrary(entry.absolute.path);
    if (resolved is! ResolvedLibraryResult) {
      throw StateError('Failed to resolve test library: $resolved');
    }
    final model = (await ModelReader(_FakeBuildStep()).read(resolved.element))!;
    final dartOut = writeDart(model);
    if (analyzeGenerated) {
      final genFile = File('${libDir.path}/assistant_actions.g.dart')..writeAsStringSync(dartOut);
      final genCollection = AnalysisContextCollection(includedPaths: [dir.absolute.path]);
      final errRes = await genCollection.contextFor(genFile.absolute.path).currentSession.getErrors(genFile.absolute.path);
      if (errRes is! ErrorsResult) {
        throw StateError('Failed to analyze generated file: $errRes');
      }
      // Note: generated file starts with `// ignore_for_file: type=lint`, so any error/warning here is a real compile/type error.
      final severe = errRes.diagnostics
          .where((e) => !e.diagnosticCode.lowerCaseName.contains('uri_does_not_exist'))
          .toList();
      expect(severe, isEmpty, reason: 'assistant_actions.g.dart failed analyzer:\n${severe.join('\n')}\n--- DART ---\n$dartOut');

      final flutterAnalyze = Process.runSync('flutter', ['analyze', '--no-pub'], workingDirectory: dir.path);
      expect(flutterAnalyze.exitCode, 0,
          reason: 'flutter analyze failed on generated assistant_actions.g.dart:\n${flutterAnalyze.stdout}\n${flutterAnalyze.stderr}\n--- DART ---\n$dartOut');
    }
    return (dartOut, SwiftWriter(model).write(), writeAppShortcuts(model));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _typecheckSwift(String generatedSwift, String generatedShortcuts) {
  final out = Directory.systemTemp.createTempSync('assistant_actions_swiftc_test_');
  try {
    final runtimeDir = Directory('../assistant_actions/darwin/assistant_actions/Sources/assistant_actions').absolute.path;
    const runtimeFiles = [
      'AssistantAppGroup.swift',
      'AssistantValues.swift',
      'AssistantInbox.swift',
      'AssistantSnapshot.swift',
      'AssistantQuery.swift',
      'AssistantSpotlight.swift',
      'AssistantMatch.swift',
      'AssistantComparison.swift',
      'AssistantRichValues.swift',
      'AssistantHostCalls.swift',
      'AssistantReply.swift',
      'AssistantDialog.swift',
      'AssistantInteraction.swift',
      'AssistantCardView.swift',
      'AssistantCardStore.swift',
      'AssistantActivityAttributes.swift',
      'AssistantLiveActivityIntent.swift',
      'AssistantLiveActivities.swift',
      'AssistantShortcutParameters.swift',
      'AssistantBridge.swift',
      'AssistantApi.g.swift',
      'AssistantBackground.swift',
      'AssistantLiveCall.swift',
      'AssistantLiveIntents.swift',
      'AssistantFileIDs.swift',
      'AssistantUndo.swift',
      'AssistantContext.swift',
      'AssistantVisualIntelligence.swift',
      'AssistantPlatformViews.swift',
    ];
    final appSwiftFile = File('${out.path}/AssistantActions.g.swift')..writeAsStringSync(generatedSwift);
    final shortcutsFile = File('${out.path}/AssistantShortcuts.g.swift')..writeAsStringSync(generatedShortcuts);

    for (final (sdk, libTarget, appTarget) in const [
      ('macosx', 'arm64-apple-macosx14.0', 'arm64-apple-macosx14.4'),
      ('iphonesimulator', 'arm64-apple-ios17.0-simulator', 'arm64-apple-ios17.4-simulator'),
    ]) {
      final sdkOut = Directory('${out.path}/$sdk')..createSync(recursive: true);

      // 1. Emit the assistant_actions runtime swiftmodule.
      final runtimeRes = Process.runSync('xcrun', [
        '--sdk',
        sdk,
        'swiftc',
        '-emit-module',
        '-module-name',
        'assistant_actions',
        '-target',
        libTarget,
        '-emit-module-path',
        '${sdkOut.path}/assistant_actions.swiftmodule',
        for (final f in runtimeFiles) '$runtimeDir/$f',
      ]);
      expect(runtimeRes.exitCode, 0, reason: '[$sdk] runtime swiftmodule failed:\n${runtimeRes.stderr}');

      // 2. Typecheck & emit assistant_actions_app swiftmodule from generated AssistantActions.g.swift.
      final appRes = Process.runSync('xcrun', [
        '--sdk',
        sdk,
        'swiftc',
        '-emit-module',
        '-module-name',
        'assistant_actions_app',
        '-target',
        libTarget,
        '-I',
        sdkOut.path,
        '-emit-module-path',
        '${sdkOut.path}/assistant_actions_app.swiftmodule',
        appSwiftFile.path,
      ]);
      expect(
        appRes.exitCode,
        0,
        reason: '[$sdk] AssistantActions.g.swift failed swiftc:\n${appRes.stderr}\n--- SWIFT ---\n$generatedSwift',
      );

      // 3. Typecheck generated AssistantShortcuts.g.swift against assistant_actions_app.
      final shortcutsRes = Process.runSync('xcrun', [
        '--sdk',
        sdk,
        'swiftc',
        '-typecheck',
        '-module-name',
        'Runner',
        '-target',
        appTarget,
        '-I',
        sdkOut.path,
        shortcutsFile.path,
      ]);
      expect(
        shortcutsRes.exitCode,
        0,
        reason: '[$sdk] AssistantShortcuts.g.swift failed swiftc:\n${shortcutsRes.stderr}\n--- SHORTCUTS ---\n$generatedShortcuts',
      );
    }
  } finally {
    out.deleteSync(recursive: true);
  }
}
