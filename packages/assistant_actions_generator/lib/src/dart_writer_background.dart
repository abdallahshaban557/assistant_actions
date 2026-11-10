part of 'dart_writer.dart';

/// The entrypoint the headless Flutter engine runs on iOS, for an app with an
/// `@AssistantBackground()` registry function.
void _backgroundEntrypoint(StringBuffer out, BackgroundModel background, String Function(Uri, String) ref) {
  out
    ..writeln()
    ..writeln('/// Run by the headless Flutter engine that Swift starts when Siri needs Dart')
    ..writeln('/// and the app has no engine (iOS). Builds the registry with')
    ..writeln('/// `${background.functionName}`.')
    ..writeln("@pragma('vm:entry-point')")
    ..writeln('Future<void> ${BackgroundModel.entrypoint}() =>')
    ..writeln('    AssistantActions.startInBackground(${ref(background.library, background.functionName)});');
}
