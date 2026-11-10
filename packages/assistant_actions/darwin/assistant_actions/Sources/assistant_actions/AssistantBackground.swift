import Foundation
import os

/// Runs the app's Dart for Siri on iOS without opening the app, for apps that
/// mark a registry function `@AssistantBackground()`.
///
/// On iOS the app's Flutter engine only starts once a scene connects, so when
/// Siri launches the app in the background there is no Dart to answer. The
/// generated intents call [prepare] first: if no engine is running, it starts
/// a headless one (`FlutterEngine` with no view) at the entrypoint the
/// generator wrote, `assistantActionsBackgroundMain`, with the app's plugins
/// registered. When the app's own engine starts, the headless one stops once
/// it is idle, and the app's Dart answers from then on.
///
/// Without `@AssistantBackground()` there is no launcher, [prepare] returns
/// whether the app's Dart is ready, and the intents bring the app forward as
/// before. macOS starts the engine with the app and never needs this.
@MainActor
public final class AssistantBackground {
  public static let shared = AssistantBackground()

  /// How long the headless engine stays after its last use, so that a few
  /// requests in a row don't each start one. Seconds.
  public var keepAlive: TimeInterval = 30

  /// Starts and stops the headless engine. The default, on iOS, is a
  /// `FlutterEngine` at the generated entrypoint, or nil when the app has no
  /// `@AssistantBackground()` function.
  lazy var launcher: AssistantEngineLauncher? = Self.defaultLauncher()

  let bridge: AssistantBridge

  init(bridge: AssistantBridge? = nil) {
    self.bridge = bridge ?? .shared
  }

  /// Where the headless engine's Dart is.
  enum State {
    /// Started; Dart is building the registry.
    case starting
    /// Dart set up its side and is applying the inbox.
    case claimed
    /// Dart finished starting.
    case ready
    /// The app's engine started first, so Dart stood down.
    case declined
  }

  /// Nil while no headless engine runs.
  private(set) var state: State?

  /// The app's own engine registered the plugin.
  private(set) var appEngine = false

  /// Set while the launcher registers plugins on the headless engine, so the
  /// plugin can tell that engine from the app's.
  var isRegisteringPlugins = false

  private static let log = Logger(subsystem: "dev.assistantactions", category: "background")

  private var lastUse = Date.distantPast
  private var stopTask: Task<Void, Never>?

  /// Whether the headless engine is running.
  public var isRunning: Bool { state != nil }

  /// Makes sure Dart can take `AssistantBridge.perform` calls, starting the
  /// headless engine if the app has none. Returns false when Dart isn't
  /// ready by [timeout], or the app isn't set up for background execution:
  /// then the intent should bring the app forward instead.
  public func prepare(timeout: TimeInterval = 15) async -> Bool {
    lastUse = Date()
    if bridge.isReady {
      if isRunning && !appEngine { scheduleStop() }
      return true
    }
    // The app's engine is starting (it registered the plugin): wait for it.
    if appEngine { return await bridge.waitUntilReady(timeout: timeout) }
    guard let launcher else { return false }
    if state == nil {
      Self.log.info("Starting a headless Flutter engine for Siri")
      guard launcher.start() else {
        Self.log.error("The headless Flutter engine didn't start")
        return false
      }
      state = .starting
    }
    let ready = await bridge.waitUntilReady(timeout: timeout)
    if !ready { Self.log.error("Dart wasn't ready within \(timeout) s; the intent continues in the foreground") }
    lastUse = Date()
    scheduleStop()
    return ready
  }

  /// Applies what an intent just queued: right away if Dart runs or the
  /// headless engine can start, otherwise when the app next runs. Generated
  /// intents call this, instead of `inboxChanged`, for apps with
  /// `@AssistantBackground(applyQueued: true)`.
  public func applyInbox(timeout: TimeInterval = 10) async {
    guard bridge.isReady || launcher != nil || appEngine else { return }
    // Starting Dart drains the inbox; asking again covers an engine that
    // drained before this item was queued.
    if await prepare(timeout: timeout) { bridge.inboxChanged() }
  }

  // ── Called by the plugin and the headless engine's Dart ──

  /// The plugin registered on an engine.
  func engineRegistered() {
    guard !isRegisteringPlugins else { return }
    appEngine = true
    // The app's Dart answers from now on; stop the headless engine once idle.
    if isRunning { scheduleStop(after: 0) }
  }

  /// Dart on the headless engine asks to serve Siri. Declined once the app's
  /// engine has started, which then serves instead.
  func claim() -> Bool {
    guard state == .starting, !appEngine else {
      if state == .starting {
        Self.log.info("The app's engine started first; the headless engine stands down")
        state = .declined
      }
      return false
    }
    state = .claimed
    return true
  }

  /// Dart on the headless engine applied the inbox and can take calls.
  func ready() {
    guard state == .claimed else { return }
    state = .ready
    Self.log.info("Dart is ready on the headless engine")
    if appEngine {
      scheduleStop(after: 0)
    } else {
      bridge.markReady()
    }
  }

  /// The `background.*` host calls Dart's `AssistantActions.startInBackground` makes.
  static func registerHostCalls() {
    AssistantHostCalls.register("background.claim") { _ in shared.claim() }
    AssistantHostCalls.register("background.ready") { _ in
      shared.ready()
      return nil
    }
  }

  // ── Stopping ──

  private func scheduleStop(after delay: TimeInterval? = nil) {
    stopTask?.cancel()
    let wait = delay ?? keepAlive
    stopTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.stopIfIdle()
    }
  }

  func stopIfIdle() {
    guard isRunning else { return }
    // Dart that is applying the inbox, or a call in flight, finishes first.
    if state == .claimed || bridge.inFlight > 0 {
      scheduleStop(after: 1)
      return
    }
    let idleUntil = lastUse.addingTimeInterval(keepAlive)
    if !appEngine && Date() < idleUntil {
      scheduleStop(after: idleUntil.timeIntervalSinceNow)
      return
    }
    stopTask = nil
    Self.log.info("Stopping the headless Flutter engine")
    launcher?.stop()
    // The app's engine, if any, set its own readiness.
    if !appEngine { bridge.engineStopped() }
    state = nil
  }

  private static func defaultLauncher() -> AssistantEngineLauncher? {
    #if os(iOS) && canImport(Flutter)
      return AssistantHeadlessEngine.make()
    #else
      return nil
    #endif
  }
}

/// Starts and stops the engine [AssistantBackground] runs Dart on.
@MainActor
protocol AssistantEngineLauncher: AnyObject {
  /// Starts the engine; false if it couldn't.
  func start() -> Bool
  func stop()
}

/// Generated as `@objc(AssistantActionsAppBackground)` for apps with an
/// `@AssistantBackground()` function: where the headless engine starts Dart.
@objc public protocol AssistantBackgroundEntrypoint {
  /// The Dart function, `assistantActionsBackgroundMain`.
  static var entrypoint: String { get }
  /// Its library, `package:<app>/assistant_actions.g.dart`.
  static var libraryURI: String { get }
}
