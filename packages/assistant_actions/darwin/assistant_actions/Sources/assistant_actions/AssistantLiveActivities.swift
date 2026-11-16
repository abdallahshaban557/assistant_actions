import Foundation

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
#endif

/// Main-app dispatcher invoked when a user taps an `AssistantLiveActivityButton`
/// on the Lock Screen or Dynamic Island.
@objc(AssistantLiveActivityIntentDispatcher)
public final class AssistantLiveActivityIntentDispatcher: NSObject, AssistantLiveActivityDispatching {
  @MainActor
  public static func dispatch(actionId: String, argsJson: String?) async throws {
    let args: [String: Any]
    if let data = argsJson?.data(using: .utf8),
      let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      args = decoded
    } else {
      args = [:]
    }
    let ready = AssistantBridge.shared.isReady ? true : await AssistantBackground.shared.prepare()
    if ready {
      _ = try await AssistantBridge.shared.perform(actionId, args: args)
    } else {
      AssistantInbox.call(actionId, args: args)
      AssistantBridge.shared.inboxChanged()
    }
  }
}

/// The Swift end of Dart's `AssistantLiveActivity`: starts, updates and ends
/// ActivityKit Live Activities of `AssistantActivityAttributes`, over
/// `AssistantHostCalls`. The app's widget extension draws them (see
/// `dart run assistant_actions:install --widgets`).
///
/// Live Activities are iOS-only: on macOS every call reports that they're
/// unavailable.
@MainActor
enum AssistantLiveActivities {
  private static let pushTokenAction = "assistant_actions.liveActivityPushToken"
  private static var pushToStartTask: Task<Void, Never>?
  private static var activityTokenTasks: [String: Task<Void, Never>] = [:]

  static func register() {
    AssistantHostCalls.register("liveActivity.enabled") { _ in enabled }
    AssistantHostCalls.register("liveActivity.start") { try start($0) }
    AssistantHostCalls.register("liveActivity.update") { update($0) }
    AssistantHostCalls.register("liveActivity.end") { end($0) }
    AssistantHostCalls.register("liveActivity.list") { _ in list() }
    AssistantHostCalls.register("liveActivity.pushToken") { pushToken($0) }
    AssistantHostCalls.register("liveActivity.observePushToStart") { _ in observePushToStart() }
    AssistantHostCalls.register("liveActivity.stopPushToStart") { _ in stopPushToStart() }
    AssistantHostCalls.register("liveActivity.observePushTokens") { observePushTokens($0) }
    AssistantHostCalls.register("liveActivity.stopPushTokens") { stopPushTokens($0) }
  }

  #if os(iOS) && canImport(ActivityKit)
    typealias Attributes = AssistantActivityAttributes

    /// The user allows Live Activities for the app (and the device has them).
    static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// `{kind, data?, enablePush?, content, staleDate?, relevanceScore?}` → the
    /// activity, or nil when Live Activities are turned off. Throws what
    /// ActivityKit throws, such as when the app is in the background or
    /// Info.plist lacks `NSSupportsLiveActivities`.
    static func start(_ args: [String: Any]) throws -> Any? {
      guard enabled else { return nil }
      let attributes = Attributes(kind: args["kind"] as? String ?? "default", data: args["data"] as? String)
      let enablePush = (args["enablePush"] as? Bool) ?? false
      let activity = try Activity.request(
        attributes: attributes, content: content(args), pushType: enablePush ? .token : nil)
      return describe(activity)
    }

    /// `{id, content, staleDate?, relevanceScore?, alert?}` → whether the
    /// activity is still there.
    static func update(_ args: [String: Any]) -> Bool {
      guard let activity = find(args["id"]) else { return false }
      let content = content(args)
      let alert = (args["alert"] as? [String: Any]).map {
        AlertConfiguration(
          title: LocalizedStringResource(stringLiteral: $0["title"] as? String ?? ""),
          body: LocalizedStringResource(stringLiteral: $0["body"] as? String ?? ""),
          sound: .default)
      }
      Task { await activity.update(content, alertConfiguration: alert) }
      return true
    }

    /// `{id, content?, dismissal: "default" | "immediate" | "after", dismissAt?}`
    /// → whether the activity was there.
    static func end(_ args: [String: Any]) -> Bool {
      guard let activity = find(args["id"]) else { return false }
      let final = args["content"] == nil ? nil : content(args)
      let dismissal: ActivityUIDismissalPolicy =
        switch args["dismissal"] as? String {
        case "immediate": .immediate
        case "after": date(args["dismissAt"]).map { .after($0) } ?? .default
        default: .default
        }
      Task { await activity.end(final, dismissalPolicy: dismissal) }
      return true
    }

    static func list() -> [[String: Any]] {
      Activity<Attributes>.activities.map(describe)
    }

    static func pushToken(_ args: [String: Any]) -> String? {
      find(args["id"])?.pushToken.map(hex)
    }

    static func observePushToStart() -> String? {
      pushToStartTask?.cancel()
      pushToStartTask = nil
      if #available(iOS 17.2, *) {
        pushToStartTask = Task { @MainActor in
          for await data in Activity<Attributes>.pushToStartTokenUpdates {
            guard !Task.isCancelled else { break }
            deliverToken(["kind": "pushToStart", "token": hex(data)])
          }
        }
        return Activity<Attributes>.pushToStartToken.map(hex)
      }
      return nil
    }

    static func stopPushToStart() -> Any? {
      pushToStartTask?.cancel()
      pushToStartTask = nil
      return nil
    }

    static func observePushTokens(_ args: [String: Any]) -> String? {
      guard let id = args["id"] as? String else { return nil }
      activityTokenTasks.removeValue(forKey: id)?.cancel()
      guard let activity = find(id) else { return nil }
      activityTokenTasks[id] = Task { @MainActor in
        for await data in activity.pushTokenUpdates {
          guard !Task.isCancelled else { break }
          deliverToken(["kind": "activity", "id": id, "token": hex(data)])
        }
        if !Task.isCancelled {
          activityTokenTasks.removeValue(forKey: id)
          deliverToken(["kind": "activity", "id": id, "done": true])
        }
      }
      return activity.pushToken.map(hex)
    }

    static func stopPushTokens(_ args: [String: Any]) -> Any? {
      if let id = args["id"] as? String {
        activityTokenTasks.removeValue(forKey: id)?.cancel()
      }
      return nil
    }

    private static func deliverToken(_ payload: [String: Any]) {
      guard AssistantBridge.shared.isReady else { return }
      Task { @MainActor in
        _ = try? await AssistantBridge.shared.perform(pushTokenAction, args: payload)
      }
    }

    private static func hex(_ data: Data) -> String {
      data.map { String(format: "%02x", $0) }.joined()
    }

    private static func find(_ id: Any?) -> Activity<Attributes>? {
      Activity<Attributes>.activities.first { $0.id == id as? String }
    }

    private static func content(_ args: [String: Any]) -> ActivityContent<Attributes.ContentState> {
      ActivityContent(
        state: Attributes.ContentState(json: args["content"] as? [String: Any] ?? [:]),
        staleDate: date(args["staleDate"]),
        relevanceScore: (args["relevanceScore"] as? NSNumber)?.doubleValue ?? 0)
    }

    private static func describe(_ activity: Activity<Attributes>) -> [String: Any] {
      let state: String =
        switch activity.activityState {
        case .active: "active"
        case .ended: "ended"
        case .dismissed: "dismissed"
        case .stale: "stale"
        case .pending: "pending"
        @unknown default: "unknown"
        }
      return ["id": activity.id, "kind": activity.attributes.kind, "state": state]
    }

    private static func date(_ value: Any?) -> Date? {
      (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
  #else
    static var enabled: Bool { false }
    static func start(_ args: [String: Any]) throws -> Any? { nil }
    static func update(_ args: [String: Any]) -> Bool { false }
    static func end(_ args: [String: Any]) -> Bool { false }
    static func list() -> [[String: Any]] { [] }
    static func pushToken(_ args: [String: Any]) -> String? { nil }
    static func observePushToStart() -> String? { nil }
    static func stopPushToStart() -> Any? { nil }
    static func observePushTokens(_ args: [String: Any]) -> String? { nil }
    static func stopPushTokens(_ args: [String: Any]) -> Any? { nil }
  #endif
}
