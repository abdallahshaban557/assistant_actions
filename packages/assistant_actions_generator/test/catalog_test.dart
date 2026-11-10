import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/schema_calls.dart';
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
  late DomainCatalog journal;

  setUpAll(() {
    reminders = _load('reminders');
    notes = _load('notes');
    journal = _load('journal');
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
    expect(library,
        contains("static const dueDate = SchemaMember<RemindersReminderSchema, DateTime?>('reminders.reminder', 'dueDate');"));
    expect(library, contains("static const tags = SchemaMember<RemindersReminderSchema, List<String>>('reminders.reminder', 'tags');"),
        reason: 'sets map to lists');
    expect(library, contains('class FixedRemindersList extends SchemaContainer'));
    expect(library, isNot(contains('class FixedRemindersLocationTrigger')));
    // Names from before domain prefixes stay as aliases.
    expect(library, contains('typedef ReminderField = RemindersReminderField;'));
    expect(library, contains('typedef FixedList = FixedRemindersList;'));
  });

  test('Dart types follow the schema types', () {
    expect(dartTypeFor(const SchemaType('attributedString')), 'String');
    expect(dartTypeFor(const SchemaType('optional', of: SchemaType('dateComponents'))), 'DateTime?');
    expect(dartTypeFor(const SchemaType('file')), 'AssistantFile');
    expect(dartTypeFor(const SchemaType('optional', of: SchemaType('placeDescriptor'))), 'AssistantPlace?');
    expect(dartTypeFor(const SchemaType('linkMetadata')), isNull);
    expect(dartTypeFor(const SchemaType('array', of: SchemaType('file'))), 'List<AssistantFile>');
    expect(dartTypeFor(const SchemaType('array', of: SchemaType('linkMetadata'))), isNull);
  });

  group('journal', () {
    test('journal.entry has its members, titled by title', () {
      final entry = journal.entities['journal.entry']!;
      expect(entry.properties.map((p) => p.name), ['title', 'message', 'mediaItems', 'entryDate', 'location']);
      expect(entry.titleProperty!.name, 'title');
      expect(entry.property('message')!.type.base.kind, 'attributedString');
      expect(entry.property('location')!.type.base.kind, 'placeDescriptor');
    });

    test('createAudioEntry is a record intent; search is not adopted', () {
      final kinds = {
        for (final (intent, kind) in journal.intentsFor(journal.entities['journal.entry']!)) intent.name: kind,
      };
      expect(kinds, {
        'createEntry': IntentKind.create,
        'createAudioEntry': IntentKind.record,
        'updateEntry': IntentKind.update,
        'deleteEntry': IntentKind.delete,
      });
      final audio = journal.intents['journal.createAudioEntry']!;
      expect(audio.recordsAudio, isTrue);
      expect(audio.opensApp, isFalse, reason: "Apple's schema doesn't open the app; the intent asks to");
      expect(recordMethod(audio), 'startAudioEntry');
      expect(journal.intents['journal.search'], isNull, reason: 'deprecated for system.searchInApp');
      expect(journal.skipped['search'], startsWith('deprecated'));
    });

    test('intents named after the entity that don\'t record audio are calls', () {
      final audio = journal.intents['journal.createAudioEntry']!;
      final plain = IntentSchema(
        id: 'journal.createAudioEntry',
        title: 't',
        availability: const {},
        parameters: const [],
      );
      final catalog = DomainCatalog(
        domain: 'journal',
        hash: journal.hash,
        xcode: journal.xcode,
        entities: journal.entities,
        enums: const {},
        intents: {'journal.createAudioEntry': plain},
      );
      expect(catalog.intentsFor(journal.entities['journal.entry']!).single.$2, IntentKind.call);
      expect(IntentSchema.fromJson(audio.id, audio.toJson()).recordsAudio, isTrue, reason: 'round-trips');
    });

    test('typed schema library maps every journal member', () {
      final library = generateSchemaLibrary(journal);
      expect(library, contains('class JournalEntry extends SchemaEntity'));
      expect(library, contains('this.createAudioEntry = false,'));
      expect(library, contains('calls `startAudioEntry()` on the generated handler'));
      expect(library, contains("static const title = SchemaMember<JournalEntrySchema, String?>('journal.entry', 'title');"));
      expect(
        library,
        contains("static const message = SchemaMember<JournalEntrySchema, String?>('journal.entry', 'message');"),
      );
      expect(library, contains("SchemaMember<JournalEntrySchema, DateTime?>('journal.entry', 'entryDate')"));
      expect(library, contains("SchemaMember<JournalEntrySchema, List<AssistantFile>>('journal.entry', 'mediaItems')"));
      expect(library, contains("SchemaMember<JournalEntrySchema, AssistantPlace?>('journal.entry', 'location')"));
      expect(library, isNot(contains('this.search')));
    });
  });
}
