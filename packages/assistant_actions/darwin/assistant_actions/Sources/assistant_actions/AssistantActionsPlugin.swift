#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Connects the generated App Intents to Dart over the `assistant_actions`
/// method channel. Flutter registers it with the engine; intents that run
/// before that (or with no engine at all) go through [AssistantInbox].
public final class AssistantActionsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "assistant_actions", binaryMessenger: messenger)
    let instance = AssistantActionsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    MainActor.assumeIsolated { AssistantBridge.shared.attach(channel) }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "markReady":
      MainActor.assumeIsolated { AssistantBridge.shared.markReady() }
      result(nil)
    case "drainInbox":
      result(AssistantInbox.drain())
    case "publish":
      guard let collection = args["collection"] as? String, let json = args["json"] as? String else {
        result(FlutterError(code: "bad-args", message: "publish needs collection and json", details: nil))
        return
      }
      do {
        try AssistantSnapshot.write(collection: collection, json: json)
        result(nil)
      } catch {
        result(FlutterError(code: "write-failed", message: "\(error)", details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
