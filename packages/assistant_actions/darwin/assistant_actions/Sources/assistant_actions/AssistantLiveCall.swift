import Foundation

/// One live call into Dart (a `Runs.withFlutter` action or a live schema
/// intent), so Dart can report progress into the intent's `Progress` and
/// hear when Siri cancels it.
///
/// Dart sees the call as `AssistantCall.current`: Swift passes its id in the
/// arguments, Dart reports progress with the `call.progress` host call, and
/// Swift cancels it by performing `assistant_actions.cancel`.
@MainActor
public final class AssistantLiveCall {
  /// The argument key carrying the call id (`AssistantCall.argument`).
  public static let argument = "__assistant_call"
  /// The action that cancels a call in Dart (`AssistantCall.cancelAction`).
  public static let cancelAction = "assistant_actions.cancel"

  private static var running: [String: AssistantLiveCall] = [:]
  private static var registered = false

  public let id = UUID().uuidString.lowercased()
  let progress: Progress?

  public init(progress: Progress?) {
    self.progress = progress
  }

  /// Runs [action] through [perform] (the bridge into Dart), with the call id
  /// added to [args].
  public func run(
    _ action: String, args: [String: Any],
    perform: (String, [String: Any]) async throws -> String?
  ) async throws -> String? {
    Self.registerHostCalls()
    Self.running[id] = self
    defer { Self.running[id] = nil }
    var withCall = args
    withCall[Self.argument] = id
    return try await perform(action, withCall)
  }

  /// The arguments that cancel this call in Dart.
  public var cancelArgs: [String: Any] { ["call": id] }

  /// Applies progress Dart reported: `{call, completed, total}`. Returns
  /// whether the call is running.
  static func report(_ args: [String: Any]) -> Bool {
    guard let id = args["call"] as? String, let call = running[id] else { return false }
    guard let progress = call.progress else { return true }
    if let total = AssistantValues.int(args["total"]), total > 0 { progress.totalUnitCount = Int64(total) }
    if let completed = AssistantValues.int(args["completed"]) {
      progress.completedUnitCount = Int64(max(0, completed))
    }
    return true
  }

  /// Registers `call.progress`, once.
  static func registerHostCalls() {
    guard !registered else { return }
    registered = true
    AssistantHostCalls.register("call.progress") { args in report(args) }
  }
}
