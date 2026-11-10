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

  /// [records] matching any of [labels] (what Visual Intelligence recognised
  /// in an image), those matching the most labels' words first. Nothing
  /// when no label narrows the search.
  public static func records(
    _ records: [AssistantRecord], matchingLabels labels: [String], ignoring: Set<String>
  ) -> [AssistantRecord] {
    let terms = Set(self.terms(labels.joined(separator: " "), ignoring: ignoring))
    guard !terms.isEmpty else { return [] }
    let scored = records.map { record -> (AssistantRecord, Int) in
      let text = self.text(record)
      return (record, terms.filter { text.contains($0) }.count)
    }
    return scored.filter { $0.1 > 0 }.enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .map(\.element.0)
  }

  /// [records] whose place [field] (an `AssistantPlace` map) is the place
  /// [place] (one too) describes: within [radius] metres of its coordinate,
  /// nearest first; else, for a place without one, those whose name or
  /// address has its name's and address's words.
  public static func records(
    _ records: [AssistantRecord], matchingPlace place: Any, field: String, ignoring: Set<String>,
    radius: Double = 150
  ) -> [AssistantRecord] {
    guard let place = place as? [String: Any] else { return [] }
    if let here = coordinate(place) {
      return records.compactMap { record -> (AssistantRecord, Double)? in
        guard let there = (record.fields[field] as? [String: Any]).flatMap(coordinate) else { return nil }
        let d = distance(here, there)
        return d <= radius ? (record, d) : nil
      }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    let words = [place["name"], place["address"]].compactMap { $0 as? String }.joined(separator: " ")
    let terms = self.terms(words, ignoring: ignoring)
    guard !terms.isEmpty else { return [] }
    return records.filter { record in
      let fields = record.fields[field] as? [String: Any] ?? [:]
      let text = normalize([record.title, fields["name"] as? String ?? "", fields["address"] as? String ?? ""]
        .joined(separator: " "))
      return terms.allSatisfy { text.contains($0) }
    }
  }

  private static func coordinate(_ map: [String: Any]) -> (Double, Double)? {
    guard let lat = AssistantValues.double(map["latitude"]), let lon = AssistantValues.double(map["longitude"])
    else { return nil }
    return (lat, lon)
  }

  /// Metres between two coordinates (haversine).
  static func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    let r = 6_371_000.0, rad = Double.pi / 180
    let dLat = (b.0 - a.0) * rad, dLon = (b.1 - a.1) * rad
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * rad) * cos(b.0 * rad) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, sqrt(h)))
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
