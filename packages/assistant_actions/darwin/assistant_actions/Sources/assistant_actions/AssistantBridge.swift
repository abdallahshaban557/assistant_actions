import Foundation

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The live path into Dart, for actions declared with `Runs.withFlutter`.
///
/// On iOS the Flutter engine only exists once a scene has connected, so the
/// generated intents bring the app to the foreground first when it isn't
/// active. macOS starts the engine with the app, so it answers in place.
@MainActor
public final class AssistantBridge {
  public static let shared = AssistantBridge()

  private var channel: FlutterMethodChannel?

  /// Set once Dart's `AssistantActions.start` has finished, so `perform`
  /// calls can be answered.
  public private(set) var isReady = false

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    isReady = false
  }

  func markReady() {
    isReady = true
  }

  /// Polls until Dart reports ready, or the timeout passes.
  public func waitUntilReady(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !isReady && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return isReady
  }

  /// Runs the Dart function behind [action] and returns what it said, if
  /// anything.
  public func perform(_ action: String, args: [String: Any]) async throws -> String? {
    guard await waitUntilReady(timeout: 60), let channel else {
      throw AssistantActionError.notRunning
    }
    return try await withCheckedThrowingContinuation { continuation in
      channel.invokeMethod("perform", arguments: ["action": action, "args": args]) { reply in
        if let error = reply as? FlutterError {
          continuation.resume(throwing: AssistantActionError.failed(error.message ?? error.code))
        } else if reply as? NSObject === FlutterMethodNotImplemented {
          continuation.resume(throwing: AssistantActionError.notRunning)
        } else {
          continuation.resume(returning: reply as? String)
        }
      }
    }
  }

  /// Lets a running app apply what an intent just queued.
  public func inboxChanged() {
    guard isReady else { return }
    channel?.invokeMethod("inboxChanged", arguments: nil)
  }
}

public enum AssistantActionError: Error, CustomLocalizedStringResourceConvertible {
  case notRunning
  case failed(String)

  public var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notRunning: return "The app couldn't start. Open it and try again."
    case .failed(let message): return "Something went wrong: \(message)"
    }
  }
}
