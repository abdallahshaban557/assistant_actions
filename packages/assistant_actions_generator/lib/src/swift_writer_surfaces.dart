part of 'swift_writer.dart';

/// App Intents for system surfaces beyond Siri: Focus filters and Live
/// Activity intents.
extension _Surfaces on SwiftWriter {
  /// The Swift that calls [a]'s Dart function at once when Dart is running,
  /// and otherwise queues the call for the next start, without bringing the
  /// app forward.
  ///
  /// With `@AssistantBackground(applyQueued: true)`, Dart is started on the
  /// headless engine when the app has none, so the call runs at once there too.
  ///
  /// A Live Activity action's call is a live call (`callDart`), which reports
  /// progress and can be cancelled; a Focus filter's isn't.
  String _performOrQueue(ActionModel a) => '''
    if ${app.background?.applyQueued ?? false ? 'await AssistantBackground.shared.prepare()' : 'AssistantBridge.shared.isReady'} {
      _ = try await ${a.liveActivity ? 'callDart' : 'AssistantBridge.shared.perform'}("${a.id}", args: args)
    } else {
      AssistantInbox.call("${a.id}", args: args)
    }''';

  /// `@AssistantFocusFilter`: a `SetFocusFilterIntent` the system runs, in the
  /// app's process, when a Focus using it turns on or off. Parameters have
  /// the Dart defaults, which the system uses when the Focus turns off.
  void _focusFilter(ActionModel a) {
    final filter = a.focusFilter!;
    _out
      ..writeln('/// `${a.functionName}` in Dart: the app\'s Focus filter, run live when Dart is running and')
      ..writeln('/// queued otherwise.')
      ..writeln('public struct ${a.swiftName}: SetFocusFilterIntent {')
      ..writeln('  public static let title: LocalizedStringResource = "${SwiftWriter._escape(a.title)}"');
    if (a.description != null) {
      _out.writeln('  public static let description: IntentDescription? = IntentDescription("${SwiftWriter._escape(a.description!)}")');
    }
    _out.writeln();
    for (final p in a.params) {
      final options = [
        'title: "${SwiftWriter._escape(p.title)}"',
        if (p.swiftDefault case final d?) 'default: $d',
        if (p.prompt case final prompt?) 'requestValueDialog: "${SwiftWriter._escape(prompt)}"',
      ];
      _out.writeln('  @Parameter(${options.join(', ')})\n  public var ${swiftName(p.name)}: ${_paramSwift(p)}\n');
    }
    final summary = filter.summary == null ? null : _spokenDialog(filter.summary!, a);
    _out
      ..writeln('  public init() {}')
      ..writeln()
      ..writeln('  public var displayRepresentation: DisplayRepresentation {')
      ..writeln(summary == null
          ? '    DisplayRepresentation(title: Self.title)'
          : '    let summary: String = $summary\n    return DisplayRepresentation(title: Self.title, subtitle: "\\(summary)")')
      ..writeln('  }')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  public func perform() async throws -> some IntentResult {')
      ..writeln(a.params.isEmpty ? '    let args: [String: Any] = [:]' : '    let args: [String: Any] = [');
    for (final p in a.params) {
      _out.writeln('      "${p.name}": ${_encodeParam(p)},');
    }
    if (a.params.isNotEmpty) _out.writeln('    ]');
    _out
      ..writeln(_performOrQueue(a))
      ..writeln('    return .result()')
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
  }

  /// The body of a `liveActivity: true` action's `perform`. It runs in the
  /// app's process (a `LiveActivityIntent`), maybe in the background, while
  /// the app records or plays: when Dart is running, call it at once. If not,
  /// a deferred action is queued and a `Runs.withFlutter` one brings the app
  /// forward first (iOS starts the Flutter engine only with a scene).
  ///
  /// With `@AssistantBackground()`, a `Runs.withFlutter` one starts Dart on the
  /// headless engine instead, like any background action.
  String _liveActivityPerform(ActionModel a, String dialog, Map<String, _Mode> modes) {
    if (a.runs == RunsModel.deferred) {
      return '''
${_performOrQueue(a)}
    return .result(dialog: IntentDialog(stringLiteral: $dialog))''';
    }
    final call = a.returnsReply
        ? 'let reply = AssistantReply(json: try await callDart("${a.id}", args: args))'
        : 'let reply = try await callDart("${a.id}", args: args)';
    final result = a.returnsReply
        ? _resultOf(dialog: 'reply.dialog ?? $dialog', snippet: true)
        : '.result(dialog: IntentDialog(stringLiteral: reply ?? $dialog))';
    // Without background execution, iOS comes forward unless Dart already runs.
    final forward = _foregroundLines(modes,
        activateOnMac: false,
        unlessReady: !_background,
        comment: _background
            ? null
            : '      // A Live Activity intent can run in the background; the Flutter engine\n'
                '      // only starts with a scene, so come forward unless Dart already runs.');
    return '$forward\n    $call\n    return $result';
  }

  /// `LiveActivityIntent` is iOS-only.
  void _liveActivityConformance(ActionModel a) {
    _out
      ..writeln('#if os(iOS)')
      ..writeln('  /// Runs in the app\'s process and may start or update Live Activities.')
      ..writeln('  extension ${a.swiftName}: LiveActivityIntent {}')
      ..writeln('#endif')
      ..writeln();
  }
}
