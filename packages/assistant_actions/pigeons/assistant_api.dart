// The bridge between the Dart runtime and the Swift generated intents, called
// over FFI (Pigeon native interop), not platform channels.
//
// Regenerate after editing (from packages/assistant_actions):
//   dart run pigeon --input pigeons/assistant_api.dart
//
// Values cross as JSON strings so the FFI surface stays to plain strings; see
// AssistantValues.swift and AssistantValue in lib/src/registry.dart for the
// encodings inside them.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    // The generated tool/pigeon script runs from this package and writes paths
    // relative to appDirectory, so they must be the same folder. Swift FFI
    // compiles AssistantApi.g.swift on its own and needs no built app.
    appDirectory: './',
    dartPackageName: 'assistant_actions',
    dartOut: 'lib/src/bridge/assistant_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'darwin/assistant_actions/Sources/assistant_actions/AssistantApi.g.swift',
    swiftOptions: SwiftOptions(useFfi: true, ffiModuleName: 'assistant_actions'),
  ),
)
/// Implemented in Swift (`AssistantActionsPlugin.swift`), called from Dart.
@HostApi()
abstract class AssistantHostApi {
  /// Dart's [AssistantFlutterApi] is set up and can take `perform` calls.
  void markReady();

  /// Returns and clears what the intents queued, as JSON, oldest first.
  List<String> drainInbox();

  /// Saves the snapshot of [collection] that entity queries read.
  void publish(String collection, String json);

  /// Runs the Swift handler registered for [method] (see
  /// `AssistantHostCalls.swift`) with [argsJson] and returns its result as
  /// JSON, if any. Features that need Swift from Dart use this, so the FFI
  /// surface doesn't grow with each one.
  String? invoke(String method, String argsJson);
}

/// Implemented in Dart (`lib/src/runtime.dart`), called from Swift.
@FlutterApi()
abstract class AssistantFlutterApi {
  /// Runs the `Runs.withFlutter` action [action] with [argsJson] and returns
  /// what Siri should say, if anything.
  @async
  String? perform(String action, String argsJson);

  /// An intent just queued an inbox item.
  void inboxChanged();
}
