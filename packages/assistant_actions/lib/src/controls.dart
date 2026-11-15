/// Control Center, Lock Screen and Action Button controls (`ControlWidget`),
/// and configurable Home Screen / Lock Screen / Desktop widget intents
/// (`WidgetConfigurationIntent`).
library;

/// Exposes an `@AssistantAction` top-level function as a `ControlWidget`
/// (iOS 18+ / macOS 26+) in Control Center, on the Lock Screen, and on the
/// Action Button.
///
/// * On a `void` / action function taking no required parameters, generates a
///   `ControlWidgetButton` that triggers the action.
/// * On an action function with a `bool value` parameter, generates a
///   `ControlWidgetToggle` backed by a `SetValueIntent`, reading its state from
///   [toggleSnapshotCollection] / [toggleEntityId] / [toggleField] when given
///   or from shared `UserDefaults` otherwise.
///
/// ```dart
/// @AssistantControl(id: 'start_timer', title: 'Start Timer', systemImage: 'timer')
/// @AssistantAction(title: 'Start Timer', dialog: 'Timer started.')
/// Future<void> startTimer() async { ... }
///
/// @AssistantControl(
///   id: 'focus_mode',
///   title: 'Focus Mode',
///   systemImage: 'moon.fill',
///   toggleSnapshotCollection: 'AppSettings',
///   toggleEntityId: 'default',
///   toggleField: 'focusEnabled',
/// )
/// @AssistantAction(title: 'Set Focus Mode', dialog: 'Updated.')
/// Future<void> setFocusMode(bool value) async { ... }
/// ```
class AssistantControl {
  const AssistantControl({
    required this.id,
    required this.title,
    required this.systemImage,
    this.subtitle,
    this.toggleSnapshotCollection,
    this.toggleEntityId,
    this.toggleField,
  });

  /// Stable kind identifier for `StaticControlConfiguration(kind:)`.
  final String id;

  /// Label shown on the control in Control Center and the control gallery.
  final String title;

  /// SF Symbol name shown on the control, such as `'timer'` or `'bolt.fill'`.
  final String systemImage;

  /// Optional subtitle / description shown with the control.
  final String? subtitle;

  /// Optional published entity collection whose record supplies a toggle's
  /// current `bool` value.
  final String? toggleSnapshotCollection;

  /// Optional entity id within [toggleSnapshotCollection]. When null, the
  /// first published record in [toggleSnapshotCollection] is used.
  final String? toggleEntityId;

  /// Field name on [toggleSnapshotCollection] holding the toggle's `bool`
  /// state.
  final String? toggleField;
}

/// Generates a `WidgetConfigurationIntent` struct from a top-level
/// configuration function or class so Home Screen, Lock Screen and macOS
/// Desktop widgets in `AssistantWidgets` can let users pick `@AssistantEntity`
/// items, `@AssistantEnum` cases, strings, booleans, or numbers.
///
/// ```dart
/// @AssistantWidgetConfig(
///   id: 'pinned_task',
///   title: 'Pinned Task',
///   description: 'Choose a task to pin on your Home Screen.',
/// )
/// void pinnedTaskWidget(
///   @Param(title: 'Task') TaskItem? task, {
///   @Param(title: 'Show Subtasks') bool showSubtasks = true,
/// }) {}
/// ```
class AssistantWidgetConfig {
  const AssistantWidgetConfig({
    required this.id,
    required this.title,
    this.description,
  });

  /// Unique identifier for the widget configuration.
  final String id;

  /// Title shown when editing the widget.
  final String title;

  /// Description shown in the widget gallery / configuration sheet.
  final String? description;
}
