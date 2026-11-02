import 'catalog.dart';

/// A Dart value type the generator can pass between Swift and Dart.
enum ValueKind { string, integer, decimal, boolean, dateTime, uri }

class ValueType {
  const ValueType(this.kind, {this.nullable = false});

  final ValueKind kind;
  final bool nullable;

  String get dart => '${switch (kind) {
        ValueKind.string => 'String',
        ValueKind.integer => 'int',
        ValueKind.decimal => 'double',
        ValueKind.boolean => 'bool',
        ValueKind.dateTime => 'DateTime',
        ValueKind.uri => 'Uri',
      }}${nullable ? '?' : ''}';

  String get swift => '${switch (kind) {
        ValueKind.string => 'String',
        ValueKind.integer => 'Int',
        ValueKind.decimal => 'Double',
        ValueKind.boolean => 'Bool',
        ValueKind.dateTime => 'Date',
        ValueKind.uri => 'URL',
      }}${nullable ? '?' : ''}';

  /// `AssistantValue.<decoder>` in Dart, `AssistantValues.<decoder>` in Swift.
  String get dartDecoder => switch (kind) {
        ValueKind.string => 'string',
        ValueKind.integer => 'integer',
        ValueKind.decimal => 'decimal',
        ValueKind.boolean => 'boolean',
        ValueKind.dateTime => 'date',
        ValueKind.uri => 'uri',
      };

  String get swiftDecoder => switch (kind) {
        ValueKind.string => 'string',
        ValueKind.integer => 'int',
        ValueKind.decimal => 'double',
        ValueKind.boolean => 'bool',
        ValueKind.dateTime => 'date',
        ValueKind.uri => 'url',
      };

  /// Dart expression encoding [expr] for Swift.
  String encodeDart(String expr) => switch (kind) {
        ValueKind.dateTime => 'AssistantValue.encodeDate($expr)',
        ValueKind.uri => nullable ? '$expr?.toString()' : '$expr.toString()',
        _ => expr,
      };
}

/// A field (or getter) of an annotated class.
class FieldModel {
  const FieldModel(this.name, this.type);

  final String name;
  final ValueType type;
}

/// `@AssistantEntity` on one of the app's classes.
class EntityModel {
  EntityModel({
    required this.className,
    required this.library,
    required this.title,
    required this.idField,
    required this.titleGetter,
    this.subtitleGetter,
  });

  final String className;
  final Uri library;
  final String title;
  final String idField;
  final String titleGetter;
  final String? subtitleGetter;

  String get swiftName => '${className}Entity';
}

/// A parameter of an `@AssistantAction` function.
class ParamModel {
  ParamModel({
    required this.name,
    required this.title,
    required this.named,
    this.value,
    this.entity,
    this.entityNullable = false,
    this.prompt,
  });

  final String name;
  final String title;
  final bool named;
  final String? prompt;

  /// Set for value parameters.
  final ValueType? value;

  /// Set for entity parameters.
  final EntityModel? entity;
  final bool entityNullable;

  bool get nullable => value?.nullable ?? entityNullable;

  String get swiftType => value?.swift ?? '${entity!.swiftName}${entityNullable ? '?' : ''}';
}

enum RunsModel { deferred, withFlutter }

class ShortcutModel {
  const ShortcutModel({required this.phrases, required this.shortTitle, required this.systemImage});

  final List<String> phrases;
  final String shortTitle;
  final String systemImage;
}

/// `@AssistantAction` on a top-level function.
class ActionModel {
  ActionModel({
    required this.functionName,
    required this.library,
    required this.title,
    required this.runs,
    required this.params,
    required this.returnsString,
    this.description,
    this.dialog,
    this.shortcut,
  });

  final String functionName;
  final Uri library;
  final String title;
  final String? description;
  final RunsModel runs;
  final String? dialog;
  final ShortcutModel? shortcut;
  final List<ParamModel> params;

  /// The function returns `String`/`String?` (possibly in a `Future`), which
  /// becomes what Siri says.
  final bool returnsString;

  String get id => functionName;
  String get swiftName => '${pascal(functionName)}Action';
}

/// A fixed container instance from a schema annotation, such as
/// `FixedList(id: 'mira', name: 'Mira')`.
class FixedInstance {
  const FixedInstance({required this.schema, required this.id, required this.strings, required this.nested});

  final String schema;
  final String id;
  final Map<String, String> strings;
  final Map<String, FixedInstance> nested;

  bool sameAs(FixedInstance other) =>
      schema == other.schema &&
      id == other.id &&
      strings.length == other.strings.length &&
      strings.entries.every((e) => other.strings[e.key] == e.value) &&
      nested.length == other.nested.length &&
      nested.entries.every((e) => other.nested[e.key]?.sameAs(e.value) ?? false);
}

/// One of the app's classes adopting an App Schema entity.
class SchemaEntityModel {
  SchemaEntityModel({
    required this.className,
    required this.library,
    required this.catalog,
    required this.schema,
    required this.idField,
    required this.mapping,
    required this.intents,
    required this.containers,
  });

  final String className;
  final Uri library;
  final DomainCatalog catalog;
  final EntitySchema schema;
  final String idField;

  /// Schema member name → the Dart field it maps to.
  final Map<String, FieldModel> mapping;

  /// The schema intents the annotation turned on.
  final List<(IntentSchema, IntentKind)> intents;

  /// Entity member name → its fixed instance.
  final Map<String, FixedInstance> containers;

  String get collection => className;
  String get swiftName => '${className}Entity';

  /// Every Dart field mapped by at least one member, in declaration order.
  List<FieldModel> get fields {
    final seen = <String>{};
    return [for (final f in mapping.values) if (seen.add(f.name)) f];
  }

  Iterable<IntentKind> get kinds => {for (final (_, k) in intents) k == IntentKind.append ? IntentKind.update : k};
}

/// Everything the builder read from the app.
class AppModel {
  AppModel({
    required this.appName,
    required this.actions,
    required this.entities,
    required this.schemaEntities,
  });

  final String appName;
  final List<ActionModel> actions;
  final List<EntityModel> entities;
  final List<SchemaEntityModel> schemaEntities;

  Iterable<Uri> get libraries => {
        for (final a in actions) a.library,
        for (final e in entities) e.library,
        for (final s in schemaEntities) s.library,
      };
}
