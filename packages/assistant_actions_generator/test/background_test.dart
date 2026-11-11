import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

SchemaEntityModel _adopt(String id, Map<String, FieldModel> mapping, {required String className}) {
  final catalog = _load(id.split('.').first);
  final schema = catalog.entities[id]!;
  return SchemaEntityModel(
    className: className,
    library: Uri.parse('package:app/models.dart'),
    catalog: catalog,
    schema: schema,
    idField: 'id',
    mapping: mapping,
    intents: catalog.intentsFor(schema),
    containers: const {},
  );
}

ActionModel _action(String name,
        {RunsModel runs = RunsModel.withFlutter, bool opensApp = false, bool liveActivity = false}) =>
    ActionModel(
      functionName: name,
      library: Uri.parse('package:app/assistant_actions.dart'),
      title: name,
      runs: runs,
      params: const [],
      returnsString: runs == RunsModel.withFlutter,
      dialog: runs == RunsModel.deferred ? 'Done.' : null,
      opensApp: opensApp,
      liveActivity: liveActivity,
    );

BackgroundModel _backgroundModel({bool applyQueued = true}) => BackgroundModel(
      functionName: 'appRegistry',
      library: Uri.parse('package:app/store.dart'),
      entrypointLibrary: Uri.parse('package:app/assistant_actions.g.dart'),
      applyQueued: applyQueued,
    );

/// Photos (iOS 26 with their types) and stopwatches (iOS 27) have live calls that return items;
/// journal records audio; system.open opens items.
AppModel _app({bool background = true, bool applyQueued = true}) => AppModel(
      appName: 'Mira',
      actions: [
        _action('countTasks'),
        _action('showTask', opensApp: true),
        _action('addToList', runs: RunsModel.deferred),
        _action('record', liveActivity: true),
        _action('stopRecording', runs: RunsModel.deferred, liveActivity: true),
      ],
      entities: const [],
      schemaEntities: [
        _adopt('photos.asset', const {}, className: 'Photo'),
        _adopt('clock.stopwatch', const {'startTime': FieldModel('started', ValueType(ValueKind.dateTime))},
            className: 'Watch'),
        _adopt('journal.entry', const {'message': FieldModel('text', ValueType(ValueKind.string))},
            className: 'Entry'),
      ],
      schemaDomains: [
        SchemaDomainModel(className: 'SystemHandler', catalog: _load('system'), intents: _load('system').domainIntents),
      ],
      catalogs: {for (final d in ['photos', 'clock', 'journal', 'system']) d: _load(d)},
      background: background ? _backgroundModel(applyQueued: applyQueued) : null,
    );

/// Just actions, for the Dart side (schemas need app enums there).
AppModel _plain({required bool background}) => AppModel(
      appName: 'Mira',
      actions: [_action('countTasks')],
      entities: const [],
      schemaEntities: const [],
      background: background ? _backgroundModel() : null,
    );

String _block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

void main() {
  group('without @AssistantBackground', () {
    final swift = SwiftWriter(_app(background: false)).write();
    final dart = writeDart(_plain(background: false));

    test('live intents bring the app forward, as before', () {
      final count = _block(swift, 'public struct CountTasksAction');
      expect(count, startsWith('public struct CountTasksAction: AppIntent, ForegroundContinuableIntent {'));
      expect(count, contains("// iOS doesn't start the Flutter engine without a scene, so answer from the foreground."));
      expect(count, contains('try await requestToContinueInForeground()'));
      expect(swift, isNot(contains('AssistantBackground')));
      expect(swift, isNot(contains('supportedModes: IntentModes {')));
      expect(swift, isNot(contains('AssistantActionsAppBackground')));
    });

    test('Live Activity actions keep their own check for running Dart', () {
      expect(_block(swift, 'public struct RecordAction'), contains('if !AssistantBridge.shared.isReady && UIApplication'));
      expect(_block(swift, 'public struct StopRecordingAction'), contains('    if AssistantBridge.shared.isReady {'));
    });

    test('queued intents only nudge a running app', () {
      expect(_block(swift, 'public struct AddToListAction'), contains('AssistantBridge.shared.inboxChanged()'));
    });

    test('Dart has no background entrypoint', () {
      expect(dart, isNot(contains('vm:entry-point')));
    });
  });

  group('with @AssistantBackground', () {
    final swift = SwiftWriter(_app()).write();
    final dart = writeDart(_plain(background: true));

    test('the runtime finds the entrypoint by class name', () {
      expect(swift, contains('''
#if os(iOS)
  /// Where `AssistantBackground` starts Dart on a headless engine: the
  /// generated `assistantActionsBackgroundMain`, which builds the registry with
  /// `appRegistry`.
  @objc(AssistantActionsAppBackground)
  public final class AssistantActionsAppBackground: NSObject, AssistantBackgroundEntrypoint {
    public static let entrypoint = "assistantActionsBackgroundMain"
    public static let libraryURI = "package:app/assistant_actions.g.dart"
  }
#endif'''));
    });

    test('Dart gets an entrypoint that builds the registry with the app function', () {
      expect(dart, contains("import 'package:app/store.dart' as a"));
      expect(dart, contains("@pragma('vm:entry-point')\nFuture<void> assistantActionsBackgroundMain() =>\n"
          '    AssistantActions.startInBackground(a'));
      expect(dart, contains('.appRegistry);'));
    });

    test('Runs.withFlutter actions run in the background, foregrounding only as a fallback', () {
      final count = _block(swift, 'public struct CountTasksAction');
      expect(count, startsWith('public struct CountTasksAction: AppIntent, ForegroundContinuableIntent {'),
          reason: 'continuing in the foreground before iOS 26 needs the conformance');
      expect(count, contains('''
  #if os(iOS)
  @available(iOS 26.0, *)
  public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
  #endif
'''));
      expect(count, contains('''
    #if os(iOS)
      // Dart answers in the background (on a headless engine if the app has none);
      // the app comes forward only if that fails.
      if !(await AssistantBackground.shared.prepare()), UIApplication.shared.applicationState != .active {
        if #available(iOS 26.0, *) {
          try await continueInForeground()
        } else {
          try await requestToContinueInForeground()
        }
      }
    #endif
    let reply = try await AssistantBridge.shared.perform("countTasks", args: args)'''));
    });

    test('opensApp actions still come to the foreground, and activate on macOS', () {
      final show = _block(swift, 'public struct ShowTaskAction');
      expect(show, isNot(contains('AssistantBackground')));
      expect(show, isNot(contains('supportedModes')));
      expect(show, contains('try await requestToContinueInForeground()'));
      expect(show, contains('NSApplication.shared.activate()'));
    });

    test('a live call raised to iOS 26 by its types declares modes outright too', () {
      // photos.duplicateAssets is iOS 18, but PhotoEntity needs iOS 26.
      final duplicate = _block(swift, 'struct PhotoDuplicateAssetsIntent');
      expect(duplicate, startsWith('struct PhotoDuplicateAssetsIntent {\n  #if os(iOS)\n  static let supportedModes'));
      expect(duplicate, contains('AssistantBackground.shared.prepare()'));
      expect(duplicate, isNot(contains('requestToContinueInForeground')));
    });

    test('live calls from iOS 26 declare modes outright and never use the deprecated API', () {
      final start = _block(swift, 'struct WatchStartStopwatchIntent');
      expect(start, startsWith('struct WatchStartStopwatchIntent {'));
      expect(start, contains('''
  #if os(iOS)
  static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
  #endif'''));
      expect(start, contains('        try await continueInForeground()\n      }'));
      expect(start, isNot(contains('requestToContinueInForeground')));
      expect(start, isNot(contains('#available')));
    });

    test('recording and opening intents still come to the foreground', () {
      final audio = _block(swift, 'struct EntryCreateAudioEntryIntent');
      expect(audio, contains('try await requestToContinueInForeground()'));
      expect(audio, isNot(contains('AssistantBackground')));
      final open = _block(swift, 'struct OpenEntryIntent');
      expect(open, contains('try await requestToContinueInForeground()'));
      expect(open, isNot(contains('AssistantBackground')));
      final search = _block(swift, 'struct SystemSearchInAppIntent');
      expect(search, contains('static let supportedModes: IntentModes = .foreground\n'));
      expect(search, isNot(contains('AssistantBackground')));
    });

    test('queued intents apply right away on the headless engine', () {
      expect(_block(swift, 'public struct AddToListAction'), contains('await AssistantBackground.shared.applyInbox()'));
      expect(_block(swift, 'struct EntryCreateEntryIntent'), contains('await AssistantBackground.shared.applyInbox()'));
      expect(swift, isNot(contains('AssistantBridge.shared.inboxChanged()')));
    });

    test('Live Activity actions start Dart in the background too', () {
      final record = _block(swift, 'public struct RecordAction');
      expect(record, contains('public static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }'));
      expect(record, contains('if !(await AssistantBackground.shared.prepare()), UIApplication'));
      expect(record, isNot(contains('AssistantBridge.shared.isReady')));
      final stop = _block(swift, 'public struct StopRecordingAction');
      expect(stop, contains('    if await AssistantBackground.shared.prepare() {\n'
          '      _ = try await AssistantBridge.shared.perform("stopRecording", args: args)\n'
          '    } else {\n'
          '      AssistantInbox.call("stopRecording", args: args)'));
      expect(swift, contains('extension RecordAction: LiveActivityIntent {}'));
    });

    test('applyQueued: false leaves queued intents for the next launch', () {
      final queued = SwiftWriter(_app(applyQueued: false)).write();
      expect(queued, isNot(contains('applyInbox')));
      expect(_block(queued, 'public struct AddToListAction'), contains('AssistantBridge.shared.inboxChanged()'));
      expect(_block(queued, 'public struct CountTasksAction'), contains('AssistantBackground.shared.prepare()'));
      expect(_block(queued, 'public struct StopRecordingAction'), contains('    if AssistantBridge.shared.isReady {'),
          reason: 'a deferred Live Activity action still runs only in a running engine');
    });
  });
}
