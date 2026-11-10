import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/camera.dart';
import 'package:assistant_actions/schemas/clock.dart';
import 'package:assistant_actions/schemas/journal.dart';
import 'package:assistant_actions/schemas/notes.dart';
import 'package:assistant_actions/schemas/reminders.dart';

/// Level 2: one of the app's own types, searchable by Siri.
@AssistantEntity(title: 'Recipe')
class Recipe {
  const Recipe({required this.id, required this.name, required this.minutes});

  @EntityId()
  final String id;

  @DisplayTitle()
  final String name;

  final int minutes;

  @DisplaySubtitle()
  String get subtitle => '$minutes min';
}

/// Level 3: a task Siri understands as a reminder (`reminders.reminder`).
/// Siri says what it did, and asks before deleting ("Delete Buy milk?"), as
/// deletes do by default.
@RemindersReminder(
  list: FixedRemindersList(id: 'tasks', name: 'Tasks'),
  createReminder: true,
  updateReminder: true,
  deleteReminders: true,
  dialogs: {
    'createReminder': 'Added {title} to your tasks.',
    'updateReminder': 'Updated {result}.',
    'deleteReminders': 'Deleted {entities}.',
  },
)
class TaskItem {
  TaskItem({required this.id, required this.title, this.due, this.done = false});

  @EntityId()
  final String id;

  @RemindersReminderField.title
  String title;

  @RemindersReminderField.dueDate
  DateTime? due;

  @RemindersReminderField.isCompleted
  bool done;
}

/// Level 3: a fact Siri understands as a note (`notes.note`).
@NotesNote(
  folder: FixedNotesFolder(id: 'memories', name: 'Memories', account: FixedNotesAccount(id: 'local', name: 'On this device')),
  createNote: true,
  appendText: true,
  updateNote: true,
)
class MemoryItem {
  MemoryItem({required this.id, required this.text, this.pinned = false});

  @EntityId()
  final String id;

  @NotesNoteField.name
  @NotesNoteField.content
  String text;

  @NotesNoteField.isPinned
  bool pinned;
}

/// Level 3: a voice journal entry Siri understands as `journal.entry`.
/// `createAudioEntry` lets "record a journal entry in …" open the app and
/// call `JournalHandler.startAudioEntry`; the app records the audio.
@JournalEntry(
  createEntry: true,
  createAudioEntry: true,
  updateEntry: true,
  deleteEntry: true,
)
class JournalItem {
  JournalItem({required this.id, required this.text, this.title, this.date, this.media = const [], this.place});

  @EntityId()
  final String id;

  @JournalEntryField.title
  String? title;

  @JournalEntryField.message
  String text;

  @JournalEntryField.entryDate
  DateTime? date;

  /// Recordings and photos. Files Siri passes are copied into the app's
  /// Application Support folder first.
  @JournalEntryField.mediaItems
  List<AssistantFile> media;

  @JournalEntryField.location
  AssistantPlace? place;
}

/// Level 3: a countdown Siri understands as `clock.timer`. `createTimer`
/// arrives through the inbox; pausing and resuming are handler calls, queued
/// until the app runs. Siri asks before pausing.
@ClockTimer(
  createTimer: true,
  pauseTimer: true,
  resumeTimer: true,
  dialogs: {'createTimer': 'Started a {duration} timer.', 'pauseTimer': 'Paused.'},
  confirm: {'pauseTimer': 'Pause {timer}?'},
)
class Countdown {
  Countdown({required this.id, required this.length, this.label, this.state = ClockTimerState.running})
      : left = length;

  @EntityId()
  final String id;

  @ClockTimerField.duration
  Duration length;

  @ClockTimerField.durationRemaining
  Duration left;

  @ClockTimerField.label
  String? label;

  @ClockTimerField.state
  ClockTimerState state;
}

/// `camera.captureMode` and friends have no cases in Apple's schema: the app
/// names its own, and Siri offers them.
@CameraCaptureMode()
enum CaptureMode { photo, video }

@CameraCaptureDevice()
enum Lens { front, back }

@CameraCaptureDuration()
enum CaptureDelay { threeSeconds, tenSeconds }
