import AppIntents
import Foundation

/// One live call into Dart (a `Runs.withFlutter` action or a live schema
/// intent), so Dart can report progress into the intent's `Progress`, hear
/// when Siri cancels it, and ask Siri follow-up questions mid-execution.
///
/// Dart sees the call as `AssistantCall.current`: Swift passes its id in the
/// arguments, Dart reports progress with `call.progress` and prompts Siri with
/// `call.prompt`, and Swift delivers answers with `assistant_actions.promptReply`
/// or cancels with `assistant_actions.cancel`.
@MainActor
public final class AssistantLiveCall {
  /// The argument key carrying the call id (`AssistantCall.argument`).
  public static let argument = "__assistant_call"
  /// The action that cancels a call in Dart (`AssistantCall.cancelAction`).
  public static let cancelAction = "assistant_actions.cancel"
  /// The action that delivers a mid-call prompt answer back to Dart
  /// (`AssistantCall.promptReplyAction`).
  public static let promptReplyAction = "assistant_actions.promptReply"

  public typealias ConfirmHandler = @MainActor (String, String?) async -> Bool
  public typealias ChooseHandler = @MainActor ([[String: Any]], String) async throws -> String?
  public typealias RequestValueHandler = @MainActor (String?) async throws -> Any
  public typealias DisambiguateHandler = @MainActor ([Any], String?) async throws -> Any
  public typealias PromptReplySender = @MainActor ([String: Any]) async -> Void

  private static var running: [String: AssistantLiveCall] = [:]
  private static var registered = false

  public let id = UUID().uuidString.lowercased()
  let progress: Progress?

  var confirmHandler: ConfirmHandler?
  var chooseHandler: ChooseHandler?
  private var valueRequesters: [String: RequestValueHandler] = [:]
  private var disambiguators: [String: DisambiguateHandler] = [:]
  var replySender: PromptReplySender?

  public init(progress: Progress?) {
    self.progress = progress
  }

  /// Binds confirmation and option-choice prompts to [intent].
  public func bind<I: AppIntent>(to intent: I) {
    confirmHandler = { prompt, actionLabel in
      await intent.assistantConfirmPrompt(prompt, actionLabel: actionLabel)
    }
    chooseHandler = { choices, prompt in
      try await intent.assistantChooseOption(choices, prompt: prompt)
    }
  }

  /// Registers a custom mid-call confirmation handler.
  public func onConfirm(_ handler: @escaping ConfirmHandler) {
    confirmHandler = handler
  }

  /// Registers a custom mid-call choice handler.
  public func onChoose(_ handler: @escaping ChooseHandler) {
    chooseHandler = handler
  }

  /// Registers `$<param>.requestValue` for [param].
  public func onRequestValue(_ param: String, _ handler: @escaping RequestValueHandler) {
    valueRequesters[param] = handler
  }

  /// Registers `$<param>.requestDisambiguation` for [param].
  public func onDisambiguate(_ param: String, _ handler: @escaping DisambiguateHandler) {
    disambiguators[param] = handler
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

  /// Starts answering a mid-call prompt Dart requested (`call.prompt`),
  /// returning `["pending": true]` while the async Siri prompt runs.
  static func prompt(_ args: [String: Any]) -> [String: Any] {
    guard let id = args["call"] as? String,
      let promptId = args["promptId"] as? String,
      let call = running[id]
    else {
      return ["cancelled": true]
    }
    Task { @MainActor in
      await call.answerPrompt(promptId: promptId, args: args)
    }
    return ["pending": true]
  }

  private func answerPrompt(promptId: String, args: [String: Any]) async {
    var payload: [String: Any] = ["call": id, "promptId": promptId]
    let promptText = args["prompt"] as? String
    do {
      switch args["kind"] as? String {
      case "confirm":
        guard let confirmHandler else {
          payload["cancelled"] = true
          break
        }
        payload["value"] = await confirmHandler(promptText ?? "", args["actionLabel"] as? String)
      case "choose":
        guard let chooseHandler else {
          payload["cancelled"] = true
          break
        }
        let choices = (args["choices"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        if let chosen = try await chooseHandler(choices, promptText ?? "") {
          payload["value"] = chosen
        } else {
          payload["cancelled"] = true
        }
      case "requestValue":
        guard let param = args["param"] as? String, let handler = valueRequesters[param] else {
          payload["error"] = "No promptable parameter '\(args["param"] ?? "")' on this intent"
          break
        }
        payload["value"] = try await handler(promptText)
      case "disambiguate":
        guard let param = args["param"] as? String, let handler = disambiguators[param] else {
          payload["error"] = "No promptable parameter '\(args["param"] ?? "")' on this intent"
          break
        }
        let choices = args["choices"] as? [Any] ?? []
        if choices.isEmpty {
          payload["cancelled"] = true
        } else {
          payload["value"] = try await handler(choices, promptText)
        }
      default:
        payload["error"] = "Unknown prompt kind '\(args["kind"] ?? "")'"
      }
    } catch {
      payload["cancelled"] = true
    }
    if let replySender {
      await replySender(payload)
    } else {
      _ = try? await AssistantBridge.shared.perform(Self.promptReplyAction, args: payload)
    }
  }

  /// Registers `call.progress` and `call.prompt`, once.
  static func registerHostCalls() {
    guard !registered else { return }
    registered = true
    AssistantHostCalls.register("call.progress") { args in report(args) }
    AssistantHostCalls.register("call.prompt") { args in prompt(args) }
  }
}
