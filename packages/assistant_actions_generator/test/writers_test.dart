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
