// Exports Apple's App Intents schema catalog from the selected Xcode into the
// `assistant_actions` package: normalised JSON per domain (read by the
// builder) and the typed schema libraries (imported by apps).
//
//   dart run tool/export_catalog.dart reminders notes
//
// Maintainers run this for each new Xcode release; apps never do.

import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> domains) async {
  if (domains.isEmpty) {
    stderr.writeln('usage: dart run tool/export_catalog.dart <domain>...');
    exit(64);
  }
  final developer = (await _run('xcode-select', ['-p'])).trim();
  final source = p.join(p.dirname(developer), 'Developer', 'Toolchains', 'XcodeDefault.xctoolchain', 'usr',
      'lib', 'AppIntentSchemas.framework', 'Versions', 'A', 'Resources', 'AppIntentSchemas.sqlite');
  final xcode = RegExp(r'Build version (\S+)').firstMatch(await _run('xcodebuild', ['-version']))!.group(1)!;

  // The catalog lives in a root-owned folder, and SQLite needs a writable one.
  final temp = await Directory.systemTemp.createTemp('assistant_actions_catalog');
  final db = p.join(temp.path, 'AppIntentSchemas.sqlite');
  await File(source).copy(db);

  try {
    final hash = (await _query(db, 'select hash from metadata')).single['hash'] as String;
    final names = {
      for (final row in await _query(db, 'select schemaIdentifier, schemaName, domainID from schemaRecord'))
        '${row['domainID']}/${row['schemaIdentifier']}': row['schemaName'] as String,
    };
    final root = p.normalize(p.join(p.dirname(Platform.script.toFilePath()), '..', '..', 'assistant_actions'));

    for (final domain in domains) {
      final catalog = DomainCatalog(
        domain: domain,
        hash: hash,
        xcode: xcode,
        entities: {
          for (final row in _latest(await _query(db, "select * from entitySchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name?)
              '$domain.$name': EntitySchema(
                id: '$domain.$name',
                title: row['_displayRepresentation'] as String? ?? name,
                availability: _availability(row['availability']),
                properties: [for (final m in _json(row['_properties']) as List) _member(names, m)],
              ),
        },
        enums: {
          for (final row in _latest(await _query(db, "select * from enumSchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name?)
              '$domain.$name': EnumSchema(
                id: '$domain.$name',
                title: row['_displayRepresentation'] as String? ?? name,
                cases: [for (final c in _json(row['_cases']) as List) (c as Map)['_name'] as String],
              ),
        },
        intents: {
          for (final row in _latest(await _query(db, "select * from intentSchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name?)
              '$domain.$name': IntentSchema(
                id: '$domain.$name',
                title: row['_title'] as String? ?? name,
                description: row['_description'] as String?,
                availability: _availability(row['availability']),
                parameters: [for (final m in _json(row['_parameters']) as List) _member(names, m)],
                result: row['_result'] == null ? null : _type(names, _json(row['_result']) as Map),
              ),
        },
      );
      if (catalog.entities.isEmpty && catalog.intents.isEmpty) {
        stderr.writeln('No schemas found for domain "$domain".');
        exit(1);
      }
      final json = p.join(root, 'lib', 'src', 'catalog', '$domain.json');
      await File(json).writeAsString('${const JsonEncoder.withIndent('  ').convert(catalog.toJson())}\n');
      final library = p.join(root, 'lib', 'schemas', '$domain.dart');
      await File(library).writeAsString(generateSchemaLibrary(catalog));
      await _run('dart', ['format', '--page-width', '100', library]);
      stdout.writeln('$domain: ${catalog.entities.length} entities, ${catalog.enums.length} enums, '
          '${catalog.intents.length} intents → ${p.relative(json)}, ${p.relative(library)}');
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

/// The highest version of each schema row.
Iterable<Map<String, Object?>> _latest(List<Map<String, Object?>> rows) {
  num version(Map<String, Object?> r) =>
      [r['versionMajor'], r['versionMinor'], r['versionPatch']]
          .map((v) => num.tryParse('$v') ?? 0)
          .fold<num>(0, (sum, v) => sum * 1000 + v);
  final best = <String, Map<String, Object?>>{};
  for (final row in rows) {
    final id = row['id'] as String;
    if (best[id] == null || version(row) > version(best[id]!)) best[id] = row;
  }
  return best.values;
}

String? _name(Map<String, String> names, String domain, Map<String, Object?> row) =>
    names['$domain/${row['id']}'];

SchemaMember _member(Map<String, String> names, Object? raw) {
  final m = raw as Map;
  return SchemaMember(
    name: m['name'] as String,
    title: m['title'] as String? ?? m['name'] as String,
    description: m['description'] as String?,
    updatable: m['isUpdatable'] as bool? ?? true,
    indexingKey: m['indexingKey'] as String?,
    type: _type(names, m['type'] as Map),
  );
}

/// `{"optional":{"_0":{"string":{}}}}` → `SchemaType('optional', of: string)`.
SchemaType _type(Map<String, String> names, Map raw) {
  final MapEntry(:key, :value) = raw.entries.single;
  final kind = key as String;
  switch (kind) {
    case 'optional' || 'array' || 'set':
      return SchemaType(kind, of: _type(names, (value as Map)['_0'] as Map));
    case 'entity' || 'enum':
      final target = (value as Map)['_0'] as Map;
      final domain = target['domainID'] as String;
      final name = names['$domain/${target['id']}'] ?? target['id'] as String;
      return SchemaType(kind, ref: '$domain.$name');
    default:
      return SchemaType(kind);
  }
}

Map<String, num> _availability(Object? raw) {
  final json = (_json(raw) as Map?) ?? const {};
  return {
    for (final platform in ['iOS', 'macOS'])
      if (json[platform] case final num version) platform: version,
  };
}

Object? _json(Object? raw) => raw == null ? null : jsonDecode(raw as String);

Future<List<Map<String, Object?>>> _query(String db, String sql) async {
  final out = await _run('sqlite3', ['-json', db, sql]);
  if (out.trim().isEmpty) return const [];
  return [for (final row in jsonDecode(out) as List) (row as Map).cast<String, Object?>()];
}

Future<String> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw ProcessException(executable, args, '${result.stderr}', result.exitCode);
  }
  return result.stdout as String;
}
