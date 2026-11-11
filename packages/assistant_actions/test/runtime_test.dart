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

  test('intents run on a locked device unless an annotation says otherwise', () {
    expect(const AssistantActionsApp(name: 'App').requiresUnlock, Unlock.notRequired);
    expect(const AssistantAction(title: 'Go').requiresUnlock, isNull, reason: 'null inherits');
    expect(const AssistantEntity(title: 'Item').requiresUnlock, isNull);
    expect(const AssistantAction(title: 'Go', summary: 'Go {there}').summary, 'Go {there}');
    expect(const AssistantEntity(title: 'Item', systemImage: 'book').systemImage, 'book');
    expect(const CaseTitle('Snack', systemImage: 'moon').systemImage, 'moon');
    // Apple's order, least restrictive first: the generator relies on it.
    expect(Unlock.values, [Unlock.notRequired, Unlock.required, Unlock.onThisDevice]);
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

  test('callSwift runs a named Swift handler over the host, when it has one', () async {
    final host = _CallingHost();
    await AssistantActions.start(const AssistantActionsRegistry(), host: host);
    expect(await AssistantActions.callSwift('echo', {'a': 1}), {'method': 'echo', 'args': {'a': 1}});
    await AssistantActions.start(const AssistantActionsRegistry(), host: _FakeHost([]));
    expect(await AssistantActions.callSwift('echo'), isNull, reason: 'plain hosts have no Swift calls');
  });

  group('AssistantReply', () {
    test('encodes the dialog, a card and the value for Swift', () {
      const reply = AssistantReply<String>(
        value: 't1',
        dialog: 'Opened it.',
        card: AssistantCard(
          title: 'Pancakes',
          subtitle: '20 min',
          rows: [AssistantCardRow('Serves', '4'), AssistantCardRow('Vegan', 'No')],
          imagePath: '/tmp/p.png',
          systemImage: 'fork.knife',
        ),
      );
      expect(jsonDecode(AssistantReply.encode(reply)), {
        'value': 't1',
        'dialog': 'Opened it.',
        'card': {
          'title': 'Pancakes',
          'subtitle': '20 min',
          'rows': [
            ['Serves', '4'],
            ['Vegan', 'No'],
          ],
          'imagePath': '/tmp/p.png',
          'systemImage': 'fork.knife',
        },
      });
    });

    test('leaves out what is not set, and encodes values like fields', () {
      expect(jsonDecode(AssistantReply.encode(const AssistantReply<void>())), isEmpty);
      expect(jsonDecode(AssistantReply.encode(null)), isEmpty);
      expect(jsonDecode(AssistantReply.encode(const AssistantReply(card: AssistantCard(title: 'T')))), {
        'card': {'title': 'T'},
      });
      final union = AssistantReply(value: AssistantUnion('when', DateTime.fromMillisecondsSinceEpoch(1500)));
      expect(jsonDecode(AssistantReply.encode(union)), {
        'value': {'case': 'when', 'value': 1.5},
      });
    });

    test('choose sends the ids to ask about and the question', () {
      expect(jsonDecode(AssistantReply.encode(const AssistantReply<String>.choose(['a', 'b'], prompt: 'Which tab?'))), {
        'choices': ['a', 'b'],
        'prompt': 'Which tab?',
      });
    });

    test('perform returns what a registry entry encoded', () async {
      await AssistantActions.start(
          AssistantActionsRegistry(actions: {
            'show': (args) async => AssistantReply.encode(AssistantReply<void>(dialog: 'Hi ${args['name']}.')),
          }),
          host: _FakeHost([]));
      expect(jsonDecode((await AssistantActions.perform('show', '{"name":"Mira"}'))!), {'dialog': 'Hi Mira.'});
    });
  });

  test('action results reach Swift as JSON with an optional dialog', () async {
    expect(jsonDecode(AssistantValue.encodeResult(3, dialog: 'Three.')), {'value': 3, 'dialog': 'Three.'});
    expect(jsonDecode(AssistantValue.encodeResult(['a', 'b'])), {
      'value': ['a', 'b'],
    });
    expect(jsonDecode(AssistantValue.encodeResult(null)), {'value': null});
    expect(
        jsonDecode(AssistantReply.encodeValue(
            const AssistantReply(value: _Case.a, dialog: 'One.', card: AssistantCard(title: 'A')), 'id-a')),
        {
          'value': 'id-a',
          'dialog': 'One.',
          'card': {'title': 'A'},
        },
        reason: 'a reply carries the encoded value (an entity as its id) with its dialog and card');
    expect(jsonDecode(AssistantReply.encodeValue(const AssistantReply.choose(['a', 'b']), null)), {
      'choices': ['a', 'b'],
    });
    const result = ActionResult(2, dialog: 'Two.');
    expect((result.value, result.dialog), (2, 'Two.'));

    await AssistantActions.start(
        AssistantActionsRegistry(actions: {
          'count': (args) async => AssistantValue.encodeResult(args['n'], dialog: 'Counted.'),
        }),
        host: _FakeHost([]));
    expect(jsonDecode((await AssistantActions.perform('count', '{"n":4}'))!), {'value': 4, 'dialog': 'Counted.'});
  });

  test('App Enums and shortcut options are const annotations', () {
    const tile = AssistantActionsApp(name: 'Mira', shortcutTileColor: ShortcutTileColor.grape);
    expect(tile.shortcutTileColor, ShortcutTileColor.grape);
    const shortcut = IntentShortcut('camera.startCapture', phrases: ['Open {app}'], shortTitle: 'Camera', systemImage: 'camera');
    expect(shortcut, isA<AppShortcut>());
    expect(const CaseTitle('Extra large', synonyms: ['XL']).synonyms, ['XL']);
    expect(const AssistantAction(title: 'T').isDiscoverable, isTrue);
    expect(ShortcutTileColor.values.length, 15, reason: "one per App Intents' ShortcutTileColor case");
  });
  test('startInBackground claims the headless engine, drains, then reports ready over host calls', () async {
    final applied = <String>[];
    final host = _BackgroundHost(claim: true, [jsonEncode({'kind': 'call', 'action': 'add', 'args': {'n': 1}})]);
    await AssistantActions.startInBackground(
      () async => AssistantActionsRegistry(actions: {'add': (args) async => (applied..add('add ${args['n']}')).last}),
      host: host,
    );
    expect(AssistantActions.inBackground, isTrue);
    expect(applied, ['add 1']);
    expect(host.calls, ['invoke background.claim', 'drainInbox', 'invoke background.ready'],
        reason: 'ready goes through background.ready, never markReady');
    expect(await AssistantActions.perform('add', jsonEncode({'n': 2})), 'add 2');
  });

  test('the drain action applies the inbox and answers once it is applied', () async {
    final applied = <String>[];
    final host = _FakeHost([]);
    await AssistantActions.start(
      AssistantActionsRegistry(actions: {'add': (args) async => (applied..add('add ${args['n']}')).last}),
      host: host,
    );
    host.inbox = [jsonEncode({'kind': 'call', 'action': 'add', 'args': {'n': 7}})];
    expect(await AssistantActions.perform(AssistantActions.drainAction, '{}'), isNull);
    expect(applied, ['add 7']);
  });

  test('startInBackground stands down when Swift declines (the app engine started)', () async {
    final host = _BackgroundHost(claim: false, [jsonEncode({'kind': 'call', 'action': 'add', 'args': {}})]);
    var built = false;
    await AssistantActions.startInBackground(() {
      built = true;
      return const AssistantActionsRegistry();
    }, host: host);
    expect(built, isTrue);
    expect(host.calls, ['invoke background.claim'], reason: 'the inbox is left for the app engine');
    expect(host.inbox, hasLength(1));
  });
  group('Apple Intelligence in context', () {
    final registry = AssistantActionsRegistry(codecs: {
      _Item: EntityCodec<_Item>('Item', id: (e) => e.id, title: (e) => e.name, fields: (e) => const {}),
    });
    const walk = _Item('w1', 'Walk', null);

    test('showing, stopShowing and donate name the item to Swift', () async {
      final host = _CallingHost();
      await AssistantActions.start(registry, host: host);
      expect(await AssistantActions.showing(walk), isFalse, reason: 'the echo host returns no true');
      await AssistantActions.stopShowing();
      await AssistantActions.donate(walk);
      await AssistantActions.donateAction('pinNote', {'note': 'w1', 'times': 2});
      expect(host.invoked, [
        ['context.showing', {'collection': 'Item', 'id': 'w1'}],
        ['context.stopShowing', <String, Object?>{}],
        ['donate.entity', {'collection': 'Item', 'id': 'w1'}],
        [
          'donate.action',
          {
            'action': 'pinNote',
            'args': {'note': 'w1', 'times': 2},
          },
        ],
      ]);
    });

    test('showing reports what Swift did, and needs an entity class', () async {
      await AssistantActions.start(registry, host: _CallingHost(reply: 'true'));
      expect(await AssistantActions.showing(walk), isTrue);
      expect(await AssistantActions.showing<Object>(walk), isTrue, reason: 'found by runtime type');
      expect(() => AssistantActions.showing('not an entity'), throwsStateError);
      await AssistantActions.start(registry, host: _FakeHost([]));
      expect(await AssistantActions.donate(walk), isFalse, reason: 'no Swift side');
    });

    test('Visual Intelligence content decodes labels and the image', () {
      final content = AssistantValue.semanticContent({
        'labels': ['dog', 3, 'golden retriever'],
        'image': {'path': '/tmp/image.png', 'name': 'image.png', 'type': 'public.png'},
      })!;
      expect(content.labels, ['dog', 'golden retriever']);
      expect(content.image, const AssistantFile(path: '/tmp/image.png', name: 'image.png', type: 'public.png'));
      expect(AssistantSemanticContent.fromJson(content.toJson()), content);
      expect(AssistantValue.semanticContent({'labels': <String>[]})!.image, isNull);
      expect(AssistantValue.semanticContent('nope'), isNull);
    });

    test('schema and plain entity annotations take a deep link and Visual Intelligence', () {
      const entry = JournalEntry(createEntry: true, url: 'mira://journal/{id}', visualSearch: true);
      expect((entry.url, entry.visualSearch), ('mira://journal/{id}', true));
      expect(const NotesNote().url, isNull);
      const recipe = AssistantEntity(title: 'Recipe', url: 'cook://recipes/{id}');
      expect((recipe.url, recipe.visualSearch), ('cook://recipes/{id}', false));
      final catalog = jsonDecode(File('lib/src/catalog/journal.json').readAsStringSync()) as Map;
      expect((catalog['queries'] as Map)['entryTransferable']['property'], 'location');
    });
  });
}

class _BackgroundHost extends _FakeHost implements AssistantHostCalls {
  _BackgroundHost(super.inbox, {required this.claim});

  final bool claim;

  @override
  Future<String?> invoke(String method, String argsJson) async {
    calls.add('invoke $method');
    return method == 'background.claim' ? jsonEncode(claim) : null;
  }
}

enum _Case { a, b, this$ }

class _CallingHost extends _FakeHost implements AssistantHostCalls {
  _CallingHost({this.reply}) : super([]);

  /// What every call returns; by default it echoes the call.
  final String? reply;
  final invoked = <List<Object?>>[];

  @override
  Future<String?> invoke(String method, String argsJson) async {
    invoked.add([method, jsonDecode(argsJson)]);
    return reply ?? jsonEncode({'method': method, 'args': jsonDecode(argsJson)});
  }
}
