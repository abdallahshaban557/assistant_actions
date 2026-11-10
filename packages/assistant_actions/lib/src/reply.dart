/// What live actions and schema intents tell Siri besides their value.
library;

import 'dart:convert';

import 'registry.dart' show AssistantValue;

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
}

/// A result card Siri shows after an action or intent: a title, a subtitle,
/// a few label and value rows, and an optional image.
///
/// ```dart
/// AssistantCard(
///   title: 'Pancakes',
///   subtitle: '20 min',
///   rows: [AssistantCardRow('Serves', '4')],
///   systemImage: 'fork.knife',
/// )
/// ```
class AssistantCard {
  const AssistantCard({required this.title, this.subtitle, this.rows = const [], this.imagePath, this.systemImage});

  final String title;
  final String? subtitle;

  /// Shown in order, label on the left. Keep it to a few.
  final List<AssistantCardRow> rows;

  /// A local image file (PNG, JPEG or HEIC) shown beside the title, such as
  /// one in the app's documents or Application Support folder.
  final String? imagePath;

  /// An SF Symbol name, shown when there's no [imagePath].
  final String? systemImage;

  Map<String, Object?> toJson() => {
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (rows.isNotEmpty) 'rows': [for (final r in rows) [r.label, r.value]],
        if (imagePath != null) 'imagePath': imagePath,
        if (systemImage != null) 'systemImage': systemImage,
      };
}

/// One row of an [AssistantCard].
class AssistantCardRow {
  const AssistantCardRow(this.label, this.value);

  final String label;
  final String value;
}
