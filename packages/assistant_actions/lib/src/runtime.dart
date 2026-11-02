import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    _host = host ?? FfiAssistantHost();
    if (host == null) AssistantFlutterApi.setUp(_FlutterApi());
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(drain()));
    await drain();
    await _host!.markReady();
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
