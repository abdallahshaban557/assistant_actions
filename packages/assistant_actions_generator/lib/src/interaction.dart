/// How the generated intents talk with the user: spoken results (`dialogs`),
/// confirmations (`confirm`, deletes by default) and replies from Dart
/// (`replies`: a dialog, a result card, or items to choose from). Shared by
/// the reader, the writers and `tool/validate_schemas.dart`.
library;

import 'catalog.dart';

/// The Siri conversation options on a schema entity or `…Intents`
/// annotation, by intent name.
class Interactions {
  const Interactions({
    this.dialogs = const {},
    this.confirm = const {},
    this.confirmDeletes = true,
    this.replies = const {},
  });

  static const none = Interactions();

  /// Intent name → what Siri says when it finishes (a template).
  final Map<String, String> dialogs;

  /// Intent name → the question Siri asks first (a template).
  final Map<String, String> confirm;

  /// Deletes ask "Delete …?" unless listed in [confirm].
  final bool confirmDeletes;

  /// Live intents whose Dart handler returns an `AssistantReply`.
  final Set<String> replies;

  bool get isEmpty => dialogs.isEmpty && confirm.isEmpty && replies.isEmpty;

  /// The question for [intent] of [kind], or null when it runs at once.
  /// [Confirmation.question] is null for the default delete question.
  Confirmation? confirmationFor(IntentSchema intent, IntentKind kind) {
    if (confirm[intent.name] case final question?) {
      return Confirmation(question, destructive: kind == IntentKind.delete);
    }
    if (kind == IntentKind.delete && confirmDeletes) return const Confirmation(null, destructive: true);
    return null;
  }

  bool repliesTo(IntentSchema intent) => replies.contains(intent.name);
}

/// A question Siri asks before an intent runs.
class Confirmation {
  const Confirmation(this.question, {required this.destructive});

  /// The template, or null for "Delete …?" naming the items.
  final String? question;

  /// Labels the button "Delete".
  final bool destructive;
}

/// Placeholder names in a template: `{title}` → `title`.
Iterable<String> templatePlaceholders(String template) =>
    RegExp(r'\{(\w+)\}').allMatches(template).map((m) => m.group(1)!);

/// Schema types Siri can read out in a template.
const _speakable = {
  'string', 'attributedString', 'int', 'double', 'bool', 'date', 'dateComponents', 'duration', 'url', //
  'person', 'enum', 'openEnum', 'stringSearchCriteria',
};

/// Whether a parameter of type [t] can be a template placeholder: text,
/// numbers, dates, durations, URLs, people, enums and items (by title), or
/// lists of them.
bool speakable(SchemaType t) {
  final base = t.base;
  if (base.isList && base.of!.base.isList) return false;
  final element = t.element;
  if (element.kind == 'entity') return element.ref != null;
  return _speakable.contains(element.kind);
}

/// Whether [intent] returns one item, which `{result}` names.
bool returnsItem(IntentSchema intent) => intent.result?.base.kind == 'entity' && intent.result!.base.ref != null;

/// Whether Dart can reply to [intent] of [kind]: only live calls and
/// records run Dart while Siri waits.
bool canReply(IntentSchema intent, IntentKind kind) =>
    kind == IntentKind.record || (kind == IntentKind.call && intent.isLive);

/// Checks [ix] against the intents an annotation turned on, returning what
/// is wrong, or null. [annotation] names it in messages
/// (`@RemindersReminder`).
String? checkInteractions(Interactions ix, List<(IntentSchema, IntentKind)> intents, String annotation) {
  final byName = {for (final (intent, kind) in intents) intent.name: (intent, kind)};
  final on = byName.keys.join(', ');

  for (final (option, names) in [
    ('dialogs', ix.dialogs.keys),
    ('confirm', ix.confirm.keys),
    ('replies', ix.replies),
  ]) {
    for (final name in names) {
      final found = byName[name];
      if (found == null) {
        return '$annotation: $option names $name, which is not an intent turned on here'
            '${on.isEmpty ? ' (none are)' : ' ($on)'}.';
      }
      final (intent, kind) = found;
      if (intent.id == 'system.open') {
        return '$annotation: system.open (open) can\'t have dialogs, confirm or replies yet.';
      }
      if (option == 'replies' && !canReply(intent, kind)) {
        return '$annotation: replies names $name, but ${intent.id} '
            '${kind == IntentKind.call ? 'is queued' : 'goes through the inbox'} and runs when the app next does, '
            'so Dart can\'t reply while Siri waits. Give it a dialog in dialogs instead.';
      }
    }
  }
  for (final (option, templates) in [('dialogs', ix.dialogs), ('confirm', ix.confirm)]) {
    for (final MapEntry(key: name, value: template) in templates.entries) {
      final (intent, _) = byName[name]!;
      for (final placeholder in templatePlaceholders(template)) {
        if (placeholder == 'result') {
          if (option == 'dialogs' && returnsItem(intent)) continue;
          return '$annotation: $option[\'$name\'] uses {result}, but '
              '${option == 'confirm' ? 'a confirmation comes before there is a result' : '${intent.id} returns no item'}.';
        }
        final p = intent.parameter(placeholder);
        if (p == null) {
          final params = intent.parameters.map((p) => p.name).join(', ');
          return '$annotation: $option[\'$name\'] uses {$placeholder}, which is not a parameter of ${intent.id}'
              '${params.isEmpty ? ' (it has none)' : ' ($params)'}.';
        }
        if (!speakable(p.type)) {
          return '$annotation: $option[\'$name\'] uses {$placeholder}, a ${p.type}, which Siri can\'t read out. '
              'Use text, numbers, dates, durations, enums or items.';
        }
      }
    }
  }
  return null;
}
