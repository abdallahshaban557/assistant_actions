// Focus filters and Live Activity intents: system surfaces beyond Siri.
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

final _library = Uri.parse('package:app/assistant_actions.dart');

/// `applyFocus({bool hideTasks = false, int level = 2, String? tag})`.
ActionModel _focus({String? summary = 'Only {tag}'}) => ActionModel(
      functionName: 'applyFocus',
      library: _library,
      title: 'Journal Focus',
      description: 'Choose what shows during a Focus.',
      runs: RunsModel.deferred,
      returnsString: false,
      focusFilter: FocusFilterModel(summary: summary),
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

AppModel _app(List<ActionModel> actions) =>
    AppModel(appName: 'Mira', actions: actions, entities: const [], schemaEntities: const []);

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
      final body = swift.substring(swift.indexOf('struct ApplyFocusFocusFilter'));
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
      _ = try await AssistantBridge.shared.perform("stopRecording", args: args)
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
}
