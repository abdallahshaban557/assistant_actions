import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/camera.dart';
import 'package:assistant_actions/schemas/clock.dart';
import 'package:assistant_actions/schemas/system.dart';
import 'package:flutter/foundation.dart';

import 'assistant_actions.g.dart';
import 'models/models.dart';

/// The app's handlers. `main` starts with it, and so does the headless
/// engine Siri uses on iOS when the app isn't running
/// (`@AssistantBackground()`), so live actions answer without opening the app.
@AssistantBackground()
AssistantActionsRegistry appRegistry() {
  final store = Store.instance;
  return assistantActionsRegistry(
    findRecipe: (id) => store.recipes.where((r) => r.id == id).firstOrNull,
    taskItem: TaskHandler(),
    memoryItem: MemoryHandler(),
    journalItem: JournalHandler(),
    countdown: CountdownHandler(),
    docItem: DocHandler(),
    system: SystemHandler(),
    camera: CameraHandler(),
  );
}

/// In-memory data for the example. A real app would persist it: the
/// headless engine has its own memory, so it starts from an empty store.
class Store extends ChangeNotifier {
  Store._();
  static final instance = Store._();

  final recipes = [
    const Recipe(id: 'pancakes', name: 'Pancakes', minutes: 20),
    const Recipe(id: 'risotto', name: 'Mushroom Risotto', minutes: 45),
  ];
  final tasks = <TaskItem>[];
  final memories = <MemoryItem>[];
  final journal = <JournalItem>[];
  final timers = <Countdown>[];
  final docs = [
    DocItem(path: '/Documents/Notes', created: DateTime(2026, 11, 1)),
    DocItem(path: '/Documents/Notes/Plan.txt', created: DateTime(2026, 11, 2)),
  ];

  /// What Siri last asked the app to show or do on screen.
  String? onScreen;

  /// Whether the app is recording an audio journal entry Siri asked for.
  bool recording = false;

  /// The Live Activity shown while [recording] (iOS; null elsewhere).
  AssistantLiveActivity? recordingActivity;

  /// What the Focus filter asks for (see `applyFocus`): the defaults mean no
  /// Focus is on.
  bool hideTasks = false;
  String? focusNote;
  final shopping = <String>[];

  /// Stops recording and ends its Live Activity: the Stop button, and Siri's
  /// "Stop Recording" (`stopRecording`), which can run while the app records
  /// in the background.
  Future<void> stopRecording() async {
    recording = false;
    final activity = recordingActivity;
    recordingActivity = null;
    changed();
    await activity?.end(
      content: const AssistantActivityContent(title: 'Journal entry saved', systemImage: 'checkmark.circle.fill'),
      dismissal: AssistantActivityDismissal.after,
      dismissAt: DateTime.now().add(const Duration(seconds: 5)),
    );
  }

  /// What Siri planned for each meal (`planMeal`).
  final plan = <Meal, String>{};

  /// Tells listeners and republishes what Siri can see.
  void changed() => changedAndPublished();

  /// [changed], finishing once Siri can see the change.
  Future<void> changedAndPublished() {
    notifyListeners();
    return publish();
  }

  /// Republishes what Siri can see.
  Future<void> publish() async {
    await Future.wait([
      AssistantActions.publish(recipes),
      AssistantActions.publish(tasks),
      AssistantActions.publish(memories),
      AssistantActions.publish(journal),
      AssistantActions.publish(timers),
      AssistantActions.publish(docs),
    ]);
  }
}

/// Applies Siri's reminders.* changes to tasks.
class TaskHandler implements TaskItemAssistantHandler {
  Store get _store => Store.instance;

  @override
  Future<void> create(String id, TaskItemValues values) async {
    _store.tasks.add(TaskItem(id: id, title: values.title ?? '', due: values.due));
    _store.changed();
  }

  @override
  Future<void> update(String id, TaskItemValues changes) async {
    for (final t in _store.tasks.where((t) => t.id == id)) {
      t
        ..title = changes.title ?? t.title
        ..due = changes.dueCleared ? null : changes.due ?? t.due
        ..done = changes.done ?? t.done;
    }
    _store.changed();
  }

  @override
  Future<void> delete(String id) async {
    _store.tasks.removeWhere((t) => t.id == id);
    _store.changed();
  }
}

/// Applies Siri's notes.* changes to memories.
class MemoryHandler implements MemoryItemAssistantHandler {
  Store get _store => Store.instance;

  @override
  Future<void> create(String id, MemoryItemValues values) async {
    _store.memories.add(MemoryItem(id: id, text: values.text ?? '', pinned: values.pinned ?? false));
    _store.changed();
  }

  @override
  Future<void> update(String id, MemoryItemValues changes) async {
    for (final m in _store.memories.where((m) => m.id == id)) {
      m
        ..text = changes.text ?? m.text
        ..pinned = changes.pinned ?? m.pinned;
    }
    _store.changed();
  }
}

/// Applies Siri's journal.* changes to the journal.
class JournalHandler implements JournalItemAssistantHandler {
  Store get _store => Store.instance;

  @override
  Future<void> create(String id, JournalItemValues values) async {
    _store.journal.add(JournalItem(
      id: id,
      text: values.text ?? '',
      title: values.title,
      date: values.date ?? DateTime.now(),
      media: values.media ?? const [],
      place: values.place,
    ));
    _store.changed();
  }

  @override
  Future<void> update(String id, JournalItemValues changes) async {
    for (final e in _store.journal.where((e) => e.id == id)) {
      e
        ..title = changes.titleCleared ? null : changes.title ?? e.title
        ..text = changes.text ?? e.text
        ..date = changes.dateCleared ? null : changes.date ?? e.date
        ..media = changes.media ?? e.media
        ..place = changes.placeCleared ? null : changes.place ?? e.place;
    }
    _store.changed();
  }

  @override
  Future<void> delete(String id) async {
    _store.journal.removeWhere((e) => e.id == id);
    _store.changed();
  }

  /// Siri's "record a journal entry". The app is in the foreground now; a real
  /// app starts its recorder here. Apple's AudioRecordingIntent asks for a
  /// Live Activity while recording goes on, on iOS: the widget extension
  /// (`dart run assistant_actions:install --widgets`) shows it on the Lock
  /// Screen and in the Dynamic Island, with a timer since it started.
  @override
  Future<void> startAudioEntry() async {
    _store.recording = true;
    _store.changed();
    _store.recordingActivity ??= await AssistantLiveActivity.start(
      AssistantActivityContent(
        title: 'Recording a journal entry',
        subtitle: 'Say "Stop recording" or open the app to stop.',
        systemImage: 'mic.fill',
        timerStart: DateTime.now(),
      ),
      kind: 'recording',
    );
  }
}

/// Applies Siri's clock.* requests to timers.
class CountdownHandler implements CountdownAssistantHandler {
  Store get _store => Store.instance;

  @override
  Future<void> create(String id, CountdownValues values) async {
    _store.timers.add(Countdown(id: id, length: values.length ?? const Duration(minutes: 1), label: values.label));
    _store.changed();
  }

  @override
  Future<void> pauseTimer({required String timer}) async {
    for (final t in _store.timers.where((t) => t.id == timer)) {
      t.state = ClockTimerState.paused;
    }
    _store.changed();
  }

  @override
  Future<void> resumeTimer({required String timer}) async {
    for (final t in _store.timers.where((t) => t.id == timer)) {
      t.state = ClockTimerState.running;
    }
    _store.changed();
  }

  /// `@AssistantUndoable()`: undoing "create a timer" deletes it.
  @override
  Future<void> delete(String id) async {
    _store.timers.removeWhere((t) => t.id == id);
    _store.changed();
  }

  /// The user undid "pause the timer".
  @override
  Future<void> undoPauseTimer({required String timer}) => resumeTimer(timer: timer);

  /// The user undid "resume the timer".
  @override
  Future<void> undoResumeTimer({required String timer}) => pauseTimer(timer: timer);
}

/// Applies Siri's files.* requests to documents. The ids are paths; a real
/// app moves, renames and deletes the files themselves too.
class DocHandler implements DocItemAssistantHandler {
  Store get _store => Store.instance;

  DocItem? _doc(String path) => _store.docs.where((d) => d.path == path).firstOrNull;

  @override
  Future<void> openFile({required String target}) async {
    _store.onScreen = 'file ${_doc(target)?.name ?? target}';
    _store.changed();
  }

  @override
  Future<void> moveFiles({required List<String> entities, required String destinationFolder}) async {
    for (final path in entities) {
      _doc(path)?.path = '$destinationFolder/${path.split('/').last}';
    }
    _store.changed();
  }

  @override
  Future<String> createFolder({String? fileName, required String target}) async {
    final folder = DocItem(path: '$target/${fileName ?? 'New Folder'}', created: DateTime.now());
    _store.docs.add(folder);
    // Published before returning, so Siri can show it.
    await _store.changedAndPublished();
    return folder.path;
  }

  @override
  Future<void> renameFile({required String target, required String newName}) async {
    final doc = _doc(target);
    if (doc != null) doc.path = '${target.substring(0, target.lastIndexOf('/'))}/$newName';
    _store.changed();
  }

  @override
  Future<void> delete(String id) async {
    _store.docs.removeWhere((d) => d.path == id);
    _store.changed();
  }
}

/// `system.open` and `system.searchInApp`: Siri opens an item, or the app's
/// search, in the foreground.
@SystemIntents(open: true, searchInApp: true)
class SystemHandler implements SystemAssistantHandler {
  Store get _store => Store.instance;

  void _show(String what) {
    _store.onScreen = what;
    _store.changed();
  }

  @override
  Future<void> openRecipe(String id) async => _show('recipe $id');

  @override
  Future<void> openTaskItem(String id) async => _show('task $id');

  @override
  Future<void> openMemoryItem(String id) async => _show('memory $id');

  @override
  Future<void> openJournalItem(String id) async => _show('journal entry $id');

  @override
  Future<void> openCountdown(String id) async => _show('timer $id');

  @override
  Future<void> searchInApp({required String criteria}) async => _show('search "$criteria"');
}

/// `camera.*`: the app opens its camera. A real app starts capture here.
/// `startCapture` replies, so Siri says what's on and shows a card. "Take a
/// video with …" is an App Shortcut for it.
@CameraIntents(startCapture: true, stopCapture: true, replies: {'startCapture'})
@IntentShortcut('camera.startCapture',
    phrases: ['Take a {captureMode} with {app}', 'Open the {app} camera'], shortTitle: 'Camera', systemImage: 'camera')
class CameraHandler implements CameraAssistantHandler {
  @override
  Future<AssistantReply<void>> startCapture({
    required CaptureMode captureMode,
    Lens? device,
    CaptureDelay? timerDuration,
  }) async {
    Store.instance
      ..onScreen = 'camera: ${captureMode.name}${device == null ? '' : ', ${device.name}'}'
      ..changed();
    return AssistantReply(
      dialog: 'The camera is ready for a ${captureMode.name}.',
      card: AssistantCard(
        title: 'Camera',
        subtitle: captureMode == CaptureMode.photo ? 'Photo' : 'Video',
        rows: [
          if (device != null) AssistantCardRow('Lens', device.name),
          if (timerDuration != null) AssistantCardRow('Timer', timerDuration.name),
        ],
        systemImage: 'camera',
      ),
    );
  }

  @override
  Future<void> stopCapture() async {
    Store.instance
      ..onScreen = null
      ..changed();
  }
}
