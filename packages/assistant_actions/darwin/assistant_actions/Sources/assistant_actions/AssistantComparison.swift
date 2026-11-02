import Foundation

/// A value Siri can compare an entity property with, reduced to what the
/// comparison needs.
public enum AssistantKey: Equatable {
  case bool(Bool)
  case number(Double)
  case text(String)
  /// A date; [allDay] when it names a day without a time ("due Tuesday").
  case date(Date, allDay: Bool)
}

/// Values entity property comparators work on. The generated queries call
/// [AssistantPredicate] with these.
public protocol AssistantComparable {
  var assistantKey: AssistantKey { get }
}

extension Bool: AssistantComparable {
  public var assistantKey: AssistantKey { .bool(self) }
}

extension Int: AssistantComparable {
  public var assistantKey: AssistantKey { .number(Double(self)) }
}

extension Double: AssistantComparable {
  public var assistantKey: AssistantKey { .number(self) }
}

extension String: AssistantComparable {
  public var assistantKey: AssistantKey { .text(self) }
}

extension AttributedString: AssistantComparable {
  public var assistantKey: AssistantKey { .text(String(characters)) }
}

extension URL: AssistantComparable {
  public var assistantKey: AssistantKey { .text(absoluteString) }
}

extension Date: AssistantComparable {
  public var assistantKey: AssistantKey { .date(self, allDay: false) }
}

extension DateComponents: AssistantComparable {
  /// Components without an hour name a whole day.
  public var assistantKey: AssistantKey {
    .date(Calendar.current.date(from: self) ?? .distantPast, allDay: hour == nil)
  }
}

/// App Intents' `LessThanComparator` and friends need a `Comparable` value,
/// and schema dates such as `reminders.reminder.dueDate` are
/// `DateComponents`. Ordered by the date they name in the current calendar.
extension DateComponents: @retroactive Comparable {
  public static func < (a: DateComponents, b: DateComponents) -> Bool {
    (Calendar.current.date(from: a) ?? .distantPast) < (Calendar.current.date(from: b) ?? .distantPast)
  }
}

/// One of Siri's property comparisons ("is completed", "due before Friday",
/// "name contains milk"), evaluated in Swift.
public struct AssistantComparison: Equatable {
  public enum Operator: Equatable {
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual, between, contains
  }

  public let op: Operator
  /// What the property is compared with: one value, or two for [between].
  /// Nil when Siri asks for a property with no value.
  public let operands: [AssistantKey?]

  public init(_ op: Operator, _ operands: [AssistantKey?]) {
    self.op = op
    self.operands = operands
  }

  /// Whether a property holding [value] passes.
  ///
  /// Text compares ignoring case and accents. A date naming a whole day
  /// covers all of it: "due today" equals any time today, "before Friday"
  /// means before Friday starts and "after Friday" after it ends. A missing
  /// value only equals a missing operand.
  public func matches(_ value: AssistantKey?) -> Bool {
    let operand = operands.first ?? nil
    switch op {
    case .equal: return Self.equal(value, operand)
    case .notEqual: return !Self.equal(value, operand)
    case .contains:
      guard case .text(let text)? = value, case .text(let part)? = operand else { return false }
      return part.isEmpty || Self.fold(text).contains(Self.fold(part))
    case .between:
      guard operands.count == 2 else { return false }
      return Self.order(value, .greaterOrEqual, operands[0]) && Self.order(value, .lessOrEqual, operands[1])
    case .less, .lessOrEqual, .greater, .greaterOrEqual:
      return Self.order(value, op, operand)
    }
  }

  /// Orders two property values for sorting; missing values come last.
  public static func compare(_ a: AssistantKey?, _ b: AssistantKey?) -> ComparisonResult {
    switch (a, b) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case (.bool(let x)?, .bool(let y)?): return x == y ? .orderedSame : (!x ? .orderedAscending : .orderedDescending)
    case (.number(let x)?, .number(let y)?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    case (.date(let x, _)?, .date(let y, _)?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    case (.text(let x)?, .text(let y)?): return x.localizedStandardCompare(y)
    default: return .orderedSame
    }
  }

  private static func equal(_ value: AssistantKey?, _ operand: AssistantKey?) -> Bool {
    switch (value, operand) {
    case (nil, nil): return true
    case (.text(let x)?, .text(let y)?): return fold(x) == fold(y)
    case (.date(let x, _)?, .date(let y, let allDay)?):
      return allDay ? Calendar.current.isDate(x, inSameDayAs: y) : x == y
    default: return value == operand
    }
  }

  private static func order(_ value: AssistantKey?, _ op: Operator, _ operand: AssistantKey?) -> Bool {
    switch (value, operand) {
    case (.date(let x, _)?, .date(let y, true)?):
      let start = Calendar.current.startOfDay(for: y)
      let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
      switch op {
      case .less: return x < start
      case .lessOrEqual: return x < end
      case .greater: return x >= end
      default: return x >= start
      }
    case (.number?, .number?), (.text?, .text?), (.date?, .date?):
      let order = compare(value, operand)
      switch op {
      case .less: return order == .orderedAscending
      case .lessOrEqual: return order != .orderedDescending
      case .greater: return order == .orderedDescending
      default: return order != .orderedAscending
      }
    default:
      return false
    }
  }

  /// Lowercased, without accents.
  private static func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
  }
}

/// A comparison of one property of [Entity]: the `ComparatorMappingType` of
/// the generated `EntityPropertyQuery` conformances.
public struct AssistantPredicate<Entity> {
  private let value: (Entity) -> AssistantKey?
  public let comparison: AssistantComparison

  /// Compares the property [value] reads with [operands] (one, or two for
  /// `.between`; nil for "has no value").
  public init<V: AssistantComparable>(
    _ value: @escaping (Entity) -> V?, _ op: AssistantComparison.Operator, _ operands: V?...
  ) {
    self.value = { value($0)?.assistantKey }
    comparison = AssistantComparison(op, operands.map { $0?.assistantKey })
  }

  public func matches(_ entity: Entity) -> Bool { comparison.matches(value(entity)) }

  /// Answers an `EntityPropertyQuery`: the [entities] passing all of
  /// [predicates] (or any, when [all] is false; none given passes everything),
  /// sorted by [sorts] in turn and cut to [limit]. Sorting is stable.
  public static func apply(
    _ predicates: [AssistantPredicate], all: Bool, to entities: [Entity],
    sortedBy sorts: [(key: (Entity) -> AssistantKey?, ascending: Bool)] = [], limit: Int? = nil
  ) -> [Entity] {
    var found = entities.filter { entity in
      predicates.isEmpty
        || (all ? predicates.allSatisfy { $0.matches(entity) } : predicates.contains { $0.matches(entity) })
    }
    if !sorts.isEmpty {
      found = found.enumerated().sorted { a, b in
        for sort in sorts {
          var order = AssistantComparison.compare(sort.key(a.element), sort.key(b.element))
          let missing = sort.key(a.element) == nil || sort.key(b.element) == nil
          if !sort.ascending && !missing && order != .orderedSame {
            order = order == .orderedAscending ? .orderedDescending : .orderedAscending
          }
          if order != .orderedSame { return order == .orderedAscending }
        }
        return a.offset < b.offset
      }.map(\.element)
    }
    if let limit { found = Array(found.prefix(max(limit, 0))) }
    return found
  }
}
