/// User-facing errors that stop Siri and Shortcuts with a clean message.
library;

/// An error whose [message] Siri speaks and Shortcuts shows directly, stopping
/// a multi-step shortcut without a `"Something went wrong:"` prefix.
///
/// Throw it from a `Runs.withFlutter` `@AssistantAction` function or a live
/// schema handler method when the request cannot proceed:
///
/// ```dart
/// if (account == null) {
///   throw const AssistantError('Sign in to send messages.');
/// }
/// ```
class AssistantError implements Exception {
  const AssistantError(this.message);

  /// What Siri speaks or Shortcuts displays.
  final String message;

  /// The bridge error code `AssistantBridge` maps to
  /// `AssistantActionError.userFacing`.
  static const code = 'assistant_actions.user_error';

  @override
  String toString() => message;

  @override
  bool operator ==(Object other) => other is AssistantError && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
