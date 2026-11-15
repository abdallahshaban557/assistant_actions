// System surfaces beyond Siri: App Groups, Controls, Configurable Widgets,
// Live Activity intents, Focus filters (appContext & cold-start current), and
// in-app discovery intent lookup.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/reader.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

final _library = Uri.parse('package:app/assistant_actions.dart');
final _models = Uri.parse('package:app/models.dart');

final _taskEntity = EntityModel(
  className: 'TaskItem',
  library: _models,
  title: 'Task',
  idField: 'id',
  titleGetter: 'title',
  systemImage: 'checkmark.circle',
  fields: const [
    FieldModel('done', ValueType(ValueKind.boolean)),
    FieldModel('priorityScore', ValueType(ValueKind.integer)),
  ],
);

final _settingsEntity = EntityModel(
  className: 'AppSettings',
  library: _models,
  title: 'Settings',
  idField: 'id',
  titleGetter: 'name',
  fields: const [FieldModel('focusEnabled', ValueType(ValueKind.boolean))],
);

final _priorityEnum = AppEnumModel(
  className: 'TaskPriority',
  library: _models,
  title: 'Priority',
  cases: const [
    AppEnumCase(name: 'low', title: 'Low'),
    AppEnumCase(name: 'high', title: 'High', systemImage: 'exclamationmark.triangle'),
  ],
);

/// `applyFocus({bool hideTasks = false, int level = 2, String? tag})`.
ActionModel _focus({String? summary = 'Only {tag}', String? filterCriteriaParam}) => ActionModel(
      functionName: 'applyFocus',
      library: _library,
      title: 'Journal Focus',
      description: 'Choose what shows during a Focus.',
      runs: RunsModel.deferred,
      returnsString: false,
      focusFilter: FocusFilterModel(summary: summary, filterCriteriaParam: filterCriteriaParam),
      params: [
        ParamModel(
            name: 'hideTasks',
            title: 'Hide tasks',
            named: true,
            value: const ValueType(ValueKind.boolean),
            swiftDefault: 'false'),
        ParamModel(name: 'level', title: 'Level', named: true, value: const ValueType(ValueKind.integer), swiftDefault: '2'),
        ParamModel(
            name: 'tag',
            title: 'Tag',
            named: true,
            value: const ValueType(ValueKind.string, nullable: true),
            swiftDefault: '"work"'),
      ],
    );

ActionModel _recording(RunsModel runs) => ActionModel(
      functionName: 'stopRecording',
      library: _library,
      title: 'Stop Recording',
      runs: runs,
      returnsString: runs == RunsModel.withFlutter,
      dialog: 'Stopped.',
      liveActivity: true,
      params: const [],
    );

AppModel _app(
  List<ActionModel> actions, {
  String? appGroup,
  List<EntityModel> entities = const [],
  Map<String, AppEnumModel> appEnums = const {},
  List<WidgetConfigModel> widgetConfigs = const [],
}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: entities,
      schemaEntities: const [],
      appGroup: appGroup,
      appEnums: appEnums,
      widgetConfigs: widgetConfigs,
    );

/// Minimal [BuildStep] for running [ModelReader] directly in unit tests.
class _FakeBuildStep implements BuildStep {
  _FakeBuildStep(this._runtimeRoot);

  final String _runtimeRoot;

  File _assetFile(AssetId id) {
    if (id.package == 'assistant_actions') {
      return File(p.join(_runtimeRoot, id.path));
    }
    throw UnimplementedError('Unexpected asset: $id');
  }

  @override
  Future<bool> canRead(AssetId id) async => _assetFile(id).existsSync();

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async =>
      _assetFile(id).readAsStringSync(encoding: encoding);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppModel?> _readDartSource(String source, {String? modelsSource}) async {
  final runtimeRoot = p.normalize(p.join(Directory.current.path, '..', 'assistant_actions'));
  final runtimePkgConfig = jsonDecode(
    File(p.join(runtimeRoot, '.dart_tool', 'package_config.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final existingPackages = (runtimePkgConfig['packages'] as List).cast<Map<String, Object?>>();

  final temp = await Directory.systemTemp.createTemp('surfaces_reader_');
  try {
    Directory(p.join(temp.path, 'lib')).createSync(recursive: true);
    Directory(p.join(temp.path, '.dart_tool')).createSync(recursive: true);
    final resolvedPackages = <Map<String, Object?>>[];
    for (final pkg in existingPackages) {
      if (pkg['name'] == 'assistant_actions') continue;
      final rawUri = pkg['rootUri'] as String;
      final absUri = rawUri.startsWith('file://')
          ? rawUri
          : Uri.directory(p.normalize(p.join(runtimeRoot, '.dart_tool', rawUri))).toString();
      resolvedPackages.add({...pkg, 'rootUri': absUri});
    }
    resolvedPackages.add({
      'name': 'assistant_actions',
      'rootUri': Uri.directory(runtimeRoot).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.6',
    });
    resolvedPackages.add({
      'name': 'test_app',
      'rootUri': Uri.directory(temp.path).toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.6',
    });
    File(p.join(temp.path, '.dart_tool', 'package_config.json')).writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': resolvedPackages}),
    );
    if (modelsSource != null) {
      File(p.join(temp.path, 'lib', 'models.dart')).writeAsStringSync(modelsSource);
    }
    final entryPath = p.normalize(p.join(temp.path, 'lib', 'assistant_actions.dart'));
    File(entryPath).writeAsStringSync(source);

    final collection = AnalysisContextCollection(includedPaths: [temp.path]);
    final context = collection.contextFor(entryPath);
    final resolved = await context.currentSession.getResolvedLibrary(entryPath);
    if (resolved is! ResolvedLibraryResult) {
      throw StateError('Failed to resolve library: $resolved');
    }
    return await ModelReader(_FakeBuildStep(runtimeRoot)).read(resolved.element);
  } finally {
    await temp.delete(recursive: true);
  }
}

void main() {
  group('Focus filters', () {
    late String swift;
    setUp(() => swift = SwiftWriter(_app([_focus()])).write());

    test('become a SetFocusFilterIntent with the Dart defaults', () {
      expect(swift, contains('public struct ApplyFocusFocusFilter: SetFocusFilterIntent {'));
      expect(swift, contains('public static let title: LocalizedStringResource = "Journal Focus"'));
      expect(swift, contains('IntentDescription("Choose what shows during a Focus.")'));
      expect(swift, contains('@Parameter(title: "Hide tasks", default: false)\n  public var hideTasks: Bool\n'));
      expect(swift, contains('@Parameter(title: "Level", default: 2)\n  public var level: Int\n'));
      expect(swift, contains('@Parameter(title: "Tag", default: "work")\n  public var tag: String?\n'),
          reason: 'optional parameters can have defaults too');
    });

    test('show the summary under the title in Settings', () {
      expect(swift, contains(r'let summary: String = "Only \(tag.map { "\($0)" } ?? "")"'));
      expect(swift, contains(r'DisplayRepresentation(title: Self.title, subtitle: "\(summary)")'));
      final plain = SwiftWriter(_app([_focus(summary: null)])).write();
      expect(plain, contains('DisplayRepresentation(title: Self.title)\n'));
    });

    test('call Dart live when it runs, and queue the call otherwise, never coming forward', () {
      final start = swift.indexOf('struct ApplyFocusFocusFilter');
      final end = swift.indexOf('\n}\n', start);
      final body = swift.substring(start, end);
      expect(body, contains('"hideTasks": AssistantValues.encode(hideTasks),'));
      expect(body, contains('''
    if AssistantBridge.shared.isReady {
      _ = try await AssistantBridge.shared.perform("applyFocus", args: args)
    } else {
      AssistantInbox.call("applyFocus", args: args)
    }'''));
      expect(body, isNot(contains('requestToContinueInForeground')));
      expect(body, isNot(contains('ForegroundContinuableIntent')));
    });

    test('are called by the registry like actions, and have no shortcut', () {
      final dart = writeDart(_app([_focus()]));
      expect(dart, contains("'applyFocus': (args) async {"));
      expect(dart, contains("final _hideTasks = AssistantValue.boolean(args['hideTasks']) ?? (throw ArgumentError.notNull('hideTasks'));"));
      expect(dart, contains('await a0.applyFocus(hideTasks: _hideTasks, level: _level, tag: _tag);'));
      expect(writeShortcuts(_app([_focus()])), contains('No @AssistantAction has a shortcut'));
    });

    test('generate appContext notificationFilterPredicate when filterCriteriaParam is set', () {
      final withCriteria = SwiftWriter(_app([_focus(filterCriteriaParam: 'tag')])).write();
      expect(withCriteria, contains('public var appContext: FocusFilterAppContext {'));
      expect(withCriteria, contains('NSPredicate(format: "SELF IN %@", allowed)'));
      expect(swift, isNot(contains('var appContext: FocusFilterAppContext')),
          reason: 'unset filterCriteriaParam leaves default appContext');
    });

    test('register focusFilter.current host call for cold-start queries', () {
      expect(swift, contains('AssistantHostCalls.register("focusFilter.current") { args in queryFocusFilter(args) }'));
      expect(swift, contains('let current = try await ApplyFocusFocusFilter.current'));
      expect(swift, contains('"assistant_actions.focusFilterResult"'));
      expect(swift, contains('"action": "applyFocus"'));
    });
  });

  group('Live Activity intents', () {
    test('are LiveActivityIntents on iOS only', () {
      final swift = SwiftWriter(_app([_recording(RunsModel.deferred)])).write();
      expect(swift, contains('#if os(iOS)\n  /// Runs in the app\'s process and may start or update Live Activities.\n'
          '  extension StopRecordingAction: LiveActivityIntent {}\n#endif'));
    });

    test('deferred ones run at once when Dart runs, and queue otherwise', () {
      final swift = SwiftWriter(_app([_recording(RunsModel.deferred)])).write();
      expect(swift, contains('''
    if AssistantBridge.shared.isReady {
      _ = try await callDart("stopRecording", args: args)
    } else {
      AssistantInbox.call("stopRecording", args: args)
    }
    return .result(dialog: IntentDialog(stringLiteral: "Stopped."))'''));
      expect(swift, isNot(contains('ForegroundContinuableIntent')));
    });

    test('live ones come forward only when Dart is not running', () {
      final swift = SwiftWriter(_app([_recording(RunsModel.withFlutter)])).write();
      expect(swift, contains('public struct StopRecordingAction: AppIntent, ForegroundContinuableIntent {'));
      expect(swift, contains('if !AssistantBridge.shared.isReady && UIApplication.shared.applicationState != .active {'));
      expect(swift, contains('return .result(dialog: IntentDialog(stringLiteral: reply ?? "Stopped."))'));
    });

    test('plain actions are unchanged', () {
      final plain = ActionModel(
          functionName: 'ping', library: _library, title: 'Ping', runs: RunsModel.deferred, params: const [],
          returnsString: false, dialog: 'Pong.');
      final swift = SwiftWriter(_app([plain])).write();
      expect(swift, isNot(contains('LiveActivityIntent')));
      expect(swift, contains('AssistantInbox.call("ping", args: args)\n    AssistantBridge.shared.inboxChanged()'));
    });
  });

  test('a live Live Activity action can also reply with a card', () {
    final action = ActionModel(
      functionName: 'stopRecording',
      library: _library,
      title: 'Stop Recording',
      runs: RunsModel.withFlutter,
      returnsString: false,
      returnsReply: true,
      liveActivity: true,
      params: const [],
    );
    final swift = SwiftWriter(_app([action])).write();
    expect(swift, contains('if !AssistantBridge.shared.isReady && UIApplication.shared.applicationState != .active'));
    expect(swift, contains('let reply = AssistantReply(json: try await callDart("stopRecording", args: args))'));
    expect(swift, contains('ProvidesDialog & ShowsSnippetView'));
    expect(swift, contains('extension StopRecordingAction: LiveActivityIntent {}'));
  });

  group('App Group, Controls, WidgetConfigurationIntent & Discovery Lookup', () {
    final startTimer = ActionModel(
      functionName: 'startTimer',
      library: _library,
      title: 'Start Timer',
      runs: RunsModel.deferred,
      params: const [],
      returnsString: false,
      dialog: 'Timer started.',
      shortcut: const ShortcutModel(
        phrases: ['Start timer in {app}'],
        shortTitle: 'Start Timer',
        systemImage: 'timer',
      ),
      control: const ControlModel(
        id: 'start_timer',
        title: 'Start Timer',
        systemImage: 'timer',
        subtitle: 'Starts a quick timer.',
      ),
    );

    final setFocusMode = ActionModel(
      functionName: 'setFocusMode',
      library: _library,
      title: 'Set Focus Mode',
      runs: RunsModel.deferred,
      params: [
        ParamModel(name: 'value', title: 'Value', named: false, value: const ValueType(ValueKind.boolean)),
      ],
      returnsString: false,
      dialog: 'Updated.',
      control: const ControlModel(
        id: 'focus_mode',
        title: 'Focus Mode',
        systemImage: 'moon.fill',
        subtitle: 'Toggle Focus mode.',
        isToggle: true,
        toggleSnapshotCollection: 'AppSettings',
        toggleEntityId: 'default',
        toggleField: 'focusEnabled',
      ),
    );

    final pinnedWidget = WidgetConfigModel(
      id: 'pinned_task',
      name: 'pinnedTask',
      library: _library,
      title: 'Pinned Task',
      description: 'Choose a task to pin.',
      params: [
        ParamModel(name: 'task', title: 'Task', named: false, entity: _taskEntity, entityNullable: true),
        ParamModel(
          name: 'priority',
          title: 'Priority',
          named: true,
          value: const ValueType(ValueKind.enumeration, appEnum: 'TaskPriority'),
          swiftDefault: '.high',
        ),
        ParamModel(
          name: 'showCompleted',
          title: 'Show Completed',
          named: true,
          value: const ValueType(ValueKind.boolean),
          swiftDefault: 'true',
        ),
      ],
    );

    late AppModel model;
    late String mainSwift;
    late String widgetsSwift;

    setUp(() {
      model = _app(
        [startTimer, setFocusMode, _focus(filterCriteriaParam: 'tag')],
        appGroup: 'group.dev.mira.shared',
        entities: [_taskEntity, _settingsEntity],
        appEnums: {'TaskPriority': _priorityEnum},
        widgetConfigs: [pinnedWidget],
      );
      mainSwift = SwiftWriter(model).write();
      widgetsSwift = writeWidgets(model);
    });

    test('emits AssistantActionsAppGroup in main Swift and configuredAppGroup in extension Swift', () {
      expect(mainSwift, contains('@objc(AssistantActionsAppGroup)'));
      expect(mainSwift, contains('public static var appGroupIdentifier: String? { "group.dev.mira.shared" }'));
      expect(widgetsSwift, contains('public static let configuredAppGroup: String? = "group.dev.mira.shared"'));

      final noGroup = _app([startTimer]);
      expect(SwiftWriter(noGroup).write(), isNot(contains('AssistantActionsAppGroup')));
      expect(writeWidgets(noGroup), contains('public static let configuredAppGroup: String? = nil'));
    });

    test('emits ControlWidgetButton, ControlWidgetToggle, SetValueIntent and WidgetConfigurationIntent', () {
      expect(mainSwift, contains('extension SetFocusModeAction: SetValueIntent {}'));
      expect(mainSwift, contains('AssistantAppGroup.userDefaults.set(value, forKey: "assistant_actions.control.focus_mode")'));
      expect(mainSwift, contains('assistantReloadControl("focus_mode")'));
      expect(mainSwift, contains('public struct PinnedTaskWidgetIntent: WidgetConfigurationIntent {'));

      expect(widgetsSwift, contains('public struct StartTimerControlWidget: ControlWidget {'));
      expect(widgetsSwift, contains('ControlWidgetButton(action: StartTimerAction())'));
      expect(widgetsSwift, contains('public struct FocusModeControlValueProvider: ControlValueProvider {'));
      expect(widgetsSwift, contains('public struct FocusModeControlWidget: ControlWidget {'));
      expect(widgetsSwift, contains('ControlWidgetToggle("Focus Mode", isOn: isOn, action: SetFocusModeAction())'));
      expect(widgetsSwift, contains('collection: "AppSettings"'));
      expect(widgetsSwift, contains('entityId: "default"'));
      expect(widgetsSwift, contains('field: "focusEnabled"'));
      expect(widgetsSwift, contains('public struct PinnedTaskWidgetIntent: WidgetConfigurationIntent {'));
      expect(widgetsSwift, contains('public var assistantControlsBundle: some Widget {'));
    });

    test('extension Swift has zero Flutter or plugin imports', () {
      expect(widgetsSwift, isNot(contains('import Flutter')));
      expect(widgetsSwift, isNot(contains('import FlutterMacOS')));
      expect(widgetsSwift, isNot(contains('import assistant_actions')));
    });

    test('emits AssistantActionsAppIntents lookup for AssistantSiriTip', () {
      expect(mainSwift, contains('@objc(AssistantActionsAppIntents)'));
      expect(mainSwift, contains('public final class AssistantActionsAppIntents: NSObject, AssistantIntentProvider {'));
      expect(mainSwift, contains('case "startTimer":\n      return StartTimerAction()'));
      expect(mainSwift, contains('case "startTimer": return "Start timer in Mira"'));
      expect(mainSwift, contains('case "startTimer": return "Start Timer"'));
    });

    test('typechecks generated main Swift and standalone widget extension Swift on iOS and macOS', () async {
      final dir = await Directory.systemTemp.createTemp('surfaces_swiftc_');
      addTearDown(() => dir.delete(recursive: true));

      final runtimeRoot = p.normalize(p.join(Directory.current.path, '..', 'assistant_actions'));
      final runtimeSrc = p.join(runtimeRoot, 'darwin', 'assistant_actions', 'Sources', 'assistant_actions');
      final widgetsDir = p.join(runtimeRoot, 'darwin', 'widgets');

      // 1. Standalone widget extension compilation (iOS Simulator + macOS).
      final genWidgetsFile = File(p.join(dir.path, 'AssistantWidgets.g.swift'))..writeAsStringSync(widgetsSwift);
      for (final (sdkName, target, includeLiveActivity) in [
        ('iphonesimulator', 'arm64-apple-ios17.0-simulator', true),
        ('macosx', 'arm64-apple-macosx14.0', false),
      ]) {
        final sdk = (await Process.run('xcrun', ['--sdk', sdkName, '--show-sdk-path'])).stdout.toString().trim();
        final extFiles = [
          p.join(runtimeSrc, 'AssistantAppGroup.swift'),
          p.join(runtimeSrc, 'AssistantActivityAttributes.swift'),
          p.join(runtimeSrc, 'AssistantLiveActivityIntent.swift'),
          if (includeLiveActivity) p.join(widgetsDir, 'AssistantLiveActivityWidget.swift'),
          p.join(widgetsDir, 'AssistantWidgets.swift'),
          genWidgetsFile.path,
        ];
        final res = await Process.run('xcrun', [
          'swiftc',
          '-typecheck',
          '-parse-as-library',
          '-sdk',
          sdk,
          '-target',
          target,
          ...extFiles,
        ]);
        expect(res.exitCode, 0, reason: 'Widget extension ($sdkName): ${res.stdout}${res.stderr}');
      }

      // 2. Main plugin Swift compilation (iOS Simulator + macOS).
      final genMainFile = File(p.join(dir.path, 'AssistantActions.g.swift'))
        ..writeAsStringSync(mainSwift.replaceFirst('import assistant_actions\n', ''));
      final bridgeStub = File(p.join(dir.path, 'BridgeStub.swift'))
        ..writeAsStringSync('''
import Foundation
@MainActor public final class AssistantBridge {
  public static let shared = AssistantBridge()
  public var isReady: Bool = false
  public func perform(_ action: String, args: [String: Any]) async throws -> String? { nil }
  public func waitUntilReady(timeout: TimeInterval) async -> Bool { false }
  public func inboxChanged() {}
}
public enum AssistantActionError: Error { case notRunning; case failed(String) }
@MainActor public final class AssistantBackground {
  public static let shared = AssistantBackground()
  public func prepare(timeout: TimeInterval = 15) async -> Bool { false }
  public func applyInbox(timeout: TimeInterval = 10) async {}
}
@objc public protocol AssistantBackgroundEntrypoint {
  static var entrypoint: String { get }
  static var libraryURI: String { get }
}
''');
      final mainFiles = [
        genMainFile.path,
        bridgeStub.path,
        for (final f in [
          'AssistantAppGroup',
          'AssistantValues',
          'AssistantInbox',
          'AssistantSnapshot',
          'AssistantQuery',
          'AssistantSpotlight',
          'AssistantMatch',
          'AssistantComparison',
          'AssistantRichValues',
          'AssistantHostCalls',
          'AssistantReply',
          'AssistantDialog',
          'AssistantInteraction',
          'AssistantCardView',
          'AssistantCardStore',
          'AssistantLiveCall',
          'AssistantLiveIntents',
          'AssistantFileIDs',
          'AssistantUndo',
          'AssistantContext',
          'AssistantVisualIntelligence',
          'AssistantPlatformViews',
        ])
          p.join(runtimeSrc, '$f.swift'),
      ];
      for (final (sdkName, target) in [
        ('iphonesimulator', 'arm64-apple-ios17.0-simulator'),
        ('macosx', 'arm64-apple-macosx14.0'),
      ]) {
        final sdk = (await Process.run('xcrun', ['--sdk', sdkName, '--show-sdk-path'])).stdout.toString().trim();
        final res = await Process.run('xcrun', [
          'swiftc',
          '-typecheck',
          '-parse-as-library',
          '-sdk',
          sdk,
          '-target',
          target,
          ...mainFiles,
        ]);
        expect(res.exitCode, 0, reason: 'Main generated Swift ($sdkName): ${res.stdout}${res.stderr}');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('ModelReader end-to-end validation for System Surfaces', () {
    test('reads @AssistantApp(appGroup:), @AssistantControl, @AssistantWidgetConfig and filterCriteriaParam', () async {
      final app = await _readDartSource('''
@AssistantApp(name: 'Mira', appGroup: 'group.dev.mira')
library;

import 'package:assistant_actions/assistant_actions.dart';

@AssistantEnum(title: 'Priority')
enum Priority { low, high }

@AssistantEntity(title: 'Task')
class TaskItem {
  const TaskItem(this.id, this.title, {this.done = false});
  @EntityId()
  final String id;
  @DisplayTitle()
  final String title;
  final bool done;
}

@AssistantControl(id: 'quick_add', title: 'Quick Add', systemImage: 'plus.circle')
@AssistantAction(title: 'Quick Add', dialog: 'Added.')
Future<void> quickAdd() async {}

@AssistantControl(
  id: 'toggle_done',
  title: 'Task Done',
  systemImage: 'checkmark.circle',
  toggleSnapshotCollection: 'TaskItem',
  toggleEntityId: 'main',
  toggleField: 'done',
)
@AssistantAction(title: 'Set Task Done', dialog: 'Updated.')
Future<void> setTaskDone(bool value) async {}

@AssistantWidgetConfig(id: 'task_widget', title: 'Task Widget', description: 'Pick a task.')
void taskWidget(@Param(title: 'Task') TaskItem? task, {@Param(title: 'Priority') Priority priority = Priority.high}) {}

@AssistantWidgetConfig(id: 'counter_widget', title: 'Counter Widget')
class CounterWidgetConfig {
  const CounterWidgetConfig({@Param(title: 'Count') this.count = 3, this.label = 'Today'});
  final int count;
  final String label;
}

@AssistantFocusFilter(title: 'Work Focus', summary: 'Account {account}', filterCriteriaParam: 'account')
Future<void> applyWorkFocus({String? account = 'work', bool hideBadges = true}) async {}
''');

      expect(app, isNotNull);
      expect(app!.appGroup, 'group.dev.mira');
      expect(app.controls, hasLength(2));
      expect(app.controls[0].$2.isToggle, isFalse);
      expect(app.controls[1].$2.isToggle, isTrue);
      expect(app.controls[1].$2.toggleSnapshotCollection, 'TaskItem');
      expect(app.controls[1].$2.toggleField, 'done');
      expect(app.widgetConfigs.map((w) => w.swiftName), ['TaskWidgetWidgetIntent', 'CounterWidgetConfigWidgetIntent']);
      expect(app.widgetConfigs[1].params.first.swiftDefault, '3');
      final focus = app.actions.singleWhere((a) => a.focusFilter != null);
      expect(focus.focusFilter!.filterCriteriaParam, 'account');
    });

    test('rejects invalid control, widget config and focus filter declarations', () async {
      await expectLater(
        _readDartSource('''
@AssistantApp(name: 'Mira')
library;
import 'package:assistant_actions/assistant_actions.dart';

@AssistantControl(id: 'orphan', title: 'Orphan', systemImage: 'star')
Future<void> orphan() async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>().having(
          (e) => e.message,
          'message',
          contains('@AssistantControl requires @AssistantAction'),
        )),
      );

      await expectLater(
        _readDartSource('''
@AssistantApp(name: 'Mira')
library;
import 'package:assistant_actions/assistant_actions.dart';

@AssistantControl(id: 'bad_btn', title: 'Bad', systemImage: 'star')
@AssistantAction(title: 'Bad')
Future<void> badBtn(String requiredText) async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>().having(
          (e) => e.message,
          'message',
          contains('cannot take required parameters'),
        )),
      );

      await expectLater(
        _readDartSource('''
@AssistantApp(name: 'Mira')
library;
import 'package:assistant_actions/assistant_actions.dart';

@AssistantFocusFilter(title: 'Focus', filterCriteriaParam: 'missing')
Future<void> focus({bool hide = false}) async {}
'''),
        throwsA(isA<InvalidGenerationSourceError>().having(
          (e) => e.message,
          'message',
          contains('filterCriteriaParam "missing" is not a parameter'),
        )),
      );
    });
  });
}
