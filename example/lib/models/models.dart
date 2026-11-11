import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/camera.dart';
import 'package:assistant_actions/schemas/clock.dart';
import 'package:assistant_actions/schemas/files.dart';
import 'package:assistant_actions/schemas/journal.dart';
import 'package:assistant_actions/schemas/notes.dart';
import 'package:assistant_actions/schemas/reminders.dart';

/// Level 2: one of the app's own types, searchable by Siri. "Open Pancakes in
/// …" is an App Shortcut for `system.open` that learns each recipe the app
/// publishes. Each recipe has a deep link (`system.open` opens it, and Apple
/// Intelligence can share it), and Visual Intelligence can show recipes for
/// what the camera sees. Siri, Spotlight and Shortcuts show each recipe with
/// a fork and knife.
@AssistantEntity(
    title: 'Recipe', url: 'assistantactions://recipes/{id}', visualSearch: true, systemImage: 'fork.knife')
@IntentShortcut('system.open',
    phrases: ['Open {target} in {app}', 'Show a recipe in {app}'], shortTitle: 'Open Recipe', systemImage: 'book')
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
/// Syncable, like Apple's reminders, so Siri can pass a task it found to
/// "update …"; and undoable, so "undo" takes Siri's change back.
@AssistantSyncable()
@AssistantUndoable()
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
  // How Shortcuts shows "Create Reminder": a sentence instead of a list of
  // fields. The parameters it leaves out are listed under it.
  summaries: {'createReminder': 'Add {title} to my tasks, due {dueDate}'},
  systemImage: 'checklist',
)
@IntentShortcut('reminders.createReminder',
    phrases: ['Add a task in {app}', 'New {app} task'], shortTitle: 'New Task', systemImage: 'plus.circle')
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
/// Journals are private: Siri asks to unlock the device before any journal
/// intent, or `system.open` on an entry, runs. Each entry shows its first
/// photo, else a book.
@JournalEntry(
  createEntry: true,
  createAudioEntry: true,
  updateEntry: true,
  deleteEntry: true,
  visualSearch: true,
  requiresUnlock: Unlock.required,
  systemImage: 'book.closed',
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

  /// The first photo attached, which Siri, Spotlight and Shortcuts show with
  /// the entry. Attached files are in the app's container, which the
  /// generated Swift reads in the app's process.
  @EntityImage()
  String? get cover => media.where(_isImage).firstOrNull?.path;

  static bool _isImage(AssistantFile f) =>
      const {'public.jpeg', 'public.png', 'public.heic', 'public.image'}.contains(f.type) ||
      RegExp(r'\.(jpe?g|png|heic)$', caseSensitive: false).hasMatch(f.path);
}

/// Level 3: a countdown Siri understands as `clock.timer`. `createTimer`
/// arrives through the inbox; pausing and resuming are handler calls, queued
/// until the app runs. Siri asks before pausing. Undoable: undoing a pause
/// resumes the timer.
@AssistantUndoable()
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

/// One of the app's enums as an App Enum, for `planMeal`'s parameter and its
/// shortcut phrases.
@AssistantEnum(title: 'Meal')
enum Meal {
  breakfast,
  lunch,
  dinner,
  @CaseTitle('Late-night snack', synonyms: ['snack', 'midnight snack'], systemImage: 'moon.stars')
  snack,
}

/// Level 3: a document Siri understands as a file (`files.file`). The id is
/// the file's path; Swift gives Siri a `FileEntityIdentifier` for it.
@FilesFile(openFile: true, moveFiles: true, createFolder: true, renameFile: true, deleteFiles: true, visualSearch: true)
class DocItem {
  DocItem({required this.path, this.created});

  @EntityId()
  String path;

  @FilesFileField.creationDate
  DateTime? created;

  String get name => path.split('/').last;
}

/// `camera.captureMode` and friends have no cases in Apple's schema: the app
/// names its own, and Siri offers them.
@CameraCaptureMode()
enum CaptureMode { photo, video }

@CameraCaptureDevice()
enum Lens { front, back }

@CameraCaptureDuration()
enum CaptureDelay { threeSeconds, tenSeconds }
