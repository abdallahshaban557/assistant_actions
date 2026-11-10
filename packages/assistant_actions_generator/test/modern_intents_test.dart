// Newer App Intents protocols: SyncableEntity, IndexedEntityQuery,
// UndoableIntent, live calls (progress, cancellation, long-running), the
// foreground path without ForegroundContinuableIntent from iOS 26 / macOS 26,
// and file entities (files.file).
import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

SchemaEntityModel _adopt(
  String id,
  Map<String, FieldModel> mapping, {
  required String className,
  bool? syncable,
  bool undoable = false,
  bool longRunning = false,
  Map<String, FixedInstance> containers = const {},
}) {
  final catalog = _load(id.split('.').first);
  final schema = catalog.entities[id]!;
  return SchemaEntityModel(
    className: className,
    library: Uri.parse('package:app/models.dart'),
    catalog: catalog,
    schema: schema,
    idField: 'id',
    mapping: mapping,
    intents: catalog.intentsFor(schema),
    containers: containers,
    syncableOverride: syncable,
    undoable: undoable,
    longRunning: longRunning,
  );
}

SchemaEntityModel _task({bool? syncable, bool undoable = false}) => _adopt(
      'reminders.reminder',
      const {
        'title': FieldModel('title', ValueType(ValueKind.string)),
        'dueDate': FieldModel('due', ValueType(ValueKind.dateTime, nullable: true)),
      },
      className: 'TaskItem',
      syncable: syncable,
      undoable: undoable,
      containers: {
        'list': const FixedInstance(schema: 'reminders.list', id: 'tasks', strings: {'name': 'Tasks'}, nested: {}),
      },
    );

SchemaEntityModel _note({bool? syncable}) => _adopt(
      'notes.note',
      const {'name': FieldModel('text', ValueType(ValueKind.string))},
      className: 'MemoryItem',
      syncable: syncable,
      containers: {
        'folder': const FixedInstance(schema: 'notes.folder', id: 'f', strings: {'name': 'F'}, nested: {
          'account': FixedInstance(schema: 'notes.account', id: 'a', strings: {'name': 'A'}, nested: {}),
        }),
      },
    );

SchemaEntityModel _timer({bool undoable = false, bool longRunning = false}) => _adopt(
      'clock.timer',
      const {
        'duration': FieldModel('length', ValueType(ValueKind.duration)),
        'durationRemaining': FieldModel('left', ValueType(ValueKind.duration)),
        'state': FieldModel('state', ValueType(ValueKind.enumeration, enumRef: 'clock.timerState')),
      },
      className: 'Countdown',
      undoable: undoable,
      longRunning: longRunning,
    );

SchemaEntityModel _doc() => _adopt(
      'files.file',
      const {'creationDate': FieldModel('created', ValueType(ValueKind.dateTime, nullable: true))},
      className: 'DocItem',
    );

ActionModel _live({bool longRunning = false}) => ActionModel(
      functionName: 'countTasks',
      library: Uri.parse('package:app/actions.dart'),
      title: 'Count Tasks',
      runs: RunsModel.withFlutter,
      params: const [],
      returnsString: true,
      longRunning: longRunning,
    );

AppModel _app({
  List<SchemaEntityModel> schemaEntities = const [],
  List<ActionModel> actions = const [],
  List<SchemaDomainModel> domains = const [],
  List<EntityModel> entities = const [],
  DeploymentTarget deployment = DeploymentTarget.minimum,
  bool background = false,
}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: entities,
      schemaEntities: schemaEntities,
      schemaDomains: domains,
      catalogs: {for (final d in ['reminders', 'notes', 'clock', 'files', 'camera', 'system']) d: _load(d)},
      deployment: deployment,
      background: background
          ? BackgroundModel(
              functionName: 'backgroundRegistry',
              library: Uri.parse('package:app/main.dart'),
              entrypointLibrary: Uri.parse('package:app/assistant_actions.g.dart'))
          : null,
    );

String _block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

void main() {
  group('SyncableEntity', () {
    test('schema entities Apple makes syncable are, unless the class opts out', () {
      expect(_load('notes').entities['notes.note']!.isSyncable, isTrue);
      expect(_load('reminders').entities['reminders.reminder']!.isSyncable, isFalse);
      final swift = SwiftWriter(_app(schemaEntities: [_note()])).write();
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\nextension MemoryItemEntity: SyncableEntity {}'));
      expect(SwiftWriter(_app(schemaEntities: [_note(syncable: false)])).write(), isNot(contains('SyncableEntity')));
    });

    test('@AssistantSyncable() opts other entities in, keeping their String ids', () {
      expect(SwiftWriter(_app(schemaEntities: [_task()])).write(), isNot(contains('SyncableEntity')));
      final swift = SwiftWriter(_app(schemaEntities: [_task(syncable: true)])).write();
      expect(swift, contains('extension TaskItemEntity: SyncableEntity {}'));
      expect(_block(swift, 'struct TaskItemEntity {'), contains('  let id: String\n'));
      final plain = EntityModel(
          className: 'Recipe',
          library: Uri.parse('package:app/models.dart'),
          title: 'Recipe',
          idField: 'id',
          titleGetter: 'name',
          fields: const [],
          syncable: true);
      expect(SwiftWriter(_app(entities: [plain])).write(), contains('extension RecipeEntity: SyncableEntity {}'));
    });

    test('syncable containers can still be fixed instances', () {
      final notes = _load('notes');
      expect(notes.entities['notes.folder']!.isSyncable, isTrue);
      expect(notes.isFixable(notes.entities['notes.folder']!), isTrue);
    });
  });

  test('every entity query is an IndexedEntityQuery from iOS 27', () {
    final swift = SwiftWriter(_app(schemaEntities: [_task()])).write();
    expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\nextension TaskItemEntityQuery: IndexedEntityQuery {'));
    expect(swift, contains('func reindexEntities(for identifiers: [TaskItemEntity.ID], indexDescription: CSSearchableIndexDescription)'));
    expect(swift, contains('try await CSSearchableIndex.default().indexAppEntities(try await allEntities())'));
  });

  group('foreground continuation', () {
    test('below iOS 26 live intents continue in the foreground the old way', () {
      final swift = SwiftWriter(_app(actions: [_live()])).write();
      final action = _block(swift, 'public struct CountTasksAction');
      expect(action, contains('public struct CountTasksAction: AppIntent, ForegroundContinuableIntent {'));
      expect(action, contains('try await requestToContinueInForeground()'));
      expect(action, isNot(contains('supportedModes')));
    });

    test('from iOS 26 / macOS 26 they declare .foreground(.dynamic) instead', () {
      const at26 = DeploymentTarget(iOS: 26, macOS: 26);
      final swift = SwiftWriter(_app(actions: [_live()], schemaEntities: [_timer()], deployment: at26)).write();
      expect(swift, isNot(contains('ForegroundContinuableIntent')));
      expect(swift, isNot(contains('requestToContinueInForeground')));
      final action = _block(swift, 'public struct CountTasksAction');
      expect(action, contains('public struct CountTasksAction: AppIntent {'));
      expect(action, contains('  public static let supportedModes: IntentModes = .foreground(.dynamic)\n'));
      expect(action, contains('try await continueInForeground(alwaysConfirm: false)'));
    });

    test('intents that open the app use .foreground from 26', () {
      final camera = _load('camera');
      final domain = SchemaDomainModel(className: 'Camera', catalog: camera, intents: [camera.intents['camera.startCapture']!]);
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [domain],
        catalogs: {'camera': camera},
        openEnums: {
          for (final id in ['camera.captureMode', 'camera.captureDevice', 'camera.captureDuration'])
            id: OpenEnumModel(schema: id, className: 'E', library: Uri.parse('package:app/e.dart'), cases: const ['a']),
        },
        deployment: const DeploymentTarget(iOS: 26, macOS: 26),
      );
      final start = _block(SwiftWriter(app).write(), 'struct CameraStartCaptureIntent');
      expect(start, contains('struct CameraStartCaptureIntent {\n  static let supportedModes: IntentModes = .foreground\n'));
      expect(start, isNot(contains('NSApplication.shared.activate()')), reason: 'the system brings the app forward');
      expect(start, isNot(contains('continueInForeground')));
    });

    test('with only iOS at 26, macOS keeps ForegroundContinuableIntent in an extension', () {
      final swift = SwiftWriter(_app(actions: [_live()], deployment: const DeploymentTarget(iOS: 26, macOS: 14))).write();
      final action = _block(swift, 'public struct CountTasksAction');
      expect(action, contains('public struct CountTasksAction: AppIntent {'));
      expect(action, contains('  #if os(iOS)\n  public static let supportedModes: IntentModes = .foreground(.dynamic)\n  #endif\n'));
      expect(swift, contains('#if os(macOS)\nextension CountTasksAction: ForegroundContinuableIntent {}\n#endif\n'));
    });

    test('with background execution: [.background, .foreground(.dynamic)], from 26 without the old conformance', () {
      final at17 = _block(SwiftWriter(_app(actions: [_live()], background: true)).write(), 'public struct CountTasksAction');
      expect(at17, contains('public struct CountTasksAction: AppIntent, ForegroundContinuableIntent {'));
      expect(at17, contains('  #if os(iOS)\n  @available(iOS 26.0, *)\n'
          '  public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }\n  #endif\n'));
      expect(at17, contains('try await requestToContinueInForeground()'));
      final swift = SwiftWriter(_app(
              actions: [_live()], background: true, deployment: const DeploymentTarget(iOS: 26, macOS: 26)))
          .write();
      expect(swift, isNot(contains('ForegroundContinuableIntent')));
      final at26 = _block(swift, 'public struct CountTasksAction');
      expect(at26, contains('  #if os(iOS)\n  public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]\n  #endif\n'
          '  #if os(macOS)\n  public static let supportedModes: IntentModes = .foreground(.dynamic)\n  #endif\n'));
      expect(at26, contains('if !(await AssistantBackground.shared.prepare()), UIApplication.shared.applicationState != .active {\n'
          '        try await continueInForeground()\n'));
      expect(at26, contains('let reply = try await callDart("countTasks", args: args)'));
    });
  });

  group('live calls', () {
    test('report progress and can be cancelled; long-running ones say so', () {
      final swift = SwiftWriter(_app(actions: [_live(longRunning: true)])).write();
      expect(_block(swift, 'public struct CountTasksAction'), contains('let reply = try await callDart("countTasks", args: args)'));
      expect(swift, contains('extension CountTasksAction: ProgressReportingIntent {}'));
      expect(swift, contains('@available(iOS 26.4, macOS 26.4, *)\nextension CountTasksAction: CancellableIntent {}'));
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\nextension CountTasksAction: LongRunningIntent {}'));
      expect(SwiftWriter(_app(actions: [_live()])).write(), isNot(contains('LongRunningIntent')));
    });

    test('@AssistantLongRunning() makes a schema class\'s live intents long-running', () {
      final camera = _load('camera');
      final domain = SchemaDomainModel(
          className: 'Camera', catalog: camera, intents: [camera.intents['camera.stopCapture']!], longRunning: true);
      final swift = SwiftWriter(AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [domain],
        catalogs: {'camera': camera},
      )).write();
      // stopCapture is queued, not live: nothing to run long.
      expect(swift, isNot(contains('LongRunningIntent')));
    });
  });

  group('UndoableIntent', () {
    test('inbox changes register their inverse', () {
      final swift = SwiftWriter(_app(schemaEntities: [_task(undoable: true)])).write();
      final create = _block(swift, 'struct TaskItemCreateReminderIntent');
      expect(create, contains('AssistantUndo.register(undoManager, "Create Reminder", AssistantUndo.create("TaskItem", id: id))'));
      final update = _block(swift, 'struct TaskItemUpdateReminderIntent');
      expect(update, contains('let before = AssistantUndo.records("TaskItem", ids: [target.id]).first'));
      expect(update, contains('AssistantUndo.update("TaskItem", id: target.id, before: before, fields: fields, cleared: cleared)'));
      final delete = _block(swift, 'struct TaskItemDeleteRemindersIntent');
      expect(delete, contains('let removed = AssistantUndo.records("TaskItem", ids: entities.map(\\.id))'));
      expect(delete, contains('AssistantUndo.delete("TaskItem", records: removed)'));
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\nextension TaskItemCreateReminderIntent: UndoableIntent {}'));
      expect(SwiftWriter(_app(schemaEntities: [_task()])).write(), isNot(contains('Undo')));
    });

    test('other intents call an undo method on the handler with the same arguments', () {
      final app = _app(schemaEntities: [_timer(undoable: true)]);
      final pause = _block(SwiftWriter(app).write(), 'struct CountdownPauseTimerIntent');
      expect(pause, contains('AssistantUndo.call("Countdown.pauseTimer", args: args)'));
      final dart = writeDart(app);
      expect(dart, contains('Future<void> undoPauseTimer({required String timer});'));
      expect(dart, contains("'Countdown.pauseTimer.undo': (args) async {"));
      expect(dart, contains('await countdown.undoPauseTimer(timer: '));
      expect(dart, contains('Future<void> delete(String id);'), reason: 'undoing a create deletes');
    });

    test('below iOS 26 the registration is guarded', () {
      final books = _load('books');
      final schema = books.entities['books.book']!;
      final book = SchemaEntityModel(
        className: 'Book',
        library: Uri.parse('package:app/models.dart'),
        catalog: books,
        schema: schema,
        idField: 'id',
        mapping: const {},
        intents: [for (final e in books.intentsFor(schema)) if (e.$2 == IntentKind.call) e],
        containers: const {},
        undoable: true,
      );
      final swift = SwiftWriter(AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: [book],
        catalogs: {'books': books},
      )).write();
      expect(swift, contains('    if #available(iOS 26.0, macOS 26.0, *) {\n      AssistantUndo.register(undoManager,'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension BookNavigatePageIntent: UndoableIntent {}'));
      expect(swift, isNot(contains('extension BookOpenBookIntent: UndoableIntent')), reason: 'opening needs no undo');
    });

    test('a system intent from before 26 states SystemIntent before the 26-only UndoableIntent', () {
      final sheets = _load('spreadsheet');
      final schema = sheets.entities['spreadsheet.document']!;
      final doc = SchemaEntityModel(
        className: 'Sheet',
        library: Uri.parse('package:app/models.dart'),
        catalog: sheets,
        schema: schema,
        idField: 'id',
        mapping: {
          for (final p in schema.properties)
            if (p.type.base.kind == 'string') p.name: FieldModel(p.name, ValueType(ValueKind.string, nullable: p.type.isOptional)),
        },
        intents: sheets.intentsFor(schema),
        containers: const {},
        undoable: true,
      );
      final swift = SwiftWriter(AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: [doc],
        catalogs: {'spreadsheet': sheets},
      )).write();
      expect(
          swift,
          contains('@available(iOS 18.0, macOS 15.0, *)\nextension SheetDeleteIntent: SystemIntent {}\n\n'
              '@available(iOS 26.0, macOS 26.0, *)\nextension SheetDeleteIntent: UndoableIntent {}'));
    });
  });

  group('files.file', () {
    test('ids are FileEntityIdentifiers, with the Dart path kept as dartID', () {
      final swift = SwiftWriter(_app(schemaEntities: [_doc()])).write();
      expect(swift, contains('import UniformTypeIdentifiers'));
      final entity = _block(swift, 'struct DocItemEntity {');
      expect(entity, contains('  static let supportedContentTypes: [UTType] = [.item]\n'));
      expect(entity, contains('  let id: FileEntityIdentifier\n'));
      expect(entity, contains('  let dartID: String\n'));
      expect(entity, contains('    id = AssistantFileIDs.identifier(record.id)\n    dartID = record.id\n'));
      expect(entity, contains('DisplayRepresentation(title: "\\((dartID as NSString).lastPathComponent)")'));
      final query = _block(swift, 'struct DocItemEntityQuery');
      expect(query, contains('func entities(for identifiers: [FileEntityIdentifier]) async throws -> [DocItemEntity] {'));
      expect(query, contains('await AssistantFileIDs.records(AssistantSnapshot.records("DocItem"), for: identifiers)'));
      expect(swift, contains('try await Self.updateFiles('));
      expect(swift, contains('where E.ID == FileEntityIdentifier {'));
    });

    test('files.* intents pass paths to Dart', () {
      final app = _app(schemaEntities: [_doc()]);
      final swift = SwiftWriter(app).write();
      expect(_block(swift, 'struct DocItemOpenFileIntent'), contains('"target": target.dartID,'));
      final move = _block(swift, 'struct DocItemMoveFilesIntent');
      expect(move, contains('"entities": entities.map(\\.dartID),'));
      expect(move, contains('"destinationFolder": destinationFolder.dartID,'));
      expect(_block(swift, 'struct DocItemCreateFolderIntent'),
          contains('guard let id = reply, let value = DocItemEntityQuery().entities(dartIDs: [id]).first else {'));
      expect(_block(swift, 'struct DocItemDeleteFilesIntent'), contains('AssistantInbox.delete("DocItem", id: item.dartID)'));
      final dart = writeDart(app);
      expect(dart, contains('Future<String> createFolder({String? fileName, required String target});'));
      expect(dart, contains('Future<void> moveFiles({required List<String> entities, required String destinationFolder});'));
      expect(dart, contains('Future<void> delete(String id);'));
    });
  });

  group('deployment target', () {
    test('reads the plugin package platforms', () {
      expect(DeploymentTarget.fromPackageSwift('platforms: [.iOS("26.0"), .macOS("26.2")],'),
          const DeploymentTarget(iOS: 26, macOS: 26.2));
      expect(DeploymentTarget.fromPackageSwift('platforms: [.iOS(.v18), .macOS(.v15)]'),
          const DeploymentTarget(iOS: 18, macOS: 15));
      expect(DeploymentTarget.fromPackageSwift('platforms: [.iOS("12.0")]'), DeploymentTarget.minimum);
      expect(DeploymentTarget.fromPackageSwift('// no platforms'), isNull);
    });

    test('builder options win', () {
      expect(DeploymentTarget.fromOptions({'ios_deployment_target': '26.0'}, DeploymentTarget.minimum),
          const DeploymentTarget(iOS: 26, macOS: 14));
      expect(DeploymentTarget.fromOptions(const {}, const DeploymentTarget(iOS: 18, macOS: 15)),
          const DeploymentTarget(iOS: 18, macOS: 15));
    });
  });
}
