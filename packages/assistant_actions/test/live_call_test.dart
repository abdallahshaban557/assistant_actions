import 'dart:async';
import 'dart:convert';

import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

class _Recipe {
  const _Recipe(this.id, this.title);
  final String id;
  final String title;
}

enum _Size { small, extraLarge }

/// A Swift side that records host calls and answers `call.prompt` asynchronously
/// via `AssistantCall.promptReplyAction`, just like `AssistantLiveCall` in Swift.
class _Host implements AssistantHost, AssistantHostCalls {
  _Host({this.onPrompt});

  final FutureOr<Map<String, Object?>> Function(Map<String, Object?> args)? onPrompt;
  final invoked = <(String, Map<String, Object?>)>[];

  @override
  Future<List<String>> drainInbox() async => const [];

  @override
  Future<void> markReady() async {}

  @override
  Future<void> publish(String collection, String json) async {}

  @override
  Future<String?> invoke(String method, String argsJson) async {
    final args = (jsonDecode(argsJson) as Map).cast<String, Object?>();
    invoked.add((method, args));
    if (method == 'call.prompt' && onPrompt != null) {
      unawaited(Future<void>.delayed(Duration.zero, () async {
        final reply = await onPrompt!(args);
        await AssistantActions.perform(
          AssistantCall.promptReplyAction,
          jsonEncode({
            'call': args['call'],
            'promptId': args['promptId'],
            ...reply,
          }),
        );
      }));
      return jsonEncode({'pending': true});
    }
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

  test('confirm and choose ask Siri mid-call and resume Dart with the answer', () async {
    final host = _Host(onPrompt: (args) {
      if (args['kind'] == 'confirm') {
        return {'value': args['actionLabel'] == 'Delete'};
      }
      if (args['kind'] == 'choose') {
        final choices = (args['choices'] as List).cast<Map<String, Object?>>();
        return {'value': choices.last['id']};
      }
      return const {'cancelled': true};
    });

    await AssistantActions.start(
      AssistantActionsRegistry(actions: {
        'cleanup': (args) async {
          final call = AssistantCall.current!;
          final ok = await call.confirm('Delete old drafts?', actionLabel: 'Delete');
          final nope = await call.confirm('Also wipe backups?');
          final picked = await call.choose('Which folder?', const [
            AssistantChoice('inbox', 'Inbox'),
            AssistantChoice('trash', 'Trash', destructive: true),
          ]);
          return '$ok,$nope,$picked';
        },
      }),
      host: host,
    );

    final result = await AssistantActions.perform('cleanup', jsonEncode({AssistantCall.argument: 'c3'}));
    expect(result, 'true,false,trash');
    expect(host.invoked.map((e) => e.$2['kind']).toList(), ['confirm', 'confirm', 'choose']);
    expect(host.invoked.last.$2['choices'], [
      {'id': 'inbox', 'title': 'Inbox'},
      {'id': 'trash', 'title': 'Trash', 'destructive': true},
    ]);
  });

  test('requestValue and disambiguate decode primitives, enums and entities mid-call', () async {
    const soup = _Recipe('r1', 'Soup');
    const pie = _Recipe('r2', 'Pie');
    final recipes = {'r1': soup, 'r2': pie};

    final host = _Host(onPrompt: (args) => switch ((args['kind'], args['param'])) {
          ('requestValue', 'servings') => const {'value': 4},
          ('requestValue', 'when') => const {'value': 1.5},
          ('requestValue', 'size') => const {'value': 'extraLarge'},
          ('requestValue', 'recipe') => const {'value': 'r2'},
          ('requestValue', 'cancelledParam') => const {'cancelled': true},
          ('requestValue', 'unknownParam') => const {'error': 'No promptable parameter'},
          ('disambiguate', 'recipe') => {'value': (args['choices'] as List).first},
          ('disambiguate', 'size') => {'value': (args['choices'] as List).last},
          _ => const {'cancelled': true},
        });

    await AssistantActions.start(
      AssistantActionsRegistry(
        codecs: {
          _Recipe: EntityCodec<_Recipe>('Recipe', id: (r) => r.id, title: (r) => r.title, fields: (_) => const {}),
        },
        decoders: {
          _Recipe: (v) async => v is String ? recipes[v] : null,
          _Size: (v) => AssistantValue.enumeration(_Size.values, v),
        },
        actions: {
          'cook': (args) async {
            final call = AssistantCall.current!;
            final servings = await call.requestValue<int>('servings', prompt: 'How many servings?');
            final when = await call.requestValue<DateTime>('when');
            final size = await call.requestValue<_Size>('size');
            final requested = await call.requestValue<_Recipe>('recipe');
            final skipped = await call.requestValue<String>('cancelledParam');
            final chosenRecipe = await call.disambiguate<_Recipe>('recipe', const [soup, pie], prompt: 'Which dish?');
            final chosenSize = await call.disambiguate<_Size>('size', const [_Size.small, _Size.extraLarge]);
            await expectLater(
              () => call.requestValue<String>('unknownParam'),
              throwsArgumentError,
            );
            return '$servings,${when?.millisecondsSinceEpoch},${size?.name},${requested?.title},'
                '$skipped,${chosenRecipe?.id},${chosenSize?.name}';
          },
        },
      ),
      host: host,
    );

    final out = await AssistantActions.perform('cook', jsonEncode({AssistantCall.argument: 'c4'}));
    expect(out, '4,1500,extraLarge,Pie,null,r1,extraLarge');
    final disambiguateCalls = host.invoked.where((c) => c.$2['kind'] == 'disambiguate').toList();
    expect(disambiguateCalls[0].$2['choices'], ['r1', 'r2'], reason: 'entities encode as their ids');
    expect(disambiguateCalls[1].$2['choices'], ['small', 'extraLarge'], reason: 'enums encode as case names');
  });

  test('requestValue and disambiguate support currency, all 6 measurements, and list variants', () async {
    final host = _Host(onPrompt: (args) => switch ((args['kind'], args['param'])) {
          ('requestValue', 'cost') => const {
              'value': {'amount': 12.5, 'currencyCode': 'usd'}
            },
          ('requestValue', 'distance') => const {
              'value': {'value': 5.0, 'unit': 'kilometers'}
            },
          ('requestValue', 'mass') => const {
              'value': {'value': 250.0, 'unit': 'grams'}
            },
          ('requestValue', 'temp') => const {
              'value': {'value': 93.0, 'unit': 'celsius'}
            },
          ('requestValue', 'vol') => const {
              'value': {'value': 500.0, 'unit': 'milliliters'}
            },
          ('requestValue', 'speed') => const {
              'value': {'value': 10.0, 'unit': 'metersPerSecond'}
            },
          ('requestValue', 'energy') => const {
              'value': {'value': 400.0, 'unit': 'kilocalories'}
            },
          ('disambiguate', 'cost') => {'value': (args['choices'] as List).last},
          _ => const {'cancelled': true},
        });

    await AssistantActions.start(
      AssistantActionsRegistry(
        actions: {
          'measure': (args) async {
            final call = AssistantCall.current!;
            final cost = await call.requestValue<AssistantCurrency>('cost');
            final dist = await call.requestValue<AssistantLength>('distance');
            final mass = await call.requestValue<AssistantMass>('mass');
            final temp = await call.requestValue<AssistantTemperature>('temp');
            final vol = await call.requestValue<AssistantVolume>('vol');
            final speed = await call.requestValue<AssistantSpeed>('speed');
            final energy = await call.requestValue<AssistantEnergy>('energy');
            final picked = await call.disambiguate<AssistantCurrency>('cost', const [
              AssistantCurrency(amount: 5, currencyCode: 'USD'),
              AssistantCurrency(amount: 9.5, currencyCode: 'EUR'),
            ]);
            return '${cost?.amount}:${cost?.currencyCode},'
                '${dist?.value}:${dist?.unit.name},'
                '${mass?.value}:${mass?.unit.name},'
                '${temp?.value}:${temp?.unit.name},'
                '${vol?.value}:${vol?.unit.name},'
                '${speed?.value}:${speed?.unit.name},'
                '${energy?.value}:${energy?.unit.name},'
                '${picked?.amount}:${picked?.currencyCode}';
          },
        },
      ),
      host: host,
    );

    final out = await AssistantActions.perform('measure', jsonEncode({AssistantCall.argument: 'c4_rich'}));
    expect(
      out,
      '12.5:USD,5.0:kilometers,250.0:grams,93.0:celsius,500.0:milliliters,10.0:metersPerSecond,400.0:kilocalories,9.5:EUR',
    );
  });

  test('cancelling a choose prompt or cancelling the call unblocks pending prompts cleanly', () async {
    final promptSent = Completer<void>();
    final host = _Host(onPrompt: (args) async {
      if (args['prompt'] == 'hang') {
        promptSent.complete();
        await Completer<void>().future;
      }
      return const {'cancelled': true};
    });

    await AssistantActions.start(
      AssistantActionsRegistry(actions: {
        'cancelledChoose': (args) async {
          final call = AssistantCall.current!;
          expect(() => call.choose('Empty?', const []), throwsArgumentError);
          return call.choose('Pick one', const [AssistantChoice('a', 'A')]);
        },
        'hangConfirm': (args) async {
          final ok = await AssistantCall.current!.confirm('hang');
          return 'ok=$ok';
        },
      }),
      host: host,
    );

    await expectLater(
      () => AssistantActions.perform('cancelledChoose', jsonEncode({AssistantCall.argument: 'c5'})),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'assistant_actions.cancelled')),
    );

    final hanging = AssistantActions.perform('hangConfirm', jsonEncode({AssistantCall.argument: 'c6'}));
    await promptSent.future;
    await AssistantActions.perform(AssistantCall.cancelAction, jsonEncode({'call': 'c6'}));
    expect(await hanging, 'ok=false');
  });
}
