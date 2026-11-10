## 0.0.12

* People, places, files, recurrence rules and unions cross to Dart as
  `AssistantPerson`, `AssistantPlace`, `AssistantFile`, `AssistantRecurrence`
  and `AssistantUnion`, as intent parameters, results and entity fields. A
  file Siri passes is copied into Application Support
  (`assistant_actions/files/`), so its path still works for calls queued
  while the app wasn't running.
* List members map to Dart lists (`List<AssistantFile>` for a journal
  entry's `mediaItems`, `List<String>` for reminder tags).
* So every public schema entity can be adopted except `files.file`, which
  needs file-based ids (`FileEntity`).
* `messages.destination` leaves out its `conversation` case, which Apple's
  metadata processor rejects.
* Needs assistant_actions_generator 0.0.10.

## 0.0.11

* Every App Schema domain the SDK defines publicly: 23 typed libraries in
  `package:assistant_actions/schemas/` (`calendar`, `clock`, `camera`, `mail`,
  `photos`, `browser`, `books`, `presentation`, `spreadsheet`,
  `wordProcessor`, `system`, … plus `reminders`, `notes` and `journal`), from
  Xcode 27.2 (27B52, catalog c2d369abe24c). The 12 domains with no public
  schemas (`home`, `health`, `playbackControls`, `voiceMemos`, …) aren't
  exported. See `doc/schemas.md` for what each domain supports.
* Only public, non-deprecated schemas are exported. Each catalog lists the
  others under `skipped`, with why. `journal.search` is gone: Apple
  deprecated it for `system.searchInApp`.
* Schema enums are Dart enums (`ClockTimerState`). Enums whose cases the app
  defines (`camera.captureMode`) get an annotation for the app's own enum:
  `@CameraCaptureMode() enum CaptureMode { photo, video }`.
* `@<Domain>Intents(...)` (`@CameraIntents`, `@SystemIntents`) turns on the
  intents that belong to no entity.
* Names carry their domain, so several libraries import together:
  `RemindersReminderField`, `FixedRemindersList`, `JournalEntryField`. The
  reminders and notes names from before (`ReminderField`, `FixedList`,
  `NoteField`, `FixedFolder`, …) stay as aliases.
* Field members that are other entities map to `String` ids
  (`List<String>` for lists).
* Runtime values: `AssistantValue.enumeration`/`encodeEnum`, `duration`/
  `encodeDuration` and `list` in Dart; `Duration`, enum and id-list
  encoding in Swift.
* Needs assistant_actions_generator 0.0.9.

## 0.0.10

* `journal` App Schemas (`package:assistant_actions/schemas/journal.dart`):
  `@JournalEntry` adopts `journal.entry` with `EntryField.title`, `.message`
  and `.entryDate`, and the create, update and delete intents.
  `createAudioEntry: true` adopts `journal.createAudioEntry`: Siri brings the
  app forward and calls `startAudioEntry()` on the generated handler; the app
  records. `mediaItems` and `location` have no Dart mapping yet, and
  `journal.search` isn't adopted. Exported from Xcode 27.2 (27B52, catalog
  c2d369abe24c), like `reminders` and `notes`.
* The bundled catalogs record each schema intent's system protocols (such as
  `audioStarting`) and whether it opens the app.
* Journal needs assistant_actions_generator 0.0.8.

## 0.0.9

* Docs: bump the app's build number whenever the generated actions or
  entities change. Siri caches App Intents per build number, so an app
  rebuilt with the same number can keep failing with "Flow tool not found in
  database" (`ToolDiscoveryError`). `dart run assistant_actions:install` now
  says so too.

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
