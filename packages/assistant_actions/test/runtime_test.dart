import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/journal.dart';
import 'package:assistant_actions/schemas/notes.dart';
import 'package:assistant_actions/schemas/reminders.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  const _Item(this.id, this.name, this.due);
  final String id;
  final String name;
  final DateTime? due;
}

/// Stands in for the Swift side of the FFI bridge.
class _FakeHost implements AssistantHost {
  _FakeHost(this.inbox);

  List<String> inbox;
  final calls = <String>[];
  final published = <String, String>{};

  @override
  Future<List<String>> drainInbox() async {
    calls.add('drainInbox');
    final items = inbox;
    inbox = [];
    return items;
  }

  @override
  Future<void> markReady() async => calls.add('markReady');

  @override
  Future<void> publish(String collection, String json) async {
    calls.add('publish');
    published[collection] = json;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start applies queued calls and changes in order, then marks ready', () async {
    final applied = <String>[];
    final host = _FakeHost([
      jsonEncode({'kind': 'call', 'action': 'add', 'args': {'n': 2}}),
      jsonEncode({'kind': 'create', 'collection': 'Item', 'id': 'a', 'fields': {'name': 'x'}}),
      jsonEncode({'kind': 'delete', 'collection': 'Item', 'id': 'a'}),
    ]);
    await AssistantActions.start(
      AssistantActionsRegistry(
        actions: {'add': (args) async => (applied..add('add ${args['n']}')).last},
        collections: {'Item': (change) async => applied.add('${change.kind} ${change.id} ${change.fields}')},
      ),
      host: host,
    );
    expect(applied, ['add 2', 'create a {name: x}', 'delete a {}']);
    expect(host.calls, ['drainInbox', 'markReady']);
  });

  test('perform runs a live action with the arguments Swift sent', () async {
    await AssistantActions.start(
      AssistantActionsRegistry(actions: {'count': (args) async => 'You have ${args['n']}.'}),
      host: _FakeHost([]),
    );
    expect(await AssistantActions.perform('count', jsonEncode({'n': 3})), 'You have 3.');
    expect(() => AssistantActions.perform('missing', '{}'), throwsArgumentError);
  });

  test('publish sends the encoded snapshot for the entity collection', () async {
    final host = _FakeHost([]);
    await AssistantActions.start(
      AssistantActionsRegistry(codecs: {
        _Item: EntityCodec<_Item>('Item', id: (e) => e.id, title: (e) => e.name, fields: (e) => const {}),
      }),
      host: host,
    );
    await AssistantActions.publish([const _Item('1', 'Milk', null)]);
    expect(jsonDecode(host.published['Item']!), {
      'records': [
        {'id': '1', 'title': 'Milk', 'fields': {}},
      ],
    });
  });

  test('EntityCodec encodes id, title, subtitle and fields', () {
    final codec = EntityCodec<_Item>(
      'Item',
      id: (e) => e.id,
      title: (e) => e.name,
      subtitle: (e) => 'sub',
      fields: (e) => {'due': AssistantValue.encodeDate(e.due)},
    );
    expect(codec.encode(_Item('1', 'Milk', DateTime.fromMillisecondsSinceEpoch(1500))), {
      'id': '1',
      'title': 'Milk',
      'subtitle': 'sub',
      'fields': {'due': 1.5},
    });
  });

  test('AssistantValue decodes what Swift sends', () {
    expect(AssistantValue.date(1.5), DateTime.fromMillisecondsSinceEpoch(1500));
    expect(AssistantValue.integer(3.0), 3);
    expect(AssistantValue.string(3), isNull);
    expect(AssistantValue.uri('https://a.b'), Uri.parse('https://a.b'));
  });

  test('InboxChange reads a queued update', () {
    final change = InboxChange.fromJson({
      'kind': 'update',
      'collection': 'Item',
      'id': 'a',
      'fields': {'done': true},
      'cleared': ['due'],
    });
    expect(change.fields, {'done': true});
    expect(change.cleared, ['due']);
  });

  test('every bundled catalog has its typed schema library', () {
    final domains = [
      for (final f in Directory('lib/src/catalog').listSync())
        if (f.path.endsWith('.json') && !f.path.endsWith('generator_api.json'))
          f.uri.pathSegments.last.replaceAll('.json', ''),
    ];
    expect(domains, containsAll(['reminders', 'notes', 'journal', 'camera', 'wordProcessor']));
    for (final domain in domains) {
      final catalog = jsonDecode(File('lib/src/catalog/$domain.json').readAsStringSync()) as Map;
      expect(catalog['domain'], domain);
      final library = domain.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
      expect(File('lib/schemas/$library.dart').existsSync(), isTrue, reason: library);
    }
  });

  test('journal.entry adopts createAudioEntry as an opt-in', () {
    const entry = JournalEntry(createEntry: true, createAudioEntry: true);
    expect(entry.schema, 'journal.entry');
    expect(entry.createAudioEntry, isTrue);
    expect(entry.updateEntry, isFalse);
    expect(JournalEntryField.message.name, 'message');
    final catalog = jsonDecode(File('lib/src/catalog/journal.json').readAsStringSync()) as Map;
    expect((catalog['intents'] as Map)['createAudioEntry']['protocols'], ['audioStarting']);
  });

  test('AssistantValue decodes enums, durations and lists', () {
    expect(AssistantValue.enumeration(_Case.values, 'b'), _Case.b);
    expect(AssistantValue.enumeration(_Case.values, 'this'), _Case.this$, reason: r'reserved names end in $');
    expect(AssistantValue.enumeration(_Case.values, 'nope'), isNull);
    expect(AssistantValue.encodeEnum(_Case.this$), 'this');
    expect(AssistantValue.duration(90.5), const Duration(seconds: 90, milliseconds: 500));
    expect(AssistantValue.encodeDuration(const Duration(minutes: 2)), 120);
    expect(AssistantValue.list(['a', 1, 'b'], AssistantValue.string), ['a', 'b']);
    expect(AssistantValue.list('x', AssistantValue.string), isNull);
  });

  test('reminders and notes keep their names from before domain prefixes', () {
    expect(ReminderField.dueDate, same(RemindersReminderField.dueDate));
    expect(const FixedList(id: 'tasks', name: 'Tasks'), isA<FixedRemindersList>());
    expect(NoteField.name, same(NotesNoteField.name));
  });

  test('people, places, files, recurrence and unions round-trip as maps', () {
    const person = AssistantPerson(name: 'Sam', email: 'sam@example.com');
    expect(AssistantValue.person(AssistantValue.encodePerson(person)), person);
    const place = AssistantPlace(name: 'Lake', latitude: 1.5, longitude: -2);
    expect(AssistantValue.place(AssistantValue.encodePlace(place)), place);
    const file = AssistantFile(path: '/tmp/a.m4a', name: 'a.m4a', type: 'com.apple.m4a-audio');
    expect(AssistantValue.file(AssistantValue.encodeFile(file)), file);
    expect(AssistantValue.file({'name': 'no path'}), isNull);
    final rule = AssistantValue.recurrence({'frequency': 'weekly', 'interval': 2})!;
    expect((rule.frequency, rule.interval), ('weekly', 2));
    final union = AssistantValue.union({'case': 'place', 'kind': 'placeDescriptor', 'value': place.toJson()});
    expect(union, const AssistantUnion('place', place));
    expect(AssistantValue.union({'case': 'date', 'kind': 'date', 'value': 0})!.value, DateTime.fromMillisecondsSinceEpoch(0));
    expect(AssistantValue.encodeUnion(AssistantUnion('when', DateTime.fromMillisecondsSinceEpoch(1500))),
        {'case': 'when', 'value': 1.5});
  });
}

enum _Case { a, b, this$ }
