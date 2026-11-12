/// Siri polish shared by the reader, the writers and
/// `tool/validate_schemas.dart`: whether intents run on a locked device
/// (`requiresUnlock`), the sentences Shortcuts shows actions as (`summary`,
/// `summaries`) and the SF Symbols items show with (`systemImage`).
library;

import 'catalog.dart';

/// `Unlock` in Dart: App Intents' `IntentAuthenticationPolicy`, from the
/// least restrictive. The index is Apple's (`_authenticationPolicy` in the
/// schema catalog).
enum UnlockModel {
  notRequired,
  required,
  onThisDevice;

  /// The `IntentAuthenticationPolicy` case.
  String get swift => switch (this) {
        notRequired => '.alwaysAllowed',
        required => '.requiresAuthentication',
        onThisDevice => '.requiresLocalDeviceAuthentication',
      };

  /// The stricter of this and [other].
  UnlockModel atLeast(UnlockModel other) => other.index > index ? other : this;

  /// What a schema [intent] uses for this: at least what Apple's schema asks
  /// of an intent that sets a policy (`system.open` and the journal intents
  /// need [onThisDevice]). [notRequired] stays Apple's default.
  UnlockModel forSchema(IntentSchema intent) =>
      this == notRequired ? this : atLeast(UnlockModel.values[intent.authenticationPolicy.clamp(0, 2)]);
}

/// The parameters a Shortcuts [summary] names, in order.
List<String> summaryPlaceholders(String summary) =>
    [for (final m in RegExp(r'\{(\w+)\}').allMatches(summary)) m.group(1)!];

/// What is wrong with [summary] for an intent taking [params], or null.
/// [what] names it in messages (`summary`, `summaries['createReminder']`).
String? summaryError(String summary, List<String> params, String what) {
  if (summary.trim().isEmpty) return '$what is empty.';
  final seen = <String>{};
  for (final name in summaryPlaceholders(summary)) {
    if (!params.contains(name)) {
      return '$what uses {$name}, which is not a parameter'
          '${params.isEmpty ? ' (there are none)' : ' (${params.map((p) => '{$p}').join(', ')})'}.';
    }
    if (!seen.add(name)) return '$what uses {$name} twice; Shortcuts shows each parameter once.';
  }
  if (RegExp(r'\{[^}]*\}').allMatches(summary).length != seen.length) {
    return '$what has a {…} that is not a parameter name.';
  }
  return null;
}

/// Checks a schema annotation's `summaries` against the [intents] it turned
/// on, returning what is wrong, or null. [annotation] names it in messages.
String? checkSummaries(Map<String, String> summaries, List<(IntentSchema, IntentKind)> intents, String annotation) {
  final byName = {for (final (intent, _) in intents) intent.name: intent};
  for (final MapEntry(key: name, value: summary) in summaries.entries) {
    final intent = byName[name];
    if (intent == null) {
      final on = byName.keys.join(', ');
      return '$annotation: summaries names $name, which is not an intent turned on here'
          '${on.isEmpty ? ' (none are)' : ' ($on)'}.';
    }
    if (intent.id == 'system.open') {
      return '$annotation: system.open (open) can\'t have a summary: Apple\'s is used for every entity it opens.';
    }
    final error = summaryError(
        summary, [for (final p in intent.parameters) p.name], '$annotation: summaries[\'$name\'] (${intent.id})');
    if (error != null) return error;
  }
  return null;
}

/// What is wrong with SF Symbol name [name], or null.
String? systemImageError(String name) => RegExp(r'^[a-z0-9]+(\.[a-z0-9]+)*$').hasMatch(name)
    ? null
    : 'systemImage "$name" is not an SF Symbol name, such as "book" or "person.crop.circle".';
