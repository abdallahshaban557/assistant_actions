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

  public let title: String
  public let subtitle: String?
  public let rows: [Row]
  public let imagePath: String?
  public let systemImage: String?

  public init?(json: Any?) {
    guard let object = json as? [String: Any], let title = object["title"] as? String else { return nil }
    self.title = title
    subtitle = object["subtitle"] as? String
    rows = (object["rows"] as? [Any] ?? []).compactMap { row in
      guard let pair = row as? [Any], pair.count == 2, let label = pair[0] as? String, let value = pair[1] as? String
      else { return nil }
      return Row(label: label, value: value)
    }
    imagePath = object["imagePath"] as? String
    systemImage = object["systemImage"] as? String
  }
}
