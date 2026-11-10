import Foundation

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
#endif

/// The Swift end of Dart's `AssistantLiveActivity`: starts, updates and ends
/// ActivityKit Live Activities of `AssistantActivityAttributes`, over
/// `AssistantHostCalls`. The app's widget extension draws them (see
/// `dart run assistant_actions:install --widgets`).
///
/// Live Activities are iOS-only: on macOS every call reports that they're
/// unavailable.
@MainActor
enum AssistantLiveActivities {
  static func register() {
    AssistantHostCalls.register("liveActivity.enabled") { _ in enabled }
    AssistantHostCalls.register("liveActivity.start") { try start($0) }
    AssistantHostCalls.register("liveActivity.update") { update($0) }
    AssistantHostCalls.register("liveActivity.end") { end($0) }
    AssistantHostCalls.register("liveActivity.list") { _ in list() }
  }

  #if os(iOS) && canImport(ActivityKit)
    typealias Attributes = AssistantActivityAttributes

    /// The user allows Live Activities for the app (and the device has them).
    static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// `{kind, data?, content, staleDate?, relevanceScore?}` → the activity,
    /// or nil when Live Activities are turned off. Throws what ActivityKit
    /// throws, such as when the app is in the background or Info.plist lacks
    /// `NSSupportsLiveActivities`.
    static func start(_ args: [String: Any]) throws -> Any? {
      guard enabled else { return nil }
      let attributes = Attributes(kind: args["kind"] as? String ?? "default", data: args["data"] as? String)
      let activity = try Activity.request(attributes: attributes, content: content(args), pushType: nil)
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
  #endif
}
