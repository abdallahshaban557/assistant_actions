import 'package:assistant_actions/assistant_actions.dart';
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
@RemindersReminder(
  list: FixedList(id: 'tasks', name: 'Tasks'),
  createReminder: true,
  updateReminder: true,
  deleteReminders: true,
)
class TaskItem {
  TaskItem({required this.id, required this.title, this.due, this.done = false});

  @EntityId()
  final String id;

  @ReminderField.title
  String title;

  @ReminderField.dueDate
  DateTime? due;

  @ReminderField.isCompleted
  bool done;
}

/// Level 3: a fact Siri understands as a note (`notes.note`).
@NotesNote(
  folder: FixedFolder(id: 'memories', name: 'Memories', account: FixedAccount(id: 'local', name: 'On this device')),
  createNote: true,
  appendText: true,
  updateNote: true,
)
class MemoryItem {
  MemoryItem({required this.id, required this.text, this.pinned = false});

  @EntityId()
  final String id;

  @NoteField.name
  @NoteField.content
  String text;

  @NoteField.isPinned
  bool pinned;
}
