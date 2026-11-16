// The Live Activity attributes behind Dart's `AssistantLiveActivity`.
//
// The assistant_actions runtime compiles this file into the app, which starts
// and updates the activities. `dart run assistant_actions:install --widgets`
// copies it, unchanged, into the app's widget extension, which draws them.
// ActivityKit matches the two by type name and by their Codable fields, so
// the copies must stay identical: run the install step again after upgrading
// assistant_actions. Foundation (and, on iOS, ActivityKit) only.

import Foundation

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
#endif

/// What every Live Activity started from Dart carries.
public struct AssistantActivityAttributes: Codable, Hashable, Sendable {
  /// What the activity is, such as `recording`, so a widget can draw kinds
  /// differently. Fixed for the activity's lifetime.
  public var kind: String

  /// A JSON object the app passed when it started the activity, also fixed.
  public var data: String?

  public init(kind: String, data: String? = nil) {
    self.kind = kind
    self.data = data
  }

  /// [data], decoded.
  public var dataObject: [String: Any] { Self.object(data) }

  /// What the activity shows now. Dart replaces it with each update.
  public struct ContentState: Codable, Hashable, Sendable {
    /// An interactive button rendered on the Lock Screen and Dynamic Island.
    public struct Button: Codable, Hashable, Sendable {
      public var label: String
      public var actionId: String
      public var systemImage: String?
      public var args: String?

      public init(
        label: String, actionId: String, systemImage: String? = nil, args: String? = nil
      ) {
        self.label = label
        self.actionId = actionId
        self.systemImage = systemImage
        self.args = args
      }

      public init?(json: [String: Any]) {
        guard let label = json["label"] as? String, !label.isEmpty,
          let actionId = json["actionId"] as? String, !actionId.isEmpty
        else { return nil }
        let argsString: String?
        if let raw = json["args"] as? String {
          argsString = raw
        } else if let obj = json["args"] as? [String: Any],
          JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj)
        {
          argsString = String(data: data, encoding: .utf8)
        } else {
          argsString = nil
        }
        self.init(
          label: label, actionId: actionId, systemImage: json["systemImage"] as? String,
          args: argsString)
      }

      /// [args], decoded.
      public var argsObject: [String: Any] { AssistantActivityAttributes.object(args) }
    }

    public var title: String
    public var subtitle: String?

    /// An SF Symbol name, such as `mic.fill`.
    public var systemImage: String?

    /// From 0 to 1.
    public var progress: Double?

    /// With [timerEnd], a countdown; alone, a timer counting up from it.
    public var timerStart: Date?
    public var timerEnd: Date?

    /// Interactive buttons shown on the Lock Screen and Dynamic Island.
    public var buttons: [Button]

    /// A JSON object of anything else the app's own views need.
    public var data: String?

    private enum CodingKeys: String, CodingKey {
      case title, subtitle, systemImage, progress, timerStart, timerEnd, buttons, data
    }

    public init(
      title: String, subtitle: String? = nil, systemImage: String? = nil, progress: Double? = nil,
      timerStart: Date? = nil, timerEnd: Date? = nil, buttons: [Button] = [], data: String? = nil
    ) {
      self.title = title
      self.subtitle = subtitle
      self.systemImage = systemImage
      self.progress = progress
      self.timerStart = timerStart
      self.timerEnd = timerEnd
      self.buttons = buttons
      self.data = data
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.title = try c.decode(String.self, forKey: .title)
      self.subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
      self.systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
      self.progress = try c.decodeIfPresent(Double.self, forKey: .progress)
      self.timerStart = try c.decodeIfPresent(Date.self, forKey: .timerStart)
      self.timerEnd = try c.decodeIfPresent(Date.self, forKey: .timerEnd)
      self.buttons = try c.decodeIfPresent([Button].self, forKey: .buttons) ?? []
      self.data = try c.decodeIfPresent(String.self, forKey: .data)
    }

    /// The state Dart sent: dates are seconds since the Unix epoch.
    public init(json: [String: Any]) {
      func date(_ key: String) -> Date? {
        (json[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      }
      let rawButtons = (json["buttons"] as? [[String: Any]]) ?? []
      self.init(
        title: json["title"] as? String ?? "",
        subtitle: json["subtitle"] as? String,
        systemImage: json["systemImage"] as? String,
        progress: (json["progress"] as? NSNumber).map { min(max($0.doubleValue, 0), 1) },
        timerStart: date("timerStart"),
        timerEnd: date("timerEnd"),
        buttons: rawButtons.compactMap(Button.init(json:)),
        data: json["data"] as? String)
    }

    /// [data], decoded.
    public var dataObject: [String: Any] { AssistantActivityAttributes.object(data) }
  }

  static func object(_ json: String?) -> [String: Any] {
    guard let data = json?.data(using: .utf8) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

#if os(iOS) && canImport(ActivityKit)
  extension AssistantActivityAttributes: ActivityAttributes {}
#endif
