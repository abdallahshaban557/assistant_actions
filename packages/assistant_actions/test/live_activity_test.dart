import 'dart:convert';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plays the Swift side of `liveActivity.*` (AssistantLiveActivities.swift).
class _ActivityHost implements AssistantHost, AssistantHostCalls {
  _ActivityHost({this.enabled = true});

  final bool enabled;
  final calls = <(String, Map<String, Object?>)>[];
  final activities = <String, Map<String, Object?>>{};

  @override
  Future<List<String>> drainInbox() async => const [];

  @override
  Future<void> markReady() async {}

  @override
  Future<void> publish(String collection, String json) async {}

  @override
  Future<String?> invoke(String method, String argsJson) async {
    final args = (jsonDecode(argsJson) as Map).cast<String, Object?>();
    calls.add((method, args));
    final Object? result = switch (method) {
      'liveActivity.enabled' => enabled,
      'liveActivity.start' when enabled => (activities['a${activities.length + 1}'] = {
          'id': 'a${activities.length + 1}',
          'kind': args['kind'],
          'state': 'active',
        }),
      'liveActivity.start' => null,
      'liveActivity.update' => activities.containsKey(args['id']),
      'liveActivity.end' => activities.remove(args['id']) != null,
      'liveActivity.list' => activities.values.toList(),
      'liveActivity.pushToken' => pushTokens[args['id']],
      'liveActivity.observePushToStart' => initialPushToStartToken,
      'liveActivity.stopPushToStart' => null,
      'liveActivity.observePushTokens' => pushTokens[args['id']],
      'liveActivity.stopPushTokens' => null,
      _ => throw StateError('No Swift handler for $method'),
    };
    return jsonEncode(result);
  }

  String? initialPushToStartToken;
  final pushTokens = <String, String>{};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('content crosses to Swift as JSON, dates in Unix seconds', () {
    final start = DateTime.fromMillisecondsSinceEpoch(1500);
    final content = AssistantActivityContent(
      title: 'Recording',
      subtitle: 'Journal',
      systemImage: 'mic.fill',
      timerStart: start,
      data: const {'entry': 'j1'},
      relevanceScore: 2,
    );
    expect(content.toJson(), {
      'content': {
        'title': 'Recording',
        'subtitle': 'Journal',
        'systemImage': 'mic.fill',
        'timerStart': 1.5,
        'data': '{"entry":"j1"}',
      },
      'relevanceScore': 2.0,
    });
    expect(const AssistantActivityContent(title: 'x').toJson()['content'], {'title': 'x'},
        reason: 'unset fields are left out');
  });

  test('start, update, list and end go through the named Swift calls', () async {
    final host = _ActivityHost();
    await AssistantActions.start(const AssistantActionsRegistry(), host: host);
    expect(await AssistantLiveActivity.areEnabled(), isTrue);

    final activity = await AssistantLiveActivity.start(
      const AssistantActivityContent(title: 'Recording', progress: 0.5),
      kind: 'recording',
      data: const {'entry': 'j1'},
    );
    expect(activity?.id, 'a1');
    expect(activity?.kind, 'recording');
    final (method, args) = host.calls.last;
    expect(method, 'liveActivity.start');
    expect(args, {
      'kind': 'recording',
      'data': '{"entry":"j1"}',
      'content': {'title': 'Recording', 'progress': 0.5},
      'relevanceScore': 0.0,
    });

    expect(await activity!.update(const AssistantActivityContent(title: 'Saving'), alertTitle: 'Done'), isTrue);
    expect(host.calls.last.$2['alert'], {'title': 'Done', 'body': ''});
    expect(await AssistantLiveActivity.running(), [activity]);

    expect(await activity.end(dismissal: AssistantActivityDismissal.immediate), isTrue);
    expect(host.calls.last.$2, {'id': 'a1', 'dismissal': 'immediate'});
    expect(await activity.end(), isFalse, reason: 'it had already ended');
    expect(await activity.update(const AssistantActivityContent(title: 'x')), isFalse);
    expect(await AssistantLiveActivity.running(), isEmpty);
  });

  test('ending after a date needs the date', () async {
    final host = _ActivityHost();
    await AssistantActions.start(const AssistantActionsRegistry(), host: host);
    final activity = (await AssistantLiveActivity.start(const AssistantActivityContent(title: 'x')))!;
    expect(() => activity.end(dismissal: AssistantActivityDismissal.after), throwsArgumentError);
    expect(
        await activity.end(
            dismissal: AssistantActivityDismissal.after,
            dismissAt: DateTime.fromMillisecondsSinceEpoch(2000),
            content: const AssistantActivityContent(title: 'Saved')),
        isTrue);
    expect(host.calls.last.$2, {
      'id': 'a1',
      'content': {'title': 'Saved'},
      'relevanceScore': 0.0,
      'dismissal': 'after',
      'dismissAt': 2.0,
    });
  });

  test('start returns null where Live Activities are unavailable', () async {
    await AssistantActions.start(const AssistantActionsRegistry(), host: _ActivityHost(enabled: false));
    expect(await AssistantLiveActivity.areEnabled(), isFalse);
    expect(await AssistantLiveActivity.start(const AssistantActivityContent(title: 'x')), isNull);
  });

  test('interactive buttons serialize actionId, label, systemImage and encoded args', () {
    final when = DateTime.fromMillisecondsSinceEpoch(2500);
    final b1 = AssistantLiveActivityButton(
      label: 'Pause',
      actionId: 'pauseWorkout',
      systemImage: 'pause.fill',
      args: {'id': 'w1', 'at': when},
    );
    const b2 = AssistantLiveActivityButton(label: 'Stop', actionId: 'stopWorkout');
    final content = AssistantActivityContent(title: 'Running', buttons: [b1, b2]);
    expect(content.toJson()['content'], {
      'title': 'Running',
      'buttons': [
        {
          'label': 'Pause',
          'actionId': 'pauseWorkout',
          'systemImage': 'pause.fill',
          'args': '{"id":"w1","at":2.5}',
        },
        {
          'label': 'Stop',
          'actionId': 'stopWorkout',
        },
      ],
    });
    expect(
      AssistantLiveActivityButton(
        label: 'Pause',
        actionId: 'pauseWorkout',
        systemImage: 'pause.fill',
        args: {'id': 'w1', 'at': when},
      ),
      equals(b1),
    );
  });

  test('APNs push tokens: enablePush, pushToken, pushTokens and pushToStartTokens', () async {
    final host = _ActivityHost()
      ..initialPushToStartToken = 'aa11'
      ..pushTokens['a1'] = 'bb22';
    await AssistantActions.start(const AssistantActionsRegistry(), host: host);

    final pushToStartReceived = <String>[];
    final startSub = AssistantLiveActivity.pushToStartTokens().listen(pushToStartReceived.add);
    await Future<void>.delayed(Duration.zero);
    expect(pushToStartReceived, ['aa11']);

    await AssistantActions.perform(
      'assistant_actions.liveActivityPushToken',
      jsonEncode({'kind': 'pushToStart', 'token': 'aa11'}),
    );
    await AssistantActions.perform(
      'assistant_actions.liveActivityPushToken',
      jsonEncode({'kind': 'pushToStart', 'token': 'cc33'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(pushToStartReceived, ['aa11', 'cc33'], reason: 'duplicate tokens are deduplicated');
    await startSub.cancel();
    expect(host.calls.last.$1, 'liveActivity.stopPushToStart');

    final activity = (await AssistantLiveActivity.start(
      const AssistantActivityContent(title: 'Delivery'),
      kind: 'delivery',
      enablePush: true,
    ))!;
    expect(host.calls.last.$2['enablePush'], isTrue);
    expect(await activity.pushToken(), 'bb22');

    final activityTokens = <String>[];
    var closed = false;
    final tokenSub = activity.pushTokens().listen(activityTokens.add, onDone: () => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(activityTokens, ['bb22']);

    await AssistantActions.perform(
      'assistant_actions.liveActivityPushToken',
      jsonEncode({'kind': 'activity', 'id': 'a1', 'token': 'dd44'}),
    );
    await AssistantActions.perform(
      'assistant_actions.liveActivityPushToken',
      jsonEncode({'kind': 'activity', 'id': 'a1', 'done': true}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(activityTokens, ['bb22', 'dd44']);
    expect(closed, isTrue);
    await tokenSub.cancel();
  });
}
