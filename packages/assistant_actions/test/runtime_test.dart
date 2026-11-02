import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  const _Item(this.id, this.name, this.due);
  final String id;
  final String name;
  final DateTime? due;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('assistant_actions');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> inbox;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'drainInbox') {
        final items = inbox;
        inbox = [];
        return items;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('start applies queued calls and changes in order, then marks ready', () async {
    final applied = <String>[];
    inbox = [
      jsonEncode({'kind': 'call', 'action': 'add', 'args': {'n': 2}}),
      jsonEncode({'kind': 'create', 'collection': 'Item', 'id': 'a', 'fields': {'name': 'x'}}),
      jsonEncode({'kind': 'delete', 'collection': 'Item', 'id': 'a'}),
    ];
    await AssistantActions.start(AssistantActionsRegistry(
      actions: {'add': (args) async => (applied..add('add ${args['n']}')).last},
      collections: {'Item': (change) async => applied.add('${change.kind} ${change.id} ${change.fields}')},
    ));
    expect(applied, ['add 2', 'create a {name: x}', 'delete a {}']);
    expect(calls.map((c) => c.method), ['drainInbox', 'markReady']);
  }, skip: Platform.isMacOS ? false : 'AssistantActions only talks to Swift on iOS and macOS');

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
