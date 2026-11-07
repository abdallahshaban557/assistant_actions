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

/// Runs live; Siri speaks the result.
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
  list: FixedList(id: 'tasks', name: 'Tasks'),   // required by reminders.reminder
  createReminder: true, updateReminder: true, deleteReminders: true,
)
class TaskItem {
  @EntityId() final String id;
  @ReminderField.title String title;
  @ReminderField.dueDate DateTime? due;
  @ReminderField.isCompleted bool done;
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

Available now: `reminders` and `notes`.

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

## Run

```dart
await AssistantActions.start(assistantActionsRegistry(
  findRecipe: (id) => recipes.byId(id),
  taskItem: TaskHandler(),
));
AssistantActions.publish(recipes);  // whenever they change
AssistantActions.publish(tasks);
```

## How it works

- Generated intents live in a local plugin (`packages/assistant_actions_app`), so
  adding actions never touches `project.pbxproj`. Only the App Shortcuts file has
  to be in the Runner targets, because Apple reads shortcuts only from the app.
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

## macOS notes

- Sign with a development team: macOS refuses App Intents from ad-hoc-signed
  apps when running them.
- Siri on macOS doesn't voice-invoke App Shortcut phrases (Apple's limitation).
  Actions still appear in Shortcuts and Spotlight.
