import 'dart:async';

import 'runtime.dart';

/// A live call from Siri into the app's Dart code: a `Runs.withFlutter`
/// action or a schema intent that waits for Dart.
///
/// While a handler runs for one, [AssistantCall.current] is that call, so the
/// handler can report progress (the intent is a `ProgressReportingIntent`)
/// and notice when the user cancels (`CancellableIntent`, iOS 26.4 /
/// macOS 26.4):
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

  static final _running = <String, AssistantCall>{};

  /// The live call the current code runs for, if any.
  static AssistantCall? get current => Zone.current[#assistant_actions.call] as AssistantCall?;

  /// Swift's id for the call.
  final String id;

  final _cancelled = Completer<void>();

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

  /// Runs [body] as call [id] (from the arguments Swift sent).
  static Future<T> run<T>(String? id, Future<T> Function() body) {
    if (id == null) return body();
    final call = _running[id] = AssistantCall._(id);
    return runZoned(body, zoneValues: {#assistant_actions.call: call}).whenComplete(() => _running.remove(id));
  }

  /// Swift cancelled call [id]. Returns whether it was running.
  static bool cancel(String? id) {
    final call = _running[id];
    if (call == null) return false;
    if (!call._cancelled.isCompleted) call._cancelled.complete();
    return true;
  }
}
