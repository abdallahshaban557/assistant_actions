/// Apple's App Intents schema catalog, normalised.
///
/// `tool/export_catalog.dart` reads `AppIntentSchemas.sqlite` from Xcode and
/// writes one JSON file per domain into `package:assistant_actions/src/catalog/`.
/// The builder and the typed schema libraries both come from those files.
library;

/// A schema value type: `string`, `optional(of)`, `entity(ref)`, …
class SchemaType {
  const SchemaType(this.kind, {this.of, this.ref});

  factory SchemaType.fromJson(Map<String, Object?> json) => SchemaType(
        json['kind'] as String,
        of: json['of'] == null ? null : SchemaType.fromJson((json['of'] as Map).cast()),
        ref: json['ref'] as String?,
      );

  /// A primitive (`string`, `attributedString`, `bool`, `date`,
  /// `dateComponents`, `url`, `file`, …) or `optional`, `array`, `set`,
  /// `entity`, `enum`.
  final String kind;

  /// The element type of `optional`, `array` and `set`.
  final SchemaType? of;

  /// The schema id of an `entity` or `enum`, such as `reminders.list`.
  final String? ref;

  bool get isOptional => kind == 'optional';

  /// This type without `optional`.
  SchemaType get base => isOptional ? of! : this;

  Map<String, Object?> toJson() => {
        'kind': kind,
        if (of != null) 'of': of!.toJson(),
        if (ref != null) 'ref': ref,
      };

  @override
  String toString() => switch (kind) {
        'optional' => '$of?',
        'array' => '[$of]',
        'set' => 'Set<$of>',
        'entity' || 'enum' => '$kind:$ref',
        _ => kind,
      };
}

/// A property of an entity schema or a parameter of an intent schema.
class SchemaMember {
  const SchemaMember({
    required this.name,
    required this.title,
    required this.type,
    this.description,
    this.updatable = true,
    this.indexingKey,
  });

  factory SchemaMember.fromJson(Map<String, Object?> json) => SchemaMember(
        name: json['name'] as String,
        title: json['title'] as String? ?? json['name'] as String,
        type: SchemaType.fromJson((json['type'] as Map).cast()),
        description: json['description'] as String?,
        updatable: json['updatable'] as bool? ?? true,
        indexingKey: json['indexingKey'] as String?,
      );

  final String name;
  final String title;
  final SchemaType type;
  final String? description;
  final bool updatable;

  /// Spotlight's key for the value (`title`, `displayName`, …).
  final String? indexingKey;

  Map<String, Object?> toJson() => {
        'name': name,
        'title': title,
        'type': type.toJson(),
        if (description != null) 'description': description,
        if (!updatable) 'updatable': false,
        if (indexingKey != null) 'indexingKey': indexingKey,
      };
}

class EntitySchema {
  const EntitySchema({
    required this.id,
    required this.title,
    required this.availability,
    required this.properties,
  });

  factory EntitySchema.fromJson(String id, Map<String, Object?> json) => EntitySchema(
        id: id,
        title: json['title'] as String? ?? id,
        availability: (json['availability'] as Map?)?.cast<String, num>() ?? const {},
        properties: [
          for (final p in json['properties'] as List) SchemaMember.fromJson((p as Map).cast()),
        ],
      );

  /// `reminders.reminder`.
  final String id;
  final String title;

  /// Platform → first OS major version, e.g. `{iOS: 27, macOS: 27}`.
  final Map<String, num> availability;
  final List<SchemaMember> properties;

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  SchemaMember? property(String name) => properties.where((p) => p.name == name).firstOrNull;

  /// The property Siri shows as the title: the one indexed as `title` or
  /// `displayName`, else the first string.
  SchemaMember? get titleProperty =>
      properties.where((p) => p.indexingKey == 'title' || p.indexingKey == 'displayName').firstOrNull ??
      properties.where((p) => p.type.base.kind == 'string' || p.type.base.kind == 'attributedString').firstOrNull;

  Map<String, Object?> toJson() => {
        'title': title,
        'availability': availability,
        'properties': [for (final p in properties) p.toJson()],
      };
}

class EnumSchema {
  const EnumSchema({required this.id, required this.title, required this.cases});

  factory EnumSchema.fromJson(String id, Map<String, Object?> json) => EnumSchema(
        id: id,
        title: json['title'] as String? ?? id,
        cases: (json['cases'] as List).cast<String>(),
      );

  final String id;
  final String title;
  final List<String> cases;

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  Map<String, Object?> toJson() => {'title': title, 'cases': cases};
}

class IntentSchema {
  const IntentSchema({
    required this.id,
    required this.title,
    required this.availability,
    required this.parameters,
    this.description,
    this.result,
    this.opensApp = false,
    this.protocols = const [],
  });

  factory IntentSchema.fromJson(String id, Map<String, Object?> json) => IntentSchema(
        id: id,
        title: json['title'] as String? ?? id,
        description: json['description'] as String?,
        availability: (json['availability'] as Map?)?.cast<String, num>() ?? const {},
        parameters: [
          for (final p in json['parameters'] as List) SchemaMember.fromJson((p as Map).cast()),
        ],
        result: json['result'] == null ? null : SchemaType.fromJson((json['result'] as Map).cast()),
        opensApp: json['opensApp'] as bool? ?? false,
        protocols: (json['protocols'] as List?)?.cast<String>() ?? const [],
      );

  /// `reminders.createReminder`.
  final String id;
  final String title;
  final String? description;
  final Map<String, num> availability;
  final List<SchemaMember> parameters;

  /// What `perform()` must return, if anything.
  final SchemaType? result;

  /// Apple's schema opens the app when the intent runs (`_openApp`).
  final bool opensApp;

  /// System intent protocols the schema adopts (`_systemProtocols`), such as
  /// `audioStarting` for `AudioRecordingIntent` or `search`.
  final List<String> protocols;

  /// Starts an audio recording (`AudioRecordingIntent`).
  bool get recordsAudio => protocols.contains('audioStarting');

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  SchemaMember? parameter(String name) => parameters.where((p) => p.name == name).firstOrNull;

  Map<String, Object?> toJson() => {
        'title': title,
        if (description != null) 'description': description,
        'availability': availability,
        'parameters': [for (final p in parameters) p.toJson()],
        if (result != null) 'result': result!.toJson(),
        if (opensApp) 'opensApp': true,
        if (protocols.isNotEmpty) 'protocols': protocols,
      };
}

/// How an intent schema changes items of an entity schema.
///
/// [record] intents (`journal.createAudioEntry`) take nothing and return
/// nothing: they bring the app forward and the app starts recording a new
/// item itself.
enum IntentKind { create, update, append, delete, record }

/// One domain's schemas (`reminders`, `notes`, …), plus where they came from.
class DomainCatalog {
  const DomainCatalog({
    required this.domain,
    required this.hash,
    required this.xcode,
    required this.entities,
    required this.enums,
    required this.intents,
  });

  factory DomainCatalog.fromJson(Map<String, Object?> json) {
    final domain = json['domain'] as String;
    Map<String, Object?> section(String key) => (json[key] as Map).cast();
    return DomainCatalog(
      domain: domain,
      hash: json['hash'] as String,
      xcode: json['xcode'] as String,
      entities: {
        for (final MapEntry(:key, :value) in section('entities').entries)
          '$domain.$key': EntitySchema.fromJson('$domain.$key', (value as Map).cast()),
      },
      enums: {
        for (final MapEntry(:key, :value) in section('enums').entries)
          '$domain.$key': EnumSchema.fromJson('$domain.$key', (value as Map).cast()),
      },
      intents: {
        for (final MapEntry(:key, :value) in section('intents').entries)
          '$domain.$key': IntentSchema.fromJson('$domain.$key', (value as Map).cast()),
      },
    );
  }

  final String domain;

  /// `metadata.hash` of the `AppIntentSchemas.sqlite` this came from.
  final String hash;

  /// The Xcode build it came from, such as `27B52`.
  final String xcode;

  final Map<String, EntitySchema> entities;
  final Map<String, EnumSchema> enums;
  final Map<String, IntentSchema> intents;

  /// The intents that create, change or delete items of [entity], with how.
  ///
  /// Creates return the entity and take no target; updates take a `target`
  /// (appends are updates named `append…`); deletes take a list of entities.
  /// Records start an audio recording of a new item, take no parameters and
  /// are named after the entity (`createAudioEntry` for `journal.entry`).
  List<(IntentSchema, IntentKind)> intentsFor(EntitySchema entity) {
    bool isEntity(SchemaType? t) => t?.base.kind == 'entity' && t!.base.ref == entity.id;
    return [
      for (final intent in intents.values)
        if (intent.parameter('target') case final target? when isEntity(target.type))
          (intent, intent.name.startsWith('append') ? IntentKind.append : IntentKind.update)
        else if (intent.parameter('entities') case final list?
            when list.type.kind == 'array' && isEntity(list.type.of))
          (intent, IntentKind.delete)
        else if (isEntity(intent.result) && intent.parameter('target') == null)
          (intent, IntentKind.create)
        else if (intent.recordsAudio &&
            intent.parameters.isEmpty &&
            intent.result == null &&
            intent.name.endsWith(pascal(entity.name)))
          (intent, IntentKind.record),
    ];
  }

  /// Whether a fixed instance of [entity] can be written as a const in Dart:
  /// its properties are strings, enums, or other such entities.
  bool isFixable(EntitySchema entity, [Set<String> seen = const {}]) {
    if (seen.contains(entity.id)) return true;
    return entity.properties.every((p) {
      final t = p.type.base;
      if (t.kind == 'string' || t.kind == 'enum') return true;
      if (t.kind == 'entity') {
        if (t.ref == entity.id) return p.type.isOptional;
        final target = entities[t.ref];
        return target != null && isFixable(target, {...seen, entity.id});
      }
      return false;
    });
  }

  Map<String, Object?> toJson() => {
        'domain': domain,
        'hash': hash,
        'xcode': xcode,
        'entities': {for (final e in entities.values) e.name: e.toJson()},
        'enums': {for (final e in enums.values) e.name: e.toJson()},
        'intents': {for (final i in intents.values) i.name: i.toJson()},
      };
}

/// Dart type for a schema member, when the generator can map one; null for
/// types only Swift handles (files, sets, recurrence rules, places, …).
String? dartTypeFor(SchemaType type) {
  final base = switch (type.base.kind) {
    'string' || 'attributedString' => 'String',
    'bool' => 'bool',
    'int' => 'int',
    'double' => 'double',
    'date' || 'dateComponents' => 'DateTime',
    'url' => 'Uri',
    _ => null,
  };
  if (base == null) return null;
  return type.isOptional ? '$base?' : base;
}

/// `createReminder` → `CreateReminder`, `reminders` → `Reminders`.
String pascal(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The handler method a [IntentKind.record] intent calls in Dart:
/// `createAudioEntry` → `startAudioEntry`.
String recordMethod(IntentSchema intent) => 'start${pascal(intent.name.replaceFirst(RegExp('^create'), ''))}';

/// `CreateReminder` → `createReminder`.
String camel(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
