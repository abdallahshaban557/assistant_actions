part of 'dart_writer.dart';

/// The enums plain actions take and return, for the imports: schema enums by
/// id ([useEnum]), the app's own by library ([useAppEnum]).
void _actionEnums(AppModel app, void Function(String ref) useEnum, void Function(Uri library, String name) useAppEnum) {
  for (final a in app.actions) {
    for (final v in [for (final p in a.params) ?p.value, ?a.result?.value]) {
      if (v.kind != ValueKind.enumeration) continue;
      if (v.appEnum case final name?) {
        final library = app.appEnums[name]?.library ?? app.openEnums[v.enumRef]!.library;
        useAppEnum(library, name);
      } else {
        useEnum(v.enumRef!);
      }
    }
  }
}

/// The registry entries running the app's `@AssistantAction` functions.
void _actionEntries(StringBuffer out, AppModel app, String Function(Uri library, String name) ref) {
  for (final a in app.actions) {
    out.writeln("    '${a.id}': (args) async {");
    final callArgs = <String>[];
    for (final p in a.params) {
      final local = '_${p.name}';
      final raw = "args['${p.name}']";
      if (p.entity case final e?) {
        if (p.entityList) {
          final items = '[for (final id in AssistantValue.list($raw, AssistantValue.string) ?? const <String>[]) '
              'if (await find${e.className}(id) case final e?) e]';
          out.writeln(p.entityNullable ? '      final $local = $raw is List ? $items : null;' : '      final $local = $items;');
        } else {
          out.writeln("      final $local = $raw is String ? await find${e.className}($raw as String) : null;");
          if (!p.entityNullable) out.writeln('      if ($local == null) return null;');
        }
      } else {
        final decode = p.value!.decodeDart(raw);
        out.writeln(switch (p.defaultDart) {
          final d? => '      final $local = $decode ?? $d;',
          _ when p.nullable => '      final $local = $decode;',
          _ => "      final $local = $decode ?? (throw ArgumentError.notNull('${p.name}'));",
        });
      }
      callArgs.add(p.named ? '${p.name}: $local' : local);
    }
    final call = '${ref(a.library, a.functionName)}(${callArgs.join(', ')})';
    final result = a.result;
    if (a.returnsReply) {
      out.writeln(result == null
          ? '      return AssistantReply.encode(await $call);'
          : '      final reply = await $call;\n'
              '      return AssistantReply.encodeValue(reply, ${_encodeResult(result, 'reply.value', nullable: true)});');
    } else if (result == null) {
      out.writeln(a.returnsString ? '      return await $call;' : '      await $call;\n      return null;');
    } else {
      final value = result.wrapped ? 'result.value' : 'result';
      final dialog = result.wrapped ? ', dialog: result.dialog' : '';
      out
        ..writeln('      final result = await $call;')
        ..writeln('      return AssistantValue.encodeResult(${_encodeResult(result, value)}$dialog);');
    }
    out.writeln('    },');
  }
}

/// Dart expression encoding a result [expr] for Swift: entities as ids.
/// [nullable]: [expr] may be null whatever the result type (an
/// `AssistantReply`'s value).
String _encodeResult(ResultModel r, String expr, {bool nullable = false}) {
  final optional = nullable || r.nullable;
  if (r.isEntity) {
    final id = r.idField;
    if (r.list) return optional ? '$expr?.map((e) => e.$id).toList()' : '[for (final e in $expr) e.$id]';
    return optional ? '$expr?.$id' : '$expr.$id';
  }
  final v = r.value!;
  final type = ValueType(v.kind,
      nullable: optional, enumRef: v.enumRef, entityRef: v.entityRef, list: v.list, appEnum: v.appEnum);
  return type.encodeDart(expr);
}
