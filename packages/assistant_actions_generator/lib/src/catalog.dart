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
  /// `dateComponents`, `url`, `file`, `duration`, `person`, …) or `optional`,
  /// `array`, `set`, `entity`, `enum`, `union`.
  final String kind;

  /// The element type of `optional`, `array` and `set`.
  final SchemaType? of;

  /// The schema id of an `entity`, `enum` or `union`, such as
  /// `reminders.list`. Null for an `entity` that can be any of the app's
  /// entities (the target of `system.open`).
  final String? ref;

  bool get isOptional => kind == 'optional';

  bool get isList => kind == 'array' || kind == 'set';

  /// This type without `optional`, `array` or `set`.
  SchemaType get element => isOptional || isList ? of!.element : this;

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
        'entity' || 'enum' || 'union' => '$kind:${ref ?? 'any'}',
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
    this.protocols = const [],
  });

  factory EntitySchema.fromJson(String id, Map<String, Object?> json) => EntitySchema(
        id: id,
        title: json['title'] as String? ?? id,
        availability: (json['availability'] as Map?)?.cast<String, num>() ?? const {},
        properties: [
          for (final p in json['properties'] as List) SchemaMember.fromJson((p as Map).cast()),
        ],
        protocols: (json['protocols'] as List?)?.cast<String>() ?? const [],
      );

  /// `reminders.reminder`.
  final String id;
  final String title;

  /// Platform → first OS major version, e.g. `{iOS: 27, macOS: 27}`.
  final Map<String, num> availability;
  final List<SchemaMember> properties;

  /// Entity protocols Apple's schema adopts: `file` (`FileEntity`, with
  /// file-based ids), `unique` (`UniqueAppEntity`, one instance) or
  /// `syncable` (`SyncableEntity`: Apple's own items of this schema keep
  /// stable ids across devices).
  final List<String> protocols;

  /// A `files.file`-like schema whose ids are `FileEntityIdentifier`s.
  bool get isFile => protocols.contains('file');

  /// Apple's own entities of this schema are `SyncableEntity`.
  bool get isSyncable => protocols.contains('syncable');

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
        if (protocols.isNotEmpty) 'protocols': protocols,
      };
}

/// A value that is one of several types, such as a calendar event's location
/// (a place or an address).
class UnionSchema {
  const UnionSchema({required this.id, required this.title, required this.cases, this.availability = const {}});

  factory UnionSchema.fromJson(String id, Map<String, Object?> json) => UnionSchema(
        id: id,
        title: json['title'] as String? ?? id,
        availability: (json['availability'] as Map?)?.cast<String, num>() ?? const {},
        cases: [
          for (final c in json['cases'] as List)
            (name: (c as Map)['name'] as String, type: SchemaType.fromJson((c['type'] as Map).cast())),
        ],
      );

  /// `calendar.eventLocation`.
  final String id;
  final String title;
  final Map<String, num> availability;
  final List<({String name, SchemaType type})> cases;

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  Map<String, Object?> toJson() => {
        'title': title,
        if (availability.isNotEmpty) 'availability': availability,
        'cases': [for (final c in cases) {'name': c.name, 'type': c.type.toJson()}],
      };
}

class EnumSchema {
  const EnumSchema({required this.id, required this.title, required this.cases, this.availability = const {}});

  factory EnumSchema.fromJson(String id, Map<String, Object?> json) => EnumSchema(
        id: id,
        title: json['title'] as String? ?? id,
        cases: (json['cases'] as List).cast<String>(),
        availability: (json['availability'] as Map?)?.cast<String, num>() ?? const {},
      );

  final String id;
  final String title;
  final List<String> cases;
  final Map<String, num> availability;

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  Map<String, Object?> toJson() => {
        'title': title,
        if (availability.isNotEmpty) 'availability': availability,
        'cases': cases,
      };
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

  /// A [IntentKind.call] for this intent runs Dart live (on iOS, from the
  /// foreground) rather than queueing the call: when it opens the app, starts
  /// audio, or must return a value.
  bool get isLive => opensApp || result != null || recordsAudio || protocols.contains('audioRecording');

  String get domain => id.split('.').first;
  String get name => id.split('.').last;

  /// Changes something the user could want undone: not an open intent
  /// (`OpenIntent`), which only shows an item.
  bool get canUndo => !protocols.contains('open');

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
///
/// [call] is every other intent: it calls a handler method named after the
/// intent with the parameters, in Dart. See [IntentSchema.isLive].
enum IntentKind { create, update, append, delete, record, call }

/// One domain's schemas (`reminders`, `notes`, …), plus where they came from.
class DomainCatalog {
  const DomainCatalog({
    required this.domain,
    required this.hash,
    required this.xcode,
    required this.entities,
    required this.enums,
    required this.intents,
    this.unions = const {},
    this.skipped = const {},
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
      unions: {
        for (final MapEntry(:key, :value) in ((json['unions'] as Map?) ?? const {}).cast<String, Object?>().entries)
          '$domain.$key': UnionSchema.fromJson('$domain.$key', (value as Map).cast()),
      },
      skipped: ((json['skipped'] as Map?) ?? const {}).cast<String, String>(),
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
  final Map<String, UnionSchema> unions;

  /// Schemas in Apple's catalog for this domain that apps can't adopt, with
  /// why: no public Swift definition in the SDK, or deprecated.
  final Map<String, String> skipped;

  /// The entity whose annotation turns [intent] on: the entity it targets,
  /// deletes or returns, else the first entity of this domain it takes. Null
  /// for domain-level intents (`camera.startCapture`, `system.open`), which
  /// go on the domain's `…Intents` annotation.
  EntitySchema? ownerOf(IntentSchema intent) {
    SchemaType? ref(SchemaType? t) => t != null && t.element.kind == 'entity' && t.element.ref != null ? t.element : null;
    final candidates = [
      ref(intent.parameter('target')?.type),
      ref(intent.parameter('entities')?.type),
      ref(intent.result),
      for (final p in intent.parameters) ref(p.type),
    ];
    for (final t in candidates) {
      if (t == null) continue;
      if (entities[t.ref] case final owner?) return owner;
    }
    // Else the entity it's named after: `createAudioEntry` → `journal.entry`.
    for (final e in entities.values) {
      if (intent.name.endsWith(pascal(e.name))) return e;
    }
    return null;
  }

  /// The intents [entity]'s annotation turns on, with how each is handled.
  ///
  /// Through the inbox, as field changes (parameters that aren't mapped
  /// members, such as a reminder's images, are dropped):
  /// * creates are named `create…`, return the entity, take no target and
  ///   don't open the app;
  /// * updates are named `update…` (or `append…`, which add text), take the
  ///   entity as `target` and don't open the app;
  /// * deletes take a list of the entities and adopt the delete protocol.
  ///
  /// Records start an audio recording of a new item, take no parameters and
  /// are named after the entity (`createAudioEntry` for `journal.entry`).
  /// Every other intent [ownerOf] gives to [entity] is a [IntentKind.call].
  List<(IntentSchema, IntentKind)> intentsFor(EntitySchema entity) {
    bool isEntity(SchemaType? t) => t?.base.kind == 'entity' && t!.base.ref == entity.id;
    IntentKind? kind(IntentSchema intent) {
      if (ownerOf(intent)?.id != entity.id) return null;
      final name = intent.name;
      if (intent.recordsAudio && intent.parameters.isEmpty && intent.result == null && name.endsWith(pascal(entity.name))) {
        return IntentKind.record;
      }
      if (!intent.opensApp) {
        if (intent.parameter('target') case final target? when isEntity(target.type)) {
          if (name.startsWith('append')) return IntentKind.append;
          if (name.startsWith('update') && (intent.result == null || isEntity(intent.result))) return IntentKind.update;
        }
        if (intent.parameter('entities') case final list?
            when list.type.kind == 'array' &&
                isEntity(list.type.of) &&
                intent.parameters.length == 1 &&
                intent.protocols.contains('delete')) {
          return IntentKind.delete;
        }
        if (name.startsWith('create') &&
            isEntity(intent.result) &&
            intent.result!.kind == 'entity' &&
            intent.parameter('target') == null) {
          return IntentKind.create;
        }
      }
      return IntentKind.call;
    }

    return [
      for (final intent in intents.values)
        if (kind(intent) case final k?) (intent, k),
    ];
  }

  /// Intents no entity owns, for the domain's `…Intents` annotation.
  List<IntentSchema> get domainIntents => [
        for (final intent in intents.values)
          if (ownerOf(intent) == null) intent,
      ];

  /// Whether a fixed instance of [entity] can be written as a const in Dart:
  /// its properties are strings, enums, or other such entities.
  bool isFixable(EntitySchema entity, [Set<String> seen = const {}]) {
    if (seen.contains(entity.id)) return true;
    // Syncable containers are plain entities with string ids.
    if (entity.isFile || entity.protocols.contains('unique')) return false;
    return entity.properties.every((p) {
      final t = p.type.base;
      if (t.kind == 'entity') {
        if (t.ref == entity.id) return p.type.isOptional;
        final target = entities[t.ref];
        return target != null && isFixable(target, {...seen, entity.id});
      }
      if (t.kind == 'string' || t.kind == 'enum' || t.kind == 'bool') return true;
      // Other optionals and lists start empty.
      return p.type.isOptional || t.isList;
    });
  }

  Map<String, Object?> toJson() => {
        'domain': domain,
        'hash': hash,
        'xcode': xcode,
        'entities': {for (final e in entities.values) e.name: e.toJson()},
        'enums': {for (final e in enums.values) e.name: e.toJson()},
        if (unions.isNotEmpty) 'unions': {for (final u in unions.values) u.name: u.toJson()},
        'intents': {for (final i in intents.values) i.name: i.toJson()},
        if (skipped.isNotEmpty) 'skipped': skipped,
      };
}

/// `createReminder` → `CreateReminder`, `reminders` → `Reminders`.
String pascal(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The handler method a [IntentKind.record] intent calls in Dart:
/// `createAudioEntry` → `startAudioEntry`.
String recordMethod(IntentSchema intent) => 'start${pascal(intent.name.replaceFirst(RegExp('^create'), ''))}';

/// `CreateReminder` → `createReminder`.
String camel(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
