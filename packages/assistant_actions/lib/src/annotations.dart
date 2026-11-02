/// Annotations read by `assistant_actions_generator`.
library;

/// Marks the library that defines the app's assistant actions
/// (`lib/assistant_actions.dart`).
///
/// ```dart
/// @AssistantActionsApp(name: 'Cookbook')
/// library;
/// ```
class AssistantActionsApp {
  const AssistantActionsApp({required this.name});

  /// The app's name, as used by `{app}` in shortcut phrases.
  final String name;
}

/// Where an action's Dart function runs.
enum Runs {
  /// Works without Flutter running. The call is queued and Siri replies at
  /// once with [AssistantAction.dialog]. The function runs with the queued
  /// arguments when the app next starts, resumes or is already running.
  deferred,

  /// Calls the function live and speaks what it returns. On iOS the app is
  /// brought to the foreground first if it isn't active; macOS answers in
  /// place.
  withFlutter,
}

/// Exposes a top-level function to Siri, Shortcuts and Spotlight as an App
/// Intent. Its parameters become the intent's parameters.
class AssistantAction {
  const AssistantAction({
    required this.title,
    this.description,
    this.runs = Runs.deferred,
    this.dialog,
    this.shortcut,
  });

  final String title;
  final String? description;
  final Runs runs;

  /// What Siri says when the action finishes. `{name}` is replaced with the
  /// parameter `name`. Required for [Runs.deferred]; for [Runs.withFlutter]
  /// it's used when the function returns nothing.
  final String? dialog;

  /// Siri phrases that run the action with no setup by the user.
  final AppShortcut? shortcut;
}

/// Describes an [AssistantAction] parameter.
class Param {
  const Param({this.title, this.prompt});

  /// Shown in Shortcuts. Defaults to the parameter name in title case.
  final String? title;

  /// What Siri asks when the value is missing.
  final String? prompt;
}

/// An App Shortcut: phrases Siri recognises for an action.
class AppShortcut {
  const AppShortcut({required this.phrases, required this.shortTitle, required this.systemImage});

  /// Each phrase must contain `{app}`, the app's name.
  final List<String> phrases;
  final String shortTitle;

  /// An SF Symbol name, such as `checklist`.
  final String systemImage;
}

/// Exposes one of the app's classes as an App Entity, so actions can take it
/// as a parameter and Siri can search it. Publish the current items with
/// `AssistantActions.publish`.
class AssistantEntity {
  const AssistantEntity({required this.title});

  /// The type's name, such as `Recipe`.
  final String title;
}

/// The field holding an entity's unique, stable id (a `String`).
class EntityId {
  const EntityId();
}

/// The field or getter Siri shows as an entity's title.
class DisplayTitle {
  const DisplayTitle();
}

/// The field or getter Siri shows under an entity's title.
class DisplaySubtitle {
  const DisplaySubtitle();
}
