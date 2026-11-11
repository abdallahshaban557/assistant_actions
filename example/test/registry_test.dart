// Drives the generated registry the way AssistantActions does when it drains
// Siri's inbox. No device, simulator or Siri needed.
import 'dart:convert';

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

/// Also plays the Swift side of Live Activities.
class _ActivityHost extends _NoHost implements AssistantHostCalls {
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<String?> invoke(String method, String argsJson) async {
    final args = (jsonDecode(argsJson) as Map).cast<String, Object?>();
    calls.add((method, args));
    return jsonEncode(switch (method) {
      'liveActivity.start' => {'id': 'a1', 'kind': args['kind'], 'state': 'active'},
      'liveActivity.end' => true,
      _ => null,
    });
  }
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
    store
      ..recording = false
      ..recordingActivity = null
      ..hideTasks = false
      ..focusNote = null;
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

  test('startCapture replies with a dialog and a result card', () async {
    final reply = jsonDecode((await AssistantActions.perform('camera.startCapture', '{"captureMode":"photo","device":"back"}'))!);
    expect(reply, {
      'dialog': 'The camera is ready for a photo.',
      'card': {
        'title': 'Camera',
        'subtitle': 'Photo',
        'rows': [
          ['Lens', 'back'],
        ],
        'systemImage': 'camera',
      },
    });
  });

  test('a live action returns a recipe card; a confirmed one removes from the list', () async {
    store.shopping
      ..clear()
      ..add('Pancakes × 2');
    final reply = jsonDecode((await AssistantActions.perform('showRecipeCard', '{"recipe":"pancakes"}'))!) as Map;
    expect(reply['dialog'], 'Pancakes takes 20 minutes.');
    expect((reply['card'] as Map)['rows'], [
      ['On shopping list', 'Yes'],
    ]);
    // Swift asked "Remove Pancakes from your shopping list?" before queuing this.
    await registry.actions['removeFromShoppingList']!({'recipe': 'pancakes'});
    expect(store.shopping, isEmpty);
  });

  test('system.open and searchInApp show things in the app', () async {
    await AssistantActions.perform('system.open.Recipe', '{"id":"pancakes"}');
    expect(store.onScreen, 'recipe pancakes');
    await AssistantActions.perform('system.searchInApp', '{"criteria":"lake"}');
    expect(store.onScreen, 'search "lake"');
  });

  test('Siri attaches files and a place to a journal entry', () async {
    await apply(const InboxChange(kind: 'create', collection: 'JournalItem', id: 'j2', fields: {
      'text': 'Voice note',
      'media': [
        {'path': '/tmp/note.m4a', 'name': 'note.m4a', 'type': 'com.apple.m4a-audio'},
      ],
      'place': {'name': 'Lake', 'latitude': 47.6, 'longitude': -122.3},
    }));
    final entry = store.journal.single;
    expect(entry.media.single.path, '/tmp/note.m4a');
    expect(entry.place?.name, 'Lake');
  });

  test('the Focus filter applies its values, and its defaults when the Focus ends', () async {
    await AssistantActions.perform('applyFocus', '{"hideTasks":true,"note":"Deep work"}');
    expect((store.hideTasks, store.focusNote), (true, 'Deep work'));
    await AssistantActions.perform('applyFocus', '{"hideTasks":false,"note":null}');
    expect((store.hideTasks, store.focusNote), (false, null));
  });

  test('recording an audio entry shows a Live Activity, and stopping ends it', () async {
    final host = _ActivityHost();
    await AssistantActions.start(registry, host: host);
    await AssistantActions.perform('JournalItem.startAudioEntry', '{}');
    expect(store.recording, isTrue);
    expect(store.recordingActivity?.kind, 'recording');
    final (method, args) = host.calls.single;
    expect(method, 'liveActivity.start');
    expect((args['content'] as Map)['systemImage'], 'mic.fill');

    await AssistantActions.perform('stopRecording', '{}');
    expect(store.recording, isFalse);
    expect(store.recordingActivity, isNull);
    expect(host.calls.last.$1, 'liveActivity.end');
    expect((host.calls.last.$2['content'] as Map)['title'], 'Journal entry saved');
  });

  test('without Live Activities, recording still starts', () async {
    await AssistantActions.perform('JournalItem.startAudioEntry', '{}');
    expect(store.recording, isTrue);
    expect(store.recordingActivity, isNull);
  });
}
