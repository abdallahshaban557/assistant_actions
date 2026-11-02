import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'registry.dart';

/// Connects the generated App Intents to the app.
///
/// ```dart
/// await AssistantActions.start(assistantActionsRegistry(...));
/// AssistantActions.publish(recipes);
/// ```
abstract final class AssistantActions {
  static const _channel = MethodChannel('assistant_actions');

  static AssistantActionsRegistry? _registry;
  static AppLifecycleListener? _lifecycle;
  static Future<void>? _draining;

  static bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Applies what Siri queued while the app wasn't running, then starts
  /// answering live actions. Call once, after `WidgetsFlutterBinding.ensureInitialized()`.
  static Future<void> start(AssistantActionsRegistry registry) async {
    _registry = registry;
    if (!_supported) return;
    _channel.setMethodCallHandler(_handle);
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(drain()));
    await drain();
    await _channel.invokeMethod<void>('markReady');
  }

  /// Publishes the current [items] of an `@AssistantEntity` or schema entity
  /// class, so Siri can find them without the app running. Call it whenever
  /// they change.
  static Future<void> publish<T>(Iterable<T> items) async {
    final codec = _registry?.codecs[T];
    if (codec == null) {
      throw StateError('No entity codec for $T. Is it annotated, and was start() called?');
    }
    if (!_supported) return;
    final json = jsonEncode({'records': [for (final item in items) codec.encode(item)]});
    await _channel.invokeMethod<void>('publish', {'collection': codec.collection, 'json': json});
  }

  /// Applies queued calls and changes now. [start] and app resumes do this
  /// automatically.
  static Future<void> drain() {
    // One drain at a time, so a resume during start doesn't apply items twice.
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  static Future<void> _drain() async {
    final registry = _registry;
    if (registry == null || !_supported) return;
    final items = await _channel.invokeListMethod<String>('drainInbox') ?? const [];
    for (final raw in items) {
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

  static Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'inboxChanged':
        await drain();
        return null;
      case 'perform':
        final args = (call.arguments as Map).cast<String, Object?>();
        final handler = _registry?.actions[args['action']];
        if (handler == null) {
          throw PlatformException(code: 'unknown-action', message: '${args['action']}');
        }
        return handler((args['args'] as Map?)?.cast<String, Object?>() ?? const {});
      default:
        throw MissingPluginException(call.method);
    }
  }
}
