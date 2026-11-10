import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter/material.dart';

import 'assistant_actions.dart';
import 'assistant_actions.g.dart';
import 'models/models.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AssistantActions.start(appRegistry());
  Store.instance.changed();
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

/// Routes deep links, such as the `assistantactions://recipes/<id>` that
/// `system.open` opens for a recipe. On iOS, Flutter passes them on
/// (`FlutterDeepLinkingEnabled` in Info.plist); macOS needs a package such as
/// `app_links`.
class _ExampleAppState extends State<ExampleApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async =>
      Store.instance.openLink(routeInformation.uri);

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Assistant Actions Example',
        home: Scaffold(
          appBar: AppBar(title: const Text('Assistant Actions')),
          body: ListenableBuilder(
            listenable: Store.instance,
            builder: (context, _) {
              final store = Store.instance;
              return ListView(
                children: [
                  if (store.focusNote case final note?) ListTile(leading: const Icon(Icons.nightlight), title: Text(note)),
                  const ListTile(title: Text('Recipes')),
                  for (final r in store.recipes)
                    ListTile(
                      title: Text(r.name),
                      subtitle: Text(r.subtitle),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RecipePage(r))),
                    ),
                  const ListTile(title: Text('Tasks (reminders.*)')),
                  if (store.hideTasks)
                    const ListTile(title: Text('Hidden during this Focus'))
                  else
                    for (final t in store.tasks)
                      CheckboxListTile(value: t.done, onChanged: null, title: Text(t.title)),
                  const ListTile(title: Text('Memories (notes.*)')),
                  for (final m in store.memories) ListTile(title: Text(m.text)),
                  if (store.onScreen case final shown?) ListTile(leading: const Icon(Icons.open_in_new), title: Text(shown)),
                  const ListTile(title: Text('Timers (clock.*)')),
                  for (final t in store.timers)
                    ListTile(title: Text(t.label ?? 'Timer'), subtitle: Text('${t.length.inMinutes} min, ${t.state.name}')),
                  const ListTile(title: Text('Journal (journal.*)')),
                  if (store.recording)
                    ListTile(
                      leading: const Icon(Icons.mic),
                      title: const Text('Recording an audio entry…'),
                      trailing: TextButton(
                        onPressed: store.stopRecording,
                        child: const Text('Stop'),
                      ),
                    ),
                  for (final e in store.journal) ListTile(title: Text(e.title ?? e.text), subtitle: e.title == null ? null : Text(e.text)),
                  const ListTile(title: Text('Files (files.*)')),
                  for (final d in store.docs) ListTile(title: Text(d.name), subtitle: Text(d.path)),
                  const ListTile(title: Text('Shopping list')),
                  for (final s in store.shopping) ListTile(title: Text(s)),
                ],
              );
            },
          ),
        ),
      );
}

/// One recipe. While it's open, Siri and Apple Intelligence know it's on
/// screen ("add this to my shopping list"), and opening it is donated.
class RecipePage extends StatefulWidget {
  const RecipePage(this.recipe, {super.key});

  final Recipe recipe;

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  @override
  void initState() {
    super.initState();
    AssistantActions.showing(widget.recipe);
    AssistantActions.donate(widget.recipe);
  }

  @override
  void dispose() {
    AssistantActions.stopShowing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.recipe.name)),
        body: Center(
          child: FilledButton(
            onPressed: () async {
              await addToShoppingList(widget.recipe, servings: 2);
              // Siri learns the user does this, and can suggest it.
              await AssistantDonations.addToShoppingList(widget.recipe, servings: 2);
            },
            child: const Text('Add to shopping list'),
          ),
        ),
      );
}
