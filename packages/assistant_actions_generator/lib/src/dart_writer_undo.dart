part of 'dart_writer.dart';

/// `undo<Method>`: the handler method that undoes a [IntentKind.call]
/// intent of an `@AssistantUndoable()` class.
String undoMethod(IntentSchema intent, EntitySchema? owner) => 'undo${pascal(callMethod(intent, owner))}';

/// The `result` an undo method gets: the ids the intent returned.
String? _undoResultType(IntentSchema intent) => switch (callResult(intent)) {
      CallResult.entity => 'String?',
      CallResult.entities => 'List<String>?',
      _ => null,
    };

/// The undo method declaration for [intent].
void _undoMethodDeclaration(StringBuffer out, IntentSchema intent, EntitySchema? owner, Map<String, String> openEnums) {
  final args = [
    for (final p in intent.parameters)
      if (callArg(p, openEnums) case final a?) a.optional ? '${a.dartType} ${a.name}' : 'required ${a.dartType} ${a.name}',
    if (_undoResultType(intent) case final t?) '$t result',
  ];
  out
    ..writeln()
    ..writeln('  /// The user undid `${intent.id}` ("${intent.title}"): reverse what')
    ..writeln('  /// `${callMethod(intent, owner)}` did. Gets the same arguments'
        '${_undoResultType(intent) == null ? '' : ', and the ids it returned as [result]'}.')
    ..writeln('  Future<void> ${undoMethod(intent, owner)}(${args.isEmpty ? '' : '{${args.join(', ')}}'});');
}

/// The registry entry for undoing [intent] (`<id>.undo`).
void _undoEntry(
    StringBuffer out, String id, String handler, IntentSchema intent, EntitySchema? owner, Map<String, String> openEnums) {
  final args = [
    for (final p in intent.parameters)
      if (callArg(p, openEnums) case final a?) '${a.name}: ${_decodeArg(a)}',
    if (callResult(intent) == CallResult.entity) "result: AssistantValue.string(args['result'])",
    if (callResult(intent) == CallResult.entities)
      "result: AssistantValue.list(args['result'], (v) => AssistantValue.string(v))",
  ];
  out
    ..writeln("    '$id.undo': (args) async {")
    ..writeln('      await $handler.${undoMethod(intent, owner)}(${args.join(', ')});')
    ..writeln('      return null;')
    ..writeln('    },');
}
