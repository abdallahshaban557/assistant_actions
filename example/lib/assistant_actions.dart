@AssistantActionsApp(name: 'Assistant Actions Example', shortcutTileColor: ShortcutTileColor.orange)
library;

import 'package:assistant_actions/assistant_actions.dart';

import 'models/models.dart';
import 'store.dart';

/// Level 1, deferred: works with the app closed. Siri answers at once and
/// this runs the next time the app is open.
@AssistantAction(
  title: 'Add to Shopping List',
  description: 'Adds a recipe’s ingredients to the shopping list.',
  dialog: 'Added {recipe} to your list.',
)
Future<void> addToShoppingList(
  Recipe recipe, {
  @Param(title: 'Servings', prompt: 'For how many people?') int? servings,
}) async {
  Store.instance.shopping.add('${recipe.name} × ${servings ?? 2}');
  Store.instance.changed();
}

/// Level 1, deferred, with a confirmation: Siri asks first, and nothing is
/// queued if the user says no.
@AssistantAction(
  title: 'Remove from Shopping List',
  confirm: 'Remove {recipe} from your shopping list?',
  dialog: 'Removed {recipe}.',
)
Future<void> removeFromShoppingList(Recipe recipe) async {
  Store.instance.shopping.removeWhere((item) => item.startsWith('${recipe.name} ×'));
  Store.instance.changed();
}

/// Level 1, live, with a result card: Siri says the reply's dialog and shows
/// its card.
@AssistantAction(title: 'Show Recipe Card', runs: Runs.withFlutter)
Future<AssistantReply<void>> showRecipeCard(Recipe recipe) async {
  final onList = Store.instance.shopping.any((item) => item.startsWith('${recipe.name} ×'));
  return AssistantReply(
    dialog: '${recipe.name} takes ${recipe.minutes} minutes.',
    card: AssistantCard(
      title: recipe.name,
      subtitle: '${recipe.minutes} min',
      rows: [AssistantCardRow('On shopping list', onList ? 'Yes' : 'No')],
      systemImage: 'fork.knife',
    ),
  );
}

/// A value for Shortcuts with a result card: `AssistantReply<Recipe>`. When
/// several recipes fit the meal, Siri asks which one (iOS / macOS 26).
@AssistantAction(title: 'Pick a Recipe', runs: Runs.withFlutter, confirm: 'Pick a recipe for {meal}?')
Future<AssistantReply<Recipe>> pickRecipe({Meal meal = Meal.dinner}) async {
  final recipes = Store.instance.recipes;
  if (meal == Meal.dinner) {
    return AssistantReply.choose([for (final r in recipes) r.id], prompt: 'Which recipe?');
  }
  final quick = recipes.reduce((a, b) => a.minutes <= b.minutes ? a : b);
  return AssistantReply(
    value: quick,
    dialog: '${quick.name} for ${meal.name}.',
    card: AssistantCard(title: quick.name, subtitle: '${quick.minutes} min', systemImage: 'fork.knife'),
  );
}

/// Level 1, live: Siri speaks what this returns.
@AssistantAction(
  title: 'Count Open Tasks',
  runs: Runs.withFlutter,
  shortcut: AppShortcut(
    phrases: ['How many tasks in {app}', 'Count my {app} tasks'],
    shortTitle: 'Open Tasks',
    systemImage: 'checklist',
  ),
)
Future<String> countOpenTasks() async {
  final open = Store.instance.tasks.where((t) => !t.done).length;
  // On iOS, with the app closed, this runs on the headless engine.
  final where = AssistantActions.inBackground ? ' (answered in the background)' : '';
  return open == 1 ? 'You have 1 open task$where.' : 'You have $open open tasks$where.';
}

/// An App Shortcut with parameters: "Cook Pancakes for breakfast in …" works
/// for every published recipe and every [Meal]. Unsaid, the meal defaults
/// to dinner.
@AssistantAction(
  title: 'Plan a Meal',
  description: 'Adds a recipe to the meal plan.',
  dialog: 'Planned {recipe} for {meal}.',
  searchKeywords: ['menu', 'meal plan'],
  shortcut: AppShortcut(
    phrases: ['Cook {recipe} for {meal} in {app}', 'Plan {meal} in {app}'],
    shortTitle: 'Plan a Meal',
    systemImage: 'fork.knife',
  ),
)
Future<void> planMeal(Recipe recipe, {Meal meal = Meal.dinner}) async {
  Store.instance.plan[meal] = recipe.name;
  Store.instance.changed();
}

/// Returns values a shortcut can use in its next step: the quickest recipe
/// under a time limit, with what Siri says.
@AssistantAction(
  title: 'Quickest Recipe',
  description: 'Finds the quickest recipe, for use in a shortcut.',
  runs: Runs.withFlutter,
)
Future<ActionResult<Recipe?>> quickestRecipe({@Param(title: 'Under') Duration? under}) async {
  final recipes = [
    for (final r in Store.instance.recipes)
      if (under == null || r.minutes <= under.inMinutes) r,
  ]..sort((a, b) => a.minutes.compareTo(b.minutes));
  final quickest = recipes.firstOrNull;
  return ActionResult(quickest, dialog: quickest == null ? 'Nothing is that quick.' : '${quickest.name} it is.');
}

/// A list Shortcuts can loop over.
@AssistantAction(title: 'Shopping List', runs: Runs.withFlutter, dialog: 'Here is your list.')
Future<List<String>> shoppingList() async => [...Store.instance.shopping];

/// A schema entity as a result (`TaskItem` is a `reminders.reminder`), so the
/// action needs the OS that has the schema.
@AssistantAction(title: 'Next Task', runs: Runs.withFlutter)
Future<ActionResult<TaskItem?>> nextTask() async {
  final open = Store.instance.tasks.where((t) => !t.done && t.due != null).toList()
    ..sort((a, b) => a.due!.compareTo(b.due!));
  final next = open.firstOrNull;
  return ActionResult(next, dialog: next == null ? 'Nothing is due.' : 'Next up: ${next.title}.');
}

/// Level 1, live and long-running: reports progress to Siri as it goes and
/// stops if the user cancels (`AssistantCall.current`).
@AssistantAction(title: 'Archive Done Tasks', runs: Runs.withFlutter, longRunning: true)
Future<String> archiveDoneTasks() async {
  final call = AssistantCall.current;
  final done = Store.instance.tasks.where((t) => t.done).toList();
  var archived = 0;
  for (final task in done) {
    if (call?.isCancelled ?? false) break;
    Store.instance.tasks.remove(task);
    archived++;
    await call?.reportProgress(completed: archived, total: done.length);
  }
  Store.instance.changed();
  return archived == 1 ? 'Archived 1 task.' : 'Archived $archived tasks.';
}

/// Answered from published data in Swift, without starting Flutter: open
/// tasks, soonest first.
@AssistantAction(
  title: 'Show Open Tasks',
  description: 'Hear your open tasks, soonest first.',
  shortcut: AppShortcut(
    phrases: ["What's on my {app} list", 'Show my {app} tasks'],
    shortTitle: 'My Tasks',
    systemImage: 'list.bullet',
  ),
)
const showOpenTasks = SnapshotAnswer<TaskItem>(
  where: {'done': false},
  sortBy: 'due',
  item: '{title}[ ({due})]',
  dialog: 'You have {count} {count|task|tasks}: {items}[, and {rest} more].',
  empty: 'Your list is clear.',
);

/// The same for one of the app's own entity types.
@AssistantAction(title: 'Quick Recipes')
const quickRecipes = SnapshotAnswer<Recipe>(
  sortBy: 'minutes',
  limit: 3,
  item: '{title} ({minutes} min)',
  dialog: 'Quickest: {items}.',
  empty: 'No recipes yet.',
);

/// Ends the recording `journal.createAudioEntry` started. A Live Activity
/// intent on iOS: while the app records in the background, this runs at once,
/// without bringing the app forward, and ends the Live Activity.
@AssistantAction(
  title: 'Stop Recording',
  description: 'Stops recording the journal entry.',
  dialog: 'Stopped recording.',
  liveActivity: true,
)
Future<void> stopRecording() => Store.instance.stopRecording();

/// The app's Focus filter: in Settings → Focus, add it to, say, a Work Focus
/// and turn on "Hide tasks". Runs when that Focus turns on, and again with
/// the defaults when it turns off.
@AssistantFocusFilter(
  title: 'Assistant Actions Example',
  description: 'Choose what the app shows during this Focus.',
  summary: 'Hide tasks: {hideTasks}',
)
Future<void> applyFocus({
  @Param(title: 'Hide tasks') bool hideTasks = false,
  @Param(title: 'Note to show') String? note,
}) async {
  Store.instance
    ..hideTasks = hideTasks
    ..focusNote = note
    ..changed();
}
