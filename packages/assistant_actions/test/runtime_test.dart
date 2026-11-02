import 'dart:convert';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/src/host.dart';
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
}
