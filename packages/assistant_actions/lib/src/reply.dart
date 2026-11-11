/// What live actions and schema intents tell Siri besides their value.
library;

import 'dart:convert';

import 'registry.dart' show AssistantValue;
import 'runtime.dart' show AssistantActions;

/// What a live action or intent handler tells Siri: what to say, a result
/// card to show, and the [value] the intent returns.
///
/// Return it from a `Runs.withFlutter` `@AssistantAction` function, or from
/// a handler method of an intent listed in the annotation's `replies`:
///
/// ```dart
/// @CameraIntents(startCapture: true, replies: {'startCapture'})
/// class CameraHandler implements CameraAssistantHandler {
///   @override
///   Future<AssistantReply<void>> startCapture({required CaptureMode captureMode}) async =>
///       AssistantReply(
///         dialog: 'Camera ready.',
///         card: AssistantCard(title: 'Camera', subtitle: captureMode.name),
///       );
/// }
/// ```
///
/// [T] is what the method returns without replies: `String` for one item's
/// id, `List<String>` for several, `AssistantUnion`, or `void`.
class AssistantReply<T> {
  const AssistantReply({this.value, this.dialog, this.card})
      : choices = const [],
        prompt = null;

  /// Several items that match, by id, for an intent that returns one item:
  /// Siri asks the user which one ([prompt], such as "Which tab?") and
  /// returns it. Needs iOS 26 or macOS 26; earlier, Siri takes the first.
  const AssistantReply.choose(this.choices, {this.prompt, this.dialog, this.card}) : value = null;

  /// The value the intent returns: the id(s) or union case(s) the handler
  /// method would return without replies. Null for `void`.
  final T? value;

  /// What Siri says. Null uses the annotation's dialog, else "Done.".
  final String? dialog;

  /// A result card Siri shows.
  final AssistantCard? card;

  /// Ids of items to choose from; see [AssistantReply.choose].
  final List<String> choices;

  /// The question Siri asks when there are [choices].
  final String? prompt;

  /// The JSON the generated Swift reads (`AssistantReply` in Swift).
  Map<String, Object?> toJson() => {
        if (value != null) 'value': AssistantValue.encodeAny(value),
        if (dialog != null) 'dialog': dialog,
        if (card != null) 'card': card!.toJson(),
        if (choices.isNotEmpty) 'choices': choices,
        if (prompt != null) 'prompt': prompt,
      };

  /// [reply] as the generated registry sends it to Swift.
  static String encode(AssistantReply<Object?>? reply) => jsonEncode(reply?.toJson() ?? const {});

  /// [reply] as the generated registry sends it for an action that returns
  /// a value to Shortcuts: with [value] encoded already (an entity as its id).
  static String encodeValue(AssistantReply<Object?> reply, Object? value) =>
      jsonEncode({...reply.toJson()..remove('value'), if (value != null) 'value': value});
}

/// A result card Siri shows after an action or intent: a title, a subtitle,
/// a few label and value rows, an optional image, and buttons.
///
/// ```dart
/// AssistantCard(
///   title: 'Pancakes',
///   subtitle: '20 min',
///   rows: [AssistantCardRow('Serves', '4')],
///   systemImage: 'fork.knife',
///   buttons: [AssistantCardButton('Add to list', action: 'toggleShoppingList', args: {'recipe': 'pancakes'})],
/// )
/// ```
class AssistantCard {
  const AssistantCard({
    required this.title,
    this.subtitle,
    this.rows = const [],
    this.imagePath,
    this.systemImage,
    this.buttons = const [],
  });

  final String title;
  final String? subtitle;

  /// Shown in order, label on the left. Keep it to a few.
  final List<AssistantCardRow> rows;

  /// A local image file (PNG, JPEG or HEIC) shown beside the title, such as
  /// one in the app's documents or Application Support folder.
  final String? imagePath;

  /// An SF Symbol name, shown when there's no [imagePath].
  final String? systemImage;

  /// Buttons under the rows that run an action in Dart and update the card
  /// (interactive snippets, iOS 26 / macOS 26). Earlier, the card shows
  /// without them. Keep it to one or two.
  final List<AssistantCardButton> buttons;

  Map<String, Object?> toJson() => {
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (rows.isNotEmpty) 'rows': [for (final r in rows) [r.label, r.value]],
        if (imagePath != null) 'imagePath': imagePath,
        if (systemImage != null) 'systemImage': systemImage,
        if (buttons.isNotEmpty) 'buttons': [for (final b in buttons) b.toJson()],
      };
}

/// One row of an [AssistantCard].
class AssistantCardRow {
  const AssistantCardRow(this.label, this.value);

  final String label;
  final String value;
}

/// A button on an [AssistantCard]: pressing it runs [action] in Dart with
/// [args], without leaving Siri, and the card then shows the `card` of the
/// `AssistantReply` the action returns (or stays as it was).
///
/// [action] is the id of an `@AssistantAction` function (its name) or of a
/// schema intent (such as `Countdown.pauseTimer`): a key of the generated
/// registry's `actions`. [args] are its parameters by name, encoded as Swift
/// would send them: an item as its id, an enum as its case name.
///
/// ```dart
/// @AssistantAction(title: 'Toggle on List', runs: Runs.withFlutter, isDiscoverable: false)
/// Future<AssistantReply<void>> toggleOnList(Recipe recipe) async {
///   ...
///   return AssistantReply(card: recipeCard(recipe));   // the card after the press
/// }
///
/// AssistantCardButton('Add to list', action: 'toggleOnList', args: {'recipe': recipe.id}, systemImage: 'cart')
/// ```
///
/// Needs iOS 26 or macOS 26 (`SnippetIntent`); earlier, cards show without
/// buttons. With `@AssistantBackground()`, a press runs Dart without opening
/// the app on iOS, like other live actions.
class AssistantCardButton {
  const AssistantCardButton(this.title,
      {required this.action, this.args = const {}, this.systemImage, this.destructive = false});

  final String title;

  /// The id of the action the button runs.
  final String action;

  /// The action's parameters by name.
  final Map<String, Object?> args;

  /// An SF Symbol shown before [title].
  final String? systemImage;

  /// Shows the button as destructive (in red).
  final bool destructive;

  /// Throws an [ArgumentError] when the app has no action [action].
  Map<String, Object?> toJson() {
    if (AssistantActions.hasAction(action) == false) {
      throw ArgumentError.value(action, 'action',
          'Card button "$title" runs no known action. Use the id of an @AssistantAction function or a schema intent');
    }
    return {
      'title': title,
      'action': action,
      'args': {for (final MapEntry(:key, :value) in args.entries) key: AssistantValue.encodeAny(value)},
      if (systemImage != null) 'systemImage': systemImage,
      if (destructive) 'destructive': true,
    };
  }
}
