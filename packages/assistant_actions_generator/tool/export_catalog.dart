// Exports Apple's App Intents schema catalog from the selected Xcode into the
// `assistant_actions` package: normalised JSON per domain (read by the
// builder) and the typed schema libraries (imported by apps).
//
//   dart run tool/export_catalog.dart              # every domain apps can adopt
//   dart run tool/export_catalog.dart reminders notes
//
// Only schemas the SDK defines publicly (`AppSchema.<domain>.<name>` in
// AppIntents' Swift interface) and doesn't deprecate are exported: the rest
// can't be adopted, and are listed under `skipped` with why.
//
// Maintainers run this for each new Xcode release; apps never do.

import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final developer = (await _run('xcode-select', ['-p'])).trim();
  final source = p.join(p.dirname(developer), 'Developer', 'Toolchains', 'XcodeDefault.xctoolchain', 'usr',
      'lib', 'AppIntentSchemas.framework', 'Versions', 'A', 'Resources', 'AppIntentSchemas.sqlite');
  final xcode = RegExp(r'Build version (\S+)').firstMatch(await _run('xcodebuild', ['-version']))!.group(1)!;
  final public = await _publicSchemas();

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
    final allDomains = [for (final row in await _query(db, 'select domain from domainSchema')) row['domain'] as String]
      ..sort();
    final domains = args.isEmpty ? allDomains : args;
    final summary = <String>[];

    for (final domain in domains) {
      final skipped = <String, String>{};
      // Keeps public, non-deprecated schemas; records why the others aren't.
      bool adoptable(String kind, Map<String, Object?> row, String name) {
        switch (public['$kind/$domain.$name']) {
          case null:
            skipped[name] = 'no public definition in the SDK';
            return false;
          case final String replacement:
            skipped[name] = 'deprecated${replacement.isEmpty ? '' : ': $replacement'}';
            return false;
          default:
            return true;
        }
      }

      final unions = <String, UnionSchema>{};
      final context = _Context(names, unions);
      var catalog = DomainCatalog(
        domain: domain,
        hash: hash,
        xcode: xcode,
        entities: {
          for (final row in _latest(await _query(db, "select * from entitySchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name? when adoptable('Entity', row, name))
              '$domain.$name': EntitySchema(
                id: '$domain.$name',
                title: row['_displayRepresentation'] as String? ?? name,
                availability: _availability(row['availability']),
                properties: [for (final m in _json(row['_properties']) as List) context.member(m)],
                protocols: _entityProtocols(row['_systemProtocols']),
              ),
        },
        enums: {
          for (final row in _latest(await _query(db, "select * from enumSchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name? when adoptable('Enum', row, name))
              '$domain.$name': EnumSchema(
                id: '$domain.$name',
                title: row['_displayRepresentation'] as String? ?? name,
                availability: _availability(row['availability']),
                cases: [for (final c in _json(row['_cases']) as List) (c as Map)['_name'] as String],
              ),
        },
        intents: {
          for (final row in _latest(await _query(db, "select * from intentSchema where domainID = '$domain'")))
            if (_name(names, domain, row) case final name? when adoptable('Intent', row, name))
              '$domain.$name': IntentSchema(
                id: '$domain.$name',
                title: row['_title'] as String? ?? name,
                description: row['_description'] as String?,
                availability: _availability(row['availability']),
                parameters: [for (final m in _json(row['_parameters']) as List) context.member(m)],
                result: row['_result'] == null ? null : context.type(_json(row['_result']) as Map),
                opensApp: row['_openApp'] == 1,
                protocols: _protocols(row['_systemProtocols']),
              ),
        },
        unions: unions,
        skipped: Map.fromEntries(skipped.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      );
      catalog = _withoutPrivateReferences(catalog, public, skipped);
      final json = p.join(root, 'lib', 'src', 'catalog', '$domain.json');
      final library = p.join(root, 'lib', 'schemas', schemaLibraryFile(domain));
      if (catalog.entities.isEmpty && catalog.intents.isEmpty) {
        // Nothing an app can adopt: remove what an older export wrote.
        for (final f in [json, library]) {
          if (File(f).existsSync()) File(f).deleteSync();
        }
        summary.add('$domain: not adoptable (${skipped.length} schemas, none public)');
        continue;
      }
      await File(json).writeAsString('${const JsonEncoder.withIndent('  ').convert(catalog.toJson())}\n');
      await File(library).writeAsString(generateSchemaLibrary(catalog));
      await _run('dart', ['format', '--page-width', '100', library]);
      summary.add('$domain: ${catalog.entities.length} entities, ${catalog.enums.length} enums, '
          '${catalog.unions.length} unions, ${catalog.intents.length} intents'
          '${skipped.isEmpty ? '' : ', ${skipped.length} skipped'}');
    }
    stdout.writeln(summary.join('\n'));
  } finally {
    await temp.delete(recursive: true);
  }
}

/// `Kind/domain.name` → true for public schemas, or a deprecation message
/// (possibly empty) for deprecated ones, from AppIntents' iOS and macOS Swift
/// interfaces (`AppSchema.Intent("…")` getters in `extension
/// `AppSchema.Domain…Intent`, `…Entity` and `…Enum`).
Future<Map<String, Object>> _publicSchemas() async {
  final result = <String, Object>{};
  for (final (sdk, arch) in [('iphoneos', 'arm64e-apple-ios'), ('macosx', 'arm64e-apple-macos')]) {
    final root = (await _run('xcrun', ['--sdk', sdk, '--show-sdk-path'])).trim();
    final file = File(p.join(root, 'System', 'Library', 'Frameworks', 'AppIntents.framework', 'Modules',
        'AppIntents.swiftmodule', '$arch.swiftinterface'));
    final source = await file.readAsString();
    final extensions = RegExp(r'extension AppIntents::AppSchema\.AppIntents::(\w+?)(Intent|Entity|Enum) \{(.*?)\n\}',
        dotAll: true);
    final getter = RegExp(
        r'((?:  @available\([^\n]*\n)*)  @_alwaysEmitIntoClient public var (\w+): some[^\n]*\n\s*get \{\n\s*AppSchema\.\w+\("\w+"\)');
    for (final m in extensions.allMatches(source)) {
      final domain = camel(m[1]!);
      for (final g in getter.allMatches(m[3]!)) {
        final key = '${m[2]}/$domain.${g[2]}';
        final deprecated = RegExp(r'deprecated[^)]*?(?:message: "([^"]*)")?\)').firstMatch(g[1]!);
        if (deprecated != null) {
          result.putIfAbsent(key, () => deprecated[1] ?? '');
        } else {
          result[key] = true;
        }
      }
    }
  }
  return result;
}

/// [catalog] without the schemas that use an entity or enum the SDK doesn't
/// define publicly (`phone.startCall` can call a private `phone.group`),
/// recorded in [skipped]. Repeats, as dropping an entity can strand others.
DomainCatalog _withoutPrivateReferences(DomainCatalog catalog, Map<String, Object> public, Map<String, String> skipped) {
  var entities = Map.of(catalog.entities);
  var intents = Map.of(catalog.intents);
  String? privateRef(SchemaType t, [Set<String> seen = const {}]) {
    if (t.of case final of?) return privateRef(of, seen);
    final ref = t.ref;
    if (ref == null || seen.contains(ref)) return null;
    switch (t.kind) {
      case 'entity':
        final local = ref.startsWith('${catalog.domain}.');
        if (local ? !entities.containsKey(ref) : public['Entity/$ref'] != true) return ref;
      case 'enum':
        if (public['Enum/$ref'] != true) return ref;
      case 'openEnum':
        if (public['Enum/$ref'] != true) return ref;
      case 'union':
        for (final c in catalog.unions[ref]?.cases ?? const <({String name, SchemaType type})>[]) {
          if (privateRef(c.type, {...seen, ref}) case final r?) return r;
        }
    }
    return null;
  }

  for (var changed = true; changed;) {
    changed = false;
    for (final e in entities.values.toList()) {
      for (final m in e.properties) {
        if (privateRef(m.type, {e.id}) case final r?) {
          entities.remove(e.id);
          skipped[e.name] = r.endsWith(')') ? 'uses $r' : 'uses $r, which is not public';
          changed = true;
          break;
        }
      }
    }
  }
  for (final i in intents.values.toList()) {
    for (final t in [for (final p in i.parameters) p.type, ?i.result]) {
      if (privateRef(t) case final r?) {
        intents.remove(i.id);
        skipped[i.name] = r.endsWith(')') ? 'uses $r' : 'uses $r, which is not public';
        break;
      }
    }
  }
  return DomainCatalog(
    domain: catalog.domain,
    hash: catalog.hash,
    xcode: catalog.xcode,
    entities: entities,
    enums: catalog.enums,
    intents: intents,
    unions: {
      for (final u in catalog.unions.values)
        if (u.cases.every((c) => privateRef(c.type, {u.id}) == null)) u.id: u,
    },
    skipped: Map.fromEntries(skipped.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
  );
}

/// Resolves schema types, collecting the unions they use.
class _Context {
  _Context(this.names, this.unions);

  final Map<String, String> names;
  final Map<String, UnionSchema> unions;

  SchemaMember member(Object? raw) {
    final m = raw as Map;
    return SchemaMember(
      name: m['name'] as String,
      title: m['title'] as String? ?? m['name'] as String,
      description: m['description'] as String?,
      updatable: m['isUpdatable'] as bool? ?? true,
      indexingKey: m['indexingKey'] as String?,
      type: type(m['type'] as Map),
    );
  }

  /// `{"optional":{"_0":{"string":{}}}}` → `SchemaType('optional', of: string)`.
  SchemaType type(Map raw) {
    final MapEntry(:key, :value) = raw.entries.single;
    final kind = key as String;
    switch (kind) {
      case 'optional' || 'array' || 'set':
        return SchemaType(kind, of: type((value as Map)['_0'] as Map));
      case 'entity' || 'enum':
        // An entity with no definition is any of the app's entities.
        final target = (value as Map)['_0'] as Map?;
        if (target == null) return SchemaType(kind);
        final domain = target['domainID'] as String;
        final name = names['$domain/${target['id']}'] ?? camel(target['id'] as String);
        // An enum with no cases is one whose cases the app defines (a book's
        // fonts).
        if (kind == 'enum' && (target['_cases'] as List?)?.isEmpty == true) {
          return SchemaType('openEnum', ref: '$domain.$name');
        }
        return SchemaType(kind, ref: '$domain.$name');
      case 'unionSchema':
        final def = (value as Map)['_0'] as Map;
        final domain = def['domainID'] as String;
        final name = names['$domain/${def['id']}'] ?? camel(def['id'] as String);
        final id = '$domain.$name';
        unions[id] ??= UnionSchema(
          id: id,
          title: def['_displayRepresentation'] as String? ?? name,
          availability: _availability(def['availability']),
          cases: [
            for (final c in def['_cases'] as List) (name: (c as Map)['_name'] as String, type: type(c['_type'] as Map)),
          ],
        );
        return SchemaType('union', ref: id);
      default:
        return SchemaType(kind);
    }
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

/// The system intent protocols a schema intent adopts, such as
/// `audioStarting` (`AudioRecordingIntent`) or `search`.
List<String> _protocols(Object? raw) => [
      for (final p in (_json(raw) as List?) ?? const [])
        if ((p as Map)['primitive'] case {'wrapper': final Map wrapper}) ...wrapper.keys.cast<String>(),
    ];

/// The entity protocols a schema entity requires: 0 is `FileEntity`, 1
/// `UniqueAppEntity`. Others (3, on synced entities like notes) need nothing
/// from the app.
List<String> _entityProtocols(Object? raw) => [
      for (final p in (_json(raw) as List?) ?? const [])
        ?const {0: 'file', 1: 'unique'}[p],
    ];

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
