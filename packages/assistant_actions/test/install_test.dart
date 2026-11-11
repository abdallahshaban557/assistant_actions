// `dart run assistant_actions:install --widgets`: the widget extension it
// scaffolds and the Xcode target it adds, on a pristine `flutter create`
// project (test/fixtures).
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/install.dart' as install;

final _fixture = File('test/fixtures/flutter_ios.pbxproj').readAsStringSync();
final _plist = File('test/fixtures/flutter_ios_Info.plist').readAsStringSync();
const _sources = 'darwin/assistant_actions/Sources/assistant_actions';

String Function() _ids() {
  var n = 0;
  return () => (n++).toRadixString(16).toUpperCase().padLeft(24, 'A');
}

/// The ids listed in [pbx]'s Runner target's buildPhases, by name.
List<String> _runnerPhases(String pbx) {
  final block = RegExp(r'/\* Runner \*/ = \{\s*isa = PBXNativeTarget;[\s\S]*?buildPhases = \(([\s\S]*?)\);').firstMatch(pbx)!;
  return [for (final m in RegExp(r'/\* ([^*]+) \*/').allMatches(block.group(1)!)) m.group(1)!];
}

void main() {
  group('raiseDeploymentTarget', () {
    test('raises the Runner to iOS 17.4, which App Shortcuts need for #available', () {
      final pbx = install.raiseDeploymentTarget(_fixture, 'ios');
      expect(pbx, isNot(contains('IPHONEOS_DEPLOYMENT_TARGET = 15.0;')));
      expect(RegExp('IPHONEOS_DEPLOYMENT_TARGET = 17.4;').allMatches(pbx).length, greaterThanOrEqualTo(3));
      expect(install.raiseDeploymentTarget(pbx, 'ios'), pbx, reason: 'idempotent');
    });

    test('never lowers a target, and raises macOS to 14.4', () {
      expect(install.raiseDeploymentTarget('IPHONEOS_DEPLOYMENT_TARGET = 18.0;', 'ios'), 'IPHONEOS_DEPLOYMENT_TARGET = 18.0;');
      expect(install.raiseDeploymentTarget('MACOSX_DEPLOYMENT_TARGET = 14.0;', 'macos'), 'MACOSX_DEPLOYMENT_TARGET = 14.4;');
    });
  });

  group('addWidgetTarget', () {
    late String pbx;
    setUp(() => pbx = install.addWidgetTarget(_fixture, _ids()).pbx!);

    test('adds an app extension target with its sources', () {
      expect(pbx, contains('productType = "com.apple.product-type.app-extension";'));
      expect(pbx, contains('path = AssistantWidgets.appex; sourceTree = BUILT_PRODUCTS_DIR;'));
      for (final f in ['AssistantWidgets.swift', 'AssistantLiveActivityWidget.swift', 'AssistantActivityAttributes.swift']) {
        expect(pbx, contains('/* $f in Sources */ = {isa = PBXBuildFile;'), reason: f);
      }
      expect(pbx, contains('path = AssistantWidgets;\n\t\t\tsourceTree = "<group>";'));
    });

    test('embeds it in Runner before Thin Binary, which would otherwise make a cycle', () {
      final phases = _runnerPhases(pbx);
      expect(phases.indexOf('Embed Foundation Extensions'), lessThan(phases.indexOf('Thin Binary')));
      expect(pbx, contains('dstSubfolderSpec = 13;'));
      expect(RegExp(r'/\* Runner \*/ = \{\s*isa = PBXNativeTarget;[\s\S]*?dependencies = \(\n\t\t\t\t\w{24} /\* PBXTargetDependency \*/')
          .hasMatch(pbx), isTrue);
    });

    test("has one configuration per Runner configuration, with Runner's team and bundle id", () {
      expect(RegExp('PRODUCT_BUNDLE_IDENTIFIER = dev.fixture.freshApp.AssistantWidgets;').allMatches(pbx).length, 3);
      expect(RegExp('DEVELOPMENT_TEAM = TEAM123456;').allMatches(pbx).length, 6);
      expect(RegExp('IPHONEOS_DEPLOYMENT_TARGET = 17.0;').allMatches(pbx).length, greaterThanOrEqualTo(3));
      expect(pbx, contains('baseConfigurationReference = '));
      expect(pbx, contains('/* AssistantWidgets.xcconfig */;'));
    });

    test('is idempotent', () {
      expect(install.addWidgetTarget(pbx, _ids()).pbx, pbx);
    });

    test('changes nothing when the project is not laid out like a Flutter one', () {
      final result = install.addWidgetTarget(_fixture.replaceAll('/* Runner */', '/* App */'), _ids());
      expect(result.pbx, isNull);
      expect(result.problem, contains('the Runner target'));
    });

    test('Xcode reads the result and lists the new target', () async {
      final dir = await Directory.systemTemp.createTemp('pbx');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/Runner.xcodeproj/project.pbxproj')
        ..createSync(recursive: true)
        ..writeAsStringSync(pbx);
      // The Swift package Flutter generates at build time, which Xcode resolves first.
      const stub = 'Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage';
      File('${dir.path}/$stub/Package.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('// swift-tools-version: 5.9\nimport PackageDescription\n'
            'let package = Package(name: "FlutterGeneratedPluginSwiftPackage", products: [.library('
            'name: "FlutterGeneratedPluginSwiftPackage", targets: ["Stub"])], targets: [.target(name: "Stub")])\n');
      File('${dir.path}/$stub/Sources/Stub/Stub.swift')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      final lint = await Process.run('plutil', ['-lint', '${dir.path}/Runner.xcodeproj/project.pbxproj']);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
      final list = await Process.run('xcodebuild', ['-list', '-project', '${dir.path}/Runner.xcodeproj']);
      expect(list.stdout, contains('AssistantWidgets'), reason: '${list.stderr}');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('supportLiveActivities adds the key once', () {
    final updated = install.supportLiveActivities(_plist)!;
    expect(updated, contains('<dict>\n\t<key>NSSupportsLiveActivities</key>\n\t<true/>\n'));
    expect(install.supportLiveActivities(updated), updated);
    expect(install.supportLiveActivities('not a plist'), isNull);
  });

  test('install --widgets scaffolds the extension and is safe to run again', () async {
    final app = await Directory.systemTemp.createTemp('widgets_app');
    addTearDown(() => app.delete(recursive: true));
    File('${app.path}/pubspec.yaml').writeAsStringSync('name: app\ndependencies:\n  assistant_actions:\n    path: x\n');
    File('${app.path}/ios/Runner.xcodeproj/project.pbxproj')
      ..createSync(recursive: true)
      ..writeAsStringSync(_fixture);
    File('${app.path}/ios/Runner/Info.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync(_plist);
    final script = File('bin/install.dart').absolute.path;
    Future<ProcessResult> run() => Process.run('dart', [script, '--widgets'], workingDirectory: app.path);

    final first = await run();
    expect(first.exitCode, 0, reason: '${first.stdout}${first.stderr}');
    expect(first.stdout, contains('added the AssistantWidgets widget extension target'));
    final widgets = '${app.path}/ios/AssistantWidgets';
    expect(File('$widgets/AssistantActivityAttributes.swift').readAsStringSync(),
        File('$_sources/AssistantActivityAttributes.swift').readAsStringSync(),
        reason: 'ActivityKit matches the app and extension copies by name and fields');
    for (final f in ['AssistantWidgets.swift', 'AssistantLiveActivityWidget.swift', 'Info.plist', 'AssistantWidgets.xcconfig']) {
      expect(File('$widgets/$f').existsSync(), isTrue, reason: f);
    }
    expect(File('${app.path}/ios/Runner/Info.plist').readAsStringSync(), contains('NSSupportsLiveActivities'));

    final pbx = File('${app.path}/ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    File('$widgets/AssistantWidgets.swift').writeAsStringSync('// mine\n');
    File('$widgets/AssistantLiveActivityWidget.swift').writeAsStringSync('// stale\n');
    final second = await run();
    expect(second.exitCode, 0, reason: '${second.stdout}${second.stderr}');
    expect(second.stdout, contains('the AssistantWidgets target is already there'));
    expect(File('${app.path}/ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(), pbx);
    expect(File('$widgets/AssistantWidgets.swift').readAsStringSync(), '// mine\n', reason: 'the bundle is the app\'s');
    expect(File('$widgets/AssistantLiveActivityWidget.swift').readAsStringSync(),
        File('darwin/widgets/AssistantLiveActivityWidget.swift').readAsStringSync(),
        reason: 'the generic view follows the runtime');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
