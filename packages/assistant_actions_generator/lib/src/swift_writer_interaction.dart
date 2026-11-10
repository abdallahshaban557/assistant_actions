part of 'swift_writer.dart';

/// Siri conversations in the generated intents: confirmations, spoken
/// results (`ProvidesDialog`) and Dart replies with result cards
/// (`ShowsSnippetView`) or items to choose from.
extension _Interaction on SwiftWriter {
  /// `base & ProvidesDialog & ShowsSnippetView`, as needed.
  String _resultType(String base, {required bool dialog, bool snippet = false}) =>
      [base, if (dialog) 'ProvidesDialog', if (snippet) 'ShowsSnippetView'].join(' & ');

  /// `.result(value: …, dialog: …, view: …)`. [dialog] is a Swift `String`.
  String _resultOf({String? value, String? dialog, bool snippet = false}) {
    if (snippet) _imports.add('SwiftUI');
    return '.result(${[
      if (value != null) 'value: $value',
      if (dialog != null) 'dialog: IntentDialog(stringLiteral: $dialog)',
      if (snippet) 'view: AssistantCardView(reply.card)',
    ].join(', ')})';
  }

  /// A Swift string literal for a `dialogs` or `confirm` [template] of
  /// [intent], reading its parameters (as `self.<name>`) and, as
  /// `{result}`, the item [result] (a Swift expression) names.
  String _schemaTemplate(String template, IntentSchema intent, {String? result}) {
    return '"${SwiftWriter._escape(template).replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final name = m.group(1)!;
      if (name == 'result') return '\\(${_titleExpr(_entitySchema(intent.result!.base.ref!), '$result.')})';
      final p = intent.parameter(name)!;
      return '\\(${_spoken(p.type, 'self.${swiftName(p.name)}')})';
    })}"';
  }

  /// A Swift `String` expression reading [value], of schema type [t], aloud.
  String _spoken(SchemaType t, String value) {
    final base = t.base;
    // Closures name their parameter: an entity without a title member reads
    // as its type's name and doesn't use it.
    if (base.isList) {
      final each = _spoken(base.of!.base, 'item');
      return 'AssistantDialog.list($value${t.isOptional ? '?' : ''}.map { item in $each })';
    }
    if (base.kind == 'entity') {
      final schema = _entitySchema(base.ref!);
      return t.isOptional
          ? '($value.map { item in ${_titleExpr(schema, 'item.')} } ?? "")'
          : _titleExpr(schema, '$value.');
    }
    return switch (base.kind) {
      'string' when !t.isOptional => value,
      'stringSearchCriteria' => t.isOptional ? 'AssistantDialog.text($value?.term)' : '$value.term',
      _ => 'AssistantDialog.text($value)',
    };
  }

  /// The lines that ask the user to confirm [intent] first, if it does.
  String _confirmLines(IntentSchema intent, IntentKind kind, Interactions ix) {
    final confirmation = ix.confirmationFor(intent, kind);
    if (confirmation == null) return '';
    final question = confirmation.question == null
        ? '"Delete \\(${_spoken(intent.parameter('entities')!.type, 'self.entities').replaceFirst('AssistantDialog.list(', 'AssistantDialog.items(')})?"'
        : _schemaTemplate(confirmation.question!, intent);
    return '    try await assistantConfirm($question${confirmation.destructive ? ', destructive: true' : ''})\n';
  }

  /// What a schema intent says when it finishes: its `dialogs` template, or
  /// null. [result] names the item it returns, for `{result}`.
  String? _schemaDialog(IntentSchema intent, Interactions ix, {String? result}) {
    final template = ix.dialogs[intent.name];
    return template == null ? null : _schemaTemplate(template, intent, result: result);
  }

  /// The end of a live call whose Dart handler returns an `AssistantReply`:
  /// its value (asking which item when Dart sent several), what it says
  /// (else the `dialogs` template [dialog], else "Done.") and its card.
  void _replyResult(IntentSchema intent, String id, String method, String? result, String? resultType,
      String? unionType, String? dialog, {String undo = ''}) {
    final says = 'reply.dialog ?? ${dialog ?? '"Done."'}';
    _out
      ..writeln('    let reply = AssistantReply(json: try await callDart("$id", args: args))')
      // Undo (`swift_writer_modern.dart`) gets the ids the reply names.
      ..write(undo);
    switch (callResult(intent)) {
      case CallResult.entity:
        _out
          ..writeln('    let candidates = ${_lookup(resultType!, result, 'reply.ids')}')
          ..writeln('    guard let value = try await assistantChoose(among: candidates, prompt: reply.prompt) else {')
          ..writeln('      throw AssistantActionError.failed("$method returned no ${SwiftWriter._escape(result!)} item")')
          ..writeln('    }')
          ..writeln('    return ${_resultOf(value: 'value', dialog: says, snippet: true)}');
      case CallResult.entities:
        _out
          ..writeln('    let value = ${_lookup(resultType!, result, 'AssistantValues.strings(reply.value) ?? []')}')
          ..writeln('    return ${_resultOf(value: 'value', dialog: says, snippet: true)}');
      case CallResult.union:
        _out
          ..writeln('    guard let value = $unionType.decode(reply.value) else {')
          ..writeln('      throw AssistantActionError.failed("$method returned nothing Siri can use")')
          ..writeln('    }')
          ..writeln('    return ${_resultOf(value: 'value', dialog: says, snippet: true)}');
      case CallResult.unions:
        _out
          ..writeln('    let value = (AssistantValues.items(reply.value) ?? []).compactMap($unionType.decode)')
          ..writeln('    return ${_resultOf(value: 'value', dialog: says, snippet: true)}');
      default:
        _out.writeln('    return ${_resultOf(dialog: says, snippet: true)}');
    }
  }
}
