import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';

import 'bridge/assistant_api.g.dart';
import 'error.dart';
import 'host.dart';
import 'live_activity.dart';
import 'live_call.dart';
import 'param_options.dart';
import 'registry.dart';
import 'values.dart';

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

  /// Whether the registry has action [id] (for `AssistantCardButton`); null
  /// before [start].
  @internal
  static bool? hasAction(String id) => _registry?.actions.containsKey(id);

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

  /// Tells Siri and Apple Intelligence that [item] (of an `@AssistantEntity`
  /// or schema entity class) is what's on screen, so "remind me about this"
  /// or "summarize this" mean it. Call it when the item's screen appears,
  /// and [stopShowing] when it goes.
  ///
  /// The item becomes the `appEntityIdentifier` of an `NSUserActivity` on
  /// the app's key window (iOS 18.2+ / macOS 15.2+, and the OS version the
  /// entity's schema needs). Returns whether it was attached: false on older
  /// systems, without a window, or before [start].
  static Future<bool> showing<T>(T item) async {
    final codec = _codec<T>(item);
    return await callSwift('context.showing', {'collection': codec.collection, 'id': codec.idOf(item)}) == true;
  }

  /// Nothing the app shows is an entity any more; see [showing].
  static Future<void> stopShowing() async {
    await callSwift('context.stopShowing');
  }

  /// Tells Siri the user opened [item] in the app, so Siri suggestions and
  /// personal context learn what they use. Donates the item's `system.open`
  /// intent, so it needs `@SystemIntents(open: true)`; returns whether Siri
  /// got a donation.
  ///
  /// For actions the user runs in the app, call the generated
  /// `AssistantDonations.<function>(...)` instead.
  static Future<bool> donate<T>(T item) async {
    final codec = _codec<T>(item);
    return await callSwift('donate.entity', {'collection': codec.collection, 'id': codec.idOf(item)}) == true;
  }

  /// Donates `@AssistantAction` [action] run with [args] (encoded as Swift
  /// expects). Used by the generated `AssistantDonations`; call those.
  static Future<bool> donateAction(String action, Map<String, Object?> args) async =>
      await callSwift('donate.action', {'action': action, 'args': args}) == true;

  /// Opens Apple's Shortcuts app (`shortcuts://`). Returns whether the OS
  /// opened the URL.
  static Future<bool> openShortcutsApp() async => await callSwift('shortcuts.open') == true;

  static int _nextFocusRequest = 0;
  static final _focusRequests = <String, Completer<({String? action, Map<String, Object?> params})?>>{};

  /// Internal action Swift calls to deliver `MyFocusFilterIntent.current`.
  @internal
  static const focusFilterResultAction = 'assistant_actions.focusFilterResult';

  /// Queries the currently active `@AssistantFocusFilter`'s parameters via
  /// `SetFocusFilterIntent.current` on cold start, returning null when no
  /// Focus filter is configured or active.
  static Future<Map<String, Object?>?> currentFocusFilter() async => (await _queryFocusFilter())?.params;

  /// Queries `SetFocusFilterIntent.current` and invokes the registered Dart
  /// `@AssistantFocusFilter` handler with those parameters on cold launch.
  /// Returns the applied parameters, or null when no Focus filter is active.
  static Future<Map<String, Object?>?> syncCurrentFocusFilter() async {
    final current = await _queryFocusFilter();
    if (current == null) return null;
    final actions = _registry?.actions;
    if (actions != null) {
      final handler = current.action != null ? actions[current.action] : null;
      await handler?.call(Map<String, Object?>.of(current.params));
    }
    return current.params;
  }

  static Future<({String? action, Map<String, Object?> params})?> _queryFocusFilter() async {
    final requestId = 'ff_${++_nextFocusRequest}';
    final completer = Completer<({String? action, Map<String, Object?> params})?>();
    _focusRequests[requestId] = completer;
    try {
      final raw = await callSwift('focusFilter.current', {'requestId': requestId});
      if (raw == null) {
        _focusRequests.remove(requestId);
        return null;
      }
      if (raw is Map) {
        final map = raw.cast<String, Object?>();
        if (map['pending'] == true) {
          return await completer.future;
        }
        _focusRequests.remove(requestId);
        return _parseFocusFilter(map);
      }
      _focusRequests.remove(requestId);
      return null;
    } catch (_) {
      _focusRequests.remove(requestId);
      return null;
    }
  }

  static ({String? action, Map<String, Object?> params})? _parseFocusFilter(Map<String, Object?> map) {
    if (map['none'] == true) return null;
    final action = map['action'] as String?;
    final nested = map['params'];
    if (nested is Map) {
      return (action: action, params: nested.cast<String, Object?>());
    }
    return (action: action, params: map);
  }

  static EntityCodec<Object?> _codec<T>(T item) {
    final codecs = _registry?.codecs ?? const {};
    final codec = codecs[T] ?? codecs[item.runtimeType];
    if (codec == null) {
      throw StateError('No entity codec for ${item.runtimeType}. Is it annotated, and was start() called?');
    }
    return codec;
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

  /// Encodes a mid-call disambiguation choice for Swift.
  @internal
  static Object? encodePromptValue<T>(T value) {
    if (value == null) return null;
    final codecs = _registry?.codecs ?? const {};
    final codec = codecs[T] ?? codecs[value.runtimeType];
    if (codec != null) return codec.idOf(value);
    return AssistantValue.encodeAny(value);
  }

  /// Decodes a mid-call prompt value Swift returned into [T].
  @internal
  static Future<T?> decodePromptValue<T>(Object? raw) async {
    if (raw == null) return null;
    if (_registry?.decoders[T] case final decoder?) {
      return (await decoder(raw)) as T?;
    }
    if (_sameOrNullable<T, String>()) return AssistantValue.string(raw) as T?;
    if (_sameOrNullable<T, int>()) return AssistantValue.integer(raw) as T?;
    if (_sameOrNullable<T, double>()) return AssistantValue.decimal(raw) as T?;
    if (_sameOrNullable<T, num>()) return (raw is num ? raw : null) as T?;
    if (_sameOrNullable<T, bool>()) return AssistantValue.boolean(raw) as T?;
    if (_sameOrNullable<T, DateTime>()) return AssistantValue.date(raw) as T?;
    if (_sameOrNullable<T, Duration>()) return AssistantValue.duration(raw) as T?;
    if (_sameOrNullable<T, Uri>()) return AssistantValue.uri(raw) as T?;
    if (_sameOrNullable<T, AssistantPerson>()) return AssistantValue.person(raw) as T?;
    if (_sameOrNullable<T, AssistantPlace>()) return AssistantValue.place(raw) as T?;
    if (_sameOrNullable<T, AssistantFile>()) return AssistantValue.file(raw) as T?;
    if (_sameOrNullable<T, AssistantRecurrence>()) return AssistantValue.recurrence(raw) as T?;
    if (_sameOrNullable<T, AssistantUnion>()) return AssistantValue.union(raw) as T?;
    if (_sameOrNullable<T, AssistantCurrency>()) return AssistantValue.currency(raw) as T?;
    if (_sameOrNullable<T, AssistantLength>()) return AssistantValue.length(raw) as T?;
    if (_sameOrNullable<T, AssistantMass>()) return AssistantValue.mass(raw) as T?;
    if (_sameOrNullable<T, AssistantTemperature>()) return AssistantValue.temperature(raw) as T?;
    if (_sameOrNullable<T, AssistantVolume>()) return AssistantValue.volume(raw) as T?;
    if (_sameOrNullable<T, AssistantSpeed>()) return AssistantValue.speed(raw) as T?;
    if (_sameOrNullable<T, AssistantEnergy>()) return AssistantValue.energy(raw) as T?;
    final listInput = raw is List ? raw : [raw];
    if (_sameOrNullable<T, List<String>>()) return AssistantValue.list(listInput, AssistantValue.string) as T?;
    if (_sameOrNullable<T, List<int>>()) return AssistantValue.list(listInput, AssistantValue.integer) as T?;
    if (_sameOrNullable<T, List<double>>()) return AssistantValue.list(listInput, AssistantValue.decimal) as T?;
    if (_sameOrNullable<T, List<bool>>()) return AssistantValue.list(listInput, AssistantValue.boolean) as T?;
    if (_sameOrNullable<T, List<DateTime>>()) return AssistantValue.list(listInput, AssistantValue.date) as T?;
    if (_sameOrNullable<T, List<Duration>>()) return AssistantValue.list(listInput, AssistantValue.duration) as T?;
    if (_sameOrNullable<T, List<Uri>>()) return AssistantValue.list(listInput, AssistantValue.uri) as T?;
    if (_sameOrNullable<T, List<AssistantPerson>>()) return AssistantValue.list(listInput, AssistantValue.person) as T?;
    if (_sameOrNullable<T, List<AssistantPlace>>()) return AssistantValue.list(listInput, AssistantValue.place) as T?;
    if (_sameOrNullable<T, List<AssistantFile>>()) return AssistantValue.list(listInput, AssistantValue.file) as T?;
    if (_sameOrNullable<T, List<AssistantCurrency>>()) return AssistantValue.list(listInput, AssistantValue.currency) as T?;
    if (_sameOrNullable<T, List<AssistantLength>>()) return AssistantValue.list(listInput, AssistantValue.length) as T?;
    if (_sameOrNullable<T, List<AssistantMass>>()) return AssistantValue.list(listInput, AssistantValue.mass) as T?;
    if (_sameOrNullable<T, List<AssistantTemperature>>()) return AssistantValue.list(listInput, AssistantValue.temperature) as T?;
    if (_sameOrNullable<T, List<AssistantVolume>>()) return AssistantValue.list(listInput, AssistantValue.volume) as T?;
    if (_sameOrNullable<T, List<AssistantSpeed>>()) return AssistantValue.list(listInput, AssistantValue.speed) as T?;
    if (_sameOrNullable<T, List<AssistantEnergy>>()) return AssistantValue.list(listInput, AssistantValue.energy) as T?;
    if (raw is T) return raw as T;
    return null;
  }

  static bool _sameOrNullable<T, U>() => T == U || T == _typeOf<U?>();
  static Type _typeOf<X>() => X;

  /// The action Swift performs to apply the inbox and wait until it's done
  /// (`AssistantBackground.applyInbox`), unlike `inboxChanged`, which
  /// doesn't wait.
  @internal
  static const drainAction = 'assistant_actions.drainInbox';

  /// Runs a `Runs.withFlutter` action for Swift.
  @visibleForTesting
  static Future<String?> perform(String action, String argsJson) async {
    if (action == drainAction) {
      // A drain already running may have read the inbox before this item.
      if (_draining case final running?) await running;
      await drain();
      return null;
    }
    final args = (jsonDecode(argsJson) as Map).cast<String, Object?>();
    if (action == AssistantCall.cancelAction) {
      AssistantCall.cancel(args['call'] as String?);
      return null;
    }
    if (action == AssistantLiveActivity.pushTokenAction) {
      AssistantLiveActivity.deliverPushToken(args);
      return null;
    }
    if (action == focusFilterResultAction) {
      final requestId = args['requestId'] as String?;
      final completer = requestId == null ? null : _focusRequests.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(_parseFocusFilter(args));
      }
      return null;
    }
    if (action == AssistantCall.promptReplyAction) {
      AssistantCall.completePrompt(args);
      return null;
    }
    final handler = _registry?.actions[action];
    if (handler == null) throw ArgumentError.value(action, 'action', 'Unknown action');
    // Live calls carry their id, for `AssistantCall.current`.
    final call = args.remove(AssistantCall.argument) as String?;
    try {
      return await AssistantCall.run(call, () => handler(args));
    } on AssistantError catch (e) {
      throw PlatformException(code: AssistantError.code, message: e.message);
    } on AssistantPromptCancelled {
      throw PlatformException(code: AssistantCall.cancelledErrorCode, message: 'Cancelled');
    }
  }
}

/// The Pigeon Flutter API Swift calls over FFI.
class _FlutterApi implements AssistantFlutterApi {
  @override
  Future<String?> perform(String action, String argsJson) => AssistantActions.perform(action, argsJson);

  @override
  void inboxChanged() => unawaited(AssistantActions.drain());
}
