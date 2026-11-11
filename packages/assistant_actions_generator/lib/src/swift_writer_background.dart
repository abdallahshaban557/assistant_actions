part of 'swift_writer.dart';

/// Background execution (`@AssistantBackground()`): on iOS, live intents that
/// don't need the app's screen run Dart on a headless Flutter engine instead
/// of asking to open the app. Without it the writer's output is unchanged.
extension _Background on SwiftWriter {
  bool get _background => app.background != null;

  /// A live schema intent that can answer from the background: it doesn't
  /// open the app or record audio (the microphone starts in the foreground).
  bool _backgroundCapable(IntentSchema intent) =>
      _background &&
      intent.isLive &&
      !intent.opensApp &&
      !intent.recordsAudio &&
      !intent.protocols.contains('audioRecording');

  /// The modes an intent that runs in the background declares on iOS 26 and
  /// later: it starts in the background and can still continue in the
  /// foreground (`.dynamic`) when Dart can't start. Before iOS 26 the
  /// intent's `ForegroundContinuableIntent` conformance says the same. macOS
  /// answers in place, as without background execution. Members keep the
  /// struct's indentation, so intents made public for App Shortcuts get a
  /// public `supportedModes` too.
  String _backgroundModes({required bool from26, String access = ''}) => [
        '  #if os(iOS)',
        if (from26)
          '  ${access}static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]'
        else ...[
          '  @available(iOS 26.0, *)',
          '  ${access}static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }',
        ],
        '  #endif',
        '',
      ].join('\n');

  /// The iOS lines before a live call: make sure Dart runs (starting the
  /// headless engine if the app has none), else bring the app forward as
  /// before.
  String _backgroundPrelude({required bool from26}) => [
        '    #if os(iOS)',
        '      // Dart answers in the background (on a headless engine if the app has none);',
        '      // the app comes forward only if that fails.',
        '      if !(await AssistantBackground.shared.prepare()), UIApplication.shared.applicationState != .active {',
        if (from26)
          '        try await continueInForeground()'
        else ...[
          '        if #available(iOS 26.0, *) {',
          '          try await continueInForeground()',
          '        } else {',
          '          try await requestToContinueInForeground()',
          '        }',
        ],
        '      }',
        '    #endif',
      ].join('\n');

  /// What a queued intent calls after queuing: with `applyQueued`, start
  /// Dart (headless if needed) to apply it now.
  String get _inboxChanged => app.background?.applyQueued ?? false
      ? 'await AssistantBackground.shared.applyInbox()'
      : 'AssistantBridge.shared.inboxChanged()';

  /// Tells the runtime where the headless engine starts Dart.
  void _backgroundEntrypoint() {
    final background = app.background;
    if (background == null) return;
    _out.writeln('''
#if os(iOS)
  /// Where `AssistantBackground` starts Dart on a headless engine: the
  /// generated `${BackgroundModel.entrypoint}`, which builds the registry with
  /// `${background.functionName}`.
  @objc(AssistantActionsAppBackground)
  public final class AssistantActionsAppBackground: NSObject, AssistantBackgroundEntrypoint {
    public static let entrypoint = "${BackgroundModel.entrypoint}"
    public static let libraryURI = "${background.entrypointLibrary}"
  }
#endif
''');
  }
}
