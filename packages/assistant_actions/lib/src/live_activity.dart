import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'registry.dart';
import 'runtime.dart';

/// An interactive button rendered on a Live Activity (Lock Screen and Dynamic
/// Island expanded bottom region, up to 2 buttons).
///
/// Pressing the button runs [actionId] via an extension-safe
/// `LiveActivityIntent` that dispatches to the app's `AssistantBridge` when
/// Flutter is running or queues the call in `AssistantInbox` otherwise.
class AssistantLiveActivityButton {
  const AssistantLiveActivityButton({
    required this.label,
    required this.actionId,
    this.systemImage,
    this.args = const {},
  });

  /// Button title shown on the Lock Screen and Dynamic Island.
  final String label;

  /// Id of the `@AssistantAction` function or schema intent to run.
  final String actionId;

  /// Optional SF Symbol shown alongside [label].
  final String? systemImage;

  /// Arguments passed to [actionId], keyed by parameter name.
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => {
        'label': label,
        'actionId': actionId,
        if (systemImage != null) 'systemImage': systemImage,
        if (args.isNotEmpty)
          'args': jsonEncode({
            for (final MapEntry(:key, :value) in args.entries) key: AssistantValue.encodeAny(value),
          }),
      };

  @override
  bool operator ==(Object other) =>
      other is AssistantLiveActivityButton &&
      other.label == label &&
      other.actionId == actionId &&
      other.systemImage == systemImage &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => Object.hash(label, actionId, systemImage);
}

/// What a Live Activity shows: the generic view the widget extension draws
/// (`dart run assistant_actions:install --widgets`) has an SF Symbol, a title
/// and subtitle, a timer, a progress bar, and up to 2 interactive [buttons].
/// [data] carries anything else, for views of your own.
class AssistantActivityContent {
  const AssistantActivityContent({
    required this.title,
    this.subtitle,
    this.systemImage,
    this.progress,
    this.timerStart,
    this.timerEnd,
    this.buttons = const [],
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

  /// Interactive buttons shown on the Lock Screen and Dynamic Island expanded
  /// bottom region (up to 2 rendered by the default widget).
  final List<AssistantLiveActivityButton> buttons;

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
          if (buttons.isNotEmpty) 'buttons': [for (final b in buttons) b.toJson()],
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

  /// Internal action Swift calls to push APNs token updates to Dart.
  @internal
  static const pushTokenAction = 'assistant_actions.liveActivityPushToken';

  static StreamController<String>? _pushToStartController;
  static String? _lastPushToStartToken;
  static final _activityTokenControllers = <String, StreamController<String>>{};
  static final _lastActivityTokens = <String, String>{};

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
  /// Set [enablePush] to true to request an APNs push token (`pushType: .token`),
  /// readable via [pushToken] and [pushTokens].
  ///
  /// iOS only starts activities while the app is in the foreground, or from
  /// an intent that conforms to `LiveActivityIntent`
  /// (`@AssistantAction(liveActivity: true)`) or `AudioRecordingIntent`
  /// (`journal.createAudioEntry`). Throws what ActivityKit throws otherwise.
  static Future<AssistantLiveActivity?> start(
    AssistantActivityContent content, {
    String kind = 'default',
    Map<String, Object?> data = const {},
    bool enablePush = false,
  }) async =>
      _from(await AssistantActions.callSwift('liveActivity.start', {
        'kind': kind,
        if (data.isNotEmpty) 'data': jsonEncode(data),
        if (enablePush) 'enablePush': true,
        ...content.toJson(),
      }));

  /// Hex-encoded APNs push-to-start tokens (`Activity<AssistantActivityAttributes>.pushToStartTokenUpdates`,
  /// iOS 17.2+). Empty on macOS.
  static Stream<String> pushToStartTokens() {
    var controller = _pushToStartController;
    if (controller == null) {
      _lastPushToStartToken = null;
      controller = StreamController<String>.broadcast(
        onListen: () {
          unawaited(AssistantActions.callSwift('liveActivity.observePushToStart').then((initial) {
            if (initial is String && initial.isNotEmpty && _lastPushToStartToken != initial) {
              _lastPushToStartToken = initial;
              _pushToStartController?.add(initial);
            }
          }));
        },
        onCancel: () {
          _pushToStartController = null;
          _lastPushToStartToken = null;
          unawaited(AssistantActions.callSwift('liveActivity.stopPushToStart'));
        },
      );
      _pushToStartController = controller;
    }
    return controller.stream;
  }

  /// The activity's current hex-encoded APNs push token, or null if the
  /// activity was started without `enablePush: true`, hasn't received one yet,
  /// or has ended.
  Future<String?> pushToken() async {
    final token = await AssistantActions.callSwift('liveActivity.pushToken', {'id': id});
    return token is String && token.isNotEmpty ? token : null;
  }

  /// Hex-encoded APNs push token updates for this activity
  /// (`activity.pushTokenUpdates`).
  Stream<String> pushTokens() {
    var controller = _activityTokenControllers[id];
    if (controller == null) {
      _lastActivityTokens.remove(id);
      controller = StreamController<String>.broadcast(
        onListen: () {
          unawaited(AssistantActions.callSwift('liveActivity.observePushTokens', {'id': id}).then((initial) {
            if (initial is String && initial.isNotEmpty && _lastActivityTokens[id] != initial) {
              _lastActivityTokens[id] = initial;
              _activityTokenControllers[id]?.add(initial);
            }
          }));
        },
        onCancel: () {
          _activityTokenControllers.remove(id);
          _lastActivityTokens.remove(id);
          unawaited(AssistantActions.callSwift('liveActivity.stopPushTokens', {'id': id}));
        },
      );
      _activityTokenControllers[id] = controller;
    }
    return controller.stream;
  }

  /// Delivers a push token event sent from Swift.
  @internal
  static void deliverPushToken(Map<String, Object?> args) {
    final kind = args['kind'];
    final token = args['token'];
    if (kind == 'pushToStart') {
      if (token is String && token.isNotEmpty && _lastPushToStartToken != token) {
        _lastPushToStartToken = token;
        _pushToStartController?.add(token);
      }
      return;
    }
    if (kind == 'activity' && args['id'] is String) {
      final activityId = args['id'] as String;
      if (token is String && token.isNotEmpty && _lastActivityTokens[activityId] != token) {
        _lastActivityTokens[activityId] = token;
        _activityTokenControllers[activityId]?.add(token);
      }
      if (args['done'] == true) {
        _lastActivityTokens.remove(activityId);
        unawaited(_activityTokenControllers.remove(activityId)?.close());
      }
    }
  }

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
