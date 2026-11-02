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

```yaml
dependencies:
  assistant_actions: ^0.0.2
dev_dependencies:
  build_runner: ^2.15.0
  assistant_actions_generator: ^0.0.2
```

Then, once, from the app's root:

```bash
dart run assistant_actions:install   # generated plugin, Runner wiring, deployment targets
flutter pub get
dart run build_runner build
```

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
  Future<void> update(String id, TaskItemValues changes) async { ... }
  Future<void> delete(String id) async { ... }
}
```

Available now: `reminders` and `notes`.

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
  changes.

## macOS notes

- Sign with a development team: macOS refuses App Intents from ad-hoc-signed
  apps when running them.
- Siri on macOS doesn't voice-invoke App Shortcut phrases (Apple's limitation).
  Actions still appear in Shortcuts and Spotlight.
