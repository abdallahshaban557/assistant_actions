import 'dart:async';
import 'dart:convert';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Swift side that records the host calls Dart makes.
class _Host implements AssistantHost, AssistantHostCalls {
  final invoked = <(String, Map<String, Object?>)>[];

  @override
  Future<List<String>> drainInbox() async => const [];

  @override
  Future<void> markReady() async {}

  @override
  Future<void> publish(String collection, String json) async {}

  @override
  Future<String?> invoke(String method, String argsJson) async {
    invoked.add((method, (jsonDecode(argsJson) as Map).cast()));
    return 'true';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a live call runs its handler as AssistantCall.current, which reports progress', () async {
    final host = _Host();
    AssistantCall? seen;
    await AssistantActions.start(
      AssistantActionsRegistry(actions: {
        'export': (args) async {
          seen = AssistantCall.current;
          expect(args.containsKey(AssistantCall.argument), isFalse, reason: 'the call id is not an argument');
          expect(await seen!.reportProgress(completed: 1, total: 4), isTrue);
          return 'ok ${args['n']}';
        },
      }),
      host: host,
    );
    expect(await AssistantActions.perform('export', jsonEncode({'n': 2, AssistantCall.argument: 'c1'})), 'ok 2');
    expect(seen?.id, 'c1');
    expect(host.invoked.single.$1, 'call.progress');
    expect(host.invoked.single.$2, {'call': 'c1', 'completed': 1, 'total': 4});
    expect(AssistantCall.current, isNull);
  });

  test('Swift cancels a running call; calls without an id have none', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    late AssistantCall call;
    await AssistantActions.start(
      AssistantActionsRegistry(actions: {
        'wait': (args) async {
          call = AssistantCall.current!;
          started.complete();
          await Future.any([call.whenCancelled, release.future]);
          return call.isCancelled ? 'cancelled' : 'done';
        },
        'plain': (args) async => '${AssistantCall.current}',
      }),
      host: _Host(),
    );
    final reply = AssistantActions.perform('wait', jsonEncode({AssistantCall.argument: 'c2'}));
    await started.future;
    expect(await AssistantActions.perform(AssistantCall.cancelAction, jsonEncode({'call': 'c2'})), isNull);
    expect(await reply, 'cancelled');
    expect(await call.reportProgress(completed: 1, total: 1), isFalse, reason: 'cancelled calls report nothing');
    expect(AssistantCall.cancel('c2'), isFalse, reason: 'finished calls are forgotten');
    expect(await AssistantActions.perform('plain', '{}'), 'null');
  });
}
