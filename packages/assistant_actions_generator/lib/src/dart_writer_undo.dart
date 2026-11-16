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

/// The registry entries for undoing plain `@AssistantAction`s (`<id>.undo`).
void _actionUndoEntries(StringBuffer out, AppModel app, String Function(Uri library, String name) ref) {
  for (final a in app.actions) {
    final u = a.undo;
    if (u == null) continue;
    out.writeln("    '${a.id}.undo': (args) async {");
    final callArgs = <String>[];
    var index = 0;
    for (final up in u.params) {
      final local = '_u${index++}';
      if (up.isResult) {
        const raw = "args['result']";
        final r = a.result;
        if (r == null) {
          const decode = 'AssistantValue.string($raw)';
          out.writeln(switch (up.defaultDart) {
            final d? => '      final $local = $decode ?? $d;',
            _ when up.nullable => '      final $local = $decode;',
            _ => "      final $local = $decode ?? (throw ArgumentError.notNull('${up.name}'));",
          });
        } else if (r.entity != null || (r.schemaEntity != null && up.resultAsEntity)) {
          final className = r.entityClassName;
          if (r.list) {
            final items = '[for (final id in AssistantValue.list($raw, AssistantValue.string) ?? const <String>[]) '
                'if (await find$className(id) case final e?) e]';
            out.writeln(up.nullable ? '      final $local = $raw is List ? $items : null;' : '      final $local = $items;');
          } else {
            out.writeln('      final $local = $raw is String ? await find$className($raw as String) : null;');
            if (!up.nullable) out.writeln('      if ($local == null) return null;');
          }
        } else if (r.schemaEntity != null) {
          final decode = r.list
              ? 'AssistantValue.list($raw, AssistantValue.string)'
              : 'AssistantValue.string($raw)';
          out.writeln(up.nullable
              ? '      final $local = $decode;'
              : "      final $local = $decode ?? (throw ArgumentError.notNull('${up.name}'));");
        } else {
          final decode = r.value!.decodeDart(raw);
          out.writeln(switch (up.defaultDart) {
            final d? => '      final $local = $decode ?? $d;',
            _ when up.nullable => '      final $local = $decode;',
            _ => "      final $local = $decode ?? (throw ArgumentError.notNull('${up.name}'));",
          });
        }
      } else {
        final p = up.sourceParam!;
        final raw = "args['${p.name}']";
        if (p.isEntity) {
          final className = p.entityClassName;
          if (p.entityList) {
            final items = '[for (final id in AssistantValue.list($raw, AssistantValue.string) ?? const <String>[]) '
                'if (await find$className(id) case final e?) e]';
            out.writeln(up.nullable ? '      final $local = $raw is List ? $items : null;' : '      final $local = $items;');
          } else {
            out.writeln('      final $local = $raw is String ? await find$className($raw as String) : null;');
            if (!up.nullable) out.writeln('      if ($local == null) return null;');
          }
        } else {
          final decode = p.value!.decodeDart(raw);
          out.writeln(switch (up.defaultDart) {
            final d? => '      final $local = $decode ?? $d;',
            _ when up.nullable => '      final $local = $decode;',
            _ => "      final $local = $decode ?? (throw ArgumentError.notNull('${up.name}'));",
          });
        }
      }
      callArgs.add(up.named ? '${up.name}: $local' : local);
    }
    out
      ..writeln('      await ${ref(u.library, u.functionName)}(${callArgs.join(', ')});')
      ..writeln('      return null;')
      ..writeln('    },');
  }
}
