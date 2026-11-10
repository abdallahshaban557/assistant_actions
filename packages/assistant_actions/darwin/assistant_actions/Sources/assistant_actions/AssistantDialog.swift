import AppIntents
import Foundation

/// How intent parameters read in the dialogs and confirmation questions the
/// generated intents speak (`dialogs:` and `confirm:` templates). Nil reads
/// as nothing.
public enum AssistantDialog {
  public static func text(_ value: String?) -> String { value ?? "" }

  public static func text(_ value: AttributedString?) -> String { value.map { String($0.characters) } ?? "" }

  public static func text(_ value: Int?) -> String { value.map(String.init) ?? "" }

  public static func text(_ value: Double?) -> String {
    guard let value else { return "" }
    return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : value.formatted()
  }

  public static func text(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "" }

  /// "Nov 3, 2026 at 9:00 AM", or the date alone at midnight.
  public static func text(_ value: Date?) -> String {
    guard let date = value else { return "" }
    let time = Calendar.current.dateComponents([.hour, .minute], from: date)
    return time.hour == 0 && time.minute == 0
      ? date.formatted(date: .abbreviated, time: .omitted)
      : date.formatted(date: .abbreviated, time: .shortened)
  }

  public static func text(_ value: DateComponents?) -> String {
    text(value.flatMap { Calendar.current.date(from: $0) })
  }

  /// "5 min", "1 hr, 30 min".
  public static func text(_ value: Duration?) -> String {
    value?.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) ?? ""
  }

  public static func text(_ value: URL?) -> String { value?.absoluteString ?? "" }

  /// A person's name, or their email or phone number.
  public static func text(_ value: IntentPerson?) -> String {
    let encoded = AssistantValues.encode(value) as? [String: Any]
    return encoded?["name"] as? String ?? encoded?["email"] as? String ?? encoded?["phone"] as? String ?? ""
  }

  /// A schema enum case, in words: `threeSeconds` → "three seconds".
  public static func text<E: RawRepresentable>(_ value: E?) -> String where E.RawValue == String {
    guard let raw = value?.rawValue else { return "" }
    var words = ""
    for character in raw {
      if character.isUppercase && !words.isEmpty { words.append(" ") }
      words.append(contentsOf: character.lowercased())
    }
    return words
  }

  /// "A, B and C", skipping empty items.
  public static func list(_ items: [String]?) -> String {
    (items ?? []).filter { !$0.isEmpty }.formatted(.list(type: .and))
  }

  /// Items by their [titles] ("A and B"), or "this item" / "these 3 items"
  /// when any has no title, as in the default "Delete …?" question.
  public static func items(_ titles: [String]) -> String {
    if !titles.isEmpty && !titles.contains(where: \.isEmpty) { return list(titles) }
    return titles.count == 1 ? "this item" : "these \(titles.count) items"
  }
}
