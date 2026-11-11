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

  // Its modes and the lines that start Dart before a live call are
  // `_Mode.background` / `_Mode.legacyBackground` in swift_writer_modern.dart,
  // with the foreground rules and the app's deployment target.

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
