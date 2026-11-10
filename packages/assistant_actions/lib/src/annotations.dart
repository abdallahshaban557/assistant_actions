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
///
/// On a top-level `const` [SnapshotAnswer] instead, the action answers from
/// published data in Swift, without starting Flutter; [runs] and [dialog]
/// don't apply there.
class AssistantAction {
  const AssistantAction({
    required this.title,
    this.description,
    this.runs = Runs.deferred,
    this.dialog,
    this.confirm,
    this.shortcut,
  });

  final String title;
  final String? description;
  final Runs runs;

  /// A question Siri asks before running the action, such as
  /// `'Remove {recipe} from your list?'`. `{name}` is the parameter `name`.
  /// If the user says no, nothing runs or is queued.
  final String? confirm;

  /// What Siri says when the action finishes. `{name}` is replaced with the
  /// parameter `name`. Required for [Runs.deferred]; for [Runs.withFlutter]
  /// it's used when the function returns nothing.
  ///
  /// A [Runs.withFlutter] function can also return a `String` to say, or an
  /// `AssistantReply` to say something and show a result card.
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

/// An action Siri answers from the items of [T] last published with
/// `AssistantActions.publish` (plus changes Siri queued since), without
/// starting Flutter, on iOS and macOS. [T] is an `@AssistantEntity` or schema
/// entity class.
///
/// ```dart
/// @AssistantAction(title: 'Show Tasks', shortcut: AppShortcut(...))
/// const showTasks = SnapshotAnswer<TaskItem>(
///   where: {'done': false},
///   sortBy: 'due',
///   item: '{title}[ ({due})]',
///   dialog: 'You have {count} {count|task|tasks}: {items}[, and {rest} more].',
///   empty: 'Your list is clear.',
/// );
/// ```
///
/// Templates:
/// * `{field}` is a field of [T] (`{title}` is its display title). Dates read
///   like "Nov 3, 2026 at 9:00 AM", or just the date at midnight.
/// * [dialog] takes `{count}` (matching items), `{items}` (the first [limit],
///   each formatted with [item], joined by [separator]) and `{rest}` (how
///   many more there are).
/// * `{count|one|many}` (or `{rest|…}`) picks a word by number.
/// * Text in `[…]` is left out when a placeholder inside it is empty, null
///   or 0.
///
/// The generator checks field names and value types at build time.
class SnapshotAnswer<T> {
  const SnapshotAnswer({
    required this.item,
    required this.dialog,
    required this.empty,
    this.where = const {},
    this.sortBy,
    this.descending = false,
    this.limit = 5,
    this.separator = ', ',
  });

  /// Only items whose field equals the value (a `bool`, `String` or `int`).
  final Map<String, Object> where;

  /// The field to order by; items without a value come last.
  final String? sortBy;
  final bool descending;

  /// How many items `{items}` lists.
  final int limit;

  final String item;
  final String dialog;

  /// What Siri says when nothing matches.
  final String empty;

  final String separator;
}
