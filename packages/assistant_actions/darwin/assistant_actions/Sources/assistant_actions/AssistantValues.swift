import Foundation

/// How values cross between Swift and Dart: dates are seconds since the Unix
/// epoch, URLs and attributed strings are plain strings. The generated code
/// uses these so both sides agree.
public enum AssistantValues {
  public static func encode(_ date: Date?) -> Any { date.map { $0.timeIntervalSince1970 } ?? NSNull() }

  public static func encode(_ components: DateComponents?) -> Any {
    encode(components.flatMap { Calendar.current.date(from: $0) })
  }

  public static func encode(_ text: AttributedString?) -> Any {
    text.map { String($0.characters) } ?? NSNull()
  }

  public static func encode(_ url: URL?) -> Any { url?.absoluteString ?? NSNull() }

  public static func encode<T>(_ value: T?) -> Any { value ?? NSNull() }

  public static func date(_ value: Any?) -> Date? {
    (value as? Double).map(Date.init(timeIntervalSince1970:))
      ?? (value as? Int).map { Date(timeIntervalSince1970: Double($0)) }
  }

  /// Calendar components for a date; midnight means "all day".
  public static func dateComponents(_ value: Any?) -> DateComponents? {
    guard let date = date(value) else { return nil }
    let calendar = Calendar.current
    let time = calendar.dateComponents([.hour, .minute], from: date)
    let fields: Set<Calendar.Component> =
      time.hour == 0 && time.minute == 0
      ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
    return calendar.dateComponents(fields, from: date)
  }

  public static func string(_ value: Any?) -> String? { value as? String }

  public static func attributed(_ value: Any?) -> AttributedString? {
    (value as? String).map { AttributedString($0) }
  }

  public static func url(_ value: Any?) -> URL? { (value as? String).flatMap(URL.init(string:)) }

  public static func bool(_ value: Any?) -> Bool? { value as? Bool }

  public static func int(_ value: Any?) -> Int? { value as? Int ?? (value as? Double).map(Int.init) }

  public static func double(_ value: Any?) -> Double? { value as? Double ?? (value as? Int).map(Double.init) }

  /// Joins encoded strings (such as a note's name and content) into one
  /// value, skipping empty and repeated parts.
  public static func encodeJoined(_ parts: [Any]) -> Any {
    var seen: [String] = []
    for case let text as String in parts {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !seen.contains(trimmed) { seen.append(trimmed) }
    }
    return seen.isEmpty ? NSNull() : seen.joined(separator: "\n")
  }

  /// Appends [addition] to [existing] on a new line, for schema intents that
  /// add text (such as `notes.appendText`).
  public static func append(_ existing: String?, _ addition: String) -> String {
    let head = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = addition.trimmingCharacters(in: .whitespacesAndNewlines)
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return "\(head)\n\(tail)"
  }
}
