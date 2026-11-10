/// How schema members and intent parameters cross to Dart, shared by the
/// typed schema libraries, the reader and the writers.
library;

import 'catalog.dart';

/// Dart's reserved words, which can't name a parameter or enum value.
const dartReserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', //
  'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return',
  'super', 'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

/// Swift keywords that need backticks as enum cases or members.
const swiftReserved = {
  'associatedtype', 'class', 'deinit', 'enum', 'extension', 'func', 'import', 'init', 'inout', 'internal',
  'let', 'operator', 'private', 'protocol', 'public', 'static', 'struct', 'subscript', 'typealias', 'var',
  'break', 'case', 'continue', 'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard', 'if', 'in',
  'repeat', 'return', 'switch', 'where', 'while', 'as', 'false', 'is', 'nil', 'self', 'Self', 'super',
  'throw', 'throws', 'true', 'try', 'Type', 'Any',
};

/// A Dart identifier for schema name [name]: `this` → `this$`.
String dartName(String name) => dartReserved.contains(name) ? '$name\$' : name;

/// A Swift identifier for schema name [name]: `repeat` → `` `repeat` ``.
String swiftName(String name) => swiftReserved.contains(name) ? '`$name`' : name;

/// The Dart enum generated for schema enum [id]: `camera.captureMode` →
/// `CameraCaptureMode`.
String dartEnumName(String id) {
  final [domain, name] = id.split('.');
  return '${pascal(domain)}${pascal(name)}';
}

/// Dart type for a schema member, when the generator can map one; null for
/// types only Swift handles (link metadata, visual scenes) and lists of
/// values.
///
/// People, places, files, recurrence rules and unions are the runtime's
/// `AssistantPerson`, `AssistantPlace`, `AssistantFile`,
/// `AssistantRecurrence` and `AssistantUnion`.
///
/// A member that is another entity (or a list of them) maps to its id (or
/// ids): a `String` (`List<String>`) naming an item of an entity the app
/// also adopts.
///
/// [openEnums] names the app's Dart enums for schema enums whose cases the
/// app defines (`openEnum`); without one, they are `Enum`.
String? dartTypeFor(SchemaType type, [Map<String, String> openEnums = const {}]) {
  final t = type.base;
  if (t.kind == 'entity' && t.ref != null) return type.isOptional ? 'String?' : 'String';
  if (t.isList && t.of!.base.kind == 'entity' && t.of!.base.ref != null) return 'List<String>';
  if (t.isList) {
    final element = dartElementType(t.of!.base, openEnums);
    if (element == null) return null;
    return type.isOptional ? 'List<$element>?' : 'List<$element>';
  }
  final base = dartElementType(type.base, openEnums);
  if (base == null) return null;
  return type.isOptional ? '$base?' : base;
}

/// Dart type of a non-optional, non-list schema type.
String? dartElementType(SchemaType t, [Map<String, String> openEnums = const {}]) => switch (t.kind) {
      'string' || 'attributedString' || 'stringSearchCriteria' => 'String',
      'bool' => 'bool',
      'int' => 'int',
      'double' => 'double',
      'date' || 'dateComponents' => 'DateTime',
      'url' => 'Uri',
      'duration' => 'Duration',
      'enum' => dartEnumName(t.ref!),
      'openEnum' => openEnums[t.ref] ?? 'Enum',
      'person' => 'AssistantPerson',
      'placeDescriptor' => 'AssistantPlace',
      'file' => 'AssistantFile',
      'recurrenceRule' => 'AssistantRecurrence',
      'union' => 'AssistantUnion',
      'sceneDescriptor' => 'AssistantSemanticContent',
      _ => null,
    };

/// The Dart parameter an importing query's handler method takes: `place`
/// for a `placeDescriptor`, `person` for a `person`.
String queryArgName(QuerySchema q) => switch (q.type.kind) {
      'placeDescriptor' => 'place',
      'person' => 'person',
      _ => 'value',
    };

/// The handler method answering importing query [q]:
/// `Future<List<String>> placeIntentValueQuery(AssistantPlace place)`,
/// returning ids of published items.
String queryMethodSignature(QuerySchema q) =>
    'Future<List<String>> ${q.name}(${dartElementType(q.type)} ${queryArgName(q)})';

/// How one intent parameter reaches the Dart handler method.
enum ArgShape {
  /// A value: `String`, `int`, `DateTime`, an enum, a `Duration`, ….
  value,

  /// An entity, as its id.
  entity,
}

/// One parameter of a [IntentKind.call] intent, as the handler method takes it.
class CallArg {
  CallArg(this.member, this.shape, this.element,
      {required this.list, required this.optional, this.openEnums = const {}});

  /// The app's Dart enums for `openEnum`s, by schema id.
  final Map<String, String> openEnums;

  final SchemaMember member;
  final ArgShape shape;

  /// The element's schema type (without optional or list).
  final SchemaType element;
  final bool list;
  final bool optional;

  String get name => dartName(member.name);

  /// The element's Dart type.
  String get dartElement => shape == ArgShape.entity ? 'String' : dartElementType(element, openEnums)!;

  String get dartType {
    final t = list ? 'List<$dartElement>' : dartElement;
    return optional ? '$t?' : t;
  }
}

/// [p] as a handler argument, or null when Dart can't receive it yet.
CallArg? callArg(SchemaMember p, [Map<String, String> openEnums = const {}]) {
  final optional = p.type.isOptional;
  var t = p.type.base;
  final list = t.isList;
  if (list) t = t.of!.base;
  if (t.kind == 'entity') {
    if (t.ref == null) return null;
    return CallArg(p, ArgShape.entity, t, list: list, optional: optional);
  }
  if (t.isList || dartElementType(t) == null) return null;
  return CallArg(p, ArgShape.value, t, list: list, optional: optional, openEnums: openEnums);
}

/// What a [IntentKind.call] handler method returns to Siri.
enum CallResult {
  none,

  /// The id of one item of the result entity (which the app has published).
  entity,

  /// Ids of items of the result entity.
  entities,

  /// One case of the result union (an `AssistantUnion`).
  union,

  /// Cases of the result union.
  unions,

  /// A result Dart can't produce.
  unsupported,
}

CallResult callResult(IntentSchema intent) {
  final r = intent.result;
  if (r == null) return CallResult.none;
  if (r.base.kind == 'entity' && r.base.ref != null) return CallResult.entity;
  if (r.base.isList && r.base.of!.base.kind == 'entity' && r.base.of!.base.ref != null) return CallResult.entities;
  if (r.base.kind == 'union') return CallResult.union;
  if (r.base.isList && r.base.of!.base.kind == 'union') return CallResult.unions;
  return CallResult.unsupported;
}

/// The entity a [CallResult.entity] or [CallResult.entities] result is.
String? resultEntity(IntentSchema intent) => switch (callResult(intent)) {
      CallResult.entity => intent.result!.base.ref,
      CallResult.entities => intent.result!.base.of!.base.ref,
      _ => null,
    };

/// The Dart handler method for [intent] (a [IntentKind.call]): the intent's
/// name, unless that clashes with the inbox methods (`create`, `update`,
/// `delete`) or a reserved word, when the [owner]'s name is added:
/// `spreadsheet.create` → `createDocument`.
String callMethod(IntentSchema intent, EntitySchema? owner) {
  final name = intent.name;
  if (const {'create', 'update', 'delete'}.contains(name) || dartReserved.contains(name)) {
    return '$name${pascal(owner?.name ?? intent.domain)}';
  }
  return name;
}

/// The Dart signature of [intent]'s handler method, such as
/// `Future<void> startCapture({required CameraCaptureMode captureMode, ...})`.
///
/// With [reply] (the intent is in the annotation's `replies`), it returns an
/// `AssistantReply` of that value instead.
String callSignature(IntentSchema intent, EntitySchema? owner,
    [Map<String, String> openEnums = const {}, bool reply = false]) {
  final args = [
    for (final p in intent.parameters)
      if (callArg(p, openEnums) case final a?) a.optional ? '${a.dartType} ${a.name}' : 'required ${a.dartType} ${a.name}',
  ];
  final returns = switch (callResult(intent)) {
    CallResult.entity => 'String',
    CallResult.entities => 'List<String>',
    CallResult.union => 'AssistantUnion',
    CallResult.unions => 'List<AssistantUnion>',
    _ => 'void',
  };
  final result = reply ? 'AssistantReply<$returns>' : returns;
  return 'Future<$result> ${callMethod(intent, owner)}(${args.isEmpty ? '' : '{${args.join(', ')}}'})';
}

/// Why deep link template [url] (an entity annotation's `url:`) can't be
/// used, or null: it must be an absolute URL whose only placeholder is
/// `{id}`.
String? urlTemplateError(String url) {
  final placeholders = RegExp(r'\{([^}]*)\}').allMatches(url).map((m) => m[1]).toSet();
  final others = placeholders.where((p) => p != 'id');
  if (others.isNotEmpty) return 'url "$url" can only use {id}, not ${others.map((p) => '{$p}').join(', ')}.';
  if (!placeholders.contains('id')) return 'url "$url" needs {id}, so each item has its own link.';
  final parsed = Uri.tryParse(url.replaceAll('{id}', 'id'));
  if (parsed == null || !parsed.hasScheme) {
    return "url \"$url\" must be an absolute URL, such as 'myapp://items/{id}'.";
  }
  return null;
}

/// The parameters of [intent] Dart doesn't receive yet, with their types.
List<SchemaMember> droppedArgs(IntentSchema intent) => [
      for (final p in intent.parameters)
        if (callArg(p) == null) p,
    ];
