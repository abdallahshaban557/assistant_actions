import 'bridge/assistant_api.g.dart';

/// The native side `AssistantActions` talks to.
///
/// On iOS and macOS this is [FfiAssistantHost], which calls Swift directly
/// over FFI. Tests pass a fake to `AssistantActions.start`.
abstract interface class AssistantHost {
  /// Dart can now take live `perform` calls.
  Future<void> markReady();

  /// Returns and clears what the intents queued, as JSON, oldest first.
  Future<List<String>> drainInbox();

  /// Saves the snapshot of [collection] that entity queries read.
  Future<void> publish(String collection, String json);
}

/// [AssistantHost] over Pigeon native interop (FFI), with no platform-channel
/// fallback: if the Swift side isn't registered this throws instead.
class FfiAssistantHost implements AssistantHost {
  FfiAssistantHost() : _api = AssistantHostApi.createWithNativeInteropApi();

  final AssistantHostApi _api;

  @override
  Future<void> markReady() => _api.markReady();

  @override
  Future<List<String>> drainInbox() => _api.drainInbox();

  @override
  Future<void> publish(String collection, String json) => _api.publish(collection, json);
}
