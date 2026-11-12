import Foundation

/// What a live Dart action or intent handler returned as an
/// `AssistantReply`: the intent's value, what Siri says, a result card, and
/// items to choose from.
public struct AssistantReply {
  /// The intent's value as Dart encoded it: an id, ids, or a union case.
  public let value: Any?
  public let dialog: String?
  public let card: AssistantCard?

  /// Ids of matching items for Siri to ask about.
  public let choices: [String]
  public let prompt: String?

  /// Reads the JSON the generated Dart registry sends (`AssistantReply.encode`).
  public init(json: String?) {
    let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
    value = object["value"].flatMap { $0 is NSNull ? nil : $0 }
    dialog = object["dialog"] as? String
    card = AssistantCard(json: object["card"])
    choices = (object["choices"] as? [Any])?.compactMap { $0 as? String } ?? []
    prompt = object["prompt"] as? String
  }

  /// The ids to look up for an intent that returns one item: the choices, or
  /// the value.
  public var ids: [String] {
    if !choices.isEmpty { return choices }
    return (value as? String).map { [$0] } ?? []
  }
}

/// A result card from Dart's `AssistantCard`, which `AssistantCardView` shows.
public struct AssistantCard: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public let label: String
    public let value: String
  }

  /// A button that runs Dart action [action] with [args] (JSON text) and
  /// updates the card (`AssistantCardStore`), from iOS 26 / macOS 26.
  public struct Button: Equatable, Sendable {
    public let title: String
    public let action: String
    public let args: String
    public let systemImage: String?
    public let destructive: Bool
  }

  public let title: String
  public let subtitle: String?
  public let rows: [Row]
  public let imagePath: String?
  public let systemImage: String?
  public let buttons: [Button]

  /// The card as JSON text, as Dart sent it: what a generated
  /// `SnippetIntent` keeps to show it again.
  public let json: String

  /// Reads JSON text, such as [json].
  public init?(text: String) {
    self.init(json: try? JSONSerialization.jsonObject(with: Data(text.utf8)))
  }

  public init?(json: Any?) {
    guard let object = json as? [String: Any], let title = object["title"] as? String,
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return nil }
    self.json = String(decoding: data, as: UTF8.self)
    self.title = title
    subtitle = object["subtitle"] as? String
    rows = (object["rows"] as? [Any] ?? []).compactMap { row in
      guard let pair = row as? [Any], pair.count == 2, let label = pair[0] as? String, let value = pair[1] as? String
      else { return nil }
      return Row(label: label, value: value)
    }
    imagePath = object["imagePath"] as? String
    systemImage = object["systemImage"] as? String
    buttons = (object["buttons"] as? [Any] ?? []).compactMap { button in
      guard let button = button as? [String: Any], let title = button["title"] as? String,
        let action = button["action"] as? String
      else { return nil }
      let args = (button["args"] as? [String: Any])
        .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        .map { String(decoding: $0, as: UTF8.self) }
      return Button(
        title: title, action: action, args: args ?? "{}", systemImage: button["systemImage"] as? String,
        destructive: button["destructive"] as? Bool ?? false)
    }
  }
}
