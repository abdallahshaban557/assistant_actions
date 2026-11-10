import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'bridge/assistant_api.g.dart';
import 'host.dart';
import 'registry.dart';

/// Connects the generated App Intents to the app.
///
/// Dart and Swift call each other directly over FFI (Pigeon native interop);
/// no platform channels are involved.
///
/// ```dart
/// await AssistantActions.start(assistantActionsRegistry(...));
/// AssistantActions.publish(recipes);
/// ```
abstract final class AssistantActions {
  static AssistantActionsRegistry? _registry;
  static AssistantHost? _host;
  static AppLifecycleListener? _lifecycle;
  static Future<void>? _draining;

  static bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Applies what Siri queued while the app wasn't running, then starts
  /// answering live actions. Call once, after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// [host] is for tests; apps leave it out.
  static Future<void> start(AssistantActionsRegistry registry, {@visibleForTesting AssistantHost? host}) async {
    _registry = registry;
    if (host == null && !_supported) return;
    _connect(host ?? FfiAssistantHost(), live: host == null);
    await drain();
    await _host!.markReady();
  }

  /// Whether this Dart runs on the headless engine Swift starts for Siri on
  /// iOS (see `AssistantBackground`), not in the app's own engine.
  static bool get inBackground => _inBackground;
  static bool _inBackground = false;

  /// The headless engine's entrypoint: builds the registry with the
  /// `@AssistantBackground()` function [registry], then does what [start]
  /// does. Generated code calls it from `assistantActionsBackgroundMain`;
  /// apps don't.
  ///
  /// If the app's own engine started meanwhile, Swift declines this one and
  /// it stays idle until Swift shuts it down.
  static Future<void> startInBackground(
    FutureOr<AssistantActionsRegistry> Function() registry, {
    @visibleForTesting AssistantHost? host,
  }) async {
    if (host == null) {
      if (!_supported) return;
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
    }
    _inBackground = true;
    final built = await registry();
    final target = host ?? FfiAssistantHost();
    if (target is! AssistantHostCalls) return;
    final calls = target as AssistantHostCalls;
    // Claiming and setting up the Flutter API happen with no await between
    // them, so the app's engine can't start in the middle.
    if (await calls.invoke('background.claim', '{}') != 'true') return;
    _registry = built;
    _connect(target, live: host == null);
    await drain();
    // Not markReady: Swift ignores this engine if the app's started since.
    await calls.invoke('background.ready', '{}');
  }

  static void _connect(AssistantHost host, {required bool live}) {
    _host = host;
    if (live) AssistantFlutterApi.setUp(_FlutterApi());
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(drain()));
  }

  /// Publishes the current [items] of an `@AssistantEntity` or schema entity
  /// class, so Siri can find them without the app running. Call it whenever
  /// they change.
  static Future<void> publish<T>(Iterable<T> items) async {
    final codec = _registry?.codecs[T];
    if (codec == null) {
      throw StateError('No entity codec for $T. Is it annotated, and was start() called?');
    }
    final host = _host;
    if (host == null) return;
    final json = jsonEncode({'records': [for (final item in items) codec.encode(item)]});
    await host.publish(codec.collection, json);
  }

  /// Applies queued calls and changes now. [start] and app resumes do this
  /// automatically.
  static Future<void> drain() {
    // One drain at a time, so a resume during start doesn't apply items twice.
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  static Future<void> _drain() async {
    final registry = _registry;
    final host = _host;
    if (registry == null || host == null) return;
    for (final raw in await host.drainInbox()) {
      final item = (jsonDecode(raw) as Map).cast<String, Object?>();
      try {
        if (item['kind'] == 'call') {
          final handler = registry.actions[item['action']];
          await handler?.call((item['args'] as Map?)?.cast<String, Object?>() ?? const {});
        } else {
          final change = InboxChange.fromJson(item);
          await registry.collections[change.collection]?.call(change);
        }
      } catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'assistant_actions',
          context: ErrorDescription('while applying a queued Siri ${item['kind']}'),
        ));
      }
    }
  }

  /// Runs Swift feature [method] (registered with `AssistantHostCalls` in
  /// Swift) with [args] and returns its decoded JSON result. For features of
  /// assistant_actions; null when the runtime isn't started or there is no
  /// Swift side (tests with a plain [AssistantHost]).
  @internal
  static Future<Object?> callSwift(String method, [Map<String, Object?> args = const {}]) async {
    final host = _host;
    if (host is! AssistantHostCalls) return null;
    final result = await (host as AssistantHostCalls).invoke(method, jsonEncode(args));
    return result == null ? null : jsonDecode(result);
  }

  /// Runs a `Runs.withFlutter` action for Swift.
  @visibleForTesting
  static Future<String?> perform(String action, String argsJson) async {
    final handler = _registry?.actions[action];
    if (handler == null) throw ArgumentError.value(action, 'action', 'Unknown action');
    return handler((jsonDecode(argsJson) as Map).cast<String, Object?>());
  }
}

/// The Pigeon Flutter API Swift calls over FFI.
class _FlutterApi implements AssistantFlutterApi {
  @override
  Future<String?> perform(String action, String argsJson) => AssistantActions.perform(action, argsJson);

  @override
  void inboxChanged() => unawaited(AssistantActions.drain());
}
