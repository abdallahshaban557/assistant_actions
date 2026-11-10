/// Types the generated `assistant_actions.g.dart` fills in.
library;

/// Runs one action with the arguments Swift sent and returns what Siri should
/// say, if anything.
typedef ActionHandler = Future<String?> Function(Map<String, Object?> args);

/// Applies one change Siri made to a schema entity collection.
typedef CollectionHandler = Future<void> Function(InboxChange change);

/// How an entity class is published to the snapshot Swift reads.
class EntityCodec<T> {
  const EntityCodec(
    this.collection, {
    required this.id,
    required this.title,
    required this.fields,
    this.subtitle,
  });

  final String collection;
  final String Function(T item) id;
  final String Function(T item) title;
  final String? Function(T item)? subtitle;
  final Map<String, Object?> Function(T item) fields;

  Map<String, Object?> encode(T item) => {
        'id': id(item),
        'title': title(item),
        if (subtitle?.call(item) case final s?) 'subtitle': s,
        'fields': fields(item),
      };
}

/// Everything `AssistantActions.start` needs, generated from the app's
/// annotations.
class AssistantActionsRegistry {
  const AssistantActionsRegistry({
    this.actions = const {},
    this.codecs = const {},
    this.collections = const {},
  });

  /// Action id → handler.
  final Map<String, ActionHandler> actions;

  /// Entity class → codec, for `AssistantActions.publish`.
  final Map<Type, EntityCodec<Object?>> codecs;

  /// Collection name → handler for Siri's creates, updates and deletes.
  final Map<String, CollectionHandler> collections;
}

/// A create, update or delete Siri queued for a schema entity collection.
class InboxChange {
  const InboxChange({
    required this.kind,
    required this.collection,
    required this.id,
    this.fields = const {},
    this.cleared = const [],
  });

  factory InboxChange.fromJson(Map<String, Object?> json) => InboxChange(
        kind: json['kind'] as String,
        collection: json['collection'] as String,
        id: json['id'] as String,
        fields: (json['fields'] as Map?)?.cast<String, Object?>() ?? const {},
        cleared: (json['cleared'] as List?)?.cast<String>() ?? const [],
      );

  /// `create`, `update` or `delete`.
  final String kind;
  final String collection;

  /// The item's id. For a create, the id Swift gave the new item: keep it,
  /// so later updates and deletes from Siri find the same item.
  final String id;

  /// Changed values, keyed by Dart field name.
  final Map<String, Object?> fields;

  /// Fields set to null.
  final List<String> cleared;
}

/// Decodes the values Swift sends (see `AssistantValues.swift`).
abstract final class AssistantValue {
  static String? string(Object? v) => v is String ? v : null;
  static bool? boolean(Object? v) => v is bool ? v : null;
  static int? integer(Object? v) => v is num ? v.toInt() : null;
  static double? decimal(Object? v) => v is num ? v.toDouble() : null;
  static Uri? uri(Object? v) => v is String ? Uri.tryParse(v) : null;

  /// Seconds since the Unix epoch.
  static DateTime? date(Object? v) =>
      v is num ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;

  static double? encodeDate(DateTime? d) => d == null ? null : d.millisecondsSinceEpoch / 1000;

  /// Seconds.
  static Duration? duration(Object? v) => v is num ? Duration(microseconds: (v * 1e6).round()) : null;

  static double? encodeDuration(Duration? d) => d == null ? null : d.inMicroseconds / 1e6;

  /// A schema enum case by its name in Apple's schema. Dart names that clash
  /// with reserved words end in `$` (`this$` for `this`).
  static T? enumeration<T extends Enum>(List<T> values, Object? v) {
    if (v is! String) return null;
    for (final value in values) {
      if (value.name == v || value.name == '$v\$') return value;
    }
    return null;
  }

  /// The case name Swift expects for a schema enum value.
  static String? encodeEnum(Enum? e) => e == null
      ? null
      : e.name.endsWith(r'$')
          ? e.name.substring(0, e.name.length - 1)
          : e.name;

  /// A list, decoding each element with [element] and dropping ones it
  /// can't read.
  static List<T>? list<T>(Object? v, T? Function(Object? element) element) =>
      v is List ? [for (final e in v) if (element(e) case final T value) value] : null;
}
