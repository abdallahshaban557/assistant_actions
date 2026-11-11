part of 'dart_writer.dart';

// Apple Intelligence in context: importing queries, Visual Intelligence
// search and donations.

typedef _Ref = String Function(Uri library, String name);

/// Whether the registry encodes JSON for queries or Visual Intelligence.
bool _intelligenceNeedsJson(AppModel app) =>
    app.visualSearchTypes.isNotEmpty || app.schemaEntities.any((s) => s.queries.isNotEmpty);

/// The handler methods answering [s]'s importing queries.
void _queryMethods(StringBuffer out, SchemaEntityModel s) {
  for (final q in s.queries) {
    out
      ..writeln()
      ..writeln('  /// Apple Intelligence asks which items are at [${queryArgName(q)}] (`${q.id}`). Return the ids')
      ..writeln('  /// of published items. While Flutter isn\'t running, Swift matches the')
      ..writeln('  /// published items itself.')
      ..writeln('  ${queryMethodSignature(q)};');
  }
}

/// The registry parameter for Visual Intelligence search, if any entity
/// takes part.
List<String> _visualSearchArgs(AppModel app) => [
      if (app.visualSearchTypes.isNotEmpty)
        'required FutureOr<Iterable<Object>> Function(AssistantSemanticContent content) visualSearch,',
    ];

/// The registry entries for importing queries and Visual Intelligence.
void _intelligenceEntries(StringBuffer out, AppModel app) {
  for (final s in app.schemaEntities) {
    for (final q in s.queries) {
      final arg = queryArgName(q);
      final decode = valueTypeFor(q.type).decodeDart("args['$arg']");
      out
        ..writeln("    '${queryActionId(s, q)}': (args) async {")
        ..writeln('      return jsonEncode(await ${camel(s.className)}.${q.name}($decode ?? '
            "(throw ArgumentError.notNull('$arg'))));")
        ..writeln('    },');
    }
  }
  if (app.visualSearchTypes.isNotEmpty) {
    out
      ..writeln("    '$visualSearchActionId': (args) async {")
      ..writeln("      final content = AssistantValue.semanticContent(args['content']) ?? const AssistantSemanticContent();")
      ..writeln('      return jsonEncode([')
      ..writeln('        for (final item in await visualSearch(content))')
      ..writeln('          if (_visualSearchReference(item) case final reference?) reference,')
      ..writeln('      ]);')
      ..writeln('    },');
  }
}

/// What follows the registry: how Visual Intelligence results name items,
/// and `AssistantDonations`.
void _intelligenceTail(StringBuffer out, AppModel app, _Ref ref) {
  final types = [
    for (final e in app.entities)
      if (e.visualSearch) (ref(e.library, e.className), e.className, e.idField),
    for (final s in app.schemaEntities)
      if (s.visualSearch) (ref(s.library, s.className), s.collection, s.idField),
  ];
  if (types.isNotEmpty) {
    out
      ..writeln()
      ..writeln('/// The collection and id of a `visualSearch` result; null for items Visual')
      ..writeln('/// Intelligence can\'t show (no `visualSearch: true` on their class).')
      ..writeln('Map<String, String>? _visualSearchReference(Object item) => switch (item) {');
    for (final (type, collection, id) in types) {
      out.writeln("      $type e => {'collection': '$collection', 'id': e.$id},");
    }
    out
      ..writeln('      _ => null,')
      ..writeln('    };');
  }

  final actions = [for (final a in app.actions) if (a.focusFilter == null) a];
  if (actions.isEmpty && app.snapshotActions.isEmpty) return;
  out
    ..writeln()
    ..writeln('/// Tells Siri the user just ran an action in the app, so Siri suggestions and')
    ..writeln('/// personal context learn it (`IntentDonationManager`). Each returns whether')
    ..writeln('/// Siri got the donation. For items the user opened, use')
    ..writeln('/// `AssistantActions.donate(item)`.')
    ..writeln('abstract final class AssistantDonations {');
  for (final a in actions) {
    final positional = <String>[];
    final optional = <String>[];
    final named = <String>[];
    final args = <String>[];
    for (final p in a.params) {
      final String type;
      final String value;
      if (p.entity case final e?) {
        final item = ref(e.library, e.className);
        type = '${p.entityList ? 'List<$item>' : item}${p.entityNullable ? '?' : ''}';
        value = p.entityList
            ? (p.entityNullable ? '${p.name}?.map((e) => e.${e.idField}).toList()' : '[for (final e in ${p.name}) e.${e.idField}]')
            : '${p.name}${p.entityNullable ? '?' : ''}.${e.idField}';
      } else {
        type = p.value!.dart;
        value = p.value!.encodeDart(p.name);
      }
      // Mirrors the function: defaults stay defaults.
      final declared = '$type ${p.name}${p.defaultDart == null ? '' : ' = ${p.defaultDart}'}';
      if (p.named) {
        named.add(p.nullable || p.defaultDart != null ? declared : 'required $declared');
      } else if (p.defaultDart != null) {
        optional.add(declared);
      } else {
        positional.add(declared);
      }
      args.add("'${p.name}': $value");
    }
    final signature = [
      ...positional,
      if (optional.isNotEmpty) '[${optional.join(', ')}]',
      if (named.isNotEmpty) '{${named.join(', ')}}',
    ].join(', ');
    out
      ..writeln()
      ..writeln('  /// The user ran `${a.functionName}` ("${a.title}") in the app.')
      ..writeln('  static Future<bool> ${a.functionName}($signature) =>')
      ..writeln("      AssistantActions.donateAction('${a.id}', ${args.isEmpty ? 'const {}' : '{${args.join(', ')}}'});");
  }
  for (final a in app.snapshotActions) {
    out
      ..writeln()
      ..writeln('  /// The user looked at what `${a.name}` ("${a.title}") answers, in the app.')
      ..writeln("  static Future<bool> ${a.name}() => AssistantActions.donateAction('${a.id}', const {});");
  }
  out.writeln('}');
}
