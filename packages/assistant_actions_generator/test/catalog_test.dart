import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:test/test.dart';

/// The catalog files bundled in the sibling `assistant_actions` package.
DomainCatalog _load(String domain) {
  final file = File('../assistant_actions/lib/src/catalog/$domain.json');
  return DomainCatalog.fromJson((jsonDecode(file.readAsStringSync()) as Map).cast());
}

void main() {
  late DomainCatalog reminders;
  late DomainCatalog notes;

  setUpAll(() {
    reminders = _load('reminders');
    notes = _load('notes');
  });

  test('reminders.reminder has the members Mira needed', () {
    final reminder = reminders.entities['reminders.reminder']!;
    expect(reminder.properties.map((p) => p.name), containsAll(['title', 'tags', 'list', 'locationTrigger']));
    expect(reminder.property('list')!.type.isOptional, isFalse, reason: 'list is required by the schema');
    expect(reminder.property('tags')!.type.kind, 'set');
    expect(reminder.titleProperty!.name, 'title');
  });

  test('intents are classified by how they change the entity', () {
    final kinds = {
      for (final (intent, kind) in reminders.intentsFor(reminders.entities['reminders.reminder']!)) intent.name: kind,
    };
    expect(kinds, {
      'createReminder': IntentKind.create,
      'updateReminder': IntentKind.update,
      'deleteReminders': IntentKind.delete,
    });
    final noteKinds = {
      for (final (intent, kind) in notes.intentsFor(notes.entities['notes.note']!)) intent.name: kind,
    };
    expect(noteKinds['appendText'], IntentKind.append);
    expect(noteKinds['createNote'], IntentKind.create);
  });

  test('containers that can be written as consts are fixable', () {
    expect(reminders.isFixable(reminders.entities['reminders.list']!), isTrue);
    expect(notes.isFixable(notes.entities['notes.folder']!), isTrue, reason: 'self-reference is optional');
    expect(reminders.isFixable(reminders.entities['reminders.locationTrigger']!), isFalse,
        reason: 'PlaceDescriptor has no const form');
  });

  test('typed schema library requires the list container and maps value members only', () {
    final library = generateSchemaLibrary(reminders);
    expect(library, contains('required this.list,'));
    expect(library, contains("static const dueDate = SchemaMember<ReminderSchema, DateTime?>('reminders.reminder', 'dueDate');"));
    expect(library, isNot(contains('static const tags')), reason: 'sets have no Dart mapping');
    expect(library, contains('class FixedList extends SchemaContainer'));
    expect(library, isNot(contains('class FixedLocationTrigger')));
  });

  test('Dart types follow the schema types', () {
    expect(dartTypeFor(const SchemaType('attributedString')), 'String');
    expect(dartTypeFor(const SchemaType('optional', of: SchemaType('dateComponents'))), 'DateTime?');
    expect(dartTypeFor(const SchemaType('file')), isNull);
  });
}
