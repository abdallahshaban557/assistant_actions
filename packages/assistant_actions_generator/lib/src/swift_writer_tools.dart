part of 'swift_writer.dart';

/// Apple Intelligence `FoundationModels.Tool` bridging (iOS 26+ / macOS 26+).
///
/// Generates `<IntentName>Tool: FoundationModels.Tool` for every discoverable
/// `@AssistantAction` whose parameters can be represented with `@Generable`
/// (`String`, `int`, `double`, `bool`, `@AssistantEnum` / schema enum, `List`
/// of those, or `@AssistantEntity` ID/title lookup) and every discoverable
/// `SnapshotAnswer`, plus `AssistantFoundationTools.all` for
/// `LanguageModelSession(tools: AssistantFoundationTools.all)`.
extension _FoundationTools on SwiftWriter {
  static const _toolFloor = <String, num>{'iOS': 26, 'macOS': 26};

  List<ActionModel> get _toolActions => [
        for (final a in app.actions)
          if (a.focusFilter == null && a.isDiscoverable && a.params.every(_isToolParam)) a,
      ];

  List<SnapshotActionModel> get _toolSnapshots => [
        for (final a in app.snapshotActions)
          if (a.isDiscoverable) a,
      ];

  bool _isToolParam(ParamModel p) {
    if (p.entity != null) return true;
    final v = p.value;
    if (v == null) return false;
    return const {
      ValueKind.string,
      ValueKind.integer,
      ValueKind.decimal,
      ValueKind.boolean,
      ValueKind.enumeration,
    }.contains(v.kind);
  }

  /// Whether [p] is optional in the `@Generable` `Arguments` struct: nullable
  /// in Dart, or backed by a Dart default value.
  bool _toolParamOptional(ParamModel p) => p.nullable || p.defaultDart != null;

  String _toolEnumName(ValueType v) => '${_valueSwift(v.element)}ToolValue';

  String _toolParamSwift(ParamModel p) {
    final optional = _toolParamOptional(p) ? '?' : '';
    if (p.entity != null) return '${p.entityList ? '[String]' : 'String'}$optional';
    final v = p.value!;
    final element = switch (v.kind) {
      ValueKind.string => 'String',
      ValueKind.integer => 'Int',
      ValueKind.decimal => 'Double',
      ValueKind.boolean => 'Bool',
      ValueKind.enumeration => _toolEnumName(v),
      _ => throw StateError('Unsupported tool parameter ${v.kind}'),
    };
    return '${v.list ? '[$element]' : element}$optional';
  }

  String _toolGuideDescription(ParamModel p) {
    if (p.prompt case final prompt?) return prompt;
    if (p.entity != null) {
      return p.entityList ? '${p.title} (IDs or titles)' : '${p.title} (ID or title)';
    }
    return p.title;
  }

  void _foundationTools() {
    _imports.add('FoundationModels');
    final actions = _toolActions;
    final snapshots = _toolSnapshots;

    _out.writeln('#if canImport(FoundationModels)');
    _emitToolEnums(actions);
    if (actions.any((a) => a.params.any((p) => p.entity != null))) {
      _out.writeln('''
/// Resolves an entity argument from an exact ID or a forgiving title match.
@available(iOS 26.0, macOS 26.0, *)
private func assistantResolveEntity<E>(
  _ query: String,
  collection: String,
  typeWords: Set<String>,
  make: (AssistantRecord) -> E
) throws -> E {
  let records = AssistantSnapshot.records(collection)
  let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
  if let exact = records.first(where: { \$0.id == trimmed }) {
    return make(exact)
  }
  if let matched = AssistantMatch.records(records, matching: trimmed, ignoring: typeWords).first {
    return make(matched)
  }
  throw AssistantActionError.failed("No \\(collection) matching \\"\\(trimmed)\\"")
}
''');
    }
    final needsValueFormatter = actions.any((a) => a.result != null && !a.result!.isEntity);
    if (needsValueFormatter) {
      _out.writeln('''
@available(iOS 26.0, macOS 26.0, *)
private func assistantDescribeToolValue(_ value: Any?) -> String? {
  guard let value, !(value is NSNull) else { return nil }
  if let text = value as? String { return text }
  if let items = value as? [Any] {
    return items.compactMap(assistantDescribeToolValue).joined(separator: ", ")
  }
  return "\\(value)"
}
''');
    }

    final toolEntries = <(String, Map<String, num>)>[];
    for (final a in actions) {
      final floor = SwiftWriter._max(_toolFloor, _actionFloor(a));
      _emitActionTool(a, floor);
      toolEntries.add(('${a.swiftName}Tool()', floor));
    }
    for (final a in snapshots) {
      _emitSnapshotTool(a);
      toolEntries.add(('${a.swiftName}Tool()', _toolFloor));
    }
    _emitToolsCatalog(toolEntries);
    _out.writeln('#endif');
    _out.writeln();
  }

  void _emitToolEnums(List<ActionModel> actions) {
    final seen = <String>{};
    for (final a in actions) {
      for (final p in a.params) {
        final v = p.value;
        if (v == null || v.kind != ValueKind.enumeration) continue;
        final name = _toolEnumName(v);
        if (!seen.add(name)) continue;
        final floor = SwiftWriter._max(_toolFloor, _valueFloor(v.element));
        final cases = v.enumRef == null
            ? [for (final c in app.appEnums[v.appEnum!]!.cases) c.name]
            : _enumSchema(v.enumRef!).cases;
        _out
          ..writeln(_availability(floor))
          ..writeln('@Generable')
          ..writeln('public enum $name: String, Sendable {');
        for (final c in cases) {
          _out.writeln(swiftName(c) == c ? '  case $c' : '  case ${swiftName(c)} = "$c"');
        }
        _out
          ..writeln('}')
          ..writeln();
      }
    }
  }

  void _emitActionTool(ActionModel a, Map<String, num> floor) {
    final toolName = '${a.swiftName}Tool';
    final desc = SwiftWriter._escape(a.description ?? a.title);
    _out
      ..writeln('/// `FoundationModels.Tool` wrapper for `${a.functionName}` (`${a.swiftName}`).')
      ..writeln(_availability(floor))
      ..writeln('public struct $toolName: FoundationModels.Tool {')
      ..writeln('  public let name = "${SwiftWriter._escape(a.id)}"')
      ..writeln('  public let description = "$desc"')
      ..writeln()
      ..writeln('  @Generable')
      ..writeln('  public struct Arguments: Sendable {');
    if (a.params.isEmpty) {
      _out.writeln('    public init() {}');
    } else {
      for (final p in a.params) {
        _out
          ..writeln('    @Guide(description: "${SwiftWriter._escape(_toolGuideDescription(p))}")')
          ..writeln('    public var ${swiftName(p.name)}: ${_toolParamSwift(p)}');
      }
    }
    _out
      ..writeln('  }')
      ..writeln()
      ..writeln('  public init() {}')
      ..writeln()
      ..writeln('  public func call(arguments: Arguments) async throws -> String {')
      ..writeln('    try await run(arguments)')
      ..writeln('  }')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  private func run(_ toolArguments: Arguments) async throws -> String {');

    final dialogExpr = a.dialog == null ? '"Done."' : _spokenDialog(a.dialog!, a);
    if (a.params.isEmpty) {
      _out
        ..writeln('    let toolPayload: [String: Any] = [:]')
        ..writeln('    let fallbackDialog = $dialogExpr');
    } else {
      final needsTry = a.params.any((p) => p.entity != null || (p.value?.kind == ValueKind.enumeration && !_optional(p) && p.swiftDefault == null && !p.value!.list));
      _out.writeln('    let (toolPayload, fallbackDialog): ([String: Any], String) = ${needsTry ? 'try ' : ''}{');
      for (final p in a.params) {
        _out.writeln('      ${_decodeToolArg(p)}');
      }
      _out.writeln('      let encodedArgs: [String: Any] = [');
      for (final p in a.params) {
        _out.writeln('        "${p.name}": ${_encodeParam(p)},');
      }
      _out
        ..writeln('      ]')
        ..writeln('      return (encodedArgs, $dialogExpr)')
        ..writeln('    }()');
    }

    if (a.runs == RunsModel.deferred) {
      if (a.liveActivity) {
        _out.writeln('''
    if ${app.background?.applyQueued ?? false ? 'await AssistantBackground.shared.prepare()' : 'AssistantBridge.shared.isReady'} {
      _ = try await AssistantBridge.shared.perform("${a.id}", args: toolPayload)
    } else {
      AssistantInbox.call("${a.id}", args: toolPayload)
    }
    return fallbackDialog''');
      } else {
        _out.writeln('''
    AssistantInbox.call("${a.id}", args: toolPayload)
    $_inboxChanged
    return fallbackDialog''');
      }
    } else {
      if (_background) {
        _out.writeln('    _ = await AssistantBackground.shared.prepare()');
      }
      _out.writeln('    let rawReply = try await AssistantBridge.shared.perform("${a.id}", args: toolPayload)');
      final result = a.result;
      if (a.returnsReply) {
        _out.writeln('    let reply = AssistantReply(json: rawReply)');
        if (result != null) {
          if (result.isEntity) {
            final entityName = result.entity?.swiftName ?? result.schemaEntity!.swiftName;
            final idsExpr = result.list ? '(AssistantValues.strings(reply.value) ?? [])' : 'reply.ids';
            _out
              ..writeln('    let found = try await ${entityName}Query().entities(for: $idsExpr)')
              ..writeln('    let valueText = found.map { String(localized: \$0.displayRepresentation.title) }.joined(separator: ", ")');
          } else {
            _out.writeln('    let valueText = assistantDescribeToolValue(reply.value) ?? ""');
          }
        }
        _out
          ..writeln('    var parts: [String] = []')
          ..writeln('    if let dialog = reply.dialog, !dialog.isEmpty { parts.append(dialog) }');
        if (result != null) {
          _out.writeln('    if !valueText.isEmpty && !parts.contains(valueText) { parts.append(valueText) }');
        }
        _out.writeln('''
    if let card = reply.card {
      if !parts.contains(card.title) { parts.append(card.title) }
      if let subtitle = card.subtitle { parts.append(subtitle) }
      for row in card.rows { parts.append("\\(row.label): \\(row.value)") }
    }
    return parts.isEmpty ? fallbackDialog : parts.joined(separator: "\\n")''');
      } else if (result == null) {
        _out.writeln('    return rawReply ?? fallbackDialog');
      } else {
        _out.writeln('    let result = AssistantValues.result(rawReply)');
        if (result.isEntity) {
          _out.write(_decodeResult(result, a, source: 'result.value'));
          final textExpr = switch ((result.list, result.nullable)) {
            (false, false) => 'Optional(String(localized: value.displayRepresentation.title))',
            (false, true) => 'value.map { String(localized: \$0.displayRepresentation.title) }',
            (true, false) => 'Optional(value.map { String(localized: \$0.displayRepresentation.title) }.joined(separator: ", "))',
            (true, true) => 'value?.map { String(localized: \$0.displayRepresentation.title) }.joined(separator: ", ")',
          };
          _out.writeln('    let valueText: String? = $textExpr');
        } else {
          _out.writeln('    let valueText = assistantDescribeToolValue(result.value)');
        }
        _out.writeln('''
    if let dialog = result.dialog, !dialog.isEmpty {
      if let valueText, !valueText.isEmpty, valueText != dialog {
        return "\\(dialog)\\n\\(valueText)"
      }
      return dialog
    }
    if let valueText, !valueText.isEmpty {
      return valueText
    }
    return fallbackDialog''');
      }
    }

    _out
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
  }

  String _decodeToolArg(ParamModel p) {
    final n = swiftName(p.name);
    if (p.entity case final e?) {
      String resolve(String expr) =>
          'try assistantResolveEntity($expr, collection: "${e.className}", typeWords: ${e.swiftName}Query.typeWords, make: ${e.swiftName}.init(record:))';
      if (p.entityList) {
        return p.nullable
            ? 'let $n = try toolArguments.$n.map { try \$0.map { ${resolve(r'$0')} } }'
            : 'let $n = try toolArguments.$n.map { ${resolve(r'$0')} }';
      }
      return p.nullable
          ? 'let $n = try toolArguments.$n.map { ${resolve(r'$0')} }'
          : 'let $n = ${resolve('toolArguments.$n')}';
    }
    final v = p.value!;
    if (v.kind == ValueKind.enumeration) {
      final enumSwift = _valueSwift(v.element);
      if (v.list) {
        return _optional(p)
            ? 'let $n = toolArguments.$n.map { \$0.compactMap { $enumSwift(rawValue: \$0.rawValue) } }'
            : 'let $n = toolArguments.$n.compactMap { $enumSwift(rawValue: \$0.rawValue) }';
      }
      if (p.swiftDefault case final d?) {
        return 'let $n: $enumSwift = toolArguments.$n.flatMap { $enumSwift(rawValue: \$0.rawValue) } ?? $d';
      }
      if (_optional(p)) {
        return 'let $n = toolArguments.$n.flatMap { $enumSwift(rawValue: \$0.rawValue) }';
      }
      return 'guard let $n = $enumSwift(rawValue: toolArguments.$n.rawValue) else { throw AssistantActionError.failed("Invalid ${SwiftWriter._escape(p.name)}") }';
    }
    if (!v.list && p.swiftDefault != null) {
      return 'let $n = toolArguments.$n ?? ${p.swiftDefault}';
    }
    return 'let $n = toolArguments.$n';
  }

  void _emitSnapshotTool(SnapshotActionModel a) {
    final toolName = '${a.swiftName}Tool';
    final desc = SwiftWriter._escape(a.description ?? a.title);
    final outputExpr = a.dialog.contains('{items}')
        ? 'answer.dialog'
        : 'answer.items.isEmpty ? answer.dialog : ([answer.dialog] + answer.items).joined(separator: "\\n")';
    _out.writeln('''
/// `FoundationModels.Tool` wrapper for `${a.name}` (`${a.swiftName}`).
${_availability(_toolFloor)}
public struct $toolName: FoundationModels.Tool {
  public let name = "${SwiftWriter._escape(a.id)}"
  public let description = "$desc"

  @Generable
  public struct Arguments: Sendable {
    public init() {}
  }

  public init() {}

  public func call(arguments: Arguments) async throws -> String {
    let answer = ${_snapshotAnswerCall(a)}
    return $outputExpr
  }
}
''');
  }

  bool _needsToolGate(Map<String, num> floor) {
    final (iOS, macOS) = _versions(floor);
    return iOS > 26 || macOS > 26 || iOS.isInfinite || macOS.isInfinite;
  }

  void _emitToolsCatalog(List<(String, Map<String, num>)> entries) {
    _out
      ..writeln('/// Every generated `FoundationModels.Tool`, ready for `LanguageModelSession(tools: AssistantFoundationTools.all)`.')
      ..writeln(_availability(_toolFloor))
      ..writeln('public enum AssistantFoundationTools {')
      ..writeln('  public static var all: [any FoundationModels.Tool] {');
    if (entries.isEmpty) {
      _out.writeln('    []');
    } else if (!entries.any((e) => _needsToolGate(e.$2))) {
      _out.writeln('    [');
      for (final (expr, _) in entries) {
        _out.writeln('      $expr,');
      }
      _out.writeln('    ]');
    } else {
      final base = [for (final (expr, floor) in entries) if (!_needsToolGate(floor)) expr];
      if (base.isEmpty) {
        _out.writeln('    var tools: [any FoundationModels.Tool] = []');
      } else {
        _out.writeln('    var tools: [any FoundationModels.Tool] = [');
        for (final expr in base) {
          _out.writeln('      $expr,');
        }
        _out.writeln('    ]');
      }
      for (final (expr, floor) in entries) {
        if (!_needsToolGate(floor)) continue;
        final (iOS, macOS) = _versions(floor);
        final os = iOS.isInfinite ? 'macOS' : (macOS.isInfinite ? 'iOS' : null);
        final checks = [
          if (iOS.isFinite && iOS > 26) 'iOS ${SwiftWriter._version(iOS)}',
          if (macOS.isFinite && macOS > 26) 'macOS ${SwiftWriter._version(macOS)}',
        ];
        var lines = <String>['tools.append($expr)'];
        if (checks.isNotEmpty) {
          lines = ['if #available(${checks.join(', ')}, *) {', for (final l in lines) '  $l', '}'];
        }
        if (os != null) {
          lines = ['#if os($os)', for (final l in lines) '  $l', '#endif'];
        }
        for (final l in lines) {
          _out.writeln('    $l');
        }
      }
      _out.writeln('    return tools');
    }
    _out
      ..writeln('  }')
      ..writeln('}');
  }
}
