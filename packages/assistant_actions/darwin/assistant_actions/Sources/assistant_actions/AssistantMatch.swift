import Foundation

/// Forgiving search for entity queries. Siri passes words like "tasks" or
/// "my reminders in Mira"; matching those literally against titles finds
/// nothing, so words that only name the kind of item, the app or a filler are
/// ignored, and a search with nothing else left lists everything.
public enum AssistantMatch {
  /// Words that never narrow a search.
  static let filler: Set<String> = [
    "a", "an", "the", "my", "mine", "any", "all", "every", "some", "of", "in", "on", "at", "for", "to",
    "from", "with", "and", "or", "do", "does", "i", "me", "have", "has", "got", "what", "which", "whats",
    "are", "is", "there", "show", "list", "find", "get", "tell", "please", "app",
  ]

  /// [records] that match [string]. [ignoring] holds words naming the entity
  /// type, schema and app (matched with or without a plural "s"/"es").
  ///
  /// Every remaining word must appear (ignoring case and accents) in the
  /// record's title or one of its text fields; if no record has them all,
  /// records with any of them are returned instead.
  public static func records(
    _ records: [AssistantRecord], matching string: String, ignoring: Set<String>
  ) -> [AssistantRecord] {
    let terms = self.terms(string, ignoring: ignoring)
    guard !terms.isEmpty else { return records }
    let texts = records.map(text)
    let all = zip(records, texts).filter { _, text in terms.allSatisfy { text.contains($0) } }.map(\.0)
    if !all.isEmpty { return all }
    return zip(records, texts).filter { _, text in terms.contains { text.contains($0) } }.map(\.0)
  }

  /// The words of [string] that narrow a search.
  static func terms(_ string: String, ignoring: Set<String>) -> [String] {
    let ignored = Set(ignoring.map(normalize)).union(filler)
    return normalize(string)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty && !ignored.contains($0) && !ignored.contains(singular($0)) }
  }

  private static func text(_ record: AssistantRecord) -> String {
    var parts = [record.title]
    for case let value as String in record.fields.values { parts.append(value) }
    return normalize(parts.joined(separator: " "))
  }

  /// Lowercased, without accents.
  private static func normalize(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
  }

  /// "tasks" → "task", "boxes" → "box"; enough for type words.
  private static func singular(_ word: String) -> String {
    if word.hasSuffix("es"), word.count > 3, ["x", "s", "z", "h"].contains(word.dropLast(2).last.map(String.init) ?? "") {
      return String(word.dropLast(2))
    }
    if word.hasSuffix("s"), word.count > 2 { return String(word.dropLast()) }
    return word
  }
}
