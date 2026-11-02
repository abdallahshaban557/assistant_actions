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
