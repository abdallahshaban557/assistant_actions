#if os(iOS)
  import Flutter

  extension AssistantBackground {
    /// Registers the app's plugins on the headless engine. By default the
    /// runtime calls the Runner's `GeneratedPluginRegistrant`, found by name;
    /// set this (in `application(_:didFinishLaunchingWithOptions:)`) to
    /// register a different set, for example without plugins that need a
    /// view.
    public static var registerPlugins: ((FlutterPluginRegistry) -> Void)?
  }

  /// A `FlutterEngine` with no view, running the generated
  /// `assistantActionsBackgroundMain`.
  @MainActor
  final class AssistantHeadlessEngine: AssistantEngineLauncher {
    private let entrypoint: AssistantBackgroundEntrypoint.Type
    private var engine: FlutterEngine?

    private init(entrypoint: AssistantBackgroundEntrypoint.Type) {
      self.entrypoint = entrypoint
    }

    /// Nil unless the app has an `@AssistantBackground()` function, for which
    /// the generator writes `AssistantActionsAppBackground`.
    static func make() -> AssistantHeadlessEngine? {
      guard let type = NSClassFromString("AssistantActionsAppBackground") as? AssistantBackgroundEntrypoint.Type else {
        return nil
      }
      return AssistantHeadlessEngine(entrypoint: type)
    }

    func start() -> Bool {
      let engine = FlutterEngine(name: "assistant_actions", project: nil, allowHeadlessExecution: true)
      guard engine.run(withEntrypoint: entrypoint.entrypoint, libraryURI: entrypoint.libraryURI) else { return false }
      // Dart runs on this thread, after this returns, so the plugins are
      // registered before it starts.
      AssistantActionsPlugin.setUpBridge()
      let background = AssistantBackground.shared
      background.isRegisteringPlugins = true
      defer { background.isRegisteringPlugins = false }
      if let register = AssistantBackground.registerPlugins {
        register(engine)
      } else if let registrant = NSClassFromString("GeneratedPluginRegistrant") as AnyObject?,
        registrant.responds(to: NSSelectorFromString("registerWithRegistry:"))
      {
        _ = registrant.perform(NSSelectorFromString("registerWithRegistry:"), with: engine)
      }
      self.engine = engine
      return true
    }

    func stop() {
      engine?.destroyContext()
      engine = nil
    }
  }
#endif
