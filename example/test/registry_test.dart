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

/// Records the Swift features Dart asks for (on-screen items, donations) and
/// says yes.
class _SwiftHost extends _NoHost implements AssistantHostCalls {
  final calls = <List<Object?>>[];

  @override
  Future<String?> invoke(String method, String argsJson) async {
    calls.add([method, jsonDecode(argsJson)]);
    return 'true';
  }
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
    registry = appRegistry();
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

  test("a recipe card's button toggles it on the shopping list and replies with the new card", () async {
    store.shopping.clear();
    final card = (jsonDecode((await AssistantActions.perform('showRecipeCard', '{"recipe":"pancakes"}'))!) as Map)['card'];
    expect((card as Map)['buttons'], [
      {
        'title': 'Add to list',
        'action': 'toggleShoppingList',
        'args': {'recipe': 'pancakes'},
        'systemImage': 'cart.badge.plus',
      },
    ]);
    // What the generated AssistantCardButtonIntent sends when it's pressed.
    final pressed = jsonDecode((await AssistantActions.perform('toggleShoppingList', '{"recipe":"pancakes"}'))!) as Map;
    expect(store.shopping, ['Pancakes × 2']);
    expect((pressed['card'] as Map)['rows'], [
      ['On shopping list', 'Yes'],
    ]);
    expect(((pressed['card'] as Map)['buttons'] as List).single['title'], 'Remove from list');
    await AssistantActions.perform('toggleShoppingList', '{"recipe":"pancakes"}');
    expect(store.shopping, isEmpty);
  });

  test('a card button must run a known action', () {
    expect(() => const AssistantCardButton('Nope', action: 'missing').toJson(), throwsArgumentError);
    expect(const AssistantCardButton('Yes', action: 'toggleShoppingList').toJson()['action'], 'toggleShoppingList');
  });

  test('system.open and searchInApp show things in the app', () async {
    await AssistantActions.perform('system.open.TaskItem', '{"id":"t1"}');
    expect(store.onScreen, 'task t1');
    await AssistantActions.perform('system.searchInApp', '{"criteria":"lake"}');
    expect(store.onScreen, 'search "lake"');
  });

  test('an App Enum parameter decodes by case name, and falls back to its default', () async {
    store.plan.clear();
    await registry.actions['planMeal']!({'recipe': 'pancakes', 'meal': 'breakfast'});
    expect(store.plan, {Meal.breakfast: 'Pancakes'});
    await registry.actions['planMeal']!({'recipe': 'risotto'});
    expect(store.plan[Meal.dinner], 'Mushroom Risotto');
  });

  test('actions return values for Shortcuts: entities by id, with a dialog', () async {
    final reply = await AssistantActions.perform('quickestRecipe', '{"under":1800}');
    expect(jsonDecode(reply!), {'value': 'pancakes', 'dialog': 'Pancakes it is.'});
    final none = await AssistantActions.perform('quickestRecipe', '{"under":60}');
    expect(jsonDecode(none!), {'value': null, 'dialog': 'Nothing is that quick.'});
  });

  test('an AssistantReply<Recipe> returns the recipe by id with its card, or ids to choose from', () async {
    expect(jsonDecode((await AssistantActions.perform('pickRecipe', '{"meal":"breakfast"}'))!), {
      'value': 'pancakes',
      'dialog': 'Pancakes for breakfast.',
      'card': {'title': 'Pancakes', 'subtitle': '20 min', 'systemImage': 'fork.knife'},
    });
    expect(jsonDecode((await AssistantActions.perform('pickRecipe', '{}'))!), {
      'choices': ['pancakes', 'risotto'],
      'prompt': 'Which recipe?',
    });
  });

  test('lists and schema entities return too', () async {
    store.shopping
      ..clear()
      ..addAll(['Eggs', 'Flour']);
    expect(jsonDecode((await AssistantActions.perform('shoppingList', '{}'))!), {
      'value': ['Eggs', 'Flour'],
    });
    store.tasks.add(TaskItem(id: 't9', title: 'Call mum', due: DateTime(2026, 11, 3)));
    expect(jsonDecode((await AssistantActions.perform('nextTask', '{}'))!),
        {'value': 't9', 'dialog': 'Next up: Call mum.'});
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

  test('a journal entry publishes its first photo as its image, for Siri and Spotlight', () {
    final codec = registry.codecs[JournalItem]!;
    final entry = JournalItem(id: 'j3', text: 'Hike', media: const [
      AssistantFile(path: '/tmp/note.m4a', type: 'com.apple.m4a-audio'),
      AssistantFile(path: '/tmp/summit.heic', type: 'public.heic'),
    ]);
    expect((codec.encode(entry)['fields'] as Map)['cover'], '/tmp/summit.heic');
    expect((codec.encode(JournalItem(id: 'j4', text: 'No photos'))['fields'] as Map)['cover'], isNull);
  });

  test('undoing a timer pause resumes it; undoing a create deletes it', () async {
    await apply(const InboxChange(kind: 'create', collection: 'Countdown', id: 'c1', fields: {'length': 60.0}));
    await registry.actions['Countdown.pauseTimer']!({'timer': 'c1'});
    // What Swift's AssistantUndo queues when the user undoes the pause.
    await registry.actions['Countdown.pauseTimer.undo']!({'timer': 'c1'});
    expect(store.timers.single.state.name, 'running');
    await apply(const InboxChange(kind: 'delete', collection: 'Countdown', id: 'c1'));
    expect(store.timers, isEmpty);
  });

  test('undoing a task delete creates it again with its id', () async {
    store.tasks.add(TaskItem(id: 't1', title: 'Call mum'));
    await apply(const InboxChange(kind: 'delete', collection: 'TaskItem', id: 't1'));
    await apply(const InboxChange(kind: 'create', collection: 'TaskItem', id: 't1', fields: {'title': 'Call mum'}));
    expect(store.tasks.single.id, 't1');
  });

  test('files.* intents get paths', () async {
    store.docs
      ..clear()
      ..add(DocItem(path: '/Documents/a.txt'));
    expect(await AssistantActions.perform('DocItem.createFolder', '{"fileName":"Old","target":"/Documents"}'),
        '/Documents/Old');
    await AssistantActions.perform('DocItem.moveFiles', '{"entities":["/Documents/a.txt"],"destinationFolder":"/Documents/Old"}');
    await AssistantActions.perform('DocItem.renameFile', '{"target":"/Documents/Old/a.txt","newName":"b.txt"}');
    expect(store.docs.map((d) => d.path), ['/Documents/Old/b.txt', '/Documents/Old']);
    await apply(const InboxChange(kind: 'delete', collection: 'DocItem', id: '/Documents/Old/b.txt'));
    expect(store.docs.single.name, 'Old');
    expect(registry.codecs[DocItem]!.encode(store.docs.single)['id'], '/Documents/Old');
  });

  test('a long-running action sees its call and stops when cancelled', () async {
    store.tasks.addAll([TaskItem(id: 'a', title: 'A', done: true), TaskItem(id: 'b', title: 'B', done: true)]);
    final reply = AssistantActions.perform('archiveDoneTasks', '{"${AssistantCall.argument}":"call-1"}');
    await AssistantActions.perform(AssistantCall.cancelAction, '{"call":"call-1"}');
    expect(await reply, 'Archived 1 task.', reason: 'it archives one, then sees the cancel');
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

  test('recipes open by deep link, not through the handler', () {
    expect(registry.actions.containsKey('system.open.Recipe'), isFalse);
    expect(store.openLink(Uri.parse('assistantactions://recipes/pancakes')), isTrue);
    expect(store.onScreen, 'recipe pancakes');
    expect(store.openLink(Uri.parse('https://example.com/recipes/pancakes')), isFalse);
  });

  test('Visual Intelligence finds recipes and journal entries by label', () async {
    store.journal.add(JournalItem(id: 'j3', text: 'Pancakes at the lake'));
    final reply = await AssistantActions.perform(
        'visualIntelligence.search', jsonEncode({'content': {'labels': ['Pancake', 'plate']}}));
    expect(jsonDecode(reply!), [
      {'collection': 'Recipe', 'id': 'pancakes'},
      {'collection': 'JournalItem', 'id': 'j3'},
    ]);
  });

  test('"more results" from Visual Intelligence gets the labels and image', () async {
    await AssistantActions.perform('visualIntelligence.semanticContentSearch', jsonEncode({
      'semanticContent': {
        'labels': ['dog'],
        'image': {'path': '/tmp/image.png', 'name': 'image.png', 'type': 'public.png'},
      },
    }));
    expect(store.onScreen, 'looking for dog');
  });

  test('the recipe on screen and donations reach Swift', () async {
    final host = _SwiftHost();
    await AssistantActions.start(registry, host: host);
    final pancakes = store.recipes.first;
    expect(await AssistantActions.showing(pancakes), isTrue);
    await AssistantActions.stopShowing();
    expect(await AssistantActions.donate(pancakes), isTrue);
    expect(await AssistantDonations.addToShoppingList(pancakes, servings: 3), isTrue);
    expect(host.calls, [
      ['context.showing', {'collection': 'Recipe', 'id': 'pancakes'}],
      ['context.stopShowing', <String, Object?>{}],
      ['donate.entity', {'collection': 'Recipe', 'id': 'pancakes'}],
      [
        'donate.action',
        {
          'action': 'addToShoppingList',
          'args': {'recipe': 'pancakes', 'servings': 3},
        },
      ],
    ]);
  });

  // Last: it switches the runtime to the headless engine's mode.
  test('the headless engine builds the same registry and answers live actions', () async {
    store.tasks.add(TaskItem(id: 't1', title: 'Call mum'));
    await AssistantActions.startInBackground(appRegistry, host: _BackgroundHost());
    expect(await AssistantActions.perform('countOpenTasks', '{}'), 'You have 1 open task (answered in the background).');
  });
}

/// Swift's side of the headless engine: lets Dart claim it.
class _BackgroundHost extends _NoHost implements AssistantHostCalls {
  @override
  Future<String?> invoke(String method, String argsJson) async => method == 'background.claim' ? 'true' : null;
}
