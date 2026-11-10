## 0.0.9

* Generates every shape in Apple's schema catalog, not only create, update
  and delete:
  * **Calls**: any other intent calls a handler method named after it, with
    its parameters as Dart values (enums, `Duration`, entity ids, lists).
    Intents that open the app, record audio or return an item run live (from
    the foreground on iOS; `supportedModes = .foreground` from iOS 26).
    Others are queued in the inbox, like `Runs.deferred`. Results are item
    ids that Swift looks up.
  * **Domain intents** (`camera.*`, `system.searchInApp`,
    `assistant.activate`) get a `<Domain>AssistantHandler` and a registry
    parameter.
  * **`system.open`** generates an open intent per adopted entity, unless the
    entity's own domain has one (Apple allows one per target).
  * **Unions** become `@UnionValue` enums. Person, file, place, recurrence,
    link and scene members get their Swift types (`IntentPerson`,
    `IntentFile`, …). These aren't passed to Dart yet; the docs list them.
  * **Unique entities** (`maps.navigationSession`) get a
    `UniqueAppEntityQuery`.
  * **Entity references**: a member that is another adopted entity maps to its
    id. Swift resolves it from the snapshot, one level deep.
  * Clear build errors for what isn't supported: file entities (`files.file`),
    union results, results of entities the app doesn't adopt, and app-defined
    enum cases the app didn't give.
* Availability: enums use their own catalog availability, a platform missing
  from the catalog is unavailable (`assistant.activate` is iOS 26.2 only),
  and `valueState` (clearing a field) raises update intents to iOS 18.2 /
  macOS 15.2.
* Create/update/delete are decided by the intent's verb and shape, so
  `clock.cancelTimer` and `photos.addAssetsToAlbum` become calls rather than
  deletes or updates.
* `tool/export_catalog.dart` exports every public domain by default and skips
  private or deprecated schemas, including ones that use a private schema.
* `tool/validate_schemas.dart` adopts every schema in a throwaway app and
  runs the builder, `flutter analyze` and Apple's
  `appintentsmetadataprocessor` for macOS and the iOS simulator.
* Needs assistant_actions 0.0.11.

## 0.0.8

* Supports Apple's `journal` schemas (assistant_actions 0.0.10): create,
  update and delete for `journal.entry`, with Spotlight indexing (title, text
  content, creation date) and property queries on the mapped members.
* Record intents: a schema intent that adopts `AudioRecordingIntent`, takes no
  parameters and is named after the entity (`journal.createAudioEntry`) is an
  opt-in flag on the entity annotation. It generates an intent that brings the
  app forward on iOS (`requestToContinueInForeground`) or activates it on
  macOS, then calls the handler's new `startAudioEntry()` live over the FFI
  bridge.
* Availability follows the Swift types a schema uses, not only Apple's
  catalog: `PlaceDescriptor` (journal entry `location`) needs iOS / macOS 26,
  so journal types are generated for 26 though the schema dates from 18.
* `export_catalog.dart` exports each intent's system protocols and `_openApp`.

## 0.0.7

* Generated entity queries are also `EntityPropertyQuery`, modelled on Apple's
  Notes, so Siri can filter and sort entities:
  * schema entities, for mapped members: bools take equal; dates and date
    components take `==`, `!=`, `<`, `<=`, `>`, `>=` and between; strings and
    attributed strings take contains. They sort by the title member and dates.
    Queryable members get `@Property(title:)` from the catalog, which Apple's
    metadata needs.
  * `@AssistantEntity` types: the title takes contains, and published bool,
    number, date and string fields become properties with the same
    comparators. They sort by title, numbers and dates.
* Needs assistant_actions 0.0.8 or later.

## 0.0.6

* Generated entity queries also conform to `EnumerableEntityQuery`
  (`allEntities()`: everything published plus Siri's pending changes), and
  `entities(matching:)` uses the runtime's forgiving `AssistantMatch` with the
  type's own words (class, schema and app names) ignored.
* Needs assistant_actions 0.0.7 or later.

## 0.0.5

* Generated entities conform to `IndexedEntity` (iOS 18+ / macOS 15+). Schema
  entities fill Spotlight attributes from the catalog's indexing keys (title,
  display name, text content, due, completion, creation and modification
  dates); `@AssistantEntity` types use their title and subtitle.
* Generates `AssistantActionsAppSpotlight`, which assistant_actions 0.0.6
  calls to index each collection.
* Needs assistant_actions 0.0.6 or later.

## 0.0.4

* Generated Swift compiles without warnings:
  * `valueState` switches handle `@unknown default` (treated as unchanged),
    which Swift 6 mode would otherwise reject;
  * update intents with no clearable field declare `cleared` as a constant.

## 0.0.3

* Generates snapshot-answer actions (`@AssistantAction` on a
  `const SnapshotAnswer<T>`) and checks their fields and value types at build
  time.
* Update intents read `$param.valueState`, so Siri clearing an optional field
  arrives as cleared, not unchanged; `…Values` classes get `cleared` and
  `<field>Cleared`.
* `@AssistantEntity` classes publish their String, int, double, bool,
  DateTime and Uri fields, so snapshot answers can use them.
* Needs assistant_actions 0.0.5 or later, and says so if it's older.
* README: install with `flutter pub add`.

## 0.0.2

* Add repository and issue tracker links.

## 0.0.1

* First preview: iOS 17+ / macOS 14+.
* Actions (`@AssistantAction`), entities (`@AssistantEntity`) and App Schema
  adoption for `reminders.*` and `notes.*` with typed annotations.
* Deferred actions and schema changes work without Flutter running, through a
  UserDefaults inbox that Dart applies on start and resume.
