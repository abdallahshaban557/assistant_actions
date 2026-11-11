@AssistantActionsApp(name: 'Assistant Actions Example')
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
  return open == 1 ? 'You have 1 open task.' : 'You have $open open tasks.';
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
