# App Schema support

Every App Schema in Xcode 27.2's catalog (27B52, hash c2d369abe24c) that the
SDK defines publicly has a typed library in `package:assistant_actions/schemas/`.
The generator was validated against all of them at once: a throwaway app that
adopts every entity it can, with every intent turned on, builds for macOS and
the iOS simulator, and Apple's `appintentsmetadataprocessor` accepts it with
no errors (`dart run tool/validate_schemas.dart` in the generator).

- **Full**: every public entity and intent can be adopted, and Dart gets every
  parameter.
- **Partial**: what's listed under gaps isn't supported yet. A dropped
  parameter still reaches the Swift intent, so the schema is valid; Dart just
  doesn't receive it.

| Domain | Support | Entities | Intents | Gaps |
|---|---|---|---|---|
| `assistant` | Full | 0/0 | 1/1 |  |
| `audio` | Full | 18/18 | 7/7 | 3 schemas not adoptable (3 not public) |
| `books` | Full | 3/3 | 7/7 | 2 schemas not adoptable (2 deprecated) |
| `browser` | Full | 5/5 | 12/12 | 4 schemas not adoptable (3 not public, 1 deprecated) |
| `calendar` | Full | 3/3 | 3/3 |  |
| `camera` | Full | 0/0 | 5/5 |  |
| `clock` | Full | 3/3 | 14/14 |  |
| `files` | Full | 1/1 | 5/5 | 1 schemas not adoptable (1 not public) |
| `journal` | Full | 1/1 | 4/4 | 1 schemas not adoptable (1 deprecated) |
| `mail` | Full | 5/5 | 12/12 |  |
| `maps` | Full | 6/6 | 6/6 | 17 schemas not adoptable (17 not public) |
| `messages` | Full | 4/4 | 5/5 | 1 schemas not adoptable (1 not public) |
| `notes` | Full | 3/3 | 3/3 |  |
| `phone` | Full | 1/1 | 0/0 | 18 schemas not adoptable (17 not public, 1 uses a private schema) |
| `photos` | Full | 3/3 | 26/26 | 15 schemas not adoptable (13 not public, 2 deprecated) |
| `presentation` | Full | 3/3 | 15/15 |  |
| `reader` | Full | 2/2 | 9/9 |  |
| `reminders` | Full | 5/5 | 5/5 |  |
| `spreadsheet` | Full | 3/3 | 14/14 |  |
| `system` | Full | 0/0 | 2/2 | 1 schemas not adoptable (1 deprecated) |
| `visualIntelligence` | Partial | 0/0 | 1/1 | `semanticContentSearch` doesn't pass `semanticContent` (sceneDescriptor) to Dart; 1 schemas not adoptable (1 not public) |
| `whiteboard` | Full | 2/2 | 7/7 |  |
| `wordProcessor` | Full | 3/3 | 9/9 |  |

## Not adoptable

These domains are in the catalog, but the SDK defines none of their schemas
publicly, so no app can adopt them: `appLaunch`, `appStore`, `contacts`,
`findMy`, `health`, `home`, `imageGeneration`, `notifications`,
`playbackControls`, `video`, `voiceMemos`, `writingTools`.

Each catalog's `skipped` section (`lib/src/catalog/<domain>.json`) lists the
schemas left out of an adoptable domain and why: no public definition,
deprecated (for example `journal.search`, replaced by `system.searchInApp`),
or using a private schema (`phone.startCall` can take a private call group).

## Newer App Intents protocols

The validation app also makes every adopted class `@AssistantUndoable()` and
`@AssistantLongRunning()`, and is built a second time for iOS 26 / macOS 26
(`--deployment=26.0`), so these are checked on every schema:

- **`FileEntity`** (`files.file`): Swift ids are `FileEntityIdentifier`s; Dart
  keeps the file's path as the `@EntityId()`.
- **`SyncableEntity`** (27): on by default for the schemas Apple's own apps
  make syncable (`audio.playlist`, `calendar.calendar`, `calendar.event`,
  `messages.message`, `notes.note`, `notes.folder`, `photos.asset`,
  `photos.album`, `photos.recognizedPerson`, `presentation.document`,
  `reminders.list`), and with
  `@AssistantSyncable()` on any other entity. Ids stay `String`s
  (`entitySyncType` 1, like Apple's Notes), so they must be stable.
  `SyncableEntityIdentifier` (separate local and stable ids, sync type 2)
  isn't used: Dart has one id per item.
- **`IndexedEntityQuery`** (27): every entity query re-indexes its items in
  Spotlight when the system asks. Queries still answer from the snapshot.
- **`UndoableIntent`** (26): with `@AssistantUndoable()`. Open intents
  (`OpenIntent`) aren't made undoable. Plain `@AssistantAction`s can't be
  undone yet (there's no Dart undo function to name).
- **`ProgressReportingIntent`** (17) and **`CancellableIntent`** (26.4) on
  every live intent, **`LongRunningIntent`** (27) with `longRunning: true` /
  `@AssistantLongRunning()`. Dart sees `AssistantCall.current`.
- **`supportedModes`** instead of the deprecated `ForegroundContinuableIntent`
  when the app's deployment target is iOS 26 / macOS 26 or later.

Not adopted:

- **`OwnershipProvidingEntity`** (27) says whether an item is shared or
  public. Nothing in an app's Dart model says so today, and guessing would
  mislead Siri, so entities don't claim ownership.
- **`@ComputedProperty` / `@DeferredProperty`** (26) compute a property from
  others, or fetch it only when asked. Snapshot entities are built from what
  Dart published, with every value already there, and Dart may not be
  running to compute one later; schema entities' members are declared by
  Apple's `@AppEntity(schema:)` macro as stored properties. Neither fits.

## Not supported yet

- **`visualIntelligence.semanticContentSearch`** doesn't pass the scene
  (`SemanticContentDescriptor`) to Dart.
- **Schema queries and facets** (`maps.placeIntentValueQuery`, the
  `…Transferable` ones) have no public macro.
- **`messages.destination`** leaves out its `conversation` case, which
  Apple's metadata processor rejects for `messages.sendMessage`.
- Open enums that are only reached through members Dart never fills get a
  placeholder `unspecified` case.

People, places, files, recurrence rules and unions cross to Dart as
`AssistantPerson`, `AssistantPlace`, `AssistantFile`, `AssistantRecurrence`
and `AssistantUnion`. Lists map to Dart lists.
