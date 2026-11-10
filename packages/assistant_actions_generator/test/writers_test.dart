import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/schema_calls.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

/// Mira's TaskItem: title, an optional due date, done.
AppModel _app() {
  final reminders = _load('reminders');
  final schema = reminders.entities['reminders.reminder']!;
  const title = FieldModel('title', ValueType(ValueKind.string));
  const due = FieldModel('due', ValueType(ValueKind.dateTime, nullable: true));
  const done = FieldModel('done', ValueType(ValueKind.boolean));
  final tasks = SchemaEntityModel(
    className: 'TaskItem',
    library: Uri.parse('package:app/models.dart'),
    catalog: reminders,
    schema: schema,
    idField: 'id',
    mapping: {'title': title, 'dueDate': due, 'isCompleted': done},
    intents: reminders.intentsFor(schema),
    containers: {
      'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
    },
  );
  return AppModel(
    appName: 'Mira',
    actions: const [],
    entities: const [],
    schemaEntities: [tasks],
    snapshotActions: [
      SnapshotActionModel(
        name: 'showTasks',
        title: 'Show Tasks',
        collection: 'TaskItem',
        fields: const [title, due, done],
        titleField: 'title',
        where: const {'done': 'false'},
        sortBy: 'due',
        limit: 5,
        item: '{title}[ ({due})]',
        dialog: 'You have {count} {count|task|tasks}: {items}.',
        empty: 'Your list is clear.',
        separator: ', ',
        shortcut: const ShortcutModel(phrases: ['Show my {app} tasks'], shortTitle: 'Tasks', systemImage: 'list.bullet'),
      ),
    ],
  );
}

/// Mira's MemoryItem: one text field as the note's name and content, pinned.
SchemaEntityModel _memories() {
  final notes = _load('notes');
  final schema = notes.entities['notes.note']!;
  const text = FieldModel('text', ValueType(ValueKind.string));
  const pinned = FieldModel('pinned', ValueType(ValueKind.boolean));
  return SchemaEntityModel(
    className: 'MemoryItem',
    library: Uri.parse('package:app/models.dart'),
    catalog: notes,
    schema: schema,
    idField: 'id',
    mapping: {'name': text, 'content': text, 'isPinned': pinned},
    intents: const [],
    containers: const {},
  );
}

/// A voice journal: title, message and date as `journal.entry`, with every
/// journal intent including the audio entry.
SchemaEntityModel _journal({bool everything = true}) {
  final journal = _load('journal');
  final schema = journal.entities['journal.entry']!;
  return SchemaEntityModel(
    className: 'JournalItem',
    library: Uri.parse('package:app/models.dart'),
    catalog: journal,
    schema: schema,
    idField: 'id',
    mapping: const {
      'title': FieldModel('title', ValueType(ValueKind.string, nullable: true)),
      'message': FieldModel('text', ValueType(ValueKind.string)),
      'entryDate': FieldModel('date', ValueType(ValueKind.dateTime, nullable: true)),
    },
    intents: [
      for (final (intent, kind) in journal.intentsFor(schema))
        if (everything || kind == IntentKind.record) (intent, kind),
    ],
    containers: const {},
  );
}

AppModel _journalApp({bool everything = true}) => AppModel(
  appName: 'Mira',
  actions: const [],
  entities: const [],
  schemaEntities: [_journal(everything: everything)],
);


/// Adopts [id] with [mapping] and every intent its annotation offers.
SchemaEntityModel _adopt(String id, Map<String, FieldModel> mapping, {String? className}) {
  final catalog = _load(id.split('.').first);
  final schema = catalog.entities[id]!;
  return SchemaEntityModel(
    className: className ?? '${pascal(schema.domain)}${pascal(schema.name)}Item',
    library: Uri.parse('package:app/models.dart'),
    catalog: catalog,
    schema: schema,
    idField: 'id',
    mapping: mapping,
    intents: catalog.intentsFor(schema),
    containers: const {},
  );
}

SchemaDomainModel _domain(String domain) {
  final catalog = _load(domain);
  return SchemaDomainModel(className: '${pascal(domain)}Handler', catalog: catalog, intents: catalog.domainIntents);
}

Map<String, DomainCatalog> _catalogs(List<String> domains) => {for (final d in domains) d: _load(d)};

/// A plain `@AssistantEntity` with a title field, a number, a date and a URL.
EntityModel _recipe() => EntityModel(
      className: 'Recipe',
      library: Uri.parse('package:app/models.dart'),
      title: 'Recipe',
      idField: 'id',
      titleGetter: 'name',
      fields: const [
        FieldModel('name', ValueType(ValueKind.string)),
        FieldModel('minutes', ValueType(ValueKind.integer)),
        FieldModel('cookedAt', ValueType(ValueKind.dateTime, nullable: true)),
        FieldModel('vegan', ValueType(ValueKind.boolean)),
        FieldModel('source', ValueType(ValueKind.uri)),
      ],
    );

void main() {
  group('cleared fields', () {
    test('update intents read valueState for nullable fields only', () {
      final swift = SwiftWriter(_app()).write();
      final update = swift.substring(swift.indexOf('struct TaskItemUpdateReminderIntent'));
      expect(update, contains(r'switch $dueDate.valueState'));
      expect(update, contains('case .set(nil): cleared.append("due")\n    @unknown default: break'));
      expect(update, contains('    var cleared: [String] = []'));
      expect(update, isNot(contains(r'$title.valueState')), reason: 'title is a non-nullable String in Dart');
      expect(update, contains('AssistantInbox.update("TaskItem", id: target.id, fields: fields, cleared: cleared)'));
      expect(update, contains('} else if cleared.contains("due") {\n      updated.dueDate = nil'));
    });

    test('intents with nothing to clear declare cleared as a constant', () {
      final swift = SwiftWriter(_app()).write();
      // updateReminder can clear due; nothing else in the app can.
      expect('var cleared: [String] = []'.allMatches(swift), hasLength(1));
    });

    test('Values classes expose cleared fields', () {
      final dart = writeDart(_app());
      expect(dart, contains("bool get dueCleared => cleared.contains('due');"));
      expect(dart, isNot(contains('titleCleared')));
      expect(dart, contains('TaskItemValues._from(change.fields, change.cleared)'));
    });
  });

  group('Spotlight', () {
    test('schema entities are IndexedEntity, with attributes from the catalog indexing keys', () {
      final swift = SwiftWriter(_app()).write();
      final ext = swift.substring(swift.indexOf('extension TaskItemEntity: IndexedEntity {'));
      expect(ext, contains('attributes.title = title'));
      expect(ext, contains(r'attributes.dueDate = dueDate.flatMap { Calendar.current.date(from: $0) }'));
      expect(swift, contains('import CoreSpotlight'));
    });

    test('the runtime finds a generated indexer covering each collection', () {
      final swift = SwiftWriter(_app()).write();
      expect(swift, contains('@objc(AssistantActionsAppSpotlight)'));
      expect(swift, contains('public final class AssistantActionsAppSpotlight: NSObject, AssistantSpotlightIndexer'));
      expect(swift, contains('case "TaskItem":'));
      expect(swift, contains('try await index.deleteAppEntities(identifiedBy: removed, ofType: E.self)'));
    });
  });

  group('entity queries', () {
    test('can list everything and match forgivingly', () {
      final swift = SwiftWriter(_app()).write();
      final query = swift.substring(swift.indexOf('struct TaskItemEntityQuery'));
      expect(query, startsWith('struct TaskItemEntityQuery: EntityStringQuery, EnumerableEntityQuery, EntityPropertyQuery {'));
      expect(query, contains('func allEntities() async throws -> [TaskItemEntity] { all() }'));
      expect(query, contains('AssistantMatch.records(AssistantSnapshot.records("TaskItem"), matching: string, ignoring: Self.typeWords)'));
    });

    test('type words cover the class, schema and app names', () {
      final swift = SwiftWriter(_app()).write();
      expect(swift, contains('static let typeWords: Set<String> = ["item", "mira", "reminder", "reminders", "task", "taskitem"]'));
    });
  });

  group('property queries', () {
    String query(String swift, String name) {
      final start = swift.indexOf('struct $name');
      return swift.substring(start, swift.indexOf('\n}\n', start));
    }

    test('schema entities title the members Siri can query, and only those', () {
      final swift = SwiftWriter(_app()).write();
      final entity = query(swift, 'TaskItemEntity {');
      expect(entity, contains('  @Property(title: "Title")\n  var title: String\n'));
      expect(entity, contains('  @Property(title: "Due Date")\n  var dueDate: DateComponents?\n'));
      expect(entity, contains('  @Property(title: "Is Completed")\n  var isCompleted: Bool\n'));
      expect(entity, contains('  var tags: Set<String>\n  var urls: [URL]\n'), reason: 'unmapped members get no title');
      expect('@Property('.allMatches(entity), hasLength(3));
    });

    test('mapped bools take equal, dates the comparisons and between, strings contains', () {
      final q = query(SwiftWriter(_app()).write(), 'TaskItemEntityQuery');
      expect(q, contains('typealias ComparatorMappingType = AssistantPredicate<TaskItemEntity>'));
      expect(q, contains('static var findIntentDescription: IntentDescription? { nil }'));
      expect(q, contains('''
    Property(\\TaskItemEntity.\$isCompleted) {
      EqualToComparator { value in AssistantPredicate({ \$0.isCompleted }, .equal, value) }
    }'''));
      expect(q, contains('''
    Property(\\TaskItemEntity.\$title) {
      ContainsComparator { value in AssistantPredicate({ \$0.title }, .contains, value) }
    }'''));
      for (final c in [
        'EqualToComparator { value in AssistantPredicate({ \$0.dueDate }, .equal, value) }',
        'NotEqualToComparator { value in AssistantPredicate({ \$0.dueDate }, .notEqual, value) }',
        'LessThanComparator { value in AssistantPredicate({ \$0.dueDate }, .less, value) }',
        'LessThanOrEqualToComparator { value in AssistantPredicate({ \$0.dueDate }, .lessOrEqual, value) }',
        'GreaterThanComparator { value in AssistantPredicate({ \$0.dueDate }, .greater, value) }',
        'GreaterThanOrEqualToComparator { value in AssistantPredicate({ \$0.dueDate }, .greaterOrEqual, value) }',
        'IsBetweenComparator { low, high in AssistantPredicate({ \$0.dueDate }, .between, low, high) }',
      ]) {
        expect(q, contains(c));
      }
    });

    test('sorts by title and dates, evaluating over the snapshot in Swift', () {
      final q = query(SwiftWriter(_app()).write(), 'TaskItemEntityQuery');
      expect(q, contains('''
  static let sortingOptions = SortingOptions {
    SortableBy(\\TaskItemEntity.\$title)
    SortableBy(\\TaskItemEntity.\$dueDate)
  }'''));
      expect(q, contains('return AssistantPredicate.apply(comparators, all: mode == .and, to: all(), sortedBy: sorts, limit: limit)'));
      expect(q, contains('case \\TaskItemEntity.\$dueDate: return { \$0.dueDate?.assistantKey }'));
      expect(q, contains('case \\TaskItemEntity.\$title: return { \$0.title.assistantKey }'));
      expect(q, isNot(contains('SortableBy(\\TaskItemEntity.\$isCompleted)')));
    });

    test('attributed strings take contains; only the title one sorts', () {
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [_memories()]);
      final q = query(SwiftWriter(app).write(), 'MemoryItemEntityQuery');
      expect(q, contains('ContainsComparator { value in AssistantPredicate({ \$0.content }, .contains, value) }'));
      expect(q, contains('SortableBy(\\MemoryItemEntity.\$name)'));
      expect(q, isNot(contains('SortableBy(\\MemoryItemEntity.\$content)')));
    });

    test('schema entities with nothing to query keep plain queries', () {
      final reminders = _load('reminders');
      final schema = reminders.entities['reminders.reminder']!;
      final bare = SchemaEntityModel(
        className: 'TaskItem',
        library: Uri.parse('package:app/models.dart'),
        catalog: reminders,
        schema: schema,
        idField: 'id',
        mapping: const {},
        intents: const [],
        containers: {
          'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
        },
      );
      final swift = SwiftWriter(AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [bare])).write();
      expect(swift, contains('struct TaskItemEntityQuery: EntityStringQuery, EnumerableEntityQuery {'));
      expect(swift, isNot(contains('@Property(')));
      expect(swift, isNot(contains('AssistantPredicate')));
    });

    test('plain entities query their title and published fields', () {
      final swift = SwiftWriter(AppModel(appName: 'Cook', actions: const [], entities: [_recipe()], schemaEntities: const [])).write();
      expect(swift, contains('public struct RecipeEntityQuery: EntityStringQuery, EnumerableEntityQuery, EntityPropertyQuery {'));
      expect(swift, contains('  @Property(title: "Title")\n  public var title: String\n'));
      expect(swift, contains('  @Property(title: "Minutes")\n  public var minutes: Int?\n'));
      expect(swift, contains('  @Property(title: "Cooked At")\n  public var cookedAt: Date?\n'));
      expect(swift, contains('  @Property(title: "Vegan")\n  public var vegan: Bool?\n'));
      expect(swift, isNot(contains('public var name:')), reason: 'the title field is already `title`');
      expect(swift, isNot(contains('public var source:')), reason: 'URLs are not compared');
      expect(swift, contains('''
    subtitle = record.subtitle
    // `@Property` members last: setting one needs every stored property set.
    title = record.title
    minutes = AssistantValues.int(record.fields["minutes"])
    cookedAt = AssistantValues.date(record.fields["cookedAt"])
    vegan = AssistantValues.bool(record.fields["vegan"])
  }'''));
      final q = query(swift, 'RecipeEntityQuery');
      expect(q, contains('public typealias ComparatorMappingType = AssistantPredicate<RecipeEntity>'));
      expect(q, contains('LessThanComparator { value in AssistantPredicate({ \$0.minutes }, .less, value) }'));
      expect(q, contains('IsBetweenComparator { low, high in AssistantPredicate({ \$0.cookedAt }, .between, low, high) }'));
      expect(q, contains('EqualToComparator { value in AssistantPredicate({ \$0.vegan }, .equal, value) }'));
      expect(q, contains('to: AssistantSnapshot.records("Recipe").map(RecipeEntity.init(record:))'));
      expect(q, contains('case \\RecipeEntity.\$minutes: return { \$0.minutes?.assistantKey }'));
      expect(q, isNot(contains('SortableBy(\\RecipeEntity.\$vegan)')));
    });
  });

  group('snapshot answers', () {
    test('become App Intents answered by AssistantQuery, with no Flutter call', () {
      final swift = SwiftWriter(_app()).write();
      final action = swift.substring(swift.indexOf('public struct ShowTasksAction'));
      expect(action, contains('AssistantQuery.answer(\n      "TaskItem",\n      where: ["done": false],'));
      expect(action, contains('dateFields: ["due"],'));
      expect(action, contains('ReturnsValue<[String]> & ProvidesDialog'));
      expect(action.substring(0, action.indexOf('\n}\n')), isNot(contains('AssistantBridge')));
      expect(action.substring(0, action.indexOf('\n}\n')), isNot(contains('ForegroundContinuableIntent')));
    });

    test('can have App Shortcuts', () {
      expect(writeShortcuts(_app()), contains('intent: ShowTasksAction(),'));
    });
  });

  group('journal', () {
    String block(String swift, String start) {
      final i = swift.indexOf(start);
      expect(i, isNonNegative, reason: start);
      return swift.substring(i, swift.indexOf('\n}\n', i));
    }

    test('journal.entry declares every member; files and places get defaults', () {
      final swift = SwiftWriter(_journalApp()).write();
      final entity = block(swift, 'struct JournalItemEntity {');
      expect(entity, contains('  var mediaItems: [IntentFile]\n'));
      expect(entity, contains('  var location: PlaceDescriptor?\n'));
      expect(entity, contains('    title = AssistantValues.string(record.fields["title"])\n'));
      expect(entity, contains('    message = AssistantValues.attributed(record.fields["text"])\n'));
      expect(entity, contains('    entryDate = AssistantValues.date(record.fields["date"])\n'));
      expect(entity, contains('    mediaItems = []\n    entryDate'));
      expect(entity, contains('    location = nil\n'));
      expect(swift, contains('import GeoToolbox'));
    });

    test('PlaceDescriptor raises availability from iOS 18 to 26', () {
      final swift = SwiftWriter(_journalApp()).write();
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\n@AppEntity(schema: .journal.entry)'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\n@AppIntent(schema: .journal.createEntry)'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\n@AppIntent(schema: .journal.createAudioEntry)'));
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension JournalItemEntity: IndexedEntity'));
      expect(swift, contains('      if #available(iOS 26.0, macOS 26.0, *) {'));
      expect(swift, isNot(contains('iOS 18.0, macOS 15.0, *)\n@')));
    });

    test('create, update and delete go through the inbox', () {
      final swift = SwiftWriter(_journalApp()).write();
      final create = block(swift, 'struct JournalItemCreateEntryIntent');
      expect(create, contains('  var message: AttributedString\n'));
      expect(create, contains('fields["text"] = AssistantValues.encode(message)'));
      expect(create, contains('fields["title"] = AssistantValues.encode(title)'));
      expect(create, contains('fields["date"] = AssistantValues.encode(entryDate)'));
      expect(create, isNot(contains('fields["location"]')));
      expect(create, contains('AssistantInbox.create("JournalItem", fields: fields)'));
      final update = block(swift, 'struct JournalItemUpdateEntryIntent');
      expect(update, contains(r'switch $title.valueState'));
      expect(update, contains(r'switch $entryDate.valueState'));
      expect(update, contains('if message != nil { fields["text"] = AssistantValues.encode(message) }'));
      final delete = block(swift, 'struct JournalItemDeleteEntryIntent');
      expect(delete, contains('var entities: [JournalItemEntity]'));
      expect(delete, contains('AssistantInbox.delete("JournalItem", id: item.id)'));
    });

    test('createAudioEntry opens the app and calls the handler live', () {
      final swift = SwiftWriter(_journalApp()).write();
      final audio = block(swift, 'struct JournalItemCreateAudioEntryIntent');
      expect(audio, startsWith('struct JournalItemCreateAudioEntryIntent: ForegroundContinuableIntent {'));
      expect(audio, contains('func perform() async throws -> some IntentResult {'));
      expect(audio, contains('try await requestToContinueInForeground()'));
      expect(audio, contains('NSApplication.shared.activate()'));
      expect(audio, contains('AssistantBridge.shared.perform("JournalItem.startAudioEntry", args: [:])'));
      expect(audio, isNot(contains('AssistantInbox')));
      expect(audio, isNot(contains('var ')), reason: 'the schema intent takes no parameters');
      expect(swift, contains('#elseif os(macOS)\n  import AppKit'));
    });

    test('Spotlight indexes the title, message and date', () {
      final swift = SwiftWriter(_journalApp()).write();
      final ext = block(swift, 'extension JournalItemEntity: IndexedEntity {');
      expect(ext, contains('attributes.title = title'));
      expect(ext, contains(r'attributes.textContent = message.map { String($0.characters) }'));
      expect(ext, contains('attributes.contentCreationDate = entryDate'));
      expect(swift, contains('case "JournalItem":'));
    });

    test('Siri can filter entries by date and text', () {
      final q = block(SwiftWriter(_journalApp()).write(), 'struct JournalItemEntityQuery');
      expect(
        q,
        contains('IsBetweenComparator { low, high in AssistantPredicate({ \$0.entryDate }, .between, low, high) }'),
      );
      expect(q, contains('ContainsComparator { value in AssistantPredicate({ \$0.message }, .contains, value) }'));
      expect(q, contains('SortableBy(\\JournalItemEntity.\$entryDate)'));
    });

    test('the handler gets create, update, delete and startAudioEntry', () {
      final dart = writeDart(_journalApp());
      expect(dart, contains('abstract interface class JournalItemAssistantHandler {'));
      expect(dart, contains('Future<void> create(String id, JournalItemValues values);'));
      expect(dart, contains('Future<void> update(String id, JournalItemValues changes);'));
      expect(dart, contains('Future<void> delete(String id);'));
      expect(dart, contains('Future<void> startAudioEntry();'));
      expect(
        dart,
        contains('''
    'JournalItem.startAudioEntry': (args) async {
      await journalItem.startAudioEntry();
      return null;
    },'''),
      );
      expect(dart, isNot(contains("case 'record'")));
    });

    test('an app can adopt only the audio entry', () {
      final dart = writeDart(_journalApp(everything: false));
      expect(dart, contains('Future<void> startAudioEntry();'));
      expect(dart, isNot(contains('Future<void> create(')));
      final swift = SwiftWriter(_journalApp(everything: false)).write();
      expect(swift, contains('struct JournalItemCreateAudioEntryIntent'));
      expect(swift, isNot(contains('struct JournalItemCreateEntryIntent')));
    });
  });

  group('every schema shape', () {
    String block(String swift, String start) {
      final i = swift.indexOf(start);
      expect(i, isNonNegative, reason: start);
      return swift.substring(i, swift.indexOf('\n}\n', i));
    }

    SchemaEntityModel timer() => _adopt('clock.timer', const {
          'duration': FieldModel('length', ValueType(ValueKind.duration)),
          'durationRemaining': FieldModel('left', ValueType(ValueKind.duration)),
          'state': FieldModel('state', ValueType(ValueKind.enumeration, enumRef: 'clock.timerState')),
          'label': FieldModel('label', ValueType(ValueKind.string, nullable: true)),
        }, className: 'Countdown');

    test('intents of an entity that are not field changes call handler methods', () {
      final kinds = {for (final (i, k) in timer().intents) i.name: k};
      expect(kinds['createTimer'], IntentKind.create);
      expect(kinds['pauseTimer'], IntentKind.call);
      expect(kinds['cancelTimer'], IntentKind.call, reason: 'takes entities but is not a delete');
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [timer()]);
      final swift = SwiftWriter(app).write();
      final pause = block(swift, 'struct CountdownPauseTimerIntent');
      expect(pause, startsWith('struct CountdownPauseTimerIntent {'), reason: 'queued, so no foreground');
      expect(pause, contains('var timer: CountdownEntity'));
      expect(pause, contains('"timer": timer.id,'));
      expect(pause, contains('AssistantInbox.call("Countdown.pauseTimer", args: args)'));
      final dart = writeDart(app);
      expect(dart, contains('Future<void> pauseTimer({required String timer});'));
      expect(dart, contains("'Countdown.pauseTimer': (args) async {"));
      expect(dart, contains("await countdown.pauseTimer(timer: AssistantValue.string(args['timer']) ?? (throw ArgumentError.notNull('timer')));"));
    });

    test('durations and schema enums map to Dart Duration and enums', () {
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [timer()]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('var duration: Duration'));
      expect(swift, contains('duration = AssistantValues.duration(record.fields["length"]) ?? .zero'));
      expect(swift, contains('state = AssistantValues.string(record.fields["state"]).flatMap(ClockTimerStateEnum.init(rawValue:))'));
      expect(swift, contains('@AppEnum(schema: .clock.timerState)'));
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\n@AppEnum(schema: .clock.timerState)'),
          reason: 'enums take their own catalog availability');
      final dart = writeDart(app);
      expect(dart, contains("import 'package:assistant_actions/schemas/clock.dart' show ClockTimerState;"));
      expect(dart, contains("'state': AssistantValue.encodeEnum(e.state),"));
      expect(dart, contains("state: AssistantValue.enumeration(ClockTimerState.values, f['state']),"));
      expect(dart, contains("'length': AssistantValue.encodeDuration(e.length),"));
    });

    test('a call that returns an entity runs live and looks the item up', () {
      final tab = _adopt('browser.tab', const {
        'name': FieldModel('name', ValueType(ValueKind.string)),
        'url': FieldModel('url', ValueType(ValueKind.uri, nullable: true)),
      }, className: 'Tab');
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [tab]);
      final swift = SwiftWriter(app).write();
      final create = block(swift, 'struct TabCreateTabIntent');
      expect(create, startsWith('struct TabCreateTabIntent: ForegroundContinuableIntent {'));
      expect(create, contains('func perform() async throws -> some ReturnsValue<TabEntity> {'));
      expect(create, contains('NSApplication.shared.activate()'), reason: 'it opens the app');
      expect(create, contains('let reply = try await AssistantBridge.shared.perform("Tab.createTab", args: args)'));
      expect(create, contains('guard let id = reply, let value = try await TabEntityQuery().entities(for: [id]).first'));
      final close = block(swift, 'struct TabCloseTabsIntent');
      expect(close, contains('"target": target.map(\\.id),'));
      final dart = writeDart(app);
      expect(dart, contains('Future<String> createTab({Uri? url, required bool isPrivate});'));
      expect(dart, contains('Future<void> closeTabs({required List<String> target});'));
      expect(dart, contains("return await tab.createTab(url: AssistantValue.uri(args['url'])"));
    });

    test('domain intents go on a domain handler; app-defined enum cases come from the app', () {
      final camera = _domain('camera');
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [camera],
        catalogs: _catalogs(['camera']),
        openEnums: {
          for (final (id, name) in [
            ('camera.captureMode', 'Mode'),
            ('camera.captureDevice', 'Lens'),
            ('camera.captureDuration', 'Delay'),
          ])
            id: OpenEnumModel(schema: id, className: name, library: Uri.parse('package:app/camera.dart'), cases: const ['one', 'this\$']),
        },
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@AppEnum(schema: .camera.captureMode)\nenum CameraCaptureModeEnum: String {\n  case one\n  case this\n'));
      final start = block(swift, 'struct CameraStartCaptureIntent');
      expect(start, contains('var captureMode: CameraCaptureModeEnum'));
      expect(start, contains('"captureMode": AssistantValues.encode(captureMode),'));
      expect(start, contains('requestToContinueInForeground()'));
      expect(start, contains('AssistantBridge.shared.perform("camera.startCapture", args: args)'));
      final dart = writeDart(app);
      expect(dart, contains("import 'package:app/camera.dart' show Delay, Lens, Mode;"));
      expect(dart, contains('abstract interface class CameraAssistantHandler {'));
      expect(dart, contains('Future<void> startCapture({required Mode captureMode, Lens? device, Delay? timerDuration});'));
      expect(dart, contains('required CameraAssistantHandler camera,'));
      expect(dart, contains("'camera.startCapture': (args) async {"));
      expect(dart, contains("captureMode: AssistantValue.enumeration(Mode.values, args['captureMode'])"));
    });

    test('an intent missing from the macOS catalog is iOS-only', () {
      final app = AppModel(
          appName: 'Mira',
          actions: const [],
          entities: const [],
          schemaEntities: const [],
          schemaDomains: [_domain('assistant')],
          catalogs: _catalogs(['assistant']));
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@available(iOS 26.2, *)\n@available(macOS, unavailable)\n@AppIntent(schema: .assistant.activate)'));
      final activate = block(swift, 'struct AssistantActivateIntent');
      expect(activate, contains('static let supportedModes: IntentModes = .foreground'),
          reason: 'iOS 26+ intents that open the app declare it');
      expect(activate, isNot(contains('ForegroundContinuableIntent')));
    });

    test('unions become @UnionValue enums at iOS 27', () {
      final event = _adopt('calendar.event', const {
        'title': FieldModel('title', ValueType(ValueKind.string)),
        'startDate': FieldModel('start', ValueType(ValueKind.dateTime)),
        'endDate': FieldModel('end', ValueType(ValueKind.dateTime)),
        'calendar': FieldModel('calendarId', ValueType(ValueKind.entityId, entityRef: 'calendar.calendar')),
      }, className: 'Event');
      final calendar = _adopt('calendar.calendar', const {'title': FieldModel('name', ValueType(ValueKind.string))},
          className: 'Calendar');
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [event, calendar]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\n@UnionValue\nenum CalendarLocationUnion {\n  case place(PlaceDescriptor)\n  case address(String)'));
      expect(swift, contains('var organizers: [IntentPerson]'));
      expect(swift, contains('var recurrence: Calendar.RecurrenceRule?'));
      expect(swift, contains('startDate = AssistantValues.date(record.fields["start"]) ?? Date(timeIntervalSince1970: 0)'));
      // An entity member mapped to an id resolves it from the snapshot, one level deep.
      expect(swift, contains('calendar = AssistantValues.string(record.fields["calendarId"]).map { CalendarEntity.reference(\$0, resolve: resolve) } ?? CalendarEntity.reference("", resolve: false)'));
      expect(swift, contains('static func reference(_ id: String, resolve: Bool) -> CalendarEntity {'));
      expect(swift, contains('import GeoToolbox'));
    });

    test('unique entities answer one item', () {
      final session = _adopt('maps.navigationSession', const {
        'estimatedArrivalDate': FieldModel('eta', ValueType(ValueKind.dateTime)),
      }, className: 'Trip');
      final app = AppModel(
          appName: 'Mira', actions: const [], entities: const [], schemaEntities: [session], catalogs: _catalogs(['maps']));
      final swift = SwiftWriter(app).write();
      expect(swift, contains('struct TripEntityQuery: UniqueAppEntityQuery, EntityStringQuery'));
      expect(swift, contains('func uniqueEntity() async throws -> TripEntity {'));
    });

    test('system.open opens each entity without its own open intent', () {
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: [_recipe()],
        schemaEntities: [_journal()],
        schemaDomains: [_domain('system')],
        catalogs: _catalogs(['system']),
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@AppIntent(schema: .system.open)\nstruct OpenJournalItemIntent: ForegroundContinuableIntent {\n  var target: JournalItemEntity'));
      expect(swift, contains('struct OpenRecipeIntent: ForegroundContinuableIntent {\n  var target: RecipeEntity'));
      expect(swift, contains('AssistantBridge.shared.perform("system.open.JournalItem", args: ["id": target.id])'));
      final search = block(swift, 'struct SystemSearchInAppIntent');
      expect(search, contains('var criteria: StringSearchCriteria'));
      expect(search, contains('"criteria": criteria.term,'));
      final dart = writeDart(app);
      expect(dart, contains('abstract interface class SystemAssistantHandler {'));
      expect(dart, contains('Future<void> openJournalItem(String id);'));
      expect(dart, contains('Future<void> searchInApp({required String criteria});'));
      expect(dart, contains("'system.open.Recipe': (args) async {"));
    });

    test('handler methods are named after intents, unless that clashes', () {
      final spreadsheet = _load('spreadsheet');
      final create = spreadsheet.intents['spreadsheet.create']!;
      expect(callMethod(create, spreadsheet.entities['spreadsheet.document']), 'createDocument');
      expect(callMethod(_load('clock').intents['clock.pauseTimer']!, null), 'pauseTimer');
    });
  });

  group('people, places, files, recurrence and unions', () {
    test('entity members map to the runtime types and back', () {
      final attendee = _adopt('calendar.attendee', const {
        'person': FieldModel('who', ValueType(ValueKind.person)),
      }, className: 'Guest');
      final place = _adopt('maps.place', const {
        'place': FieldModel('where', ValueType(ValueKind.place)),
      }, className: 'Spot');
      final app = AppModel(
          appName: 'Mira', actions: const [], entities: const [], schemaEntities: [attendee, place], catalogs: _catalogs(['calendar', 'maps']));
      final swift = SwiftWriter(app).write();
      expect(swift, contains('person = AssistantValues.person(record.fields["who"]) ?? IntentPerson(identifier: .unknown, name: .unknown, handle: nil)'));
      expect(swift, contains('place = AssistantValues.place(record.fields["where"]) ?? PlaceDescriptor(representations: [.address("")], commonName: nil)'));
      final dart = writeDart(app);
      expect(dart, contains("'who': AssistantValue.encodePerson(e.who),"));
      expect(dart, contains("'where': AssistantValue.encodePlace(e.where),"));
    });

    test('unions encode with their case and kind, and decode by case', () {
      final event = _adopt('calendar.event', const {
        'title': FieldModel('title', ValueType(ValueKind.string)),
        'startDate': FieldModel('start', ValueType(ValueKind.dateTime)),
        'endDate': FieldModel('end', ValueType(ValueKind.dateTime)),
        'calendar': FieldModel('calendarId', ValueType(ValueKind.entityId, entityRef: 'calendar.calendar')),
        'location': FieldModel('location', ValueType(ValueKind.union, nullable: true)),
        'recurrence': FieldModel('repeats', ValueType(ValueKind.recurrence, nullable: true)),
      }, className: 'Event');
      final calendar = _adopt('calendar.calendar', const {'title': FieldModel('name', ValueType(ValueKind.string))},
          className: 'Calendar');
      final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [event, calendar]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('extension CalendarLocationUnion: AssistantEncodable {'));
      expect(swift, contains('case .place(let value): AssistantValues.encodeCase("place", kind: "placeDescriptor", AssistantValues.encode(value))'));
      expect(swift, contains('case "address": return (AssistantValues.string(raw)).map { .address(\$0) }'));
      expect(swift, contains('location = CalendarLocationUnion.decode(record.fields["location"])'));
      expect(swift, contains('recurrence = AssistantValues.recurrence(record.fields["repeats"])'));
      final create = swift.substring(swift.indexOf('struct EventCreateEventIntent'));
      expect(create, contains('fields["location"] = AssistantValues.encode(location)'));
      final dart = writeDart(app);
      expect(dart, contains("location: AssistantValue.union(f['location']),"));
      expect(dart, contains("repeats: AssistantValue.recurrence(f['repeats']),"));
    });

    test('call parameters pass files, people and places to Dart', () {
      final slide = _adopt('presentation.slide', const {
        'presentation': FieldModel('deckId', ValueType(ValueKind.entityId, entityRef: 'presentation.document')),
        'slideIndex': FieldModel('index', ValueType(ValueKind.integer)),
      }, className: 'Slide');
      final deck = _adopt('presentation.document', const {'name': FieldModel('name', ValueType(ValueKind.string))},
          className: 'Deck');
      final app = AppModel(
          appName: 'Mira',
          actions: const [],
          entities: const [],
          schemaEntities: [slide, deck],
          catalogs: _catalogs(['presentation']));
      final dart = writeDart(app);
      expect(dart, contains('Future<void> addImageToSlide({required AssistantFile image, required String target});'));
      expect(dart, contains("image: AssistantValue.file(args['image']) ?? (throw ArgumentError.notNull('image'))"));
      final swift = SwiftWriter(app).write();
      expect(swift, contains('"image": AssistantValues.encode(image),'));
      expect(droppedArgs(_load('presentation').intents['presentation.addImageToSlide']!), isEmpty);
    });
  });

  test('list members map to Dart lists: journal media, reminder tags', () {
    final entry = _adopt('journal.entry', const {
      'message': FieldModel('text', ValueType(ValueKind.string)),
      'mediaItems': FieldModel('media', ValueType(ValueKind.file, list: true)),
    }, className: 'Entry');
    final tags = _adopt('reminders.reminder', const {
      'title': FieldModel('title', ValueType(ValueKind.string)),
      'tags': FieldModel('tags', ValueType(ValueKind.string, list: true)),
    }, className: 'Task');
    final app = AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [entry]);
    final swift = SwiftWriter(app).write();
    expect(swift, contains(r'mediaItems = (AssistantValues.items(record.fields["media"]) ?? []).compactMap { AssistantValues.file($0) }'));
    final create = swift.substring(swift.indexOf('struct EntryCreateEntryIntent'));
    expect(create, contains(r'fields["media"] = mediaItems.map { AssistantValues.encode($0) }'));
    final dart = writeDart(app);
    expect(dart, contains("'media': e.media.map((e) => AssistantValue.encodeFile(e)).toList(),"));
    expect(dart, contains("media: AssistantValue.list(f['media'], (v) => AssistantValue.file(v)),"));
    expect(dart, contains('final List<AssistantFile>? media;'));
    final reminders = SwiftWriter(AppModel(appName: 'Mira', actions: const [], entities: const [], schemaEntities: [
      SchemaEntityModel(
        className: tags.className,
        library: tags.library,
        catalog: tags.catalog,
        schema: tags.schema,
        idField: 'id',
        mapping: tags.mapping,
        intents: const [],
        containers: {'list': const FixedInstance(schema: 'reminders.list', id: 'l', strings: {'name': 'L'}, nested: {})},
      ),
    ])).write();
    expect(reminders, contains(r'tags = Set((AssistantValues.items(record.fields["tags"]) ?? []).compactMap { AssistantValues.string($0) })'));
  });
}
