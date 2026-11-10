#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Registers the Swift end of the Dart ↔ Swift bridge, which runs over FFI
/// (Pigeon native interop, schema in `pigeons/assistant_api.dart`), not
/// platform channels. Flutter calls `register` when it sets up the engine;
/// intents that run before that (or with no engine at all) go through
/// [AssistantInbox].
public final class AssistantActionsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    MainActor.assumeIsolated { AssistantBridge.shared.engineStarted() }
    // Registering also keeps the linker from stripping the generated setup class.
    AssistantHostApiSetup.register(api: AssistantHostApiImpl())
  }
}

/// The Pigeon host API Dart calls. Native interop calls arrive on the thread of
/// the calling Dart isolate; `AssistantActions` only calls from the root
/// isolate, which runs on the main thread.
private final class AssistantHostApiImpl: AssistantHostApi {
  func markReady() throws {
    MainActor.assumeIsolated { AssistantBridge.shared.markReady() }
  }

  func drainInbox() throws -> [String] {
    AssistantInbox.drain()
  }

  func publish(collection: String, json: String) throws {
    try AssistantSnapshot.write(collection: collection, json: json)
  }

  func invoke(method: String, argsJson: String) throws -> String? {
    try MainActor.assumeIsolated { try AssistantHostCalls.invoke(method, argsJson: argsJson) }
  }
}
