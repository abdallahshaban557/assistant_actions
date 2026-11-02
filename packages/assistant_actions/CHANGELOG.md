## 0.0.9

* `@AssistantActionsApp(spotlight: false)` turns off Spotlight indexing: no
  `IndexedEntity` conformances, no indexing on publish. Entities are then
  reached through their queries only, and Siri doesn't treat them as
  Spotlight-backed. Indexing stays on by default. Already-indexed items aren't
  removed when it's turned off.

## 0.0.8

* `AssistantPredicate` and `AssistantComparison`: Siri's entity property
  comparisons ("open reminders", "reminders due today", "notes containing
  milk"), evaluated in Swift over the published snapshot plus Siri's pending
  changes, with sorting and limits. Text compares ignoring case and accents; a
  date naming a whole day covers all of it, so "due today" matches any time
  today, "before Friday" means before Friday starts and "after Friday" after
  it ends.
* `DateComponents` is `Comparable` (by the date it names), which App Intents'
  ordering comparators need for schema dates such as a reminder's due date.
* Needs assistant_actions_generator 0.0.7.

## 0.0.7

* `AssistantMatch`: forgiving search for generated entity queries. Searches
  are split into words; filler words and words naming the entity type, schema
  or app ("tasks", "reminders", "Mira") are ignored, and a search with nothing
  else left lists everything. Remaining words match case- and
  accent-insensitively in the title or any text field (so items Siri just
  created match too); if no item has all of them, items with any are
  returned. Fixes "do I have any tasks in <app>" finding nothing. Needs
  assistant_actions_generator 0.0.6.

## 0.0.6

* Spotlight indexing: published entities are indexed with Core Spotlight
  (`indexAppEntities`, iOS 18+ / macOS 15+) whenever Dart publishes a
  collection or Siri creates, updates or deletes an item, and removed ones are
  deleted. Siri's planner finds "my reminders in App" through Spotlight, not
  only through entity queries. No app code is needed: the runtime finds the
  generated indexer by name. Needs assistant_actions_generator 0.0.5.

## 0.0.5

* `SnapshotAnswer<T>`: put `@AssistantAction` on a `const SnapshotAnswer<T>`
  and Siri answers from the items of `T` last published (plus changes Siri
  queued since), in Swift, without starting Flutter. Filter with `where`, order
  with `sortBy`, and format with `item` / `dialog` templates. Needs
  assistant_actions_generator 0.0.3.
* Schema updates can now clear optional fields: the generated `…Values` classes
  have `cleared` and a `<field>Cleared` getter per nullable field (for example
  `TaskItemValues.dueCleared` when Siri removes a due date).
* `AssistantHost` is exported, so tests can pass a fake to
  `AssistantActions.start(registry, host: ...)`.

## 0.0.4

* README: install with `flutter pub add` instead of pinned versions, which
  listed an `assistant_actions_generator` version that doesn't exist.

## 0.0.3

* Dart and Swift now talk over FFI (Pigeon native interop) instead of a
  platform channel. No API changes. Apps pick up `ffi` and `objective_c` as
  dependencies.

## 0.0.2

* Add repository and issue tracker links.

## 0.0.1

* First preview: iOS 17+ / macOS 14+.
* Actions (`@AssistantAction`), entities (`@AssistantEntity`) and App Schema
  adoption for `reminders.*` and `notes.*` with typed annotations.
* Deferred actions and schema changes work without Flutter running, through a
  UserDefaults inbox that Dart applies on start and resume.
