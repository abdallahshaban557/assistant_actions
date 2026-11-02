import Foundation

/// The live path into Dart, for actions declared with `Runs.withFlutter`,
/// over FFI through the Pigeon-generated `AssistantFlutterApi`.
///
/// On iOS the Flutter engine only exists once a scene has connected, so the
/// generated intents bring the app to the foreground first when it isn't
/// active. macOS starts the engine with the app, so it answers in place.
@MainActor
public final class AssistantBridge {
  public static let shared = AssistantBridge()

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
    do {
      return try await dart.perform(action: action, argsJson: String(decoding: data, as: UTF8.self))
    } catch let error as PigeonError {
      throw AssistantActionError.failed(error.message ?? error.code ?? "No answer")
    }
  }

  /// Lets a running app apply what an intent just queued.
  public func inboxChanged() {
    guard isReady else { return }
    try? AssistantFlutterApi.getInstance()?.inboxChanged()
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
