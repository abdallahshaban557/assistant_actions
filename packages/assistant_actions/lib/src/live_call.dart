import 'dart:async';

import 'package:flutter/foundation.dart' show internal;

import 'runtime.dart';

/// One option [AssistantCall.choose] shows the user mid-call (iOS 26 /
/// macOS 26).
class AssistantChoice {
  const AssistantChoice(this.id, this.title, {this.destructive = false});

  /// Returned by [AssistantCall.choose] when the user picks this option.
  final String id;

  /// What Siri shows and speaks for this option.
  final String title;

  /// Styles the option as destructive.
  final bool destructive;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        if (destructive) 'destructive': true,
      };

  @override
  bool operator ==(Object other) =>
      other is AssistantChoice &&
      other.id == id &&
      other.title == title &&
      other.destructive == destructive;

  @override
  int get hashCode => Object.hash(id, title, destructive);
}

/// Thrown when the user cancels a mid-call [AssistantCall.choose] prompt.
@internal
class AssistantPromptCancelled implements Exception {
  const AssistantPromptCancelled();

  @override
  String toString() => 'User cancelled the prompt.';
}

/// A live call from Siri into the app's Dart code: a `Runs.withFlutter`
/// action or a schema intent that waits for Dart.
///
/// While a handler runs for one, [AssistantCall.current] is that call, so the
/// handler can report progress (the intent is a `ProgressReportingIntent`),
/// notice when the user cancels (`CancellableIntent`, iOS 26.4 /
/// macOS 26.4), and ask Siri follow-up questions mid-execution ([confirm],
/// [choose], [requestValue], [disambiguate]):
///
/// ```dart
/// final call = AssistantCall.current;
/// for (var i = 0; i < pages.length; i++) {
///   if (call?.isCancelled ?? false) return;
///   await export(pages[i]);
///   await call?.reportProgress(completed: i + 1, total: pages.length);
/// }
/// ```
final class AssistantCall {
  AssistantCall._(this.id);

  /// The argument key Swift passes the call id in.
  static const argument = '__assistant_call';

  /// The action Swift performs to cancel a call.
  static const cancelAction = 'assistant_actions.cancel';

  /// The action Swift performs to deliver a mid-call prompt response.
  static const promptReplyAction = 'assistant_actions.promptReply';

  /// Bridge error code for a user-cancelled mid-call prompt.
  @internal
  static const cancelledErrorCode = 'assistant_actions.cancelled';

  static final _running = <String, AssistantCall>{};

  /// The live call the current code runs for, if any.
  static AssistantCall? get current => Zone.current[#assistant_actions.call] as AssistantCall?;

  /// Swift's id for the call.
  final String id;

  final _cancelled = Completer<void>();
  final _pendingPrompts = <String, Completer<Map<String, Object?>>>{};
  int _nextPromptId = 0;

  /// Siri or the user cancelled the call.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the call is cancelled.
  Future<void> get whenCancelled => _cancelled.future;

  /// Shows progress in Siri and Shortcuts: [completed] of [total] units.
  /// Returns whether Swift took it (false outside a live call).
  Future<bool> reportProgress({required int completed, required int total}) async {
    if (isCancelled) return false;
    final result = await AssistantActions.callSwift('call.progress', {'call': id, 'completed': completed, 'total': total});
    return result == true;
  }

  /// Asks Siri to confirm [prompt] mid-execution and returns `true` when the
  /// user agrees, or `false` if they cancel or dismiss.
  Future<bool> confirm(String prompt, {String? actionLabel}) async {
    final reply = await _prompt('confirm', {
      'prompt': prompt,
      if (actionLabel != null) 'actionLabel': actionLabel,
    });
    return reply?['value'] == true;
  }

  /// Asks the user to pick one of [choices] mid-execution (iOS 26 / macOS 26)
  /// and returns the chosen [AssistantChoice.id].
  Future<String> choose(String prompt, List<AssistantChoice> choices) async {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'Must not be empty');
    }
    final reply = await _prompt('choose', {
      'prompt': prompt,
      'choices': [for (final c in choices) c.toJson()],
    });
    if (reply != null && reply['error'] is String) {
      throw StateError(reply['error'] as String);
    }
    if (reply?['value'] case final String chosen) return chosen;
    throw const AssistantPromptCancelled();
  }

  /// Asks Siri for a value for intent parameter [paramName] (`$<param>.requestValue`)
  /// and returns the decoded value, or `null` if the user cancels.
  Future<T?> requestValue<T>(String paramName, {String? prompt}) async {
    final reply = await _prompt('requestValue', {
      'param': paramName,
      if (prompt != null) 'prompt': prompt,
    });
    if (reply == null || reply['cancelled'] == true) return null;
    if (reply['error'] case final String error) {
      throw ArgumentError.value(paramName, 'paramName', error);
    }
    return AssistantActions.decodePromptValue<T>(reply['value']);
  }

  /// Asks Siri to disambiguate intent parameter [paramName] among [choices]
  /// (`$<param>.requestDisambiguation`) and returns the chosen value, or
  /// `null` if the user cancels.
  Future<T?> disambiguate<T>(String paramName, List<T> choices, {String? prompt}) async {
    if (choices.isEmpty) return null;
    final encoded = [for (final item in choices) AssistantActions.encodePromptValue<T>(item)];
    final reply = await _prompt('disambiguate', {
      'param': paramName,
      'choices': encoded,
      if (prompt != null) 'prompt': prompt,
    });
    if (reply == null || reply['cancelled'] == true) return null;
    if (reply['error'] case final String error) {
      throw ArgumentError.value(paramName, 'paramName', error);
    }
    return AssistantActions.decodePromptValue<T>(reply['value']);
  }

  Future<Map<String, Object?>?> _prompt(String kind, Map<String, Object?> payload) async {
    if (isCancelled) return null;
    final promptId = '${++_nextPromptId}';
    final completer = _pendingPrompts[promptId] = Completer<Map<String, Object?>>();
    final response = await AssistantActions.callSwift('call.prompt', {
      'call': id,
      'promptId': promptId,
      'kind': kind,
      ...payload,
    });
    if (response is! Map) {
      _pendingPrompts.remove(promptId);
      return null;
    }
    final map = response.cast<String, Object?>();
    if (map['pending'] == true) {
      return completer.future;
    }
    _pendingPrompts.remove(promptId);
    return map;
  }

  void _cancelPendingPrompts() {
    if (_pendingPrompts.isEmpty) return;
    final pending = _pendingPrompts.values.toList();
    _pendingPrompts.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(const {'cancelled': true});
      }
    }
  }

  /// Runs [body] as call [id] (from the arguments Swift sent).
  static Future<T> run<T>(String? id, Future<T> Function() body) {
    if (id == null) return body();
    final call = _running[id] = AssistantCall._(id);
    return runZoned(body, zoneValues: {#assistant_actions.call: call}).whenComplete(() {
      call._cancelPendingPrompts();
      _running.remove(id);
    });
  }

  /// Swift cancelled call [id]. Returns whether it was running.
  static bool cancel(String? id) {
    final call = _running[id];
    if (call == null) return false;
    if (!call._cancelled.isCompleted) call._cancelled.complete();
    call._cancelPendingPrompts();
    return true;
  }

  /// Delivers Swift's response to a pending mid-call prompt.
  @internal
  static bool completePrompt(Map<String, Object?> args) {
    final call = _running[args['call']];
    final completer = call?._pendingPrompts.remove(args['promptId']);
    if (completer == null || completer.isCompleted) return false;
    completer.complete(args);
    return true;
  }
}
