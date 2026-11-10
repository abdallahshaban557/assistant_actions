import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/camera.dart';
import 'package:assistant_actions/schemas/clock.dart';
import 'package:assistant_actions/schemas/system.dart';
import 'package:flutter/foundation.dart';

import 'assistant_actions.g.dart';
import 'models/models.dart';

/// In-memory data for the example. A real app would persist it.
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

  /// What Siri last asked the app to show or do on screen.
  String? onScreen;

  /// Whether the app is recording an audio journal entry Siri asked for.
  bool recording = false;
  final shopping = <String>[];

  /// Tells listeners and republishes what Siri can see.
  void changed() {
    notifyListeners();
    AssistantActions.publish(recipes);
    AssistantActions.publish(tasks);
    AssistantActions.publish(memories);
    AssistantActions.publish(journal);
    AssistantActions.publish(timers);
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
    _store.journal.add(JournalItem(id: id, text: values.text ?? '', title: values.title, date: values.date ?? DateTime.now()));
    _store.changed();
  }

  @override
  Future<void> update(String id, JournalItemValues changes) async {
    for (final e in _store.journal.where((e) => e.id == id)) {
      e
        ..title = changes.titleCleared ? null : changes.title ?? e.title
        ..text = changes.text ?? e.text
        ..date = changes.dateCleared ? null : changes.date ?? e.date;
    }
    _store.changed();
  }

  @override
  Future<void> delete(String id) async {
    _store.journal.removeWhere((e) => e.id == id);
    _store.changed();
  }

  /// Siri's "record a journal entry". The app is in the foreground now; a real
  /// app starts its recorder here (and, on iOS, a Live Activity while it
  /// records, as Apple's AudioRecordingIntent asks).
  @override
  Future<void> startAudioEntry() async {
    _store.recording = true;
    _store.changed();
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
@CameraIntents(startCapture: true, stopCapture: true)
class CameraHandler implements CameraAssistantHandler {
  @override
  Future<void> startCapture({required CaptureMode captureMode, Lens? device, CaptureDelay? timerDuration}) async {
    Store.instance
      ..onScreen = 'camera: ${captureMode.name}${device == null ? '' : ', ${device.name}'}'
      ..changed();
  }

  @override
  Future<void> stopCapture() async {
    Store.instance
      ..onScreen = null
      ..changed();
  }
}
