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
    store.journal.clear();
    store.timers.clear();
    store.onScreen = null;
    store.recording = false;
    registry = assistantActionsRegistry(
      findRecipe: (id) => store.recipes.where((r) => r.id == id).firstOrNull,
      taskItem: TaskHandler(),
      memoryItem: MemoryHandler(),
      journalItem: JournalHandler(),
      countdown: CountdownHandler(),
      system: SystemHandler(),
      camera: CameraHandler(),
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

  test('createAudioEntry calls startAudioEntry live', () async {
    expect(await AssistantActions.perform('JournalItem.startAudioEntry', '{}'), isNull);
    expect(store.recording, isTrue);
  });

  test('Siri creates, updates and deletes journal entries', () async {
    final date = DateTime(2026, 11, 9, 8);
    await apply(InboxChange(
        kind: 'create',
        collection: 'JournalItem',
        id: 'j1',
        fields: {'text': 'Walked to the lake', 'date': AssistantValue.encodeDate(date)}));
    expect(store.journal.single.text, 'Walked to the lake');
    expect(store.journal.single.date, date);

    await apply(const InboxChange(
        kind: 'update', collection: 'JournalItem', id: 'j1', fields: {'title': 'Morning'}, cleared: ['date']));
    expect(store.journal.single.title, 'Morning');
    expect(store.journal.single.date, isNull);

    await apply(const InboxChange(kind: 'delete', collection: 'JournalItem', id: 'j1'));
    expect(store.journal, isEmpty);
  });

  test('Siri creates a timer, then pauses it with a queued call', () async {
    await apply(InboxChange(
        kind: 'create', collection: 'Countdown', id: 'c1', fields: {'length': 300.0, 'label': 'Tea'}));
    expect(store.timers.single.length, const Duration(minutes: 5));
    await registry.actions['Countdown.pauseTimer']!({'timer': 'c1'});
    expect(store.timers.single.state.name, 'paused');
  });

  test('domain intents decode app-defined enum cases', () async {
    await AssistantActions.perform('camera.startCapture', '{"captureMode":"video","device":"front"}');
    expect(store.onScreen, 'camera: video, front');
  });

  test('system.open and searchInApp show things in the app', () async {
    await AssistantActions.perform('system.open.Recipe', '{"id":"pancakes"}');
    expect(store.onScreen, 'recipe pancakes');
    await AssistantActions.perform('system.searchInApp', '{"criteria":"lake"}');
    expect(store.onScreen, 'search "lake"');
  });
}
