/// The `build_runner` builder for `assistant_actions`.
///
/// Reads `lib/assistant_actions.dart` (and the app libraries it imports) and
/// writes:
/// * `lib/assistant_actions.g.dart` — the registry for `AssistantActions.start`;
/// * the Swift App Intents, into the generated `assistant_actions_app` plugin;
/// * `apple/AssistantShortcuts.g.swift` — the App Shortcuts, for the Runner targets.
///
/// The Swift is written for the plugin package's deployment target (its
/// `Package.swift` platforms), unless the `ios_deployment_target` /
/// `macos_deployment_target` options say otherwise.
library;

import 'dart:io';

import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';

import 'src/dart_writer.dart';
import 'src/deployment.dart';
import 'src/reader.dart';
import 'src/swift_writer.dart';

Builder assistantActionsBuilder(BuilderOptions options) => AssistantActionsBuilder(options.config);

class AssistantActionsBuilder implements Builder {
  AssistantActionsBuilder([this.options = const {}]);

  /// The builder's options from `build.yaml`.
  final Map<String, Object?> options;

  static const input = 'lib/assistant_actions.dart';
  static const dartOutput = 'lib/assistant_actions.g.dart';
  static const swiftOutput =
      'packages/assistant_actions_app/darwin/assistant_actions_app/Sources/assistant_actions_app/AssistantActions.g.swift';
  static const shortcutsOutput = 'apple/AssistantShortcuts.g.swift';

  @override
  final buildExtensions = const {
    '^$input': [dartOutput, swiftOutput, shortcutsOutput],
  };

  @override
  Future<void> build(BuildStep step) async {
    final library = await step.inputLibrary;
    final app = await ModelReader(step, deployment: _deployment()).read(library);
    if (app == null) return;

    final package = step.inputId.package;
    final dart = DartFormatter(languageVersion: DartFormatter.latestLanguageVersion, pageWidth: 100)
        .format(writeDart(app));
    await step.writeAsString(AssetId(package, dartOutput), dart);
    await step.writeAsString(AssetId(package, swiftOutput), SwiftWriter(app).write());
    await step.writeAsString(AssetId(package, shortcutsOutput), writeShortcuts(app));
  }

  /// The plugin package's platforms (build_runner runs in the app's root),
  /// under the builder's options. Change either and run build_runner again.
  DeploymentTarget _deployment() {
    final package = File(pluginPackageSwift);
    final fromPackage = package.existsSync() ? DeploymentTarget.fromPackageSwift(package.readAsStringSync()) : null;
    return DeploymentTarget.fromOptions(options, fromPackage ?? DeploymentTarget.minimum);
  }
}
