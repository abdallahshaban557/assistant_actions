// Extension-safe `LiveActivityIntent` behind `AssistantLiveActivityButton`.
//
// Compiled into both the app (via the `assistant_actions` plugin) and the
// `AssistantWidgets` widget extension (copied by
// `dart run assistant_actions:install --widgets`). When tapped on the Lock
// Screen or Dynamic Island, iOS runs `perform()` in the app process, which
// dispatches to `AssistantBridge` (or queues in `AssistantInbox`). If run
// outside the main app, it falls back to queueing into the shared App Group
// `UserDefaults` inbox.

import AppIntents
import Foundation

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
#endif

/// Implemented in the main app by `AssistantLiveActivityIntentDispatcher` so
/// `AssistantLiveActivityButtonIntent` stays extension-safe (no `Flutter`
/// dependency).
@objc public protocol AssistantLiveActivityDispatching {
  @MainActor
  static func dispatch(actionId: String, argsJson: String?) async throws
}

/// Interactive button intent used by `AssistantLiveActivityWidget`.
public struct AssistantLiveActivityButtonIntent: AppIntent {
  public static let title: LocalizedStringResource = "Live Activity Action"
  public static let isDiscoverable = false

  @Parameter(title: "Action")
  public var actionId: String

  @Parameter(title: "Arguments")
  public var argsJson: String?

  public init() {
    self.actionId = ""
    self.argsJson = nil
  }

  public init(actionId: String, argsJson: String? = nil) {
    self.actionId = actionId
    self.argsJson = argsJson
  }

  public init(_ button: AssistantActivityAttributes.ContentState.Button) {
    self.actionId = button.actionId
    self.argsJson = button.args
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
    guard !actionId.isEmpty else { return .result() }
    if let dispatcher = NSClassFromString("AssistantLiveActivityIntentDispatcher")
      as? AssistantLiveActivityDispatching.Type
    {
      try await dispatcher.dispatch(actionId: actionId, argsJson: argsJson)
      return .result()
    }
    Self.enqueueFallback(actionId: actionId, argsJson: argsJson)
    return .result()
  }

  static func enqueueFallback(actionId: String, argsJson: String?) {
    let args: [String: Any]
    if let data = argsJson?.data(using: .utf8),
      let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      args = decoded
    } else {
      args = [:]
    }
    let entry: [String: Any] = [
      "kind": "call",
      "action": actionId,
      "args": args,
      "createdAt": Date().timeIntervalSince1970,
    ]
    guard JSONSerialization.isValidJSONObject(entry),
      let data = try? JSONSerialization.data(withJSONObject: entry),
      let json = String(data: data, encoding: .utf8)
    else { return }
    let defaults = AssistantAppGroup.userDefaults
    let key = "assistant_actions.inbox"
    let existing = defaults.stringArray(forKey: key) ?? []
    defaults.set(existing + [json], forKey: key)
  }
}

#if os(iOS) && canImport(ActivityKit)
  extension AssistantLiveActivityButtonIntent: LiveActivityIntent {}
#endif
