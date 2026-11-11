/// Class annotations that turn on newer App Intents protocols for an entity
/// class or a domain's `…Intents` class.
library;

/// Makes the generated entity a `SyncableEntity` (iOS 27 / macOS 27), so Siri
/// can carry its items between devices and into schema intents ("update my
/// reminder …") by id.
///
/// Schema entities that Apple's own apps make syncable (`notes.note`,
/// `reminders.list`, `calendar.event`, …) are syncable without it; use
/// `@AssistantSyncable(false)` to opt one out. On any other schema entity or
/// `@AssistantEntity` class, `@AssistantSyncable()` opts in.
///
/// Syncable ids must be stable: the `@EntityId()` of an item must never
/// change, on this device or another.
class AssistantSyncable {
  const AssistantSyncable([this.syncable = true]);

  final bool syncable;
}

/// Lets the user undo what Siri did through this class's schema intents
/// (`UndoableIntent`, iOS 26 / macOS 26).
///
/// * Creates, updates and deletes that arrive through the inbox are undone
///   for you: undoing a create deletes the item, undoing an update restores
///   the published values it changed, and undoing a delete creates the item
///   again with its id and published values. Your handler's `create`,
///   `update` and `delete` apply them like any other change.
/// * Every other intent of the class gets an `undo…` method on its handler
///   (`undoPauseTimer` for `pauseTimer`), called with the same arguments
///   (and, for intents that return items, the `result` ids) when the user
///   undoes it. Undos are queued like deferred calls.
class AssistantUndoable {
  const AssistantUndoable();
}

/// Marks this class's live intents (those that call Dart while Siri waits)
/// as `LongRunningIntent` (iOS 27 / macOS 27): the system keeps them running
/// in the background beyond the usual time limit. Report progress and watch
/// for cancellation with `AssistantCall.current`.
class AssistantLongRunning {
  const AssistantLongRunning();
}
