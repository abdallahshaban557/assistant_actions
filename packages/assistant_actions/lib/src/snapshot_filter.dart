/// Predicates for filtering published items in a `SnapshotAnswer`.
library;

/// Operators supported by [SnapshotFilter].
enum SnapshotOperator {
  equals,
  notEquals,
  lessThan,
  lessOrEqual,
  greaterThan,
  greaterOrEqual,
  contains,
  startsWith,
  isNull,
  isNotNull,
  isToday,
  isPast,
  isFuture,
}

/// A predicate that filters published items in a `SnapshotAnswer`.
///
/// ```dart
/// const overdueWorkTasks = SnapshotAnswer<TaskItem>(
///   filters: [
///     SnapshotFilter.equals('done', false),
///     SnapshotFilter.equals('priority', TaskPriority.high),
///     SnapshotFilter.isPast('due'),
///   ],
///   sortBy: 'due',
///   item: '{title}',
///   dialog: 'You have {count} overdue {count|task|tasks}: {items}.',
///   empty: 'Nothing overdue.',
/// );
/// ```
class SnapshotFilter {
  /// Matches items whose [field] equals [value] (`bool`, `String`, `int`,
  /// `double`, `Duration`, ISO-8601 `DateTime` string, or an `@AssistantEnum`
  /// / schema enum).
  const SnapshotFilter.equals(this.field, Object this.value)
      : operator = SnapshotOperator.equals;

  /// Matches items whose [field] does not equal [value].
  const SnapshotFilter.notEquals(this.field, Object this.value)
      : operator = SnapshotOperator.notEquals;

  /// Matches items whose `int`, `double`, `Duration` or `DateTime` [field] is
  /// strictly less than [value].
  ///
  /// For `DateTime` fields inside a `const` `SnapshotAnswer`, pass an ISO-8601
  /// `String` such as `'2026-11-03T09:00:00Z'`.
  const SnapshotFilter.lessThan(this.field, Object this.value)
      : operator = SnapshotOperator.lessThan;

  /// Matches items whose `int`, `double`, `Duration` or `DateTime` [field] is
  /// less than or equal to [value].
  const SnapshotFilter.lessOrEqual(this.field, Object this.value)
      : operator = SnapshotOperator.lessOrEqual;

  /// Matches items whose `int`, `double`, `Duration` or `DateTime` [field] is
  /// strictly greater than [value].
  const SnapshotFilter.greaterThan(this.field, Object this.value)
      : operator = SnapshotOperator.greaterThan;

  /// Matches items whose `int`, `double`, `Duration` or `DateTime` [field] is
  /// greater than or equal to [value].
  const SnapshotFilter.greaterOrEqual(this.field, Object this.value)
      : operator = SnapshotOperator.greaterOrEqual;

  /// Matches items whose `String` [field] contains [substring], ignoring case
  /// and diacritics.
  const SnapshotFilter.contains(this.field, String substring)
      : operator = SnapshotOperator.contains,
        value = substring;

  /// Matches items whose `String` [field] starts with [prefix], ignoring case
  /// and diacritics.
  const SnapshotFilter.startsWith(this.field, String prefix)
      : operator = SnapshotOperator.startsWith,
        value = prefix;

  /// Matches items whose [field] is `null`.
  const SnapshotFilter.isNull(this.field)
      : operator = SnapshotOperator.isNull,
        value = null;

  /// Matches items whose [field] is not `null`.
  const SnapshotFilter.isNotNull(this.field)
      : operator = SnapshotOperator.isNotNull,
        value = null;

  /// Matches items whose `DateTime` [field] falls on today's calendar day when
  /// Siri answers.
  const SnapshotFilter.isToday(this.field)
      : operator = SnapshotOperator.isToday,
        value = null;

  /// Matches items whose `DateTime` [field] is earlier than the moment Siri
  /// answers (overdue).
  const SnapshotFilter.isPast(this.field)
      : operator = SnapshotOperator.isPast,
        value = null;

  /// Matches items whose `DateTime` [field] is later than the moment Siri
  /// answers.
  const SnapshotFilter.isFuture(this.field)
      : operator = SnapshotOperator.isFuture,
        value = null;

  /// The entity field name to inspect.
  final String field;

  /// How [field] is tested.
  final SnapshotOperator operator;

  /// Operand for comparison and string predicates; `null` for unary checks.
  final Object? value;
}
