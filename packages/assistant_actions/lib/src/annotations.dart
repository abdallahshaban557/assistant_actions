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
  const AssistantActionsApp({required this.name, this.shortcutTileColor});

  /// The app's name, as used by `{app}` in shortcut phrases.
  final String name;

  /// The color of the app's App Shortcut tiles in the Shortcuts app.
  final ShortcutTileColor? shortcutTileColor;
}

/// Lets Siri run the app's Dart on iOS without opening the app: put it on a
/// top-level function that returns the registry `AssistantActions.start`
/// takes (or a `Future` of it), in `lib/assistant_actions.dart` or a library
/// it imports.
///
/// ```dart
/// @AssistantBackground()
/// Future<AssistantActionsRegistry> appRegistry() async {
///   await Database.open();
///   return assistantActionsRegistry(taskItem: TaskHandler(), ...);
/// }
/// ```
///
/// When an intent needs Dart and the app has no Flutter engine (Siri launched
/// it in the background), the runtime starts a headless engine that builds
/// the registry with this function and answers there, instead of asking to
/// open the app. [Runs.withFlutter] actions and live schema intents run
/// there; intents that open the app ([AssistantAction.opensApp], schema
/// intents such as `system.open` or `journal.createAudioEntry`) still come to
/// the foreground. The headless engine has its own Dart memory, so the app's
/// data must be persisted, not only held in memory. Check
/// `AssistantActions.inBackground` to tell the two engines apart.
///
/// The app's `main` should use the same function:
/// `await AssistantActions.start(await appRegistry());`.
class AssistantBackground {
  const AssistantBackground({this.applyQueued = true});

  /// Also apply queued intents (`Runs.deferred` actions and schema creates,
  /// updates, deletes and calls) right away on the headless engine, instead
  /// of at the next launch. Siri waits for Dart to start before it answers.
  final bool applyQueued;
}

/// Where an action's Dart function runs.
enum Runs {
  /// Works without Flutter running. The call is queued and Siri replies at
  /// once with [AssistantAction.dialog]. The function runs with the queued
  /// arguments when the app next starts, resumes or is already running.
  deferred,

  /// Calls the function live and speaks what it returns. On iOS the app is
  /// brought to the foreground first if it isn't active, unless the app sets
  /// up [AssistantBackground], in which case Dart answers in the background
  /// (set [AssistantAction.opensApp] for actions that need the app's
  /// screen). macOS answers in place.
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
    this.liveActivity = false,
    this.searchKeywords = const [],
    this.isDiscoverable = true,
    this.opensApp = false,
  });

  final String title;
  final String? description;
  final Runs runs;

  /// A question Siri asks before running the action, such as
  /// `'Remove {recipe} from your list?'`. `{name}` is the parameter `name`.
  /// If the user says no, nothing runs or is queued.
  final String? confirm;

  /// The action starts, updates or ends an `AssistantLiveActivity`, so the
  /// intent is a `LiveActivityIntent` on iOS: the system runs it in the app's
  /// process and lets it start Live Activities from the background. When Dart
  /// is already running (say, the app is recording in the background), the
  /// function runs at once, without bringing the app forward. Otherwise
  /// [Runs.deferred] queues the call as usual and [Runs.withFlutter] brings
  /// the app forward first; with [AssistantBackground], both start Dart on the
  /// headless engine instead (for [Runs.deferred], unless `applyQueued` is
  /// false). No effect on macOS, which has no Live Activities.
  final bool liveActivity;

  /// More words Shortcuts and Spotlight find the action by.
  final List<String> searchKeywords;

  /// Whether the action shows in Shortcuts and Spotlight. Hidden actions can't
  /// be App Shortcuts.
  final bool isDiscoverable;
  /// The action shows something in the app, so it always brings the app to
  /// the foreground (and, on macOS, activates it), even when Dart could run
  /// in the background with [AssistantBackground]. [Runs.withFlutter] only.
  final bool opensApp;

  /// What Siri says when the action finishes. `{name}` is replaced with the
  /// parameter `name`. Required for [Runs.deferred]; for [Runs.withFlutter]
  /// it's used when the function returns nothing.
  ///
  /// A [Runs.withFlutter] function can also return a `String` to say, an
  /// `AssistantReply` to say something and show a result card, or a value
  /// for Shortcuts (see [ActionResult]); `AssistantReply<T>` returns a value
  /// [T] too.
  final String? dialog;

  /// Siri phrases that run the action with no setup by the user.
  final AppShortcut? shortcut;
}

/// A value an [AssistantAction] returns to Shortcuts, plus what Siri says.
///
/// Return it (or the value alone) from a `Runs.withFlutter` action so a
/// shortcut can use the result in its next step:
///
/// ```dart
/// @AssistantAction(title: 'Count Open Tasks', runs: Runs.withFlutter)
/// Future<ActionResult<int>> countOpenTasks() async =>
///     ActionResult(open.length, dialog: 'You have ${open.length} open tasks.');
/// ```
///
/// [T] is a `String`, `int`, `double`, `bool`, `DateTime`, `Uri`, `Duration`,
/// an `@AssistantEnum` or schema enum, `AssistantPerson`, `AssistantFile`, an
/// `@AssistantEntity` or schema entity class (published first, so Siri finds
/// it by id), or a `List` of one of these. A plain `Future<String>` is still
/// only what Siri says.
class ActionResult<T> {
  const ActionResult(this.value, {this.dialog});

  final T value;

  /// What Siri says; the action's `dialog` when null.
  final String? dialog;
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

  /// Each phrase must contain `{app}`, the app's name. `{name}` stands for
  /// parameter `name` when it is an entity or enum, so "Cook {recipe} in
  /// {app}" works for each published recipe and each enum case.
  final List<String> phrases;
  final String shortTitle;

  /// An SF Symbol name, such as `checklist`.
  final String systemImage;
}

/// An App Shortcut for one of Apple's App Schema intents the app turned on,
/// such as `camera.startCapture`. Put it on the class whose annotation turns
/// the intent on (the entity class, or the `@…Intents` class); `system.open`
/// goes on the entity class it opens.
///
/// ```dart
/// @IntentShortcut('camera.startCapture',
///     phrases: ['Take a {captureMode} with {app}'], shortTitle: 'Camera', systemImage: 'camera')
/// @CameraIntents(startCapture: true)
/// class CameraHandler implements CameraAssistantHandler { ... }
/// ```
///
/// Schema intents need iOS 18 or later, so the Runner's deployment target
/// must be iOS 17.4 / macOS 14.4 or later for App Shortcuts to check the OS.
class IntentShortcut extends AppShortcut {
  const IntentShortcut(this.intent, {required super.phrases, required super.shortTitle, required super.systemImage});

  /// The schema intent's id, such as `camera.startCapture`.
  final String intent;
}

/// The colors of an app's App Shortcut tiles (`ShortcutTileColor`).
enum ShortcutTileColor {
  red,
  orange,
  tangerine,
  yellow,
  lime,
  teal,
  lightBlue,
  blue,
  navy,
  grape,
  purple,
  pink,
  grayBlue,
  grayGreen,
  grayBrown,
}

/// Exposes one of the app's enums as an App Enum, so actions can take it as
/// a parameter (and shortcut phrases can name its cases).
///
/// ```dart
/// @AssistantEnum(title: 'Size')
/// enum Size {
///   small,
///   @CaseTitle('Extra large', synonyms: ['XL'])
///   extraLarge,
/// }
/// ```
class AssistantEnum {
  const AssistantEnum({required this.title});

  /// The type's name, such as `Size`.
  final String title;
}

/// How Siri shows and hears one case of an [AssistantEnum]. Cases without
/// it are titled from their name (`extraLarge` → "Extra Large").
class CaseTitle {
  const CaseTitle(this.title, {this.synonyms = const []});

  final String title;

  /// Other words for the case.
  final List<String> synonyms;
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
