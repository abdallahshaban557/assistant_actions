import Foundation

/// The live path into Dart, for actions declared with `Runs.withFlutter`,
/// over FFI through the Pigeon-generated `AssistantFlutterApi`.
///
/// On iOS the Flutter engine only exists once a scene has connected, so the
/// generated intents bring the app to the foreground first when it isn't
/// active, or, for apps with `@AssistantBackground()`, start a headless
/// engine ([AssistantBackground]). macOS starts the engine with the app, so it
/// answers in place.
@MainActor
public final class AssistantBridge {
  public static let shared = AssistantBridge()

  /// Error code Dart sends for `AssistantError` (`AssistantError.code`).
  public static let userErrorCode = "assistant_actions.user_error"

  /// Error code Dart sends when a mid-call prompt was cancelled by the user.
  public static let cancelledErrorCode = "assistant_actions.cancelled"

  static func mapError(_ error: PigeonError) -> AssistantActionError {
    if error.code == userErrorCode {
      return .userFacing(error.message ?? "")
    }
    return .failed(error.message ?? error.code ?? "No answer")
  }

  /// Set once Dart's `AssistantActions.start` has finished, so `perform`
  /// calls can be answered.
  public private(set) var isReady = false

  /// A (new) engine registered the plugin; Dart isn't ready until it says so.
  func engineStarted() {
    isReady = false
  }

  func markReady() {
    isReady = true
  }

  /// The engine whose Dart was ready stopped (the headless one).
  func engineStopped() {
    isReady = false
  }

  /// `perform` calls waiting for Dart's answer.
  private(set) var inFlight = 0

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
    guard await waitUntilReady(timeout: 60), let dart = AssistantFlutterApi.getInstance() else {
      throw AssistantActionError.notRunning
    }
    let data = try JSONSerialization.data(withJSONObject: args)
    inFlight += 1
    defer { inFlight -= 1 }
    do {
      return try await dart.perform(action: action, argsJson: String(decoding: data, as: UTF8.self))
    } catch let error as PigeonError {
      if error.code == Self.cancelledErrorCode {
        throw CancellationError()
      }
      throw Self.mapError(error)
    }
  }

  /// Lets a running app apply what an intent just queued.
  public func inboxChanged() {
    guard isReady else { return }
    try? AssistantFlutterApi.getInstance()?.inboxChanged()
  }
}

public enum AssistantActionError: Error, Equatable, CustomLocalizedStringResourceConvertible {
  case notRunning
  case failed(String)
  case userFacing(String)

  public var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notRunning: return "The app couldn't start. Open it and try again."
    case .failed(let message): return "Something went wrong: \(message)"
    case .userFacing(let message): return "\(message)"
    }
  }
}
