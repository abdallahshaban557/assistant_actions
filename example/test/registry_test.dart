// Drives the generated registry the way AssistantActions does when it drains
// Siri's inbox. No device, simulator or Siri needed.
import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions_example/assistant_actions.g.dart';
import 'package:assistant_actions_example/models/models.dart';
import 'package:assistant_actions_example/store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the Swift side, which tests don't have.
class _NoHost implements AssistantHost {
  @override
  Future<List<String>> drainInbox() async => const [];

  @override
  Future<void> markReady() async {}

  @override
  Future<void> publish(String collection, String json) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = Store.instance;
  late AssistantActionsRegistry registry;

  setUp(() async {
    store.tasks.clear();
    registry = assistantActionsRegistry(
      findRecipe: (id) => store.recipes.where((r) => r.id == id).firstOrNull,
      taskItem: TaskHandler(),
      memoryItem: MemoryHandler(),
    );
    // The handlers republish after each change, which needs a started runtime.
    await AssistantActions.start(registry, host: _NoHost());
  });

  Future<void> apply(InboxChange change) => registry.collections[change.collection]!(change);

  test('a Siri update that clears the due date removes it', () async {
    final due = DateTime(2026, 11, 3, 9);
    store.tasks.add(TaskItem(id: 't1', title: 'Call mum', due: due));

    await apply(const InboxChange(kind: 'update', collection: 'TaskItem', id: 't1', cleared: ['due']));
    expect(store.tasks.single.due, isNull);
  });

  test('an update that leaves the due date out keeps it', () async {
    final due = DateTime(2026, 11, 3, 9);
    store.tasks.add(TaskItem(id: 't1', title: 'Call mum', due: due));

    await apply(const InboxChange(kind: 'update', collection: 'TaskItem', id: 't1', fields: {'done': true}));
    expect(store.tasks.single.due, due);
    expect(store.tasks.single.done, isTrue);
  });

  test('an update can set a new due date', () async {
    store.tasks.add(TaskItem(id: 't1', title: 'Call mum'));
    final due = DateTime(2026, 11, 4);

    await apply(InboxChange(
        kind: 'update', collection: 'TaskItem', id: 't1', fields: {'due': AssistantValue.encodeDate(due)}));
    expect(store.tasks.single.due, due);
  });

  test('TaskItemValues reports only nullable fields as clearable', () {
    const values = TaskItemValues(cleared: {'due'});
    expect(values.dueCleared, isTrue);
    expect(const TaskItemValues().dueCleared, isFalse);
  });

  test('plain entities publish their fields for snapshot answers', () {
    final codec = registry.codecs[Recipe]!;
    expect(codec.encode(store.recipes.first)['fields'], {'name': 'Pancakes', 'minutes': 20});
  });
}
