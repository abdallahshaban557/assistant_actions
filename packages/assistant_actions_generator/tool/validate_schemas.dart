// Checks every App Schema the bundled catalogs offer against Apple's own
// tools, end to end:
//
//   dart run tool/validate_schemas.dart [--keep] [--report=FILE] [domain...]
//
// 1. Writes a throwaway Flutter app whose models adopt every schema entity
//    the generator can adopt (each mappable member mapped, every intent
//    turned on) and every domain's `…Intents`.
// 2. Runs the real builder on it (`build_runner`), then `flutter analyze` on
//    the generated Dart.
// 3. Compiles the generated Swift with the runtime's Swift (a stub stands in
//    for the Flutter bridge) for macOS and the iOS simulator, and runs
//    Apple's `appintentsmetadataprocessor` on each, which validates schema
//    conformance.
//
// Prints what it couldn't adopt and why, and exits non-zero on any error.
// `--report` writes a Markdown table of what each domain supports.
// macOS with Xcode only; maintainers run it after exporting the catalog.

import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/interaction.dart';
import 'package:assistant_actions_generator/src/schema_calls.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:path/path.dart' as p;

final _here = p.dirname(Platform.script.toFilePath());
final _runtime = p.normalize(p.join(_here, '..', '..', 'assistant_actions'));
final _generator = p.normalize(p.join(_here, '..'));

Future<void> main(List<String> args) async {
  final keep = args.contains('--keep');
  final report = args.where((a) => a.startsWith('--report=')).map((a) => a.substring(9)).firstOrNull;
  final only = args.where((a) => !a.startsWith('--')).toSet();
  final catalogs = <String, DomainCatalog>{
    for (final f in Directory(p.join(_runtime, 'lib', 'src', 'catalog')).listSync().whereType<File>())
      if (f.path.endsWith('.json') && !f.path.endsWith('generator_api.json'))
        p.basenameWithoutExtension(f.path):
            DomainCatalog.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast()),
  };
  final plan = _Plan(catalogs, only.isEmpty ? catalogs.keys.toSet() : only);

  final app = await Directory.systemTemp.createTemp('schema_validation');
  stdout.writeln('App: ${app.path}');
  var failed = false;
  try {
    _writeApp(app.path, plan);
    await _step('flutter pub get', 'flutter', ['pub', 'get'], app.path);
    await _step('build_runner', 'dart', ['run', 'build_runner', 'build', '--delete-conflicting-outputs'], app.path);
    failed |= !await _step('flutter analyze', 'flutter', ['analyze', '--no-fatal-infos'], app.path, fatal: false);
    final swift = p.join(app.path, 'packages', 'assistant_actions_app', 'darwin', 'assistant_actions_app', 'Sources',
        'assistant_actions_app', 'AssistantActions.g.swift');
    for (final platform in ['macos', 'ios']) {
      failed |= !await _processSwift(swift, platform, p.join(app.path, 'swift_$platform'));
    }
  } finally {
    if (!keep && !failed) await app.delete(recursive: true);
  }

  stdout
    ..writeln()
    ..writeln('Adopted ${plan.adopted.length} entities, ${plan.intentCount} intents in ${plan.domains.length} domains.');
  if (plan.skipped.isNotEmpty) {
    stdout.writeln('Not adopted:');
    for (final MapEntry(:key, :value) in plan.skipped.entries) {
      stdout.writeln('  $key: $value');
    }
  }
  stdout.writeln(failed ? 'FAILED' : 'OK');
  if (report != null && !failed) {
    File(report).writeAsStringSync(_report(plan));
    stdout.writeln('Report: $report');
  }
  exit(failed ? 1 : 0);
}

/// A Markdown table of what each domain supports, from the validated plan.
String _report(_Plan plan) {
  final out = StringBuffer()
    ..writeln('| Domain | Support | Entities | Intents | Gaps |')
    ..writeln('|---|---|---|---|---|');
  for (final d in plan.domains..sort()) {
    final catalog = plan.catalogs[d]!;
    final entities = catalog.entities.values.toList();
    final adopted = entities.where((e) => plan.adopted.containsKey(e.id)).length;
    final intents = catalog.intents.values.toList();
    final served = {
      for (final l in [...plan.intents.values, plan.domainIntents[d] ?? const <IntentSchema>[]])
        for (final i in l)
          if (i.domain == d) i.id,
    };
    final gaps = <String>[
      for (final e in entities)
        if (plan.skipped[e.id] case final why?) '`${e.name}`: $why',
      for (final i in intents)
        if (plan.skipped[i.id] case final why?) '`${i.name}`: $why',
      for (final i in intents)
        if (served.contains(i.id) && i.id != 'system.open' && droppedArgs(i).isNotEmpty)
          '`${i.name}` doesn\'t pass ${droppedArgs(i).map((p) => '`${p.name}` (${p.type.element.kind})').join(', ')} to Dart',
    ];
    final notPublic = catalog.skipped.length;
    if (notPublic > 0) gaps.add('$notPublic schemas not adoptable (${_reasons(catalog.skipped.values)})');
    final full = adopted == entities.length && served.length == intents.length && gaps.length == (notPublic > 0 ? 1 : 0);
    out.writeln('| `$d` | ${full ? 'Full' : 'Partial'} | $adopted/${entities.length} | ${served.length}/${intents.length} | '
        '${gaps.isEmpty ? '' : gaps.join('; ').replaceAll('|', '\\|')} |');
  }
  return out.toString();
}

String _reasons(Iterable<String> reasons) {
  final counts = <String, int>{};
  for (final r in reasons) {
    final key = r.startsWith('deprecated') ? 'deprecated' : r.startsWith('uses') ? 'uses a private schema' : 'not public';
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts.entries.map((e) => '${e.value} ${e.key}').join(', ');
}

/// What the validation app adopts, with the generator's own rules.
class _Plan {
  _Plan(this.catalogs, Set<String> domains) {
    for (final d in domains) {
      final catalog = catalogs[d];
      if (catalog == null) throw ArgumentError('No catalog for $d');
      this.domains.add(d);
      for (final e in catalog.entities.values) {
        if (_whyNot(catalog, e) case final why?) {
          skipped[e.id] = why;
        } else {
          adopted[e.id] = e;
        }
      }
    }
    // A required reference to an entity that can't be adopted blocks this
    // one too; repeat until nothing changes.
    for (var changed = true; changed;) {
      changed = false;
      for (final e in adopted.values.toList()) {
        final catalog = catalogs[e.domain]!;
        for (final m in e.properties) {
          final ref = referenceOf(m);
          if (ref == null || adopted.containsKey(ref) || m.type.isOptional || m.type.base.isList) continue;
          if (catalog.entities[ref] case final c? when catalog.isFixable(c) && ref != e.id) continue;
          adopted.remove(e.id);
          skipped[e.id] = '${m.name} needs $ref, which is not adopted (${skipped[ref] ?? 'other domain'})';
          changed = true;
          break;
        }
      }
    }
    for (final d in domains) {
      final catalog = catalogs[d]!;
      for (final e in catalog.entities.values) {
        if (!adopted.containsKey(e.id)) continue;
        intents[e.id] = [
          for (final (intent, kind) in catalog.intentsFor(e))
            if (kind != IntentKind.call || _callWhyNot(intent) == null) intent,
        ];
        for (final (intent, kind) in catalog.intentsFor(e)) {
          if (kind != IntentKind.call) continue;
          if (_callWhyNot(intent) case final why?) skipped[intent.id] = why;
        }
      }
      domainIntents[d] = [
        for (final intent in catalog.domainIntents)
          if (_callWhyNot(intent) == null) intent,
      ];
      for (final intent in catalog.domainIntents) {
        if (_callWhyNot(intent) case final why?) skipped[intent.id] = why;
      }
    }
  }

  final Map<String, DomainCatalog> catalogs;
  final domains = <String>[];
  final adopted = <String, EntitySchema>{};
  final intents = <String, List<IntentSchema>>{};
  final domainIntents = <String, List<IntentSchema>>{};
  final skipped = <String, String>{};

  /// The entity [m] references (directly or as a list), if any.
  static String? referenceOf(SchemaMember m) {
    final t = m.type.base;
    if (t.kind == 'entity') return t.ref;
    if (t.isList && t.of!.base.kind == 'entity') return t.of!.base.ref;
    return null;
  }

  int get intentCount =>
      intents.values.fold(0, (n, l) => n + l.length) + domainIntents.values.fold(0, (n, l) => n + l.length);

  String? _whyNot(DomainCatalog catalog, EntitySchema e) {
    if (e.protocols.contains('file')) return 'file entity (FileEntity ids)';
    for (final m in e.properties) {
      if (dartTypeFor(m.type) != null) continue;
      if (_hasDefault(catalog, m.type)) continue;
      final t = m.type.base;
      final container = t.kind == 'entity' && t.ref != e.id ? catalog.entities[t.ref] : null;
      if (container != null && catalog.isFixable(container)) continue;
      return '${m.name} (${m.type}) is required and has no Dart mapping or default';
    }
    return null;
  }

  bool _hasDefault(DomainCatalog catalog, SchemaType t) =>
      t.isOptional ||
      switch (t.kind) {
        'array' || 'set' || 'bool' || 'string' || 'attributedString' => true,
        'enum' => _enum(t.ref!)?.cases.isNotEmpty ?? false,
        // The validation app defines cases for every one of these.
        'openEnum' => true,
        _ => false,
      };

  EnumSchema? _enum(String ref) => catalogs[ref.split('.').first]?.enums[ref];

  String? _callWhyNot(IntentSchema intent) {
    if (callResult(intent) == CallResult.unsupported) return 'returns ${intent.result}';
    if (resultEntity(intent) case final r? when !adopted.containsKey(r)) return 'returns $r, not adopted';
    return null;
  }
}

void _writeApp(String root, _Plan plan) {
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: schema_validation
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
  assistant_actions:
    path: $_runtime
dev_dependencies:
  build_runner: ^2.15.0
  assistant_actions_generator:
    path: $_generator
''');
  final lib = Directory(p.join(root, 'lib'))..createSync();
  final models = StringBuffer()
    ..writeln('// ignore_for_file: unused_import')
    ..writeln("import 'package:assistant_actions/assistant_actions.dart';");
  for (final d in plan.domains) {
    models.writeln("import 'package:assistant_actions/schemas/${schemaLibraryFile(d)}';");
  }
  // Cases for every schema enum whose cases the app defines.
  final openEnums = <String, String>{};
  for (final d in plan.domains) {
    for (final e in plan.catalogs[d]!.enums.values) {
      if (e.cases.isNotEmpty) continue;
      openEnums[e.id] = '${dartEnumName(e.id)}Value';
      models
        ..writeln()
        ..writeln('@${dartEnumName(e.id)}()')
        ..writeln('enum ${openEnums[e.id]} { first, second }');
    }
  }
  for (final d in plan.domains) {
    final catalog = plan.catalogs[d]!;
    final domainIntents = plan.domainIntents[d]!;
    if (domainIntents.isNotEmpty) {
      final options = _interactions([for (final i in domainIntents) (i, IntentKind.call)]);
      models
        ..writeln()
        ..writeln('@${domainAnnotation(d)}(${[for (final i in domainIntents) '${i.name}: true', ...options].join(', ')})')
        ..writeln('class ${pascal(d)}Handler {}');
    }
    for (final e in catalog.entities.values) {
      if (!plan.adopted.containsKey(e.id)) continue;
      final names = SchemaNames(e);
      final args = [
        for (final m in e.properties)
          if (m.type.base.kind == 'entity' && m.type.base.ref != e.id && m.type.base.ref != null)
            if (catalog.entities[m.type.base.ref] case final c? when catalog.isFixable(c))
              '${m.name}: ${_fixed(catalog, c)}',
        for (final i in plan.intents[e.id]!) '${i.name}: true',
        ..._interactions([
          for (final (intent, kind) in catalog.intentsFor(e))
            if (plan.intents[e.id]!.contains(intent)) (intent, kind),
        ]),
      ];
      models
        ..writeln()
        ..writeln('@${names.annotation}(${args.join(', ')})')
        ..writeln('class ${_className(e)} {')
        ..writeln('  ${_className(e)}(this.id);')
        ..writeln('  @EntityId()')
        ..writeln('  final String id;');
      for (final m in e.properties) {
        final type = dartTypeFor(m.type, openEnums);
        if (type == null) continue;
        // References map to ids of adopted entities; fixed containers fill in
        // the others.
        if (_Plan.referenceOf(m) case final ref?) {
          if (!plan.adopted.containsKey(ref)) continue;
          final c = catalog.entities[ref];
          if (c != null && ref != e.id && catalog.isFixable(c) && !m.type.base.isList) continue;
        }
        models
          ..writeln('  @${names.fields}.${dartName(m.name)}')
          ..writeln('  ${type.endsWith('?') ? '' : 'late '}$type ${dartName(m.name)}${type.endsWith('?') ? '' : ''};');
      }
      models.writeln('}');
    }
  }
  File(p.join(lib.path, 'models.dart')).writeAsStringSync(models.toString());
  File(p.join(lib.path, 'assistant_actions.dart')).writeAsStringSync('''
@AssistantActionsApp(name: 'Schema Validation')
library;

import 'package:assistant_actions/assistant_actions.dart';

// ignore: unused_import
import 'models.dart';
''');
}

String _className(EntitySchema e) => '${pascal(e.domain)}${pascal(e.name)}Item';

/// Annotation arguments giving every other one of [intents] a spoken result
/// reading each parameter Siri can read out (and `{result}`), a
/// confirmation, and a Dart reply where it's live, so both shapes of each
/// intent kind reach Apple's tools. Deletes confirm by default either way.
List<String> _interactions(List<(IntentSchema, IntentKind)> intents) {
  final chosen = [
    for (final (i, (intent, kind)) in intents.indexed)
      if (i.isEven && intent.id != 'system.open') (intent, kind),
  ];
  String template(IntentSchema intent, {required bool result}) => [
        for (final p in intent.parameters)
          if (speakable(p.type)) '{${p.name}}',
        if (result && returnsItem(intent)) '{result}',
        'done.',
      ].join(' ');
  String map(Iterable<String> entries) => '{${entries.join(', ')}}';
  final replies = [
    for (final (intent, kind) in chosen)
      if (canReply(intent, kind)) "'${intent.name}'",
  ];
  return [
    if (chosen.isNotEmpty) ...[
      'dialogs: ${map([for (final (intent, _) in chosen) "'${intent.name}': '${template(intent, result: true)}'"])}',
      'confirm: ${map([for (final (intent, _) in chosen) "'${intent.name}': '${template(intent, result: false)}?'"])}',
    ],
    if (replies.isNotEmpty) 'replies: {${replies.join(', ')}}',
  ];
}

/// A const fixed instance of container [c], with placeholder strings.
String _fixed(DomainCatalog catalog, EntitySchema c) {
  final args = [
    "id: '${c.id}'",
    for (final m in c.properties)
      if (m.type.base.kind == 'string' && !m.type.isOptional)
        "${m.name}: '${m.name}'"
      else if (m.type.base.kind == 'entity' && !m.type.isOptional && m.type.base.ref != c.id)
        '${m.name}: ${_fixed(catalog, catalog.entities[m.type.base.ref]!)}',
  ];
  return '${SchemaNames(c).fixed}(${args.join(', ')})';
}

/// Compiles [swift] with the runtime's Swift for [platform] and runs Apple's
/// metadata processor on it. Returns whether both succeeded without errors.
Future<bool> _processSwift(String swift, String platform, String out) async {
  final dir = Directory(out)..createSync(recursive: true);
  final sources = p.join(_runtime, 'darwin', 'assistant_actions', 'Sources', 'assistant_actions');
  final generated = p.join(dir.path, 'AssistantActions.g.swift');
  File(generated).writeAsStringSync(File(swift).readAsStringSync().replaceFirst('import assistant_actions\n', ''));
  final stub = p.join(dir.path, 'Bridge.swift');
  File(stub).writeAsStringSync(_bridgeStub);
  final files = [
    generated,
    stub,
    for (final f in ['AssistantValues', 'AssistantInbox', 'AssistantSnapshot', 'AssistantQuery', 'AssistantSpotlight',
      'AssistantMatch', 'AssistantComparison', 'AssistantRichValues', 'AssistantHostCalls', 'AssistantReply',
      'AssistantDialog', 'AssistantInteraction', 'AssistantCardView'])
      p.join(sources, '$f.swift'),
  ];
  final ios = platform == 'ios';
  final sdk = (await Process.run('xcrun', ['--sdk', ios ? 'iphonesimulator' : 'macosx', '--show-sdk-path'])).stdout
      .toString()
      .trim();
  final target = ios ? 'arm64-apple-ios17.0-simulator' : 'arm64-apple-macos14.0';
  final protocols = p.join(dir.path, 'protocols.json');
  File(protocols).writeAsStringSync(jsonEncode(_constProtocols));
  final object = p.join(dir.path, 'App.o');
  final constValues = p.join(dir.path, 'App.swiftconstvalues');
  if (!await _step('swiftc ($platform)', 'xcrun', [
    'swiftc', '-sdk', sdk, '-target', target, '-module-name', 'App', '-parse-as-library', '-wmo', '-c', ...files,
    '-o', object, '-emit-const-values-path', constValues, //
    '-Xfrontend', '-const-gather-protocols-file', '-Xfrontend', protocols,
  ], dir.path, fatal: false, echoWarnings: true)) {
    return false;
  }
  // …/XcodeDefault.xctoolchain/usr/bin/swiftc → …/XcodeDefault.xctoolchain
  final swiftc = (await Process.run('xcrun', ['--find', 'swiftc'])).stdout.toString().trim();
  final toolchain = p.dirname(p.dirname(p.dirname(swiftc)));
  File(p.join(dir.path, 'sources.list')).writeAsStringSync(files.join('\n'));
  File(p.join(dir.path, 'consts.list')).writeAsStringSync(constValues);
  File(p.join(dir.path, 'empty.list')).writeAsStringSync('');
  final result = await Process.run(p.join(toolchain, 'usr', 'bin', 'appintentsmetadataprocessor'), [
    '--toolchain-dir', toolchain, '--module-name', 'App', '--sdk-root', sdk, '--xcode-version', 'validate',
    '--platform-family', ios ? 'iOS' : 'macOS', '--deployment-target', ios ? '17.0' : '14.0',
    '--bundle-identifier', 'dev.assistantactions.validation', '--output', dir.path, '--target-triple', target,
    '--binary-file', object, '--source-file-list', p.join(dir.path, 'sources.list'),
    '--metadata-file-list', p.join(dir.path, 'empty.list'),
    '--static-metadata-file-list', p.join(dir.path, 'empty.list'),
    '--swift-const-vals-list', p.join(dir.path, 'consts.list'),
    '--force', '--compile-time-extraction', '--deployment-aware-processing', '--no-app-shortcuts-localization',
  ]);
  final log = '${result.stdout}${result.stderr}';
  final problems = log
      .split('\n')
      .where((l) => l.contains('error:') || l.contains('warning:'))
      .map((l) => l.replaceFirst(RegExp(r'^.*appintentsmetadataprocessor\[[\d:]+\] '), ''))
      .toList();
  final ok = result.exitCode == 0 && !problems.any((l) => l.contains('error:'));
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} appintentsmetadataprocessor ($platform)'
      '${problems.isEmpty ? '' : ': ${problems.length} problems'}');
  for (final l in problems.take(200)) {
    stdout.writeln('     $l');
  }
  if (ok) {
    final metadata = File(p.join(dir.path, 'Metadata.appintents', 'extract.actionsdata'));
    if (metadata.existsSync()) {
      final json = jsonDecode(metadata.readAsStringSync()) as Map;
      stdout.writeln('     metadata: ${(json['actions'] as Map).length} intents, ${(json['entities'] as Map).length} entities, '
          '${(json['enums'] as List?)?.length ?? (json['enums'] as Map?)?.length ?? 0} enums');
    }
  }
  return ok;
}

/// The protocols Xcode gathers const values for (from an Xcode build's
/// `*_const_extract_protocols.json`).
const _constProtocols = [
  'AnyResolverProviding', 'AppEntity', 'AppEnum', 'AppExtension', 'AppIntent', 'AppIntentsPackage', //
  'AppShortcutProviding', 'AppShortcutsProvider', 'AppUnionValue', 'AppUnionValueCasesProviding',
  'DynamicMigration_v1', 'DynamicOptionsProvider', 'EntityQuery', 'ExtensionPointDefining', 'IntentValueQuery',
  'Resolver', 'StaticMigration_v1', 'TransientEntity', '_AssistantIntentsProvider', '_GenerativeFunctionExtractable',
  '_IntentValueRepresentable',
];

/// Stands in for the Flutter half of the bridge, which needs the engine.
const _bridgeStub = '''
import Foundation

@MainActor
public final class AssistantBridge {
  public static let shared = AssistantBridge()
  public func perform(_ action: String, args: [String: Any]) async throws -> String? { nil }
  public func inboxChanged() {}
}

public enum AssistantActionError: Error {
  case notRunning
  case failed(String)
}
''';

Future<bool> _step(String name, String exe, List<String> args, String dir,
    {bool fatal = true, bool echoWarnings = false}) async {
  final r = await Process.run(exe, args, workingDirectory: dir);
  final ok = r.exitCode == 0;
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $name');
  final log = '${r.stdout}${r.stderr}';
  if (!ok || echoWarnings) {
    final lines = log.split('\n').where((l) => ok ? l.contains('warning:') : l.trim().isNotEmpty).toList();
    for (final l in lines.take(120)) {
      stdout.writeln('     $l');
    }
  }
  if (!ok && fatal) {
    throw StateError('$name failed');
  }
  return ok;
}
