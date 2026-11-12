import Foundation

/// The cards that generated interactive snippets show (`SnippetIntent`,
/// iOS 26 / macOS 26). A card's button runs a Dart action; the `card` of the
/// action's `AssistantReply` replaces the card, and Siri shows it when it
/// performs the snippet intent again after the press.
///
/// Kept in UserDefaults (the newest few), so a press still finds the card
/// after the app was relaunched.
public enum AssistantCardStore {
  static let key = "assistant_actions.cards"

  /// How many cards are kept: the newest.
  static let limit = 20

  /// Card [id]: the last one a button's action replied with, else [initial]
  /// (`AssistantCard.json`, which the snippet intent was made with).
  public static func card(_ id: String, initial: String) -> AssistantCard? {
    entries().last { $0[0] == id }.flatMap { AssistantCard(text: $0[1]) } ?? AssistantCard(text: initial)
  }

  /// A button's `args` (JSON text) as the arguments of a Dart call.
  public static func args(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
  }

  /// Keeps the card in [reply] (what the Dart action returned) as card [id].
  /// A reply without a card, or one that isn't an `AssistantReply`, leaves
  /// the card as it was.
  public static func update(_ id: String, reply: String?) {
    guard let card = AssistantReply(json: reply).card else { return }
    let kept = entries().filter { $0[0] != id } + [[id, card.json]]
    UserDefaults.standard.set(Array(kept.suffix(limit)), forKey: key)
  }

  /// `[id, json]` pairs, oldest first.
  private static func entries() -> [[String]] {
    (UserDefaults.standard.array(forKey: key) as? [[String]] ?? []).filter { $0.count == 2 }
  }
}
