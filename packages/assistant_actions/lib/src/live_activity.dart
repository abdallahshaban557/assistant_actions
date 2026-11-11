import 'dart:convert';

import 'registry.dart';
import 'runtime.dart';

/// What a Live Activity shows: the generic view the widget extension draws
/// (`dart run assistant_actions:install --widgets`) has an SF Symbol, a title
/// and subtitle, a timer and a progress bar. [data] carries anything else,
/// for views of your own.
class AssistantActivityContent {
  const AssistantActivityContent({
    required this.title,
    this.subtitle,
    this.systemImage,
    this.progress,
    this.timerStart,
    this.timerEnd,
    this.data = const {},
    this.staleDate,
    this.relevanceScore = 0,
  });

  final String title;
  final String? subtitle;

  /// An SF Symbol name, such as `mic.fill`.
  final String? systemImage;

  /// From 0 to 1.
  final double? progress;

  /// With [timerEnd], the view counts down to [timerEnd]; alone, it counts up
  /// from [timerStart] (how long a recording has run).
  final DateTime? timerStart;
  final DateTime? timerEnd;

  /// JSON-able values for your own SwiftUI views, which read them as
  /// `context.state.dataObject`.
  final Map<String, Object?> data;

  /// When the system shows the content as out of date.
  final DateTime? staleDate;

  /// Which of the app's activities the Dynamic Island prefers (higher wins).
  final double relevanceScore;

  /// What crosses to Swift.
  Map<String, Object?> toJson() => {
        'content': {
          'title': title,
          if (subtitle != null) 'subtitle': subtitle,
          if (systemImage != null) 'systemImage': systemImage,
          if (progress != null) 'progress': progress,
          if (timerStart != null) 'timerStart': AssistantValue.encodeDate(timerStart),
          if (timerEnd != null) 'timerEnd': AssistantValue.encodeDate(timerEnd),
          if (data.isNotEmpty) 'data': jsonEncode(data),
        },
        if (staleDate != null) 'staleDate': AssistantValue.encodeDate(staleDate),
        'relevanceScore': relevanceScore,
      };
}

/// How an ended Live Activity leaves the Lock Screen.
enum AssistantActivityDismissal {
  /// The system's default: it stays for up to four hours.
  standard,

  /// At once.
  immediate,

  /// At the `dismissAt` passed to [AssistantLiveActivity.end].
  after,
}

/// A Live Activity (ActivityKit, iOS 16.1+) on the Lock Screen and in the
/// Dynamic Island, started and updated from Dart.
///
/// Needs `AssistantActions.start` to have run, `NSSupportsLiveActivities` in
/// the app's Info.plist, and a widget extension that draws
/// `AssistantActivityAttributes`; `dart run assistant_actions:install
/// --widgets` sets all three up. On macOS, and on iOS with Live Activities
/// turned off, [start] returns null.
///
/// ```dart
/// final activity = await AssistantLiveActivity.start(
///   AssistantActivityContent(title: 'Recording', systemImage: 'mic.fill', timerStart: DateTime.now()),
///   kind: 'recording',
/// );
/// // …
/// await activity?.end(dismissal: AssistantActivityDismissal.immediate);
/// ```
class AssistantLiveActivity {
  const AssistantLiveActivity._(this.id, this.kind, this.state);

  static AssistantLiveActivity? _from(Object? json) => switch (json) {
        {'id': final String id, 'kind': final String kind} =>
          AssistantLiveActivity._(id, kind, (json as Map)['state'] as String? ?? 'active'),
        _ => null,
      };

  /// ActivityKit's id for the activity.
  final String id;

  /// What it is, as passed to [start].
  final String kind;

  /// `active`, `stale`, `ended`, `dismissed` or `pending` when last read.
  final String state;

  /// Whether the user allows Live Activities for the app. False on macOS.
  static Future<bool> areEnabled() async => await AssistantActions.callSwift('liveActivity.enabled') == true;

  /// Starts a Live Activity showing [content], or returns null where Live
  /// Activities aren't available. [kind] and [data] are fixed for its
  /// lifetime; a widget of your own can draw kinds differently.
  ///
  /// iOS only starts activities while the app is in the foreground, or from
  /// an intent that conforms to `LiveActivityIntent`
  /// (`@AssistantAction(liveActivity: true)`) or `AudioRecordingIntent`
  /// (`journal.createAudioEntry`). Throws what ActivityKit throws otherwise.
  static Future<AssistantLiveActivity?> start(
    AssistantActivityContent content, {
    String kind = 'default',
    Map<String, Object?> data = const {},
  }) async =>
      _from(await AssistantActions.callSwift('liveActivity.start', {
        'kind': kind,
        if (data.isNotEmpty) 'data': jsonEncode(data),
        ...content.toJson(),
      }));

  /// The app's activities that are still around.
  static Future<List<AssistantLiveActivity>> running() async => [
        for (final json in (await AssistantActions.callSwift('liveActivity.list') as List?) ?? const [])
          if (_from(json) case final activity?) activity,
      ];

  /// Shows [content] instead. With [alertTitle], the device lights up and
  /// shows the alert. Returns false when the activity has gone.
  Future<bool> update(AssistantActivityContent content, {String? alertTitle, String? alertBody}) async =>
      await AssistantActions.callSwift('liveActivity.update', {
        'id': id,
        ...content.toJson(),
        if (alertTitle != null) 'alert': {'title': alertTitle, 'body': alertBody ?? ''},
      }) ==
      true;

  /// Ends the activity, showing [content] (if given) until it's dismissed.
  /// Returns false when it had already gone.
  Future<bool> end({
    AssistantActivityContent? content,
    AssistantActivityDismissal dismissal = AssistantActivityDismissal.standard,
    DateTime? dismissAt,
  }) async {
    if (dismissal == AssistantActivityDismissal.after && dismissAt == null) {
      throw ArgumentError.notNull('dismissAt');
    }
    return await AssistantActions.callSwift('liveActivity.end', {
          'id': id,
          ...?content?.toJson(),
          'dismissal': dismissal.name,
          if (dismissAt != null) 'dismissAt': AssistantValue.encodeDate(dismissAt),
        }) ==
        true;
  }

  @override
  bool operator ==(Object other) => other is AssistantLiveActivity && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AssistantLiveActivity($kind, $id, $state)';
}
