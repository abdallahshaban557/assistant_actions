part of 'swift_writer.dart';

/// How a live intent gets the app forward on one platform. Below iOS 26 /
/// macOS 26 (the app's deployment target) that is the deprecated
/// `ForegroundContinuableIntent`; from 26, `supportedModes`.
enum _Mode {
  /// `ForegroundContinuableIntent` and `requestToContinueInForeground()`.
  legacy,

  /// `supportedModes = .foreground(.dynamic)` and
  /// `continueInForeground(alwaysConfirm: false)`.
  dynamic,

  /// The intent opens the app: `supportedModes = .foreground`, and the system
  /// brings it forward before `perform`.
  opens,

  /// iOS with `@AssistantBackground()`, from 26:
  /// `supportedModes = [.background, .foreground(.dynamic)]`; Dart runs on a
  /// headless engine, and the app comes forward only if that fails.
  background,

  /// The same below 26: `ForegroundContinuableIntent` for the fallback, and
  /// `supportedModes` for iOS 26 and later behind `@available`.
  legacyBackground;

  /// Brought forward with `ForegroundContinuableIntent`.
  bool get continuable => this == legacy || this == legacyBackground;
}

/// Newer App Intents protocols: foreground continuation without the
/// deprecated `ForegroundContinuableIntent` from iOS 26 / macOS 26 (with or
/// without background execution), `SyncableEntity`, `IndexedEntityQuery`,
/// `UndoableIntent`, and live calls that report progress, can be cancelled
/// and can run long.
extension _Modern on SwiftWriter {
  static const _platforms = ['iOS', 'macOS'];

  // ── Foreground continuation ───────────────────────────────────────────

  /// Each platform's [_Mode] for a live intent, from the app's deployment
  /// target and the intent's [floor].
  ///
  /// * [opensApp] intents use `.foreground` where `supportedModes` exists:
  ///   from a deployment target of 26, or when the intent itself needs 26.
  /// * [background] intents (`@AssistantBackground()`, iOS only) start in the
  ///   background: `[.background, .foreground(.dynamic)]`.
  /// * Otherwise `.foreground(.dynamic)` from a deployment target of 26, else
  ///   `ForegroundContinuableIntent`.
  Map<String, _Mode> _modes({bool opensApp = false, bool background = false, Map<String, num>? floor}) {
    bool from26(String p) => app.deployment[p] >= 26 || (floor != null && SwiftWriter._norm(floor)[p]! >= 26);
    return {
      for (final p in _platforms)
        p: background && p == 'iOS'
            ? (from26(p) ? _Mode.background : _Mode.legacyBackground)
            : opensApp && from26(p)
                ? _Mode.opens
                : app.deployment[p] >= 26
                    ? _Mode.dynamic
                    : _Mode.legacy,
    };
  }

  /// `ForegroundContinuableIntent` in the intent's header, after [prefix],
  /// when every platform still uses it.
  String _continuable(Map<String, _Mode> modes, String prefix) =>
      modes.values.every((m) => m.continuable) ? '${prefix}ForegroundContinuableIntent' : '';

  /// The `supportedModes` member for each platform that declares one (in
  /// `#if os(…)` unless both declare the same), then a blank line; or nothing.
  String _modesMember(Map<String, _Mode> modes, {String access = ''}) {
    List<String>? lines(_Mode m) => switch (m) {
          _Mode.legacy => null,
          _Mode.dynamic => ['  ${access}static let supportedModes: IntentModes = .foreground(.dynamic)'],
          _Mode.opens => ['  ${access}static let supportedModes: IntentModes = .foreground'],
          _Mode.background => ['  ${access}static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]'],
          _Mode.legacyBackground => [
              '  @available(iOS 26.0, *)',
              '  ${access}static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }',
            ],
        };
    final declared = {for (final MapEntry(:key, :value) in modes.entries) key: ?lines(value)};
    if (declared.isEmpty) return '';
    if (declared.length == 2 && modes['iOS'] == modes['macOS']) return '${declared['iOS']!.join('\n')}\n\n';
    return [
      for (final MapEntry(:key, :value) in declared.entries) ...['  #if os($key)', ...value, '  #endif'],
      '',
      '',
    ].join('\n');
  }

  /// With one platform still on `ForegroundContinuableIntent` and the other
  /// not: the conformance for that one, in an extension. Else nothing.
  String _continuableExtension(String name, Map<String, _Mode> modes, String availability) {
    final legacy = [for (final MapEntry(:key, :value) in modes.entries) if (value.continuable) key];
    if (legacy.length != 1) return '';
    return '#if os(${legacy.single})\n'
        '${availability.isEmpty ? '' : '$availability\n'}'
        'extension $name: ForegroundContinuableIntent {}\n'
        '#endif\n\n';
  }

  /// The lines of `perform` that bring the app forward: Flutter on iOS needs
  /// a scene (or, with background execution, a headless engine); macOS
  /// answers in place and activates only when [activateOnMac]. With
  /// [unlessReady], iOS comes forward only when Dart isn't already running.
  String _foregroundLines(Map<String, _Mode> modes,
      {required bool activateOnMac, String? comment, bool unlessReady = false}) {
    final ready = unlessReady ? '!AssistantBridge.shared.isReady && ' : '';
    List<String> continueWith(String call) => [
          '      if ${ready}UIApplication.shared.applicationState != .active {',
          '        try await $call',
          '      }',
        ];
    const prepare = [
      '      // Dart answers in the background (on a headless engine if the app has none);',
      '      // the app comes forward only if that fails.',
      '      if !(await AssistantBackground.shared.prepare()), UIApplication.shared.applicationState != .active {',
    ];
    final iOS = switch (modes['iOS']!) {
      _Mode.legacy => [?comment, ...continueWith('requestToContinueInForeground()')],
      _Mode.dynamic => [?comment, ...continueWith('continueInForeground(alwaysConfirm: false)')],
      _Mode.opens => const <String>[],
      _Mode.background => [...prepare, '        try await continueInForeground()', '      }'],
      _Mode.legacyBackground => [
          ...prepare,
          '        if #available(iOS 26.0, *) {',
          '          try await continueInForeground()',
          '        } else {',
          '          try await requestToContinueInForeground()',
          '        }',
          '      }',
        ],
    };
    final macOS = activateOnMac && modes['macOS'] != _Mode.opens ? ['      NSApplication.shared.activate()'] : const <String>[];
    if (iOS.isEmpty && macOS.isEmpty) return '';
    return [
      if (iOS.isNotEmpty) ...['    #if os(iOS)', ...iOS],
      if (macOS.isNotEmpty) ...[iOS.isEmpty ? '    #if os(macOS)' : '    #elseif os(macOS)', ...macOS],
      '    #endif',
    ].join('\n');
  }

  // ── Live calls ────────────────────────────────────────────────────────

  /// Live intent [name] reports progress (`ProgressReportingIntent`), can be
  /// cancelled (`CancellableIntent`, iOS 26.4 / macOS 26.4) and, when
  /// [longRunning], keeps running in the background (`LongRunningIntent`,
  /// iOS 27 / macOS 27). The runtime's `callDart` uses whichever it has.
  String _liveConformances(String name, Map<String, num>? floor, {required bool longRunning}) {
    String at(Map<String, num> min) => _availability(floor == null ? min : SwiftWriter._max(floor, min));
    return [
      if (floor != null) _availability(floor),
      'extension $name: ProgressReportingIntent {}',
      '',
      _newSdk([
        at(const {'iOS': 26.4, 'macOS': 26.4}),
        'extension $name: CancellableIntent {}',
        if (longRunning) ...['', at(const {'iOS': 27, 'macOS': 27}), 'extension $name: LongRunningIntent {}'],
      ].join('\n')),
      '',
    ].join('\n');
  }

  /// [code] using App Intents types only in the iOS / macOS 27 SDKs (and
  /// 26.4's `CancellableIntent`), compiled only by Swift 6.4 (Xcode 27), so
  /// the generated code still builds with older Xcodes.
  String _newSdk(String code) => '#if compiler(>=6.4)\n$code\n#endif';

  /// Mid-call Siri parameter prompts (`requestValue` and `requestDisambiguation`)
  /// for a live plain `@AssistantAction` with parameters.
  String _actionPromptingConformance(ActionModel a, Map<String, num>? floor) {
    final out = StringBuffer();
    if (floor != null) out.writeln(_availability(floor));
    out
      ..writeln('extension ${a.swiftName}: AssistantPromptingIntent {')
      ..writeln('  public func registerPrompts(on call: AssistantLiveCall) {');
    for (final p in a.params) {
      final paramVar = '${p.name}Param';
      out.writeln('    let $paramVar = self.\$${p.name}');
      if (p.entity case final e?) {
        out
          ..writeln('    call.onRequestValue("${p.name}") { prompt in')
          ..writeln('      let resolved = try await $paramVar.requestValue(prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return resolved.id')
          ..writeln('    }')
          ..writeln('    call.onDisambiguate("${p.name}") { rawChoices, prompt in')
          ..writeln('      let ids = rawChoices.compactMap(AssistantValues.string)')
          ..writeln('      let found = try await ${e.swiftName}Query().entities(for: ids)')
          ..writeln('      let candidates = ids.compactMap { id in found.first { \$0.id == id } }')
          ..writeln('      guard !candidates.isEmpty else { throw CancellationError() }')
          ..writeln('      let resolved = try await $paramVar.requestDisambiguation(among: candidates, dialog: prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return resolved.id')
          ..writeln('    }');
      } else {
        final each = _decodeValue(p.value!.element, r'$0');
        out
          ..writeln('    call.onRequestValue("${p.name}") { prompt in')
          ..writeln('      let resolved = try await $paramVar.requestValue(prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return AssistantValues.encode(resolved)')
          ..writeln('    }')
          ..writeln('    call.onDisambiguate("${p.name}") { rawChoices, prompt in')
          ..writeln('      let candidates = rawChoices.compactMap { $each }')
          ..writeln('      guard !candidates.isEmpty else { throw CancellationError() }')
          ..writeln('      let resolved = try await $paramVar.requestDisambiguation(among: candidates, dialog: prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return AssistantValues.encode(resolved)')
          ..writeln('    }');
      }
    }
    out
      ..writeln('  }')
      ..writeln('}');
    return out.toString();
  }

  /// Mid-call Siri parameter prompts for a live schema `call` intent.
  String _schemaPromptingConformance(String name, IntentSchema intent, Map<String, num> floor) {
    final promptable = [
      for (final p in intent.parameters)
        if (callArg(p) case final a? when a.element.kind != 'sceneDescriptor')
          if (a.shape != ArgShape.entity || a.element.ref != null) a,
    ];
    if (promptable.isEmpty) return '';
    final out = StringBuffer()
      ..writeln(_availability(floor))
      ..writeln('extension $name: AssistantPromptingIntent {')
      ..writeln('  func registerPrompts(on call: AssistantLiveCall) {');
    for (final a in promptable) {
      final pName = a.member.name;
      final paramVar = '${pName}Param';
      out.writeln('    let $paramVar = self.\$$pName');
      if (a.shape == ArgShape.entity) {
        final ref = a.element.ref!;
        final entityName = _adopted[ref]?.swiftName ?? _containerName(ref);
        out
          ..writeln('    call.onRequestValue("$pName") { prompt in')
          ..writeln('      let resolved = try await $paramVar.requestValue(prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return ${_dartID(ref, 'resolved')}')
          ..writeln('    }')
          ..writeln('    call.onDisambiguate("$pName") { rawChoices, prompt in')
          ..writeln('      let ids = rawChoices.compactMap(AssistantValues.string)')
          ..writeln('      let found = ${_lookup(entityName, ref, 'ids')}')
          ..writeln('      let candidates = ids.compactMap { id in found.first { ${_dartID(ref, r'$0')} == id } }')
          ..writeln('      guard !candidates.isEmpty else { throw CancellationError() }')
          ..writeln('      let resolved = try await $paramVar.requestDisambiguation(among: candidates, dialog: prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return ${_dartID(ref, 'resolved')}')
          ..writeln('    }');
      } else if (_decodeSchemaScalar(a.element, r'$0') case final each?) {
        final encoded = a.element.kind == 'stringSearchCriteria' ? 'resolved.term' : 'AssistantValues.encode(resolved)';
        out
          ..writeln('    call.onRequestValue("$pName") { prompt in')
          ..writeln('      let resolved = try await $paramVar.requestValue(prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return $encoded')
          ..writeln('    }')
          ..writeln('    call.onDisambiguate("$pName") { rawChoices, prompt in')
          ..writeln('      let candidates = rawChoices.compactMap { $each }')
          ..writeln('      guard !candidates.isEmpty else { throw CancellationError() }')
          ..writeln('      let resolved = try await $paramVar.requestDisambiguation(among: candidates, dialog: prompt.map { IntentDialog(stringLiteral: \$0) })')
          ..writeln('      return $encoded')
          ..writeln('    }');
      }
    }
    out
      ..writeln('  }')
      ..writeln('}');
    return out.toString();
  }

  /// Swift optional expression decoding one non-entity schema scalar [element] from [raw].
  String? _decodeSchemaScalar(SchemaType element, String raw) => switch (element.kind) {
        'string' => 'AssistantValues.string($raw)',
        'attributedString' => 'AssistantValues.attributed($raw)',
        'stringSearchCriteria' => 'AssistantValues.string($raw).map(StringSearchCriteria.init(term:))',
        'bool' => 'AssistantValues.bool($raw)',
        'int' => 'AssistantValues.int($raw)',
        'double' => 'AssistantValues.double($raw)',
        'date' => 'AssistantValues.date($raw)',
        'dateComponents' => 'AssistantValues.dateComponents($raw)',
        'url' => 'AssistantValues.url($raw)',
        'duration' => 'AssistantValues.duration($raw)',
        'enum' || 'openEnum' => 'AssistantValues.string($raw).flatMap(${_enumName(element.ref!)}.init(rawValue:))',
        'person' => 'AssistantValues.person($raw)',
        'placeDescriptor' => 'AssistantValues.place($raw)',
        'file' => 'AssistantValues.file($raw)',
        'recurrenceRule' => 'AssistantValues.recurrence($raw)',
        'union' => '${_unionName(element.ref!)}.decode($raw)',
        _ => null,
      };

  // ── Undo ──────────────────────────────────────────────────────────────

  /// Plain `@AssistantAction` [name] is an `UndoableIntent` (iOS 26 / macOS 26).
  String _actionUndoConformance(String name, Map<String, num> floor) => [
        _availability(SwiftWriter._max(floor, const {'iOS': 26, 'macOS': 26})),
        'extension $name: UndoableIntent {}',
      ].join('\n');

  /// [name] is an `UndoableIntent` (iOS 26 / macOS 26).
  ///
  /// `UndoableIntent` refines `SystemIntent`. When [intent]'s schema already
  /// makes it a system intent (`OpenIntent`, `DeleteIntent`, …) from before 26,
  /// that conformance is stated first, so the 26-only one doesn't claim it.
  String _undoConformance(String name, Map<String, num> floor, IntentSchema intent) {
    final a = SwiftWriter._norm(floor);
    final before26 = a['iOS']! < 26 || a['macOS']! < 26;
    return [
      if (before26 && intent.protocols.isNotEmpty) ...[_availability(floor), 'extension $name: SystemIntent {}', ''],
      _availability(SwiftWriter._max(floor, const {'iOS': 26, 'macOS': 26})),
      'extension $name: UndoableIntent {}',
      '',
    ].join('\n');
  }

  /// `perform` lines registering [items] (an `AssistantUndo` expression) as
  /// the undo of intent [title], from iOS 26 / macOS 26.
  String _undoLines(Map<String, num> floor, String title, String items) {
    // Undone like any other queued change: with `applyQueued`, Dart starts
    // (headless if need be) to apply it now.
    final changed = app.background?.applyQueued ?? false
        ? 'Task { await AssistantBackground.shared.applyInbox() }'
        : 'AssistantBridge.shared.inboxChanged()';
    final register = 'AssistantUndo.register(undoManager, "${SwiftWriter._escape(title)}", $items) { $changed }';
    final a = SwiftWriter._norm(floor);
    if (a['iOS']! >= 26 && a['macOS']! >= 26) return '    $register';
    return '    if #available(iOS 26.0, macOS 26.0, *) {\n      $register\n    }';
  }

  // ── Entities ──────────────────────────────────────────────────────────

  /// `SyncableEntity` and `IndexedEntityQuery` conformances for every entity.
  void _entityConformances() {
    const syncFloor = {'iOS': 27, 'macOS': 27};
    for (final e in app.entities) {
      if (e.syncable) {
        _out
          ..writeln('/// `@AssistantSyncable()`: Siri keeps `${e.className}` ids across devices.')
          ..writeln(_newSdk('${_availability(syncFloor)}\nextension ${e.swiftName}: SyncableEntity {}'))
          ..writeln();
      }
      _indexedQuery(e.swiftName, syncFloor, 'public ');
    }
    for (final s in app.schemaEntities) {
      final floor = SwiftWriter._max(_entityFloor(s.schema), syncFloor);
      if (s.syncable) {
        final why = s.syncableOverride == null ? 'Like Apple\'s own `${s.schema.id}`' : '`@AssistantSyncable()`';
        _out
          ..writeln('/// $why: Siri keeps `${s.className}` ids across devices.')
          ..writeln(_newSdk('${_availability(floor)}\nextension ${s.swiftName}: SyncableEntity {}'))
          ..writeln();
      }
      _indexedQuery(s.swiftName, floor, '');
    }
  }

  /// Lets Spotlight ask the app to index [entity]'s items again
  /// (`IndexedEntityQuery`, iOS 27 / macOS 27).
  void _indexedQuery(String entity, Map<String, num> floor, String access) {
    _out.writeln('''
/// Spotlight asks for `$entity` items to be indexed again, after it loses them.
#if compiler(>=6.4)
${_availability(floor)}
extension ${entity}Query: IndexedEntityQuery {
  ${access}func reindexEntities(for identifiers: [$entity.ID], indexDescription: CSSearchableIndexDescription) async throws {
    try await CSSearchableIndex.default().indexAppEntities(try await entities(for: identifiers))
  }

  ${access}func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    try await CSSearchableIndex.default().indexAppEntities(try await allEntities())
  }
}
#endif
''');
  }
}

/// `#if` / `#endif` lines around 26.4 / 27 SDK-only code inside a
/// declaration (an `IntentValueRepresentation` in a transfer representation),
/// as for `_newSdk`.
const _newSdkStart = '    #if compiler(>=6.4)';
const _newSdkEnd = '    #endif';
