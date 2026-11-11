import 'catalog.dart';
import 'interaction.dart';
import 'deployment.dart';
import 'polish.dart';
import 'schema_calls.dart';

export 'deployment.dart' show DeploymentTarget;
export 'polish.dart' show UnlockModel;

/// A Dart value type the generator can pass between Swift and Dart.
enum ValueKind {
  string,
  integer,
  decimal,
  boolean,
  dateTime,
  uri,
  duration,
  enumeration,
  entityId,
  person,
  place,
  file,
  recurrence,
  union,

  /// What Visual Intelligence saw (`AssistantSemanticContent`); intent
  /// parameters only.
  semanticContent,
}

class ValueType {
  const ValueType(this.kind, {this.nullable = false, this.enumRef, this.entityRef, this.list = false, this.appEnum});

  /// The app's Dart enum for an `openEnum` (whose cases the app defines).
  final String? appEnum;

  String get _enumDart => appEnum ?? dartEnumName(enumRef!);

  /// A list of this type: `List<AssistantFile>`.
  ValueType asList({bool nullable = false}) =>
      ValueType(kind, nullable: nullable, enumRef: enumRef, entityRef: entityRef, list: true, appEnum: appEnum);

  /// The element type of a list.
  ValueType get element => ValueType(kind, enumRef: enumRef, entityRef: entityRef, appEnum: appEnum);

  /// The schema entity an [ValueKind.entityId] names items of.
  final String? entityRef;

  /// An [ValueKind.entityId] list: `List<String>`.
  final bool list;

  final ValueKind kind;
  final bool nullable;

  /// The schema enum of an [ValueKind.enumeration], such as
  /// `camera.captureMode` (Dart `CameraCaptureMode`).
  final String? enumRef;

  String get dart => list ? 'List<${element.dart}>${nullable ? '?' : ''}' : _dart;

  String get _dart => '${switch (kind) {
        ValueKind.string => 'String',
        ValueKind.integer => 'int',
        ValueKind.decimal => 'double',
        ValueKind.boolean => 'bool',
        ValueKind.dateTime => 'DateTime',
        ValueKind.uri => 'Uri',
        ValueKind.duration => 'Duration',
        ValueKind.enumeration => _enumDart,
        ValueKind.entityId => 'String',
        ValueKind.person => 'AssistantPerson',
        ValueKind.place => 'AssistantPlace',
        ValueKind.file => 'AssistantFile',
        ValueKind.recurrence => 'AssistantRecurrence',
        ValueKind.union => 'AssistantUnion',
        ValueKind.semanticContent => 'AssistantSemanticContent',
      }}${nullable ? '?' : ''}';

  String get swift => '${switch (kind) {
        ValueKind.string => 'String',
        ValueKind.integer => 'Int',
        ValueKind.decimal => 'Double',
        ValueKind.boolean => 'Bool',
        ValueKind.dateTime => 'Date',
        ValueKind.uri => 'URL',
        ValueKind.duration => 'Duration',
        ValueKind.enumeration || ValueKind.entityId => 'String',
        // Schema members only, whose Swift types the writer takes from the schema.
        ValueKind.person ||
        ValueKind.place ||
        ValueKind.file ||
        ValueKind.recurrence ||
        ValueKind.union ||
        ValueKind.semanticContent =>
          'Any',
      }}${nullable ? '?' : ''}';

  /// `AssistantValue.<decoder>` in Dart, `AssistantValues.<decoder>` in Swift.
  String get dartDecoder => switch (kind) {
        ValueKind.string => 'string',
        ValueKind.integer => 'integer',
        ValueKind.decimal => 'decimal',
        ValueKind.boolean => 'boolean',
        ValueKind.dateTime => 'date',
        ValueKind.uri => 'uri',
        ValueKind.duration => 'duration',
        ValueKind.enumeration => 'enumeration',
        ValueKind.entityId => 'string',
        ValueKind.person => 'person',
        ValueKind.place => 'place',
        ValueKind.file => 'file',
        ValueKind.recurrence => 'recurrence',
        ValueKind.union => 'union',
        ValueKind.semanticContent => 'semanticContent',
      };

  String get swiftDecoder => switch (kind) {
        ValueKind.string => 'string',
        ValueKind.integer => 'int',
        ValueKind.decimal => 'double',
        ValueKind.boolean => 'bool',
        ValueKind.dateTime => 'date',
        ValueKind.uri => 'url',
        ValueKind.duration => 'duration',
        ValueKind.enumeration || ValueKind.entityId => 'string',
        ValueKind.person => 'person',
        ValueKind.place => 'place',
        ValueKind.file => 'file',
        ValueKind.recurrence => 'recurrence',
        ValueKind.union => 'union',
        ValueKind.semanticContent => 'semanticContent',
      };

  /// Dart expression decoding [expr] (what Swift sent), nullable.
  String decodeDart(String expr) {
    if (list) return 'AssistantValue.list($expr, (v) => ${element.decodeDart('v')})';
    return switch (kind) {
      ValueKind.enumeration => 'AssistantValue.enumeration($_enumDart.values, $expr)',
      _ => 'AssistantValue.$dartDecoder($expr)',
    };
  }

  /// Dart expression encoding [expr] for Swift.
  String encodeDart(String expr) {
    if (!list) return _encodeDart(expr);
    final each = element._encodeDart('e');
    return each == 'e' ? expr : '$expr${nullable ? '?' : ''}.map((e) => $each).toList()';
  }

  String _encodeDart(String expr) => switch (kind) {
        ValueKind.dateTime => 'AssistantValue.encodeDate($expr)',
        ValueKind.uri => nullable ? '$expr?.toString()' : '$expr.toString()',
        ValueKind.duration => 'AssistantValue.encodeDuration($expr)',
        ValueKind.enumeration => 'AssistantValue.encodeEnum($expr)',
        ValueKind.person => 'AssistantValue.encodePerson($expr)',
        ValueKind.place => 'AssistantValue.encodePlace($expr)',
        ValueKind.file => 'AssistantValue.encodeFile($expr)',
        ValueKind.recurrence => 'AssistantValue.encodeRecurrence($expr)',
        ValueKind.union => 'AssistantValue.encodeUnion($expr)',
        _ => expr,
      };
}

/// The Dart value type an intent parameter's [element] type crosses as.
ValueType valueTypeFor(SchemaType element, [Map<String, String> openEnums = const {}]) => switch (element.kind) {
      'bool' => const ValueType(ValueKind.boolean),
      'int' => const ValueType(ValueKind.integer),
      'double' => const ValueType(ValueKind.decimal),
      'date' || 'dateComponents' => const ValueType(ValueKind.dateTime),
      'url' => const ValueType(ValueKind.uri),
      'duration' => const ValueType(ValueKind.duration),
      'enum' => ValueType(ValueKind.enumeration, enumRef: element.ref),
      'openEnum' => ValueType(ValueKind.enumeration, enumRef: element.ref, appEnum: openEnums[element.ref]),
      'person' => const ValueType(ValueKind.person),
      'placeDescriptor' => const ValueType(ValueKind.place),
      'file' => const ValueType(ValueKind.file),
      'recurrenceRule' => const ValueType(ValueKind.recurrence),
      'union' => const ValueType(ValueKind.union),
      'sceneDescriptor' => const ValueType(ValueKind.semanticContent),
      _ => const ValueType(ValueKind.string),
    };

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
    required this.fields,
    this.subtitleGetter,
    this.syncable = false,
    this.url,
    this.visualSearch = false,
    this.unlock,
    this.systemImage,
    this.image,
  });

  final String className;
  final Uri library;
  final String title;

  /// `requiresUnlock:`, if set.
  final UnlockModel? unlock;

  /// `systemImage:`: an SF Symbol for every item.
  final String? systemImage;

  /// The `@EntityImage()` field (a `String` or `Uri`), published with the
  /// item but not one of [fields].
  final FieldModel? image;

  /// `@AssistantSyncable()`: a `SyncableEntity`.
  final bool syncable;
  final String idField;

  /// The deep link template (`cookbook://recipes/{id}`), if any.
  final String? url;

  /// Visual Intelligence can show these items.
  final bool visualSearch;
  final String titleGetter;
  final String? subtitleGetter;

  /// Fields of a supported type, published so snapshot answers can read them.
  final List<FieldModel> fields;

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
    this.entityList = false,
    this.prompt,
    this.swiftDefault,
    this.defaultDart,
  });

  final String name;
  final String title;
  final bool named;
  final String? prompt;

  /// The Dart default as a Swift literal for `@Parameter(default:)`, when
  /// App Intents can take it (strings, numbers, bools, enum cases): `false`,
  /// `3`, `"Work"`, `.dinner`.
  final String? swiftDefault;

  /// Set for value parameters.
  final ValueType? value;

  /// Set for entity parameters.
  final EntityModel? entity;
  final bool entityNullable;

  /// A `List` of [entity] items.
  final bool entityList;

  /// The Dart default as a Dart expression, used when Swift sends nothing.
  final String? defaultDart;

  bool get nullable => value?.nullable ?? entityNullable;

  String get swiftType => value?.swift ?? '${entity!.swiftName}${entityNullable ? '?' : ''}';
}

/// What an `@AssistantAction` returns to Shortcuts (`ReturnsValue`), beyond
/// what Siri says.
class ResultModel {
  const ResultModel({
    this.value,
    this.entity,
    this.schemaEntity,
    this.list = false,
    this.nullable = false,
    this.wrapped = false,
  });

  /// Set for values.
  final ValueType? value;

  /// Set for `@AssistantEntity` items, returned by id.
  final EntityModel? entity;

  /// Set for schema entity items, returned by id.
  final SchemaEntityModel? schemaEntity;

  /// A `List` of [entity] or [schemaEntity] items.
  final bool list;
  final bool nullable;

  /// The function returns an `ActionResult<T>`, which may carry a dialog.
  final bool wrapped;

  bool get isEntity => entity != null || schemaEntity != null;

  /// The Dart field holding an entity's id.
  String get idField => entity?.idField ?? schemaEntity!.idField;
}

/// `@AssistantEnum` on one of the app's enums: an App Enum actions take.
class AppEnumModel {
  const AppEnumModel({required this.className, required this.library, required this.title, required this.cases});

  final String className;
  final Uri library;
  final String title;
  final List<AppEnumCase> cases;

  String get swiftName => '${className}Enum';
}

class AppEnumCase {
  const AppEnumCase({required this.name, required this.title, this.synonyms = const [], this.systemImage});

  /// `@CaseTitle(systemImage:)`: an SF Symbol.
  final String? systemImage;

  /// The Dart case name, which is also the Swift raw value.
  final String name;
  final String title;
  final List<String> synonyms;
}

/// `@IntentShortcut(...)`: an App Shortcut for a schema intent the app
/// turned on.
class IntentShortcutModel {
  const IntentShortcutModel({required this.className, required this.intent, required this.shortcut, this.owner, this.openClass});

  /// The annotated class.
  final String className;
  final IntentSchema intent;
  final ShortcutModel shortcut;

  /// The adopting entity, for an entity's intent; null for a domain's.
  final SchemaEntityModel? owner;

  /// For `system.open`: the entity class it opens.
  final String? openClass;
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
    this.returnsReply = false,
    this.description,
    this.dialog,
    this.confirm,
    this.shortcut,
    this.liveActivity = false,
    this.focusFilter,
    this.result,
    this.searchKeywords = const [],
    this.isDiscoverable = true,
    this.opensApp = false,
    this.longRunning = false,
    this.unlock,
    this.summary,
    this.cardButtons = false,
  });

  final String functionName;

  /// `requiresUnlock:`, if set.
  final UnlockModel? unlock;

  /// `summary:`: the Shortcuts sentence, with `{param}` placeholders.
  final String? summary;

  /// `longRunning: true`: a `LongRunningIntent`.
  final bool longRunning;

  /// `cardButtons: true`: below a deployment target of 26 the reply's card
  /// is still interactive from 26 (`swift_writer_cards.dart`).
  final bool cardButtons;
  final Uri library;
  final String title;
  final String? description;
  final RunsModel runs;

  /// Always comes to the foreground, even with background execution.
  final bool opensApp;
  final String? dialog;

  /// The question Siri asks before running it (`confirm:`).
  final String? confirm;
  final ShortcutModel? shortcut;
  final List<ParamModel> params;

  /// The function returns an `AssistantReply` (possibly in a `Future`):
  /// a dialog and a result card.
  final bool returnsReply;
  /// `liveActivity: true`: a `LiveActivityIntent` on iOS that runs at once
  /// when Dart is running.
  final bool liveActivity;

  /// Set when the function is the app's `@AssistantFocusFilter` rather than
  /// an `@AssistantAction`: Swift writes a `SetFocusFilterIntent`, and the
  /// registry calls the function by [id] like any action.
  final FocusFilterModel? focusFilter;

  /// The function returns `String`/`String?` (possibly in a `Future`), which
  /// becomes what Siri says.
  final bool returnsString;

  /// What the function returns to Shortcuts, if anything.
  final ResultModel? result;

  final List<String> searchKeywords;
  final bool isDiscoverable;

  String get id => functionName;
  String get swiftName => '${pascal(functionName)}${focusFilter == null ? 'Action' : 'FocusFilter'}';
}

/// `@AssistantFocusFilter` options beyond an action's.
class FocusFilterModel {
  const FocusFilterModel({this.summary});

  /// What Settings shows under the title; `{param}` interpolates.
  final String? summary;
}

/// `@AssistantAction` on a `const SnapshotAnswer<T>`: answered in Swift from
/// the published snapshot of [collection], without Flutter.
class SnapshotActionModel {
  SnapshotActionModel({
    required this.name,
    required this.title,
    required this.collection,
    required this.fields,
    required this.where,
    required this.limit,
    required this.item,
    required this.dialog,
    required this.empty,
    required this.separator,
    this.titleField,
    this.sortBy,
    this.descending = false,
    this.description,
    this.shortcut,
    this.searchKeywords = const [],
    this.isDiscoverable = true,
    this.unlock,
  });

  final String name;

  /// `requiresUnlock:`, if set.
  final UnlockModel? unlock;
  final String title;
  final String? description;
  final ShortcutModel? shortcut;
  final List<String> searchKeywords;
  final bool isDiscoverable;

  /// The entity's collection (its class name).
  final String collection;

  /// The fields the snapshot has for each item.
  final List<FieldModel> fields;

  /// The field holding the title, for items Siri created that Dart hasn't
  /// published yet.
  final String? titleField;

  /// Field name → a Swift literal it must equal.
  final Map<String, String> where;
  final String? sortBy;
  final bool descending;
  final int limit;
  final String item;
  final String dialog;
  final String empty;
  final String separator;

  String get id => name;
  String get swiftName => '${pascal(name)}Action';
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
    this.interactions = Interactions.none,
    this.syncableOverride,
    this.undoable = false,
    this.longRunning = false,
    this.queries = const [],
    this.url,
    this.visualSearch = false,
    this.unlock,
    this.systemImage,
    this.image,
    this.summaries = const {},
  });

  final String className;
  final Uri library;
  final DomainCatalog catalog;

  /// `requiresUnlock:`, if set.
  final UnlockModel? unlock;

  /// `systemImage:`: an SF Symbol for every item.
  final String? systemImage;

  /// The `@EntityImage()` field, published with the item.
  final FieldModel? image;

  /// Intent name → its Shortcuts sentence (`summaries:`).
  final Map<String, String> summaries;

  /// `@AssistantSyncable(…)`, if the class has one.
  final bool? syncableOverride;

  /// `@AssistantUndoable()`: its intents are `UndoableIntent`s.
  final bool undoable;

  /// `@AssistantLongRunning()`: its live intents are `LongRunningIntent`s.
  final bool longRunning;

  /// A `SyncableEntity`: like Apple's own items of the schema, unless the
  /// class says otherwise.
  bool get syncable => syncableOverride ?? schema.isSyncable;

  /// A `FileEntity` (`files.file`), whose Swift ids are `FileEntityIdentifier`s.
  bool get isFile => schema.isFile;
  /// The importing queries the annotation turned on
  /// (`maps.placeIntentValueQuery`). Exporting ones are always on.
  final List<QuerySchema> queries;

  /// The deep link template (`mira://tasks/{id}`), if any.
  final String? url;

  /// Visual Intelligence can show these items.
  final bool visualSearch;
  final EntitySchema schema;

  /// Dialogs, confirmations and replies from the annotation.
  final Interactions interactions;
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

  /// Its domain's own open intent is on (`books.openBook`), which takes the
  /// place of `system.open`: Apple allows one open intent per target.
  bool get hasOwnOpen => intents.any((e) =>
      e.$2 == IntentKind.call && e.$1.protocols.contains('open') && e.$1.parameter('target')?.type.base.ref == schema.id);

  Iterable<IntentKind> get kinds => {for (final (_, k) in intents) k == IntentKind.append ? IntentKind.update : k};

  /// The handler's methods: [kinds], plus, for an [undoable] class, what
  /// undoes them (a create is undone by a delete, a delete by a create).
  Iterable<IntentKind> get handlerKinds => {
        ...kinds,
        if (undoable && kinds.contains(IntentKind.create)) IntentKind.delete,
        if (undoable && kinds.contains(IntentKind.delete)) IntentKind.create,
      };
}

/// The action id Swift uses to call importing query [q]'s handler method:
/// `MapsPlaceItem.placeIntentValueQuery`.
String queryActionId(SchemaEntityModel s, QuerySchema q) => '${s.collection}.${q.name}';

/// The action id of the registry's `visualSearch` callback.
const visualSearchActionId = 'visualIntelligence.search';

/// The action id Swift uses to call [intent]'s handler method live, such as
/// `JournalItem.startAudioEntry`.
String recordActionId(SchemaEntityModel s, IntentSchema intent) => '${s.collection}.${recordMethod(intent)}';

/// The action id of a [IntentKind.call]: `<collection>.<intent>` for an
/// entity's intent, the schema id (`camera.startCapture`) for a domain's.
String callActionId(SchemaEntityModel? owner, IntentSchema intent) =>
    owner == null ? intent.id : '${owner.collection}.${intent.name}';

/// `@CameraIntents(...)` on one of the app's classes: the domain's intents
/// that belong to no entity, handled by `CameraAssistantHandler`.
class SchemaDomainModel {
  SchemaDomainModel({
    required this.className,
    required this.catalog,
    required this.intents,
    this.interactions = Interactions.none,
    this.undoable = false,
    this.longRunning = false,
    this.unlock,
    this.summaries = const {},
  });

  final String className;

  /// `requiresUnlock:`, if set.
  final UnlockModel? unlock;

  /// Intent name → its Shortcuts sentence (`summaries:`).
  final Map<String, String> summaries;

  /// Dialogs, confirmations and replies from the annotation.
  final Interactions interactions;
  /// `@AssistantUndoable()`: its intents are `UndoableIntent`s.
  final bool undoable;

  /// `@AssistantLongRunning()`: its live intents are `LongRunningIntent`s.
  final bool longRunning;
  final DomainCatalog catalog;
  final List<IntentSchema> intents;

  String get domain => catalog.domain;

  /// `CameraAssistantHandler`.
  String get handler => '${pascal(domain)}AssistantHandler';

  /// The registry parameter: `camera`.
  String get parameter => camel(pascal(domain));

  bool get opensEntities => intents.any((i) => i.id == 'system.open');
}

/// One of the app's Dart enums giving the cases of a schema enum whose cases
/// the app defines: `@CameraCaptureMode() enum CaptureMode { photo, video }`.
class OpenEnumModel {
  const OpenEnumModel({required this.schema, required this.className, required this.library, required this.cases});

  final String schema;
  final String className;
  final Uri library;

  /// Dart value names (`this$` for `this`).
  final List<String> cases;

  /// The schema case names.
  List<String> get schemaCases => [for (final c in cases) c.endsWith(r'$') ? c.substring(0, c.length - 1) : c];
}

/// Everything the builder read from the app.
class AppModel {
  AppModel({
    required this.appName,
    required this.actions,
    required this.entities,
    required this.schemaEntities,
    this.snapshotActions = const [],
    this.schemaDomains = const [],
    this.catalogs = const {},
    this.openEnums = const {},
    this.appEnums = const {},
    this.intentShortcuts = const [],
    this.shortcutTileColor,
    this.background,
    this.deployment = DeploymentTarget.minimum,
    this.unlock = UnlockModel.notRequired,
  });

  /// `@AssistantActionsApp(requiresUnlock:)`: the default for every intent.
  final UnlockModel unlock;

  /// The `@AssistantBackground()` registry function, when the app lets Siri
  /// run Dart on a headless engine (iOS).
  final BackgroundModel? background;

  /// The app's `@AssistantEnum` enums, by class name.
  final Map<String, AppEnumModel> appEnums;

  /// App Shortcuts for schema intents.
  final List<IntentShortcutModel> intentShortcuts;

  /// A `ShortcutTileColor` case name.
  final String? shortcutTileColor;

  /// The OS versions the generated Swift is compiled for.
  final DeploymentTarget deployment;

  /// The app's enums for schema enums whose cases it defines, by schema id.
  final Map<String, OpenEnumModel> openEnums;

  /// Schema id → the app's Dart enum name.
  Map<String, String> get openEnumNames => {for (final e in openEnums.values) e.schema: e.className};

  final String appName;
  final List<ActionModel> actions;
  final List<SnapshotActionModel> snapshotActions;
  final List<EntityModel> entities;
  final List<SchemaEntityModel> schemaEntities;
  final List<SchemaDomainModel> schemaDomains;

  /// Every loaded schema domain, including those only referenced by adopted
  /// schemas (`files.file` from `presentation`). Writers also look in the
  /// adopted schemas' own catalogs.
  final Map<String, DomainCatalog> catalogs;

  /// `system.open` is turned on: each entity gets an open intent.
  bool get opensEntities => schemaDomains.any((d) => d.opensEntities);

  /// Visual Intelligence can show items of these collections (plain
  /// entities, then schema entities), as (class name, Swift type).
  List<(String, String)> get visualSearchTypes => [
        for (final e in entities)
          if (e.visualSearch) (e.className, e.swiftName),
        for (final s in schemaEntities)
          if (s.visualSearch) (s.className, s.swiftName),
      ];

  /// Whether `system.open` on the entity named [className] opens its deep
  /// link rather than calling the handler.
  bool opensUrl(String className) =>
      entities.any((e) => e.className == className && e.url != null) ||
      schemaEntities.any((s) => s.className == className && s.url != null);

  Iterable<Uri> get libraries => {
        for (final a in actions) a.library,
        for (final e in entities) e.library,
        for (final s in schemaEntities) s.library,
        if (background case final b?) b.library,
      };
}

/// `@AssistantBackground()` on a top-level function returning the registry.
class BackgroundModel {
  const BackgroundModel({
    required this.functionName,
    required this.library,
    required this.entrypointLibrary,
    this.applyQueued = true,
  });

  /// The app's registry function and its library.
  final String functionName;
  final Uri library;

  /// `package:<app>/assistant_actions.g.dart`, where the generated
  /// [entrypoint] is.
  final Uri entrypointLibrary;

  /// Queued intents also start the headless engine, to apply at once.
  final bool applyQueued;

  /// The `@pragma('vm:entry-point')` function the headless engine runs.
  static const entrypoint = 'assistantActionsBackgroundMain';
}
