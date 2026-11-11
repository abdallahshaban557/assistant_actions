part of 'swift_writer.dart';

/// The OS versions plain actions and App Shortcuts need no `@available` for:
/// the runtime's deployment target.
const _baseFloor = {'iOS': 17, 'macOS': 14};

/// Writes `apple/AssistantShortcuts.g.swift`: the app's App Shortcuts.
String writeAppShortcuts(AppModel app) => SwiftWriter(app).writeShortcuts();

/// Plain `@AssistantAction` functions, `@AssistantEnum` enums, App Shortcuts
/// (`apple/AssistantShortcuts.g.swift`) and the public types they need.
extension _Actions on SwiftWriter {
  // ── App enums ─────────────────────────────────────────────────────────

  void _appEnum(AppEnumModel e) {
    final name = e.swiftName;
    _out
      ..writeln('/// `${e.className}` in Dart.')
      ..writeln('public enum $name: String, AppEnum {');
    for (final c in e.cases) {
      _out.writeln(swiftName(c.name) == c.name ? '  case ${c.name}' : '  case ${swiftName(c.name)} = "${c.name}"');
    }
    _out
      ..writeln()
      ..writeln('  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "${SwiftWriter._escape(e.title)}"')
      ..writeln('  public static let caseDisplayRepresentations: [$name: DisplayRepresentation] = [');
    for (final c in e.cases) {
      final title = '"${SwiftWriter._escape(c.title)}"';
      _out.writeln(c.synonyms.isEmpty
          ? '    .${swiftName(c.name)}: $title,'
          : '    .${swiftName(c.name)}: DisplayRepresentation(title: $title, '
              'synonyms: [${c.synonyms.map((s) => '"${SwiftWriter._escape(s)}"').join(', ')}]),');
    }
    _out
      ..writeln('  ]')
      ..writeln('}')
      ..writeln();
  }

  // ── Plain actions ─────────────────────────────────────────────────────

  /// `static let description` and `isDiscoverable`, when set.
  String _describe(String title, String? description, List<String> keywords, bool discoverable) {
    final lines = <String>[];
    if (description != null || keywords.isNotEmpty) {
      final words = keywords.isEmpty
          ? ''
          : ', searchKeywords: [${keywords.map((k) => '"${SwiftWriter._escape(k)}"').join(', ')}]';
      lines.add('  public static let description = IntentDescription("${SwiftWriter._escape(description ?? title)}"$words)');
    }
    if (!discoverable) lines.add('  public static let isDiscoverable = false');
    return lines.map((l) => '$l\n').join();
  }

  void _plainAction(ActionModel a) {
    final foreground = a.runs == RunsModel.withFlutter;
    final result = a.result;
    final floor = _actionFloor(a);
    _out.writeln('/// `${a.functionName}` in Dart (${foreground ? 'runs with Flutter' : 'deferred'}).');
    if (_above(floor)) _out.writeln(_availability(floor));
    _out
      ..writeln('public struct ${a.swiftName}: AppIntent${foreground ? ', ForegroundContinuableIntent' : ''} {')
      ..writeln('  public static let title: LocalizedStringResource = "${SwiftWriter._escape(a.title)}"')
      ..write(_describe(a.title, a.description, a.searchKeywords, a.isDiscoverable))
      ..writeln();
    for (final p in a.params) {
      final options = [
        'title: "${SwiftWriter._escape(p.title)}"',
        if (p.swiftDefault case final d?) 'default: $d',
        if (p.prompt case final prompt?) 'requestValueDialog: "${SwiftWriter._escape(prompt)}"',
      ];
      _out.writeln('  @Parameter(${options.join(', ')})\n  public var ${swiftName(p.name)}: ${_paramSwift(p)}\n');
    }
    final reply = a.returnsReply;
    final base = result == null ? 'IntentResult' : 'IntentResult & ReturnsValue<${_resultSwift(result)}>';
    _out
      ..writeln('  public init() {}')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  public func perform() async throws -> some ${_resultType(base, dialog: true, snippet: reply)} {')
      ..writeln(a.params.isEmpty ? '    let args: [String: Any] = [:]' : '    let args: [String: Any] = [');
    for (final p in a.params) {
      _out.writeln('      "${p.name}": ${_encodeParam(p)},');
    }
    if (a.params.isNotEmpty) _out.writeln('    ]');
    // Asked before anything runs or is queued.
    if (a.confirm != null) _out.writeln('    try await assistantConfirm(${_spokenDialog(a.confirm!, a)})');
    final dialog = a.dialog == null ? '"Done."' : _spokenDialog(a.dialog!, a);
    if (a.liveActivity) {
      // The reader allows no Shortcuts value here.
      _out.writeln(_liveActivityPerform(a, dialog));
    } else if (!foreground) {
      _out.writeln('''
    AssistantInbox.call("${a.id}", args: args)
    AssistantBridge.shared.inboxChanged()
    return .result(dialog: IntentDialog(stringLiteral: $dialog))''');
    } else {
      _out.writeln('''
    #if os(iOS)
      // iOS doesn't start the Flutter engine without a scene, so answer from the foreground.
      if UIApplication.shared.applicationState != .active {
        try await requestToContinueInForeground()
      }
    #endif''');
      if (reply) {
        _out.writeln('    let reply = AssistantReply(json: try await AssistantBridge.shared.perform("${a.id}", args: args))');
        if (result != null) _out.write(_decodeResult(result, a, source: 'reply.value', reply: true));
        _out.writeln('    return ${_resultOf(value: result == null ? null : 'value', dialog: 'reply.dialog ?? $dialog', snippet: true)}');
      } else {
        _out.writeln('    let reply = try await AssistantBridge.shared.perform("${a.id}", args: args)');
        if (result == null) {
          _out.writeln('    return .result(dialog: IntentDialog(stringLiteral: reply ?? $dialog))');
        } else {
          _out
            ..writeln('    let result = AssistantValues.result(reply)')
            ..write(_decodeResult(result, a, source: 'result.value'))
            ..writeln('    return .result(value: value, dialog: IntentDialog(stringLiteral: result.dialog ?? $dialog))');
        }
      }
    }
    _out
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
    if (a.liveActivity) _liveActivityConformance(a);
  }

  /// The Swift type of an action value: `[String]`, `SizeEnum`, ….
  String _valueSwift(ValueType v) {
    final one = switch (v.kind) {
      ValueKind.string => 'String',
      ValueKind.integer => 'Int',
      ValueKind.decimal => 'Double',
      ValueKind.boolean => 'Bool',
      ValueKind.dateTime => 'Date',
      ValueKind.uri => 'URL',
      // `Duration` only works as a parameter from iOS 26.
      ValueKind.duration => 'Measurement<UnitDuration>',
      ValueKind.enumeration => v.enumRef == null ? '${v.appEnum}Enum' : _enumName(v.enumRef!),
      ValueKind.person => 'IntentPerson',
      ValueKind.place => 'PlaceDescriptor',
      ValueKind.file => 'IntentFile',
      _ => throw StateError('No action type for ${v.kind}'),
    };
    return v.list ? '[$one]' : one;
  }

  /// Whether [p]'s Swift parameter is optional: Dart takes null, or fills in
  /// a default Swift can't state.
  bool _optional(ParamModel p) => p.nullable || (p.defaultDart != null && p.swiftDefault == null);

  String _paramSwift(ParamModel p) {
    final base = p.entity != null ? (p.entityList ? '[${p.entity!.swiftName}]' : p.entity!.swiftName) : _valueSwift(p.value!);
    return '$base${_optional(p) ? '?' : ''}';
  }

  /// Swift expression encoding [p] for Dart: entities as ids.
  String _encodeParam(ParamModel p) {
    final n = swiftName(p.name);
    final optional = _optional(p);
    if (p.entity != null) {
      if (p.entityList) return optional ? 'AssistantValues.encode($n?.map(\\.id))' : '$n.map(\\.id)';
      return optional ? 'AssistantValues.encode($n?.id)' : '$n.id';
    }
    if (p.value!.list) {
      return optional
          ? '$n.map { \$0.map { AssistantValues.encode(\$0) } as Any } ?? NSNull()'
          : '$n.map { AssistantValues.encode(\$0) }';
    }
    return 'AssistantValues.encode($n)';
  }

  /// A Swift string literal for [template], with `{param}` said aloud.
  String _spokenDialog(String template, ActionModel a) {
    final escaped = SwiftWriter._escape(template);
    return '"${escaped.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final p = a.params.firstWhere((p) => p.name == m.group(1));
      final n = swiftName(p.name);
      final optional = _optional(p);
      if (p.entity != null) {
        if (p.entityList) return optional ? '\\($n?.map(\\.title).formatted() ?? "")' : '\\($n.map(\\.title).formatted())';
        return optional ? '\\($n?.title ?? "")' : '\\($n.title)';
      }
      final v = p.value!;
      if (v.list) return optional ? '\\($n?.formatted() ?? "")' : '\\($n.formatted())';
      // A String for [x], or (unless [text]) any value that reads well.
      String said(String x, {bool text = false}) => switch (v.kind) {
            ValueKind.dateTime => '$x.formatted(date: .abbreviated, time: .shortened)',
            ValueKind.uri => '$x.absoluteString',
            ValueKind.duration => '$x.formatted()',
            ValueKind.enumeration => 'String(localized: $x.localizedStringResource)',
            _ => text ? '"\\($x)"' : x,
          };
      return optional ? '\\($n.map { ${said(r'$0', text: true)} } ?? "")' : '\\(${said(n)})';
    })}"';
  }

  String _resultSwift(ResultModel r) {
    final String type;
    if (r.isEntity) {
      final name = r.entity?.swiftName ?? r.schemaEntity!.swiftName;
      type = r.list ? '[$name]' : name;
    } else {
      type = _valueSwift(r.value!);
    }
    return '$type${r.nullable ? '?' : ''}';
  }

  /// Swift lines decoding what Dart returned ([source], an `Any?`) into
  /// `value`. With a [reply], an action returning one item asks the user to
  /// pick when Dart sent `AssistantReply.choose`.
  String _decodeResult(ResultModel r, ActionModel a, {required String source, bool reply = false}) {
    final failed = 'throw AssistantActionError.failed("${a.functionName} returned nothing Siri can use")';
    if (r.isEntity) {
      final name = r.entity?.swiftName ?? r.schemaEntity!.swiftName;
      final query = '${name}Query()';
      if (!r.list) {
        if (reply) {
          final lines = [
            '    let candidates = try await $query.entities(for: reply.ids)',
            if (r.nullable)
              '    let value = try await assistantChoose(among: candidates, prompt: reply.prompt)'
            else
              '    guard let value = try await assistantChoose(among: candidates, prompt: reply.prompt) else { $failed }',
          ];
          return '${lines.join('\n')}\n';
        }
        final lines = [
          '    let ids = AssistantValues.string($source).map { [\$0] } ?? []',
          if (r.nullable)
            '    let value = try await $query.entities(for: ids).first'
          else
            '    guard let value = try await $query.entities(for: ids).first else { $failed }',
        ];
        return '${lines.join('\n')}\n';
      }
      final lines = [
        if (r.nullable) ...[
          '    var value: [$name]? = nil',
          '    if let ids = AssistantValues.strings($source) {',
          '      let found = try await $query.entities(for: ids)',
          '      value = ids.compactMap { id in found.first { \$0.id == id } }',
          '    }',
        ] else ...[
          '    let ids = AssistantValues.strings($source) ?? []',
          '    let found = try await $query.entities(for: ids)',
          '    let value = ids.compactMap { id in found.first { \$0.id == id } }',
        ],
      ];
      return '${lines.join('\n')}\n';
    }
    final v = r.value!;
    if (v.list) {
      final each = _decodeValue(v.element, r'$0');
      return r.nullable
          ? '    let value = AssistantValues.items($source)?.compactMap { $each }\n'
          : '    let value = (AssistantValues.items($source) ?? []).compactMap { $each }\n';
    }
    final decoded = _decodeValue(v, source);
    return r.nullable ? '    let value = $decoded\n' : '    guard let value = $decoded else { $failed }\n';
  }

  /// Swift expression decoding [expr] (an `Any?`) as a value of [v].
  String _decodeValue(ValueType v, String expr) => switch (v.kind) {
        ValueKind.string => 'AssistantValues.string($expr)',
        ValueKind.integer => 'AssistantValues.int($expr)',
        ValueKind.decimal => 'AssistantValues.double($expr)',
        ValueKind.boolean => 'AssistantValues.bool($expr)',
        ValueKind.dateTime => 'AssistantValues.date($expr)',
        ValueKind.uri => 'AssistantValues.url($expr)',
        ValueKind.duration => 'AssistantValues.measurement($expr)',
        ValueKind.enumeration => 'AssistantValues.string($expr).flatMap(${_valueSwift(v.element)}.init(rawValue:))',
        ValueKind.person => 'AssistantValues.person($expr)',
        ValueKind.place => 'AssistantValues.place($expr)',
        ValueKind.file => 'AssistantValues.file($expr)',
        _ => throw StateError('No action result for ${v.kind}'),
      };

  static const _none = <String, num>{'iOS': 0, 'macOS': 0};

  /// Whether [floor] is above what the runtime supports anyway.
  bool _above(Map<String, num> floor) {
    final (iOS, macOS) = _versions(floor);
    return iOS > _baseFloor['iOS']! || macOS > _baseFloor['macOS']!;
  }

  Map<String, num> _valueFloor(ValueType v) => switch (v.kind) {
        ValueKind.place => SwiftWriter._typeFloors['placeDescriptor']!,
        ValueKind.enumeration when v.enumRef != null =>
          _enumSchema(v.enumRef!).availability.isEmpty ? _none : _enumSchema(v.enumRef!).availability,
        _ => _none,
      };

  /// The earliest OS that has every type [a] takes and returns.
  Map<String, num> _actionFloor(ActionModel a) {
    var floor = _none;
    for (final p in a.params) {
      if (p.value case final v?) floor = SwiftWriter._max(floor, _valueFloor(v));
    }
    if (a.result case final r?) {
      if (r.value case final v?) floor = SwiftWriter._max(floor, _valueFloor(v));
      if (r.schemaEntity case final s?) floor = SwiftWriter._max(floor, _entityFloor(s.schema));
    }
    return floor;
  }

  /// Schema types plain actions use, which [_schemas] declares in Swift.
  List<SchemaType> get _actionSchemaTypes => [
        for (final a in app.actions) ...[
          for (final p in a.params)
            if (p.value?.enumRef case final ref?) SchemaType('enum', ref: ref),
          if (a.result?.value?.enumRef case final ref?) SchemaType('enum', ref: ref),
        ],
      ];

  /// Frameworks plain actions need: GeoToolbox for places.
  void _actionImports() {
    final places = app.actions.any((a) =>
        a.params.any((p) => p.value?.kind == ValueKind.place) || a.result?.value?.kind == ValueKind.place);
    if (places) _imports.add('GeoToolbox');
  }

  // ── Public types ──────────────────────────────────────────────────────

  /// The Swift struct of schema intent shortcut [s].
  String _intentStruct(IntentShortcutModel s) {
    if (s.openClass case final c?) return 'Open${c}Intent';
    return '${s.owner?.className ?? pascal(s.intent.domain)}${pascal(s.intent.name)}Intent';
  }

  /// Schema types that must be public: App Shortcuts live in the Runner, a
  /// different Swift module, and public plain actions take and return them.
  Set<String> get _publicTypes {
    final names = <String>{};
    void visit(SchemaType t) {
      switch (t.kind) {
        case 'optional' || 'array' || 'set':
          visit(t.of!);
        case 'entity' when t.ref != null:
          final name = _adopted[t.ref]?.swiftName ?? _containerName(t.ref!);
          if (names.add(name)) {
            names.add('${name}Query');
            for (final p in _entitySchema(t.ref!).properties) {
              visit(p.type);
            }
          }
        case 'enum' || 'openEnum':
          names.add(_enumName(t.ref!));
        case 'union':
          if (names.add(_unionName(t.ref!))) {
            for (final c in _unionSchema(t.ref!).cases) {
              visit(c.type);
            }
          }
      }
    }

    for (final t in _actionSchemaTypes) {
      visit(t);
    }
    for (final a in app.actions) {
      if (a.result?.schemaEntity case final s?) visit(SchemaType('entity', ref: s.schema.id));
    }
    for (final s in app.intentShortcuts) {
      names.add(_intentStruct(s));
      if (s.openClass case final c?) {
        if (app.schemaEntities.where((e) => e.className == c).firstOrNull case final e?) {
          visit(SchemaType('entity', ref: e.schema.id));
        }
      } else {
        for (final p in s.intent.parameters) {
          visit(p.type);
        }
        // What `perform` returns: the created item, a call's result.
        if (s.intent.result case final r?) visit(r);
        if (s.owner case final o?) visit(SchemaType('entity', ref: o.schema.id));
      }
    }
    return names;
  }

  /// Makes the [_publicTypes] declarations in [swift] and their members
  /// public, and gives intents a public `init()` for the Runner to call.
  String _publicize(String swift) {
    final types = _publicTypes;
    if (types.isEmpty) return swift;
    final intents = {for (final s in app.intentShortcuts) _intentStruct(s)};
    final declaration = RegExp(r'^(struct|enum|extension) (\w+)\b');
    final member = RegExp(r'^  (static |func |var |let |init[(<]|typealias )');
    final out = <String>[];
    var inside = false;
    for (final line in swift.split('\n')) {
      if (!inside) {
        final m = declaration.firstMatch(line);
        if (m != null && types.contains(m[2]) && line.endsWith('{')) {
          inside = true;
          // Public types aren't Sendable implicitly, and entities holding a
          // union must be (`@UnionValue enum X {`).
          final union = m[1] == 'enum' && line == 'enum ${m[2]} {';
          out.add(m[1] == 'extension' ? line : (union ? 'public enum ${m[2]}: Sendable {' : 'public $line'));
          // Intents (for the Runner) and queries (`EntityQuery`) need one.
          if (m[1] == 'struct' && (intents.contains(m[2]) || m[2]!.endsWith('Query'))) out.add('  public init() {}');
        } else {
          out.add(line);
        }
        continue;
      }
      if (line == '}') inside = false;
      out.add(member.hasMatch(line) ? '  public ${line.substring(2)}' : line);
    }
    return out.join('\n');
  }

  // ── App Shortcuts ─────────────────────────────────────────────────────

  /// The `@available` [struct] was declared with, as (iOS, macOS) versions
  /// (infinite when unavailable there).
  (num, num) _declared(String text, String struct) {
    final m = RegExp(r'((?:@available\([^)\n]*\)\n)+)(?:@\w+\([^)\n]*\)\n)*(?:public )?struct ' + struct + r'\b')
        .firstMatch(text);
    if (m == null) return (_baseFloor['iOS']!, _baseFloor['macOS']!);
    num iOS = _baseFloor['iOS']!, macOS = _baseFloor['macOS']!;
    for (final a in RegExp(r'@available\(([^)]*)\)').allMatches(m[1]!)) {
      final args = a[1]!;
      if (args == 'iOS, unavailable') iOS = double.infinity;
      if (args == 'macOS, unavailable') macOS = double.infinity;
      for (final v in RegExp(r'(iOS|macOS) ([\d.]+)').allMatches(args)) {
        if (v[1] == 'iOS') iOS = num.parse(v[2]!);
        if (v[1] == 'macOS') macOS = num.parse(v[2]!);
      }
    }
    return (iOS, macOS);
  }

  /// `apple/AssistantShortcuts.g.swift`, the one file that must be in the
  /// app's Runner targets: Apple only reads App Shortcuts from the app.
  String writeShortcuts() {
    final swift = write();
    final shortcuts = [
      for (final a in app.actions)
        if (a.shortcut case final s?) (a.swiftName, s, {for (final p in a.params) p.name}),
      for (final a in app.snapshotActions)
        if (a.shortcut case final s?) (a.swiftName, s, const <String>{}),
      for (final s in app.intentShortcuts) (_intentStruct(s), s.shortcut, const <String>{}),
    ];
    final out = StringBuffer()
      ..writeln('// GENERATED by assistant_actions_generator. Do not edit.')
      ..writeln('// Must be in both Runner targets (dart run assistant_actions:install adds it).')
      ..writeln();
    if (shortcuts.isEmpty) {
      out.writeln('// No @AssistantAction has a shortcut, so there is no AppShortcutsProvider.');
      return out.toString();
    }
    // Phrases naming entities learn new items when Dart publishes them.
    final entityPhrases = app.actions.any((a) =>
            a.shortcut != null &&
            a.params.any((p) => p.entity != null && a.shortcut!.phrases.any((ph) => ph.contains('{${p.name}}')))) ||
        app.intentShortcuts.any((s) => [
              if (s.openClass != null) 'target',
              for (final p in s.intent.parameters)
                if (p.type.base.kind == 'entity') p.name,
            ].any((name) => s.shortcut.phrases.any((ph) => ph.contains('{$name}'))));
    out
      ..writeln(entityPhrases ? 'import AppIntents\nimport Foundation' : 'import AppIntents')
      ..writeln('import assistant_actions_app')
      ..writeln()
      ..writeln('struct AssistantShortcuts: AppShortcutsProvider {');
    if (app.shortcutTileColor case final color?) {
      out
        ..writeln('  static var shortcutTileColor: ShortcutTileColor { .$color }')
        ..writeln();
    }
    out.writeln('  static var appShortcuts: [AppShortcut] {');
    var gated = false;
    for (final (struct, s, _) in shortcuts) {
      final (iOS, macOS) = _declared(swift, struct);
      final phrases = s.phrases.map((p) => '"${SwiftWriter._escape(p).replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
            return m[1] == 'app' ? r'\(.applicationName)' : '\\(\\.\$${m[1]})';
          })}"');
      final shortcut = [
        'AppShortcut(',
        '  intent: $struct(),',
        '  phrases: [${phrases.join(', ')}],',
        '  shortTitle: "${SwiftWriter._escape(s.shortTitle)}",',
        '  systemImageName: "${SwiftWriter._escape(s.systemImage)}")',
      ];
      final checks = [
        if (iOS.isFinite && iOS > _baseFloor['iOS']!) 'iOS ${SwiftWriter._version(iOS)}',
        if (macOS.isFinite && macOS > _baseFloor['macOS']!) 'macOS ${SwiftWriter._version(macOS)}',
      ];
      final os = iOS.isInfinite ? 'macOS' : (macOS.isInfinite ? 'iOS' : null);
      var lines = shortcut;
      if (checks.isNotEmpty) {
        if (!gated) {
          out.writeln('    // `if #available` here needs the Runner targets at iOS 17.4 / macOS 14.4 or later.');
          gated = true;
        }
        lines = ['if #available(${checks.join(', ')}, *) {', for (final l in lines) '  $l', '}'];
      }
      if (os != null) lines = ['#if os($os)', for (final l in lines) '  $l', '#endif'];
      for (final l in lines) {
        out.writeln('    $l');
      }
    }
    out
      ..writeln('  }')
      ..writeln('}');
    if (entityPhrases) {
      out.writeln('''

/// Found by name by the assistant_actions runtime, which calls it after
/// `AssistantActions.publish`, so phrases naming entities learn new items.
@objc(AssistantActionsAppShortcuts)
final class AssistantActionsAppShortcuts: NSObject {
  @objc static func updateAppShortcutParameters() {
    AssistantShortcuts.updateAppShortcutParameters()
  }
}''');
    }
    return out.toString();
  }
}
