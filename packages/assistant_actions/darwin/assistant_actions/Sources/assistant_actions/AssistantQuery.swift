import Foundation

/// Answers a `SnapshotAnswer` action from the published snapshot plus pending
/// inbox changes, in Swift, so Siri can reply without Flutter running.
public enum AssistantQuery {
  public struct Answer {
    /// Each listed item, formatted with the item template.
    public let items: [String]
    /// What Siri says.
    public let dialog: String
  }

  public static func answer(
    _ collection: String,
    where filters: [String: Any] = [:],
    sortBy: String? = nil,
    descending: Bool = false,
    limit: Int,
    dateFields: Set<String> = [],
    titleField: String? = nil,
    item: String,
    dialog: String,
    empty: String,
    separator: String
  ) -> Answer {
    answer(
      records: AssistantSnapshot.records(collection), where: filters, sortBy: sortBy,
      descending: descending, limit: limit, dateFields: dateFields, titleField: titleField,
      item: item, dialog: dialog, empty: empty, separator: separator)
  }

  /// [answer] over given records; separate so it can be tested.
  static func answer(
    records: [AssistantRecord],
    where filters: [String: Any],
    sortBy: String?,
    descending: Bool,
    limit: Int,
    dateFields: Set<String>,
    titleField: String?,
    item: String,
    dialog: String,
    empty: String,
    separator: String
  ) -> Answer {
    var matching = records.filter { record in
      filters.allSatisfy { key, value in matches(record.fields[key], value) }
    }
    if let sortBy {
      // Stable: equal items keep their published order.
      matching = matching.enumerated().sorted { a, b in
        let order = compare(a.element.fields[sortBy], b.element.fields[sortBy], descending: descending)
        return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
      }.map(\.element)
    }
    guard !matching.isEmpty else { return Answer(items: [], dialog: empty) }

    let shown = matching.prefix(max(limit, 0))
    let items = shown.map { record -> String in
      var values: [String: Any] = [:]
      for (key, value) in record.fields {
        values[key] = dateFields.contains(key) ? AssistantValues.date(value).map(describe) as Any : value
      }
      let title = record.title.isEmpty ? (titleField.flatMap { record.fields[$0] as? String } ?? "") : record.title
      values["title"] = title
      return render(item, values)
    }
    return Answer(
      items: items,
      dialog: render(
        dialog,
        ["count": matching.count, "items": items.joined(separator: separator), "rest": matching.count - shown.count]))
  }

  // MARK: - Templates

  /// Renders `{name}`, `{name|one|many}` and optional `[…]` segments, which are
  /// left out when a placeholder inside them is empty, null or 0.
  static func render(_ template: String, _ values: [String: Any]) -> String {
    var output = ""
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "[") {
      output += fill(rest[..<open], values).text
      guard let close = rest[open...].firstIndex(of: "]") else {
        rest = rest[open...]
        break
      }
      let segment = fill(rest[rest.index(after: open)..<close], values)
      if !segment.hasEmpty { output += segment.text }
      rest = rest[rest.index(after: close)...]
    }
    return output + fill(rest, values).text
  }

  private static func fill(_ text: Substring, _ values: [String: Any]) -> (text: String, hasEmpty: Bool) {
    var output = ""
    var hasEmpty = false
    var rest = text
    while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
      output += rest[..<open]
      let parts = rest[rest.index(after: open)..<close].split(separator: "|", omittingEmptySubsequences: false)
      let value = values[String(parts[0])]
      if parts.count == 3 {
        output += number(value) == 1 ? parts[1] : parts[2]
      } else {
        let text = format(value)
        if text.isEmpty || number(value) == 0 { hasEmpty = true }
        output += text
      }
      rest = rest[rest.index(after: close)...]
    }
    return (output + rest, hasEmpty)
  }

  private static func format(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let flag = boolean(value) { return flag ? "yes" : "no" }
    if let n = number(value) { return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n) }
    return value as? String ?? "\(value)"
  }

  /// A real boolean. JSON numbers arrive as NSNumber, and Swift would also
  /// read an NSNumber holding 0 or 1 as a Bool, so check its CF type.
  private static func boolean(_ value: Any?) -> Bool? {
    if let n = value as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil }
    return value as? Bool
  }

  private static func number(_ value: Any?) -> Double? {
    guard boolean(value) == nil else { return nil }
    if let n = value as? NSNumber { return n.doubleValue }
    return (value as? Int).map(Double.init) ?? (value as? Double)
  }

  /// "Nov 3, 2026 at 9:00 AM", or the date alone at midnight.
  private static func describe(_ date: Date) -> String {
    let time = Calendar.current.dateComponents([.hour, .minute], from: date)
    return time.hour == 0 && time.minute == 0
      ? date.formatted(date: .abbreviated, time: .omitted)
      : date.formatted(date: .abbreviated, time: .shortened)
  }

  // MARK: - Filtering and sorting

  private static func matches(_ value: Any?, _ expected: Any) -> Bool {
    switch expected {
    case let flag as Bool: return boolean(value) == flag
    case let text as String: return value as? String == text
    case let n as Int: return number(value) == Double(n)
    default: return false
    }
  }

  /// Orders values of one field; missing values always come last.
  private static func compare(_ a: Any?, _ b: Any?, descending: Bool) -> ComparisonResult {
    let a = a is NSNull ? nil : a
    let b = b is NSNull ? nil : b
    switch (a, b) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    default: break
    }
    var order: ComparisonResult
    if let x = number(a), let y = number(b) {
      order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    } else if let x = boolean(a), let y = boolean(b) {
      order = x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
    } else {
      order = format(a).localizedStandardCompare(format(b))
    }
    if descending && order != .orderedSame {
      order = order == .orderedAscending ? .orderedDescending : .orderedAscending
    }
    return order
  }
}
