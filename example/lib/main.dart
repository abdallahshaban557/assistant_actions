import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter/material.dart';

import 'assistant_actions.g.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store.instance;
  await AssistantActions.start(assistantActionsRegistry(
    findRecipe: (id) => store.recipes.where((r) => r.id == id).firstOrNull,
    taskItem: TaskHandler(),
    memoryItem: MemoryHandler(),
    journalItem: JournalHandler(),
  ));
  store.changed();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

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
                  const ListTile(title: Text('Tasks (reminders.*)')),
                  for (final t in store.tasks)
                    CheckboxListTile(value: t.done, onChanged: null, title: Text(t.title)),
                  const ListTile(title: Text('Memories (notes.*)')),
                  for (final m in store.memories) ListTile(title: Text(m.text)),
                  const ListTile(title: Text('Journal (journal.*)')),
                  if (store.recording)
                    ListTile(
                      leading: const Icon(Icons.mic),
                      title: const Text('Recording an audio entry…'),
                      trailing: TextButton(
                        onPressed: () {
                          store.recording = false;
                          store.changed();
                        },
                        child: const Text('Stop'),
                      ),
                    ),
                  for (final e in store.journal) ListTile(title: Text(e.title ?? e.text), subtitle: e.title == null ? null : Text(e.text)),
                  const ListTile(title: Text('Shopping list')),
                  for (final s in store.shopping) ListTile(title: Text(s)),
                ],
              );
            },
          ),
        ),
      );
}
