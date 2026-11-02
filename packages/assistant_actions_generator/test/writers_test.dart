import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
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

    test('spotlight: false leaves out IndexedEntity and the indexer', () {
      final base = _app();
      final app = AppModel(
        appName: base.appName,
        actions: base.actions,
        entities: base.entities,
        schemaEntities: base.schemaEntities,
        snapshotActions: base.snapshotActions,
        spotlight: false,
      );
      final swift = SwiftWriter(app).write();
      expect(swift, isNot(contains('IndexedEntity {')));
      expect(swift, isNot(contains('AssistantActionsAppSpotlight')));
      expect(swift, contains('struct TaskItemEntityQuery'), reason: 'queries are unaffected');
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
}
