# assistant_actions

Siri, Shortcuts, Spotlight and Apple Intelligence for Flutter apps on **iOS and
macOS**. Declare actions and entities in Dart, adopt Apple's **App Schemas** with
typed annotations, and let
[`assistant_actions_generator`](https://pub.dev/packages/assistant_actions_generator)
write the App Intents Swift.

> **Preview (0.0.x).** iOS 17+ and macOS 14+, Swift Package Manager only. App
> Schemas need iOS / macOS 27. Verified so far: Apple's metadata step accepts the
> generated code on both platforms, the system indexes it, and Dart ↔ Swift
> round-trips on the iOS simulator. Siri invoking actions by voice hasn't been
> tested yet.

## Install

```bash
flutter pub add assistant_actions dev:build_runner dev:assistant_actions_generator
```

Then, once, from the app's root:

```bash
dart run assistant_actions:install   # generated plugin, Runner wiring, deployment targets
                                     # add --widgets for Live Activities (iOS widget extension)
flutter pub get
dart run build_runner build
```

> **Bump the build number whenever the generated intents or entities change**
> (the `+N` in `pubspec.yaml`'s `version: 1.0.0+N`, which becomes
> `CFBundleVersion`). Siri caches an app's App Intents per build number, so an
> app rebuilt with changed actions but the same build number can keep failing
> with `ToolDiscoveryError` / "Flow tool not found in database" until the
> number changes. Clean-build after regenerating, too.

## Declare

Everything lives in `lib/assistant_actions.dart` (and the libraries it imports):

```dart
@AssistantActionsApp(name: 'Cookbook')
library;

import 'package:assistant_actions/assistant_actions.dart';

/// Works with the app closed: Siri answers at once, this runs on next launch.
@AssistantAction(title: 'Add to Shopping List', dialog: 'Added {recipe} to your list.')
Future<void> addToShoppingList(Recipe recipe, {int? servings}) async { ... }

/// Runs live; Siri speaks the result. On iOS the app comes to the foreground
/// first, unless it sets up background execution (below).
@AssistantAction(
  title: 'Count Open Tasks',
  runs: Runs.withFlutter,
  shortcut: AppShortcut(phrases: ['Count my {app} tasks'], shortTitle: 'Tasks', systemImage: 'checklist'),
)
Future<String> countOpenTasks() async => 'You have 3 open tasks.';
```

Your own types become entities Siri can search:

```dart
@AssistantEntity(title: 'Recipe')
class Recipe {
  @EntityId() final String id;
  @DisplayTitle() final String name;
  ...
}
```

### App Schemas, typed

Adopt an Apple schema and Siri understands natural requests ("remind me to call
mum tomorrow"), with no set phrases. The annotations are generated from Apple's
schema catalog, so a missing required container or a misspelled member is a
compile error:

```dart
import 'package:assistant_actions/schemas/reminders.dart';

@RemindersReminder(
  list: FixedRemindersList(id: 'tasks', name: 'Tasks'),   // required by reminders.reminder
  createReminder: true, updateReminder: true, deleteReminders: true,
)
class TaskItem {
  @EntityId() final String id;
  @RemindersReminderField.title String title;
  @RemindersReminderField.dueDate DateTime? due;
  @RemindersReminderField.isCompleted bool done;
}
```

The generator fills in every other member the schema requires and generates a
handler interface that you implement:

```dart
class TaskHandler implements TaskItemAssistantHandler {
  Future<void> create(String id, TaskItemValues values) async { ... } // keep id
  Future<void> update(String id, TaskItemValues changes) async {
    // A null field is unchanged. Siri can also clear an optional one:
    final due = changes.dueCleared ? null : changes.due ?? task.due;
  }
  Future<void> delete(String id) async { ... }
}
```

Available now: all 23 domains the SDK defines publicly, including
`reminders`, `notes`, `journal`, `calendar`, `clock`, `camera`, `mail`,
`photos`, `browser`, `books`, `presentation` and `system`. See
[doc/schemas.md](doc/schemas.md) for what each one supports and the gaps.
Names carry their domain (`RemindersReminderField`, `FixedRemindersList`), so
libraries of several domains import together; reminders and notes keep their
older names (`ReminderField`, `FixedList`, …) as aliases.

Beyond creating, updating and deleting items:

- **Other intents call a handler method** named after the intent, with its
  parameters as Dart values (`pauseTimer({required String timer})`). Entities
  arrive as ids. Intents that open the app or return an item run live; the
  rest are queued, like `Runs.deferred`, and run when the app next does. One
  that returns an item gets its id back from Dart: publish the item first.
- **Intents of no entity** (`camera.startCapture`, `system.searchInApp`) go on
  the domain's annotation, on the class implementing its handler:

  ```dart
  @CameraIntents(startCapture: true, stopCapture: true)
  class CameraHandler implements CameraAssistantHandler { ... }
  ```

  `@SystemIntents(open: true)` gives every entity an `open<Class>(id)` method
  for "open … in App", unless its own domain has an open intent.
- **Schema enums** are Dart enums (`ClockTimerState`). Some, such as
  `camera.captureMode`, leave their cases to the app: annotate your own enum,
  `@CameraCaptureMode() enum CaptureMode { photo, video }`.
- **Members that are other entities** map to ids of an entity the app also
  adopts: `@WordProcessorPageField.document String documentId;`.
- **People, places, files, recurrence rules and unions** are
  `AssistantPerson`, `AssistantPlace`, `AssistantFile`,
  `AssistantRecurrence` and `AssistantUnion`; lists are Dart lists. A file
  Siri passes (a journal entry's `mediaItems`) is copied into Application
  Support, so its `path` works even for a call queued while the app wasn't
  running. Delete the copy when you're done with it.

### Journal entries and audio recording

`journal.entry` adopts Apple's journal schema: Siri creates, updates, deletes
and finds entries ("add a journal entry about my walk", "journal entries from
last week"), the same way as reminders and notes.

```dart
import 'package:assistant_actions/schemas/journal.dart';

@JournalEntry(createEntry: true, updateEntry: true, deleteEntry: true, createAudioEntry: true)
class JournalItem {
  @EntityId() final String id;
  @JournalEntryField.title String? title;
  @JournalEntryField.message String text;
  @JournalEntryField.entryDate DateTime? date;
}
```

`createAudioEntry: true` adds Apple's `journal.createAudioEntry` ("record a
journal entry"). It takes no parameters: Siri brings the app to the
foreground (iOS only lets the microphone start there; macOS activates the app)
and calls `startAudioEntry()` on the generated `JournalItemAssistantHandler`,
live, like a `Runs.withFlutter` action. Recording is the app's job: start the
recorder there and save the entry when the user stops. Apple's schema makes
the intent an `AudioRecordingIntent`, so on iOS show a Live Activity while
recording continues in the background, or the system stops it. Start it in
`startAudioEntry` with `AssistantLiveActivity.start` (see
[Live Activities](#live-activities)) and end it when recording stops:

```dart
@override
Future<void> startAudioEntry() async {
  recorder.start();
  activity = await AssistantLiveActivity.start(
    AssistantActivityContent(title: 'Recording', systemImage: 'mic.fill', timerStart: DateTime.now()),
    kind: 'recording',
  );
}
```

`mediaItems` maps to `List<AssistantFile>` and `location` to
`AssistantPlace?`. `journal.search` is deprecated in favour of
`system.searchInApp` (`@SystemIntents(searchInApp: true)`), so it isn't
offered.
The journal schemas date from iOS 18, but `location`'s `PlaceDescriptor`
needs iOS / macOS 26, so the generated journal types are available from 26.

### Answer from published data, without starting the app

Put `@AssistantAction` on a `const SnapshotAnswer<T>` and Siri answers in
Swift from the items of `T` you last published, plus anything Siri queued since.
Flutter doesn't start, on iOS or macOS:

```dart
@AssistantAction(title: 'Show Tasks', shortcut: AppShortcut(...))
const showTasks = SnapshotAnswer<TaskItem>(
  where: {'done': false},
  sortBy: 'due',                      // items without a due date come last
  item: '{title}[ ({due})]',          // [...] is left out when {due} is empty
  dialog: 'You have {count} {count|task|tasks}: {items}[, and {rest} more].',
  empty: 'Your list is clear.',
);
```

The generator checks that every field exists and that `where` values match
the field types.

### Confirm, speak and show results

Siri can ask before acting, say what it did and show a result card, the way
Apple's own apps do.

**Confirmations** happen in Swift, before anything is queued or Dart runs; if
the user says no, nothing happens. Schema deletes (`deleteReminders`) ask
"Delete Buy milk and Call mum?" by default (`confirmDeletes: false` turns that
off). Any other intent, or a plain action, can ask its own question:

```dart
@AssistantAction(title: 'Remove from List', confirm: 'Remove {recipe}?', dialog: 'Removed {recipe}.')
Future<void> removeFromList(Recipe recipe) async { ... }

@ClockTimer(createTimer: true, pauseTimer: true, confirm: {'pauseTimer': 'Pause {timer}?'})
class Countdown { ... }
```

**Spoken results** for schema intents come from `dialogs`, by intent name:

```dart
@RemindersReminder(
  list: FixedRemindersList(id: 'tasks', name: 'Tasks'),
  createReminder: true, updateReminder: true, deleteReminders: true,
  dialogs: {
    'createReminder': 'Added {title} to your tasks.',
    'updateReminder': 'Updated {result}.',
    'deleteReminders': 'Deleted {entities}.',
  },
)
```

In `dialogs` and `confirm`, `{name}` is the intent's parameter `name`: text,
numbers, dates ("Nov 3, 2026 at 9:00 AM"), durations, enums ("three seconds"),
people, and items by their title. Lists read "A, B and C". `{result}` is the
item an intent returns. Names and types are checked at build time.

**Replies from Dart.** A `Runs.withFlutter` action can return an
`AssistantReply` instead of a `String`; so can the handler method of a live
schema intent (one that opens the app, returns an item, or records) listed in
`replies`. Siri says its `dialog` (else the `dialogs` template, else "Done.")
and shows its `card`:

```dart
@CameraIntents(startCapture: true, replies: {'startCapture'})
class CameraHandler implements CameraAssistantHandler {
  @override
  Future<AssistantReply<void>> startCapture({required CaptureMode captureMode, ...}) async =>
      AssistantReply(
        dialog: 'The camera is ready.',
        card: AssistantCard(
          title: 'Camera',
          subtitle: captureMode.name,
          rows: [AssistantCardRow('Lens', 'Back')],
          systemImage: 'camera',          // or imagePath: a local image file
        ),
      );
}
```

Listing an intent in `replies` changes its method's return type to
`AssistantReply<T>`, where `T` is what it returned before: the item's id
(`String`), ids (`List<String>`), an `AssistantUnion`, or `void`. Put the id
in `value`. The card is a generic SwiftUI view in the runtime
(`ShowsSnippetView`, iOS 17 / macOS 14 and later).

**Choosing between items.** For an intent that returns one item, return
`AssistantReply.choose(ids, prompt: 'Which tab?')` when several match: Siri
lists their titles, the user picks one (`requestChoice`, iOS / macOS 26 and
later; earlier, the first is taken), and that item is the intent's result.
Dart isn't called again with the choice, so use it where the result *is* the
answer (finding or opening an item), not to pick what to change.

Queued intents (`Runs.deferred`, inbox creates, updates and deletes, and
queued calls) run after Siri has answered, so they can confirm and use
`dialogs` but can't reply from Dart; the generator says so.

## Beyond Siri: Focus, Live Activities, controls, the Action button

### Focus filters

Put `@AssistantFocusFilter` on a top-level function and it becomes the app's
Focus filter (`SetFocusFilterIntent`). In Settings → Focus → Add Filter, the
user picks the app, sets the parameters, and the function runs when that
Focus turns on. When the Focus turns off, Apple runs the filter again with
every parameter at its default, so make the defaults mean "no Focus":

```dart
@AssistantFocusFilter(
  title: 'Journal',
  description: 'Choose what the app shows during this Focus.',
  summary: 'Hide tasks: {hideTasks}',          // under the title in Settings
)
Future<void> applyFocus({
  @Param(title: 'Hide tasks') bool hideTasks = false,
  @Param(title: 'Note to show') String? note,
}) async { ... }
```

Parameters take the same types as actions (String, int, double, bool,
DateTime, Uri, Duration, `@AssistantEntity` classes). Each must be nullable
or have a bool, int, double or String default, because the system creates
the filter from its defaults. The generator fails the build otherwise. The
system can run the filter while the app is in the background or not running
at all: if Dart is running, the function runs at once; if not, the call is
queued like a `Runs.deferred` action and runs when the app next starts or
resumes. It never brings the app forward. Works on iOS and macOS.

### Live Activities

`AssistantLiveActivity` starts, updates and ends ActivityKit Live Activities
(iOS) from Dart. Each activity carries the runtime's generic, JSON-backed
`AssistantActivityAttributes`: a title, subtitle, SF Symbol, progress, a timer,
and a `data` map for views of your own.

```dart
final activity = await AssistantLiveActivity.start(
  AssistantActivityContent(title: 'Recording', systemImage: 'mic.fill', timerStart: DateTime.now()),
  kind: 'recording',
);
await activity?.update(const AssistantActivityContent(title: 'Recording', progress: 0.5));
await activity?.end(dismissal: AssistantActivityDismissal.immediate);
```

`start` returns null on macOS, and on iOS when the user has turned Live
Activities off (`AssistantLiveActivity.areEnabled()`). iOS only starts them
while the app is in the foreground, or from an intent that allows it: an
`AudioRecordingIntent` such as `journal.createAudioEntry`, or an action with
`liveActivity: true` (see below).

A Flutter app has no widget extension, and the system needs one to draw the
activity. Add one with:

```bash
dart run assistant_actions:install --widgets
```

This step:
- writes `ios/AssistantWidgets/`: the widget bundle `AssistantWidgets.swift`
  (yours to edit; later runs leave it alone), the generic SwiftUI Live
  Activity view `AssistantLiveActivityWidget.swift` (Lock Screen and Dynamic
  Island), a copy of `AssistantActivityAttributes.swift`, an `Info.plist`, and
  an xcconfig that gives the extension Flutter's build name and number;
- adds the `AssistantWidgets` app extension target to `ios/Runner.xcodeproj`.
  It's embedded in Runner, with an "Embed Foundation Extensions" phase placed
  before Flutter's "Thin Binary" script (otherwise Xcode reports a build
  cycle). The bundle id is Runner's plus `.AssistantWidgets`, the team is
  Runner's, and the target is iOS 17. If the project isn't laid out like a
  Flutter one, nothing is changed and the step prints the Xcode steps instead;
- sets `NSSupportsLiveActivities` in `ios/Runner/Info.plist`.

Running it again refreshes the view and the attributes copy, which ActivityKit
matches with the app's copy by type name and fields. Run it after upgrading
assistant_actions. **By hand in Xcode:** for device builds, pick a team for the
`AssistantWidgets` target under Signing & Capabilities if Runner's wasn't set
when you ran the step. The simulator needs no signing.

For the journal's `createAudioEntry`, start the activity in `startAudioEntry`
and end it when recording stops. The example app does this.

### Live Activity intents

`@AssistantAction(liveActivity: true)` makes the intent a `LiveActivityIntent`
on iOS. The system runs it in the app's process, and it can start or update
Live Activities from the background. When Dart is already running, say the
app is recording in the background, the function runs at once without
bringing the app forward. When it isn't, `Runs.deferred` queues the call as
usual and `Runs.withFlutter` brings the app forward first, because iOS only
starts the Flutter engine with a scene. On macOS the option does nothing.

```dart
@AssistantAction(title: 'Stop Recording', dialog: 'Stopped recording.', liveActivity: true)
Future<void> stopRecording() => recorder.stop();
```

### Controls and widgets

Control Center controls (`ControlWidget`, iOS 18) and configurable widgets
(`WidgetConfigurationIntent`) live in the widget extension, and so must the
App Intents they run. The generated intents can't go there: they're in the
`assistant_actions_app` plugin, which links Flutter. assistant_actions
doesn't generate controls yet. Write them in Swift in `ios/AssistantWidgets/`
and add them to the bundle:

```swift
@main
struct AssistantWidgets: WidgetBundle {
  var body: some Widget {
    AssistantLiveActivityWidget()
    if #available(iOS 18.0, *) { OpenJournalControl() }
  }
}

@available(iOS 18.0, *)
struct OpenJournalControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.example.open-journal") {
      ControlWidgetButton(action: OpenJournalIntent()) { Label("Journal", systemImage: "book") }
    }
    .displayName("Open Journal")
  }
}

/// Add this file to both the Runner and AssistantWidgets targets.
@available(iOS 18.0, *)
struct OpenJournalIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Journal"
  static let openAppWhenRun = true
  func perform() async throws -> some IntentResult { .result() }
}
```

This compiles in the extension. assistant_actions hasn't checked it on a
device. The extension can't see the app's assistant_actions inbox or
snapshots, which live in the app's own UserDefaults. A control that needs app
data needs an App Group you set up yourself.

### Action button and Apple Pencil

Nothing extra to adopt. Every App Shortcut (`shortcut:` on an
`@AssistantAction`) and every action in Shortcuts can be assigned to the
Action button (Settings → Action Button → Shortcut) or to Apple Pencil Pro's
squeeze. Both run it like Siri does, so the `runs` rules apply.

### Parameters, results and App Shortcuts

Action parameters can be `String`, `int`, `double`, `bool`, `DateTime`, `Uri`,
`Duration`, `AssistantPerson`, `AssistantPlace` (iOS / macOS 26),
`AssistantFile`, an `@AssistantEntity` class, an enum (your own
`@AssistantEnum`, or a schema enum such as `ClockTimerState`), or a `List` of
one of these. Dart defaults become App Intents defaults:

```dart
@AssistantEnum(title: 'Meal')
enum Meal { breakfast, lunch, dinner, @CaseTitle('Late-night snack', synonyms: ['snack']) snack }

@AssistantAction(
  title: 'Plan a Meal',
  dialog: 'Planned {recipe} for {meal}.',
  searchKeywords: ['menu'],
  shortcut: AppShortcut(
    phrases: ['Cook {recipe} for {meal} in {app}'],   // entity and enum parameters
    shortTitle: 'Plan a Meal',
    systemImage: 'fork.knife',
  ),
)
Future<void> planMeal(Recipe recipe, {Meal meal = Meal.dinner}) async { ... }
```

Phrases with an entity parameter work for each item you publish: the runtime
calls `updateAppShortcutParameters()` after `AssistantActions.publish`. Apple
allows 10 App Shortcuts per app; the generator checks that and every phrase.
`isDiscoverable: false` hides an action from Shortcuts and Spotlight (it then
can't be an App Shortcut).

A `Runs.withFlutter` action can return a value for the next step of a shortcut
(`ReturnsValue`): any parameter type except places, an `@AssistantEntity` or
schema entity class (Siri gets the published item with that id), or a list.
Wrap it in `ActionResult` to say something too, or in `AssistantReply<T>` to
also show a result card (with `AssistantReply.choose` for one item, Siri asks
which); a bare `Future<String>` is still only what Siri says. Live Activity
actions (`liveActivity: true`) can't return values. Confirmations, dialogs and
Focus filter summaries can say every parameter type except people, places and
files.

```dart
@AssistantAction(title: 'Quickest Recipe', runs: Runs.withFlutter)
Future<ActionResult<Recipe?>> quickestRecipe({Duration? under}) async =>
    ActionResult(quickest, dialog: '${quickest.name} it is.');
```

Schema intents can be App Shortcuts too. Put `@IntentShortcut` on the class
that turns the intent on (`system.open` goes on the entity class it opens):

```dart
@CameraIntents(startCapture: true)
@IntentShortcut('camera.startCapture',
    phrases: ['Take a {captureMode} with {app}'], shortTitle: 'Camera', systemImage: 'camera')
class CameraHandler implements CameraAssistantHandler { ... }
```

Schema intents need iOS 18 / macOS 15 or later, so their shortcuts are wrapped
in `if #available`, which App Shortcuts only allow from **iOS 17.4 / macOS
14.4**. `dart run assistant_actions:install` raises the Runner targets to that
(rerun it in an app installed earlier). Set the tile color
with `@AssistantActionsApp(name: ..., shortcutTileColor: ShortcutTileColor.orange)`.

**Localizing.** Titles, descriptions and phrases go into the Swift as
localization keys (the English text), and the generator doesn't translate
them. Translate them with String Catalogs in the Runner target, Apple's usual
setup: add `AppShortcuts.xcstrings` and Xcode extracts the phrases and short
titles from `apple/AssistantShortcuts.g.swift` when it builds, with
parameters written as `${recipe}` and the app name as `${applicationName}`.
Titles and descriptions of the generated intents live in the
`assistant_actions_app` package, so add their keys to the Runner's
`Localizable.xcstrings` by hand. (Not yet verified on a device with
assistant_actions.) Spoken dialogs are plain strings: localize them in Dart
and return them from the action.

## Run

```dart
await AssistantActions.start(assistantActionsRegistry(
  findRecipe: (id) => recipes.byId(id),
  taskItem: TaskHandler(),
));
AssistantActions.publish(recipes);  // whenever they change
AssistantActions.publish(tasks);
```

### Run Dart without opening the app (iOS)

On iOS, Flutter only starts with a scene, so by default a live action
(`Runs.withFlutter`, schema intents that return an item) asks to open the app
when it isn't in the foreground. Mark one top-level function that builds your
registry `@AssistantBackground()`, and Siri runs Dart in the background
instead:

```dart
@AssistantBackground()
Future<AssistantActionsRegistry> appRegistry() async {
  await Database.open();
  return assistantActionsRegistry(taskItem: TaskHandler(), ...);
}

// main.dart
await AssistantActions.start(await appRegistry());
```

It goes in `lib/assistant_actions.dart` or a library it imports, takes no
arguments and returns the registry (or a `Future` of it). The generator writes
the entrypoint, `assistantActionsBackgroundMain` in `assistant_actions.g.dart`,
which `main.dart` must import (directly or through the function's library).
No Runner changes are needed.

- When an intent needs Dart and the app has no engine, the runtime starts a
  headless `FlutterEngine` at that entrypoint, registers the app's plugins on
  it (the Runner's `GeneratedPluginRegistrant`, or
  `AssistantBackground.registerPlugins` if you set it), waits for Dart, and
  answers there. If the app's engine is already running, it answers there,
  even with the app in the background.
- The headless engine has **its own Dart memory**: it starts from what the app
  persists, not from the running app's state. `AssistantActions.inBackground`
  tells you which engine you're on.
- It stays for `AssistantBackground.shared.keepAlive` seconds (30) after the
  last request, then shuts down. When the app's own engine starts, the
  headless one stops as soon as it's idle.
- Intents that open the app still come to the foreground: `system.open`,
  `journal.createAudioEntry` and other recording intents, schema intents that
  open the app (`camera.startCapture`), and actions with
  `@AssistantAction(opensApp: true)`.
- Queued intents (`Runs.deferred`, schema creates, updates and deletes) are
  applied right away on the headless engine too, before Siri answers. Pass
  `@AssistantBackground(applyQueued: false)` to leave them for the next launch.
- From iOS 26 the background intents declare
  `supportedModes = [.background, .foreground(.dynamic)]`; before that they
  keep `ForegroundContinuableIntent`. If Dart can't start, they continue in
  the foreground as without background execution.
- macOS starts the engine with the app and answers in place either way.

## How it works

- Generated intents live in a local plugin (`packages/assistant_actions_app`), so
  adding actions never touches `project.pbxproj`. Only the App Shortcuts file has
  to be in the Runner targets, because Apple reads shortcuts only from the app.
  The runtime finds its `AssistantActionsAppShortcuts` class by name to refresh
  phrases that name entities.
- Deferred actions and schema changes go into a UserDefaults inbox that doesn't
  need Flutter. Ids are assigned in Swift, so Siri can update or delete something
  it just created before Dart has run.
- Entity queries read the snapshot Dart publishes, overlaid with pending inbox
  changes. They also take Siri's property comparisons, like Apple's Notes:
  "open reminders", "reminders due today", "notes containing milk", evaluated
  in Swift.
- Published entities are also indexed in Spotlight (iOS 18+ / macOS 15+), and
  kept in step with Siri's changes, so Siri can find "my reminders in App".
- Dart and Swift call each other directly over FFI (Pigeon native interop,
  `pigeons/assistant_api.dart`), with no platform channels.
- With `@AssistantBackground()`, the generated `AssistantActionsAppBackground`
  class tells the runtime the entrypoint, the way the Spotlight indexer is found
  by class name. Dart on the headless engine claims it over a host call, so
  that it stands down if the app's engine started meanwhile.

## macOS notes

- Sign with a development team: macOS refuses App Intents from ad-hoc-signed
  apps when running them.
- Siri on macOS doesn't voice-invoke App Shortcut phrases (Apple's limitation).
  Actions still appear in Shortcuts and Spotlight.
