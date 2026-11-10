## 0.0.18

* `files.file` is supported: a file entity's `@EntityId()` is the file's path
  (or a `file://` URL); Swift gives Siri a `FileEntityIdentifier` for it
  (`AssistantFileIDs`) and finds published items from Siri's identifiers.
* `@AssistantSyncable([bool])`: `SyncableEntity` (iOS / macOS 27). The catalog
  marks the schemas Apple's own apps make syncable (`notes.note`,
  `reminders.list`, `calendar.event`, …), which are syncable by default.
* `@AssistantUndoable()`: `UndoableIntent` (26). Swift's `AssistantUndo` queues
  the inverse of creates, updates and deletes; other intents call `undo…`
  handler methods.
* `AssistantCall.current`: live calls report progress
  (`reportProgress`) and see cancellation (`isCancelled`, `whenCancelled`).
  `@AssistantAction(longRunning:)` and `@AssistantLongRunning()` make them
  `LongRunningIntent`s (27). Swift `AssistantLiveCall` and `callDart`.
* `install` gives the generated plugin the Runner's deployment targets, so
  the generated Swift can drop what they deprecate.
* `AssistantInbox.create` takes an optional `id`.
* Needs assistant_actions_generator 0.0.15.

## 0.0.17

* `@AssistantBackground()`: on iOS, Siri runs the app's Dart without opening
  the app. Mark the top-level function that builds the registry; when an
  intent needs Dart and the app has no Flutter engine, the runtime starts a
  headless `FlutterEngine` at the generated entrypoint, registers the app's
  plugins on it (the Runner's `GeneratedPluginRegistrant`, found by name, or
  `AssistantBackground.registerPlugins`), and answers there. No Runner changes
  are needed. The headless engine stops `AssistantBackground.shared.keepAlive`
  seconds (30) after its last use, and as soon as it's idle once the app's own
  engine starts; Dart on it claims it over a host call, so it stands down if
  the app's engine started first.
* With it, queued intents (`Runs.deferred`, schema creates, updates, deletes
  and queued calls) are applied right away on the headless engine before Siri
  answers, unless `@AssistantBackground(applyQueued: false)`.
* `AssistantActions.inBackground` and `AssistantActions.startInBackground`
  (called by generated code). Swift `AssistantBackground` (`prepare`,
  `applyInbox`, `keepAlive`, `registerPlugins`).
* `@AssistantAction(opensApp: true)`: a `Runs.withFlutter` action that always
  comes to the foreground (and activates the app on macOS).
* Needs assistant_actions_generator 0.0.14.

## 0.0.16

* `@AssistantEnum` and `@CaseTitle`: the app's enums as App Enums, with case
  titles and synonyms.
* Action parameters can be enums (the app's or schema enums such as
  `ClockTimerState`), lists, `Duration`, `AssistantPerson`, `AssistantPlace`
  and `AssistantFile`. Dart defaults become App Intents defaults.
* `Runs.withFlutter` actions can return values to Shortcuts (`ReturnsValue`):
  values, `@AssistantEntity` or schema entity items (by id), and lists. Return
  the value, an `ActionResult<T>` (with a dialog), or an `AssistantReply<T>`
  (with a dialog and a card; `choose` asks which item). Live Activity actions
  can't return values.
* `@AssistantAction(searchKeywords:, isDiscoverable:)`.
* App Shortcut phrases can name entity and enum parameters (`{recipe}`). The
  runtime refreshes them after `AssistantActions.publish` through
  `updateAppShortcutParameters()` (`AssistantShortcutParameters` finds the
  generated `AssistantActionsAppShortcuts` by name).
* `@IntentShortcut('domain.intent', ...)` makes App Schema intents App
  Shortcuts. `@AssistantActionsApp(shortcutTileColor:)` and
  `ShortcutTileColor`.
* `dart run assistant_actions:install` raises the Runner targets to iOS 17.4
  / macOS 14.4, which App Shortcuts need for `if #available` (never lowering
  one). Rerun it in apps installed earlier.
* `AssistantValue.encodeResult`, `AssistantReply.encodeValue`; Swift
  `AssistantValues.result`, `AssistantValues.measurement` and
  `encode(Measurement<UnitDuration>?)`.
* The README documents localizing titles and phrases with String Catalogs.
* Needs assistant_actions_generator 0.0.13.

## 0.0.15

* Focus filters: `@AssistantFocusFilter` on a top-level function makes it
  the app's Focus filter (`SetFocusFilterIntent`). It runs live when Dart is
  running and is queued otherwise.
* Live Activities (iOS): `AssistantLiveActivity.start / update / end /
  running / areEnabled`, with `AssistantActivityContent` and the runtime's
  JSON-backed `AssistantActivityAttributes`, over `AssistantHostCalls`.
* `dart run assistant_actions:install --widgets` adds an `AssistantWidgets`
  widget extension with a generic Live Activity view: the files, the Xcode
  target embedded in Runner, and `NSSupportsLiveActivities`.
* `@AssistantAction(liveActivity: true)` makes the intent a
  `LiveActivityIntent` on iOS, which runs at once when Dart is already
  running.
* The README documents what an app adds for Controls and widget
  configuration, which live in the widget extension, and for the Action
  button.

## 0.0.14

* Siri can confirm, speak results and show result cards.
  * `@AssistantAction(confirm: 'Remove {recipe}?')` asks before anything runs
    or is queued.
  * Schema annotations take `dialogs` (spoken results, such as
    `{'createReminder': 'Added {title}.'}`), `confirm` and `replies`. Delete
    intents confirm by default; turn that off with `confirmDeletes: false`.
  * `AssistantReply` (a dialog, an `AssistantCard`, and `choose` for picking
    among several items on iOS / macOS 26) for `Runs.withFlutter` actions and
    for live schema intents listed in `replies`.
  * New runtime Swift: `AssistantCardView` (SwiftUI), `AssistantDialog`,
    `assistantConfirm` and `assistantChoose`.
* Schema libraries are regenerated with the new annotation options.
* Needs assistant_actions_generator 0.0.11.

## 0.0.13

* `AssistantHostCalls`: Dart runs Swift features by name
  (`AssistantActions.callSwift`, internal to the package) over one new
  Pigeon FFI method, `invoke`, so new features don't change the FFI surface.
  Swift registers handlers with `AssistantHostCalls.register`; generated code
  adds its own through `AssistantActionsAppHostCalls`, found by name.
* The `AssistantHost` test interface is unchanged; hosts that also run
  Swift calls implement `AssistantHostCalls`.

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
