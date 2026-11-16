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
      final image = c.systemImage == null ? '' : ', image: .init(systemName: "${SwiftWriter._escape(c.systemImage!)}")';
      _out.writeln(c.synonyms.isEmpty && image.isEmpty
          ? '    .${swiftName(c.name)}: $title,'
          : '    .${swiftName(c.name)}: DisplayRepresentation(title: $title$image'
              '${c.synonyms.isEmpty ? '' : ', synonyms: [${c.synonyms.map((s) => '"${SwiftWriter._escape(s)}"').join(', ')}]'}),');
    }
    _out
      ..writeln('  ]')
      ..writeln('}')
      ..writeln()
      ..writeln('extension $name: AssistantComparable {}')
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
    // With `@AssistantBackground()`, live actions run Dart in the background
    // on iOS (see swift_writer_background.dart) unless they open the app.
    final background = foreground && _background && !a.opensApp;
    // How it gets the app forward, per platform (swift_writer_modern.dart).
    final modes = _modes(opensApp: a.opensApp, background: background, floor: floor);
    _out.writeln('/// `${a.functionName}` in Dart (${foreground ? 'runs with Flutter' : 'deferred'}).');
    if (_above(floor)) _out.writeln(_availability(floor));
    _out
      ..writeln('public struct ${a.swiftName}: AppIntent${foreground ? _continuable(modes, ', ') : ''} {')
      ..writeln('  public static let title: LocalizedStringResource = "${SwiftWriter._escape(a.title)}"')
      ..write(_describe(a.title, a.description, a.searchKeywords, a.isDiscoverable))
      ..write(_unlockMember(_actionUnlock(a), access: 'public '))
      ..write(_actionSummaryMember(a, access: 'public '))
      ..writeln();
    if (foreground) _out.write(_modesMember(modes, access: 'public '));
    for (final p in a.params) {
      _out.writeln('  ${_parameterAttr(a, p)}\n  public var ${swiftName(p.name)}: ${_paramSwift(p)}\n');
    }
    final reply = a.returnsReply;
    final base = result == null ? 'IntentResult' : 'IntentResult & ReturnsValue<${_resultSwift(result)}>';
    _out
      ..writeln('  public init() {}')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  public func perform() async throws -> some ${_resultType(base, dialog: true, snippet: reply, floor: floor, interactive: a.cardButtons)} {')
      ..writeln(a.params.isEmpty ? '    let args: [String: Any] = [:]' : '    let args: [String: Any] = [');
    for (final p in a.params) {
      _out.writeln('      "${p.name}": ${_encodeParam(p)},');
    }
    if (a.params.isNotEmpty) _out.writeln('    ]');
    // Asked before anything runs or is queued.
    if (a.confirm != null) _out.writeln('    try await assistantConfirm(${_spokenDialog(a.confirm!, a)})');
    if (a.control != null && a.control!.isToggle) {
      final cid = SwiftWriter._escape(a.control!.id);
      _out
        ..writeln('    AssistantAppGroup.userDefaults.set(value, forKey: "assistant_actions.control.$cid")')
        ..writeln('    assistantReloadControl("$cid")');
    }
    final dialog = a.dialog == null ? '"Done."' : _spokenDialog(a.dialog!, a);
    String undoRegister(String? resultExpr) {
      if (a.undo == null) return '';
      if (resultExpr == null || !a.undo!.takesResult) {
        return '${_undoLines(floor, a.title, 'AssistantUndo.call("${a.id}", args: args)')}\n';
      }
      return '    var undoArgs = args\n'
          '    undoArgs["result"] = $resultExpr\n'
          '${_undoLines(floor, a.title, 'AssistantUndo.call("${a.id}", args: undoArgs)')}\n';
    }

    if (a.liveActivity) {
      // The reader allows no Shortcuts value here.
      _out.writeln(_liveActivityPerform(a, dialog, modes));
    } else if (!foreground) {
      _out
        ..writeln('    AssistantInbox.call("${a.id}", args: args)')
        ..writeln('    $_inboxChanged')
        ..write(undoRegister(null))
        ..writeln('    return .result(dialog: IntentDialog(stringLiteral: $dialog))');
    } else {
      final forward = _foregroundLines(modes,
          activateOnMac: a.opensApp,
          comment: background || a.opensApp
              ? null
              : "      // iOS doesn't start the Flutter engine without a scene, so answer from the foreground.");
      if (forward.isNotEmpty) _out.writeln(forward);
      if (reply) {
        _out.writeln('    let reply = AssistantReply(json: try await callDart("${a.id}", args: args))');
        if (result != null) _out.write(_decodeResult(result, a, source: 'reply.value', reply: true));
        final undoResult = result == null
            ? null
            : result.isEntity && !result.list
                ? (result.nullable
                    ? '(${_dartID(result.schemaEntity?.schema.id, 'value?')} ?? reply.ids.first as Any? ?? NSNull())'
                    : _dartID(result.schemaEntity?.schema.id, 'value'))
                : 'reply.value ?? NSNull()';
        _out
          ..write(undoRegister(undoResult))
          ..write(_replyReturn(
              value: result == null ? null : 'value',
              dialog: 'reply.dialog ?? $dialog',
              floor: floor,
              interactive: a.cardButtons));
      } else {
        _out.writeln('    let reply = try await callDart("${a.id}", args: args)');
        if (result == null) {
          _out
            ..write(undoRegister(a.returnsString ? 'reply ?? NSNull()' : null))
            ..writeln('    return .result(dialog: IntentDialog(stringLiteral: reply ?? $dialog))');
        } else {
          _out
            ..writeln('    let result = AssistantValues.result(reply)')
            ..write(_decodeResult(result, a, source: 'result.value'))
            ..write(undoRegister('result.value ?? NSNull()'))
            ..writeln('    return .result(value: value, dialog: IntentDialog(stringLiteral: result.dialog ?? $dialog))');
        }
      }
    }
    _out
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
    if (a.control != null && a.control!.isToggle) {
      final toggleFloor = SwiftWriter._max(floor, const {'iOS': 18, 'macOS': 15});
      _out
        ..writeln(_availability(toggleFloor))
        ..writeln('extension ${a.swiftName}: SetValueIntent {}')
        ..writeln();
    }
    if (a.liveActivity) _liveActivityConformance(a);
    // Live calls report progress and can be cancelled (swift_writer_modern.dart).
    if (foreground) _out.write(_continuableExtension(a.swiftName, modes, _above(floor) ? _availability(floor) : ''));
    if (foreground || a.liveActivity) {
      _out.writeln(_liveConformances(a.swiftName, _above(floor) ? floor : null, longRunning: a.longRunning));
      if (a.params.isNotEmpty) {
        _out
          ..writeln(_actionPromptingConformance(a, _above(floor) ? floor : null))
          ..writeln();
      }
    }
    if (a.undo != null) {
      _out
        ..writeln(_actionUndoConformance(a.swiftName, floor))
        ..writeln();
    }
    _optionsProviders(a, floor);
  }

  String _optionsProviderName(ActionModel a, ParamModel p) => '${a.swiftName}${pascal(p.name)}OptionsProvider';

  static String _swiftDouble(num n) {
    final s = '${n.toDouble()}';
    return s.contains('.') || s.contains('e') ? s : '$s.0';
  }

  String? _swiftRange(ParamModel p) {
    if (p.min == null || p.max == null) return null;
    return p.value?.kind == ValueKind.integer
        ? '(${p.min!.toInt()}, ${p.max!.toInt()})'
        : '(${_swiftDouble(p.min!)}, ${_swiftDouble(p.max!)})';
  }

  String? _swiftInputOptions(ParamModel p) {
    if (!p.hasInputOptions) return null;
    final parts = [
      if (p.keyboardType case final k?) 'keyboardType: ${k.swift}',
      if (p.capitalization case final c?) 'capitalizationType: .${c.name}',
      if (p.multiline) 'multiline: true',
    ];
    return 'String.IntentInputOptions(${parts.join(', ')})';
  }

  String _parameterAttr(ActionModel a, ParamModel p) {
    final parts = [
      'title: "${SwiftWriter._escape(p.title)}"',
      if (p.swiftDefault != null && p.options == null) 'default: ${p.swiftDefault}',
      if (p.controlStyle case final c?) 'controlStyle: .${c.name}',
      if (_swiftRange(p) case final r?) 'inclusiveRange: $r',
      if (_swiftInputOptions(p) case final io?) 'inputOptions: $io',
      if (p.supportedContentTypes case final types?)
        'supportedContentTypes: [${types.map((t) => 'UTType("${SwiftWriter._escape(t)}") ?? .item').join(', ')}]',
      if (p.prompt != null) 'requestValueDialog: "${SwiftWriter._escape(p.prompt!)}"',
      if (p.options != null) 'optionsProvider: ${_optionsProviderName(a, p)}()',
    ];
    return '@Parameter(${parts.join(', ')})';
  }

  String _encodeOptionsDep(ParamModel dep) {
    if (dep.entity != null) return dep.entityList ? r'v.map(\.id)' : 'v.id';
    if (dep.schemaEntity case final s?) {
      return dep.entityList ? 'v.map(${_dartIDPath(s.schema.id)})' : _dartID(s.schema.id, 'v');
    }
    return dep.value!.list ? r'v.map { AssistantValues.encode($0) }' : 'AssistantValues.encode(v)';
  }

  void _optionsProviders(ActionModel a, Map<String, num> floor) {
    for (final p in a.params) {
      final opt = p.options;
      if (opt == null) continue;
      final elemSwift = p.isEntity ? p.entitySwiftName : _valueSwift(p.value!.element);
      _out.writeln('/// Dynamic options for `${a.functionName}.${p.name}` (`${opt.functionName}`).');
      if (_above(floor)) _out.writeln(_availability(floor));
      _out.writeln('public struct ${_optionsProviderName(a, p)}: DynamicOptionsProvider {');
      if (opt.dependencies.isNotEmpty) {
        final deps = opt.dependencies.map((d) => '\\.\$${d.name}').join(', ');
        _out
          ..writeln('  @IntentParameterDependency<${a.swiftName}>($deps)')
          ..writeln('  public var intent')
          ..writeln();
      }
      _out.writeln('  public init() {}');
      if (p.swiftDefault != null && !p.entityList && !(p.value?.list ?? false)) {
        _out
          ..writeln()
          ..writeln('  public func defaultResult() async -> $elemSwift? { ${p.swiftDefault} }');
      }
      _out
        ..writeln()
        ..writeln('  public func results() async throws -> [$elemSwift] {');
      if (opt.dependencies.isEmpty) {
        _out.writeln('    let args: [String: Any] = [:]');
      } else {
        _out.writeln('    var args: [String: Any] = [:]');
        for (final d in opt.dependencies) {
          final dep = a.params.firstWhere((q) => q.name == d.name);
          _out.writeln('    if let v = intent?.${swiftName(dep.name)} { args["${d.name}"] = ${_encodeOptionsDep(dep)} }');
        }
      }
      _out
        ..writeln('    if $_dartReady,')
        ..writeln('      let reply = try? await AssistantBridge.shared.perform("options.${a.id}.${p.name}", args: args)')
        ..writeln('    {');
      if (p.isEntity) {
        final schemaId = p.schemaEntity?.schema.id;
        _out
          ..writeln('      let ids = AssistantValues.stringList(reply)')
          ..writeln('      let found = ${_lookup(elemSwift, schemaId, 'ids')}')
          ..writeln('      return ids.compactMap { id in found.first { ${_dartID(schemaId, r'$0')} == id } }');
      } else {
        final decoder = p.value!.element.swiftDecoder;
        _out.writeln('      return (AssistantValues.items(AssistantValues.json(reply)) ?? []).compactMap(AssistantValues.$decoder)');
      }
      _out.writeln('    }');
      if (p.isEntity) {
        final records = 'AssistantSnapshot.records("${p.entityClassName}")';
        final filtered = opt.snapshotField == null
            ? records
            : '$records.filter { AssistantValues.bool(\$0.fields["${opt.snapshotField}"]) == true }';
        _out.writeln('    return $filtered.map($elemSwift.init(record:))');
      } else if (opt.snapshotCollection != null && opt.snapshotField != null) {
        final decoder = p.value!.element.swiftDecoder;
        final extract = opt.snapshotField == 'title'
            ? 'record.title'
            : 'AssistantValues.$decoder(record.fields["${opt.snapshotField}"])';
        _out
          ..writeln('    var seen = Set<$elemSwift>()')
          ..writeln('    var out: [$elemSwift] = []')
          ..writeln('    for record in AssistantSnapshot.records("${opt.snapshotCollection}") {')
          ..writeln(opt.snapshotField == 'title'
              ? '      let v = $extract\n      if !v.isEmpty && seen.insert(v).inserted { out.append(v) }'
              : '      if let v = $extract, seen.insert(v).inserted { out.append(v) }')
          ..writeln('    }')
          ..writeln('    return out');
      } else {
        _out.writeln('    return []');
      }
      _out
        ..writeln('  }')
        ..writeln('}')
        ..writeln();
    }
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
      ValueKind.currency => 'IntentCurrencyAmount',
      ValueKind.length => 'Measurement<UnitLength>',
      ValueKind.mass => 'Measurement<UnitMass>',
      ValueKind.temperature => 'Measurement<UnitTemperature>',
      ValueKind.volume => 'Measurement<UnitVolume>',
      ValueKind.speed => 'Measurement<UnitSpeed>',
      ValueKind.energy => 'Measurement<UnitEnergy>',
      _ => throw StateError('No action type for ${v.kind}'),
    };
    return v.list ? '[$one]' : one;
  }

  /// Whether [p]'s Swift parameter is optional: Dart takes null, or fills in
  /// a default Swift can't state.
  bool _optional(ParamModel p) => p.nullable || (p.defaultDart != null && p.swiftDefault == null);

  String _paramSwift(ParamModel p) {
    final base = p.isEntity ? (p.entityList ? '[${p.entitySwiftName}]' : p.entitySwiftName) : _valueSwift(p.value!);
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
    if (p.schemaEntity case final s?) {
      final idPath = _dartIDPath(s.schema.id);
      if (p.entityList) return optional ? 'AssistantValues.encode($n?.map($idPath))' : '$n.map($idPath)';
      return optional ? 'AssistantValues.encode(${_dartID(s.schema.id, '$n?')})' : _dartID(s.schema.id, n);
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
      if (p.schemaEntity != null) {
        const display = r'String(localized: $0.displayRepresentation.title)';
        if (p.entityList) {
          return optional
              ? '\\($n?.map { $display }.formatted() ?? "")'
              : '\\($n.map { $display }.formatted())';
        }
        return optional
            ? '\\($n.map { $display } ?? "")'
            : '\\(String(localized: $n.displayRepresentation.title))';
      }
      final v = p.value!;
      if (v.list) {
        if (v.kind == ValueKind.currency) {
          const fmt = r'$0.amount.formatted(.currency(code: $0.currencyCode))';
          return optional ? '\\($n?.map { $fmt }.formatted() ?? "")' : '\\($n.map { $fmt }.formatted())';
        }
        if (const {
          ValueKind.length,
          ValueKind.mass,
          ValueKind.temperature,
          ValueKind.volume,
          ValueKind.speed,
          ValueKind.energy,
        }.contains(v.kind)) {
          return optional
              ? '\\($n?.map { \$0.formatted() }.formatted() ?? "")'
              : '\\($n.map { \$0.formatted() }.formatted())';
        }
        return optional ? '\\($n?.formatted() ?? "")' : '\\($n.formatted())';
      }
      // A String for [x], or (unless [text]) any value that reads well.
      String said(String x, {bool text = false}) => switch (v.kind) {
            ValueKind.dateTime => '$x.formatted(date: .abbreviated, time: .shortened)',
            ValueKind.uri => '$x.absoluteString',
            ValueKind.duration ||
            ValueKind.length ||
            ValueKind.mass ||
            ValueKind.temperature ||
            ValueKind.volume ||
            ValueKind.speed ||
            ValueKind.energy =>
              '$x.formatted()',
            ValueKind.currency => '$x.amount.formatted(.currency(code: $x.currencyCode))',
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
      final itemId = _dartID(r.schemaEntity?.schema.id, r'$0');
      final lines = [
        if (r.nullable) ...[
          '    var value: [$name]? = nil',
          '    if let ids = AssistantValues.strings($source) {',
          '      let found = ${_lookup(name, r.schemaEntity?.schema.id, 'ids')}',
          '      value = ids.compactMap { id in found.first { $itemId == id } }',
          '    }',
        ] else ...[
          '    let ids = AssistantValues.strings($source) ?? []',
          '    let found = ${_lookup(name, r.schemaEntity?.schema.id, 'ids')}',
          '    let value = ids.compactMap { id in found.first { $itemId == id } }',
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
        ValueKind.currency => 'AssistantValues.currency($expr)',
        ValueKind.length => 'AssistantValues.length($expr)',
        ValueKind.mass => 'AssistantValues.mass($expr)',
        ValueKind.temperature => 'AssistantValues.temperature($expr)',
        ValueKind.volume => 'AssistantValues.volume($expr)',
        ValueKind.speed => 'AssistantValues.speed($expr)',
        ValueKind.energy => 'AssistantValues.energy($expr)',
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
      if (p.schemaEntity case final s?) floor = SwiftWriter._max(floor, _entityFloor(s.schema));
      if (p.supportedContentTypes != null) floor = SwiftWriter._max(floor, const {'iOS': 18, 'macOS': 15});
    }
    if (a.result case final r?) {
      if (r.value case final v?) floor = SwiftWriter._max(floor, _valueFloor(v));
      if (r.schemaEntity case final s?) floor = SwiftWriter._max(floor, _entityFloor(s.schema));
    }
    return floor;
  }

  /// Schema types plain actions and widget configs use, which [_schemas] declares in Swift.
  List<SchemaType> get _actionSchemaTypes => [
        for (final a in app.actions) ...[
          for (final p in a.params) ...[
            if (p.value?.enumRef case final ref?) SchemaType('enum', ref: ref),
            if (p.schemaEntity case final s?) SchemaType('entity', ref: s.schema.id),
          ],
          if (a.result?.value?.enumRef case final ref?) SchemaType('enum', ref: ref),
          if (a.result?.schemaEntity case final s?) SchemaType('entity', ref: s.schema.id),
        ],
        for (final w in app.widgetConfigs)
          for (final p in w.params)
            if (p.value?.enumRef case final ref?) SchemaType('enum', ref: ref),
      ];

  /// Frameworks plain actions and controls need: GeoToolbox for places,
  /// WidgetKit for controls/widgets, UniformTypeIdentifiers for file UTType filters.
  void _actionImports() {
    final places = app.actions.any((a) =>
        a.params.any((p) => p.value?.kind == ValueKind.place) || a.result?.value?.kind == ValueKind.place);
    if (places) _imports.add('GeoToolbox');
    if (app.controls.isNotEmpty || app.widgetConfigs.isNotEmpty) _imports.add('WidgetKit');
    final contentTypes = app.actions.any((a) => a.params.any((p) => p.supportedContentTypes != null));
    if (contentTypes) _imports.add('UniformTypeIdentifiers');
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
            a.params.any((p) => p.isEntity && a.shortcut!.phrases.any((ph) => ph.contains('{${p.name}}')))) ||
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
