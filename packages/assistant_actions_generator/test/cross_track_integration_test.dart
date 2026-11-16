// End-to-end cross-track integration test combining all 4 feature tracks:
// - Track 1 (Surfaces): App Group, @AssistantControl (button & toggle),
//   @AssistantWidgetConfig, FocusFilter appContext + current query, SiriTip lookup.
// - Track 2 (Runtime Calls): AssistantError, AssistantCall.requestValue /
//   disambiguate / confirm / choose, schema AssistantDonations, plain action Undo.
// - Track 3 (Params & Cards): SchemaEntity parameters on @AssistantAction and
//   @AssistantFocusFilter, AssistantCurrency & 6 Measurement wrappers,
//   DynamicOptionsProvider with @IntentParameterDependency, conditional
//   SummaryWhen / SummarySwitch, AssistantCardToggle & remote imageUrl.
// - Track 4 (Queries & Spotlight): @EntityKeywords / @EntityBody /
//   @EntityCreatedAt / @EntityUpdatedAt, SnapshotFilter predicates, richer
//   EntityPropertyQuery comparators, and FoundationModels.Tool bridging.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/reader.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:build/build.dart';
import 'package:test/test.dart';

class _FakeBuildStep implements BuildStep {
  @override
  Future<bool> canRead(AssetId id) async =>
      id.package == 'assistant_actions' && File('../assistant_actions/${id.path}').existsSync();

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async =>
      File('../assistant_actions/${id.path}').readAsStringSync(encoding: encoding);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('combines all 4 tracks seamlessly and passes flutter analyze + iOS/macOS swiftc -typecheck', () async {
    const source = '''
@AssistantApp(name: 'Mira Kitchen', appGroup: 'group.dev.mira.kitchen', shortcutTileColor: ShortcutTileColor.orange)
library;

import 'package:assistant_actions/assistant_actions.dart';
import 'package:assistant_actions/schemas/reminders.dart';

@AssistantEnum(title: 'Prep Mode')
enum PrepMode {
  @CaseTitle('Quick', systemImage: 'bolt.fill')
  quick,
  @CaseTitle('Slow Simmer', systemImage: 'flame')
  simmer,
}

@AssistantEntity(title: 'Recipe', systemImage: 'fork.knife')
class Recipe {
  const Recipe({
    required this.id,
    required this.name,
    required this.instructions,
    required this.createdAt,
    this.updatedAt,
    this.tags = const [],
    this.prepTime = const Duration(minutes: 15),
    this.mode = PrepMode.quick,
    this.pinned = false,
  });

  @EntityId()
  final String id;

  @DisplayTitle()
  final String name;

  @EntityBody()
  final String instructions;

  @EntityKeywords()
  final List<String> tags;

  @EntityCreatedAt()
  final DateTime createdAt;

  @EntityUpdatedAt()
  final DateTime? updatedAt;

  final Duration prepTime;
  final PrepMode mode;
  final bool pinned;
}

@AssistantUndoable()
@RemindersReminder(
  createReminder: true,
  updateReminder: true,
  deleteReminders: true,
  list: FixedRemindersList(id: 'kitchen', name: 'Kitchen'),
)
class KitchenTask {
  const KitchenTask({
    required this.id,
    required this.title,
    this.done = false,
    this.due,
  });

  @EntityId()
  final String id;

  @RemindersReminderField.title
  final String title;

  @RemindersReminderField.isCompleted
  final bool done;

  @RemindersReminderField.dueDate
  final DateTime? due;
}

@AssistantBackground()
Future<AssistantActionsRegistry> buildKitchenRegistry() async => throw UnimplementedError();

Future<List<KitchenTask>> suggestKitchenTasks(PrepMode mode) async => const [];
Future<List<String>> suggestAisles(Recipe recipe) async => [recipe.name];

/// Cross-track action: schema entity param + plain entity param + currency &
/// measurements + DynamicOptionsProvider + conditional summaries + undo (taking
/// schema entity, currency, measurement, and typed schema entity result) +
/// AssistantCall.requestValue / disambiguate + AssistantError + AssistantCardToggle
/// + FoundationModels.Tool!
@AssistantAction(
  title: 'Schedule Prep',
  description: 'Schedules prep for a kitchen task and recipe.',
  runs: Runs.withFlutter,
  cardButtons: true,
  undo: undoSchedulePrep,
  shortcut: AppShortcut(
    phrases: ['Prep {task} in {app}'],
    shortTitle: 'Schedule Prep',
    systemImage: 'checklist',
  ),
  summaries: [
    SummaryWhen('urgent', value: true, then: 'Urgently prep {task} with {recipe}'),
    SummarySwitch(
      'mode',
      cases: {
        PrepMode.quick: 'Quickly prep {task} with {recipe}',
        PrepMode.simmer: 'Slow-prep {task} with {recipe}',
      },
    ),
  ],
)
Future<AssistantReply<KitchenTask>> schedulePrep(
  KitchenTask task,
  Recipe recipe, {
  @Param(options: suggestKitchenTasks, snapshotField: 'done')
  KitchenTask? followUp,
  List<KitchenTask> subtasks = const [],
  @Param(options: suggestAisles, snapshotField: 'Recipe.title')
  String aisle = 'produce',
  PrepMode mode = PrepMode.quick,
  bool urgent = false,
  AssistantCurrency budget = const AssistantCurrency(amount: 12.50, currencyCode: 'USD'),
  AssistantLength walkDistance = const AssistantLength.kilometers(1.2),
  AssistantMass flourMass = const AssistantMass.grams(500),
  AssistantTemperature ovenTemp = const AssistantTemperature.celsius(200),
  AssistantVolume brothVolume = const AssistantVolume.milliliters(750),
  AssistantSpeed mixerSpeed = const AssistantSpeed(value: 2.5, unit: SpeedUnit.metersPerSecond),
  AssistantEnergy dishEnergy = const AssistantEnergy.kilocalories(640),
}) async {
  final call = AssistantCall.current;
  if (call != null) {
    final confirmed = await call.confirm('Start prep for \${task.title}?', actionLabel: 'Prep');
    if (!confirmed) throw const AssistantError('Prep was cancelled.');
    final resolvedTask = await call.requestValue<KitchenTask>('task', prompt: 'Which task?');
    final resolvedCost = await call.disambiguate<AssistantCurrency>('budget', [budget]);
    if (resolvedTask == null && resolvedCost == null) {
      await call.choose('Continue anyway?', const [AssistantChoice('yes', 'Yes')]);
    }
  }
  return AssistantReply(
    value: task,
    dialog: 'Scheduled \${task.title} in \$aisle.',
    card: AssistantCard(
      title: task.title,
      subtitle: recipe.name,
      imageUrl: 'https://example.com/prep.png',
      toggles: [
        AssistantCardToggle(
          label: 'Pin recipe',
          value: recipe.pinned,
          actionId: 'toggleKitchenTimer',
          systemImage: 'pin.fill',
        ),
      ],
    ),
  );
}

Future<void> undoSchedulePrep(
  KitchenTask task,
  Recipe recipe, {
  AssistantCurrency budget = const AssistantCurrency(amount: 12.50, currencyCode: 'USD'),
  AssistantMass flourMass = const AssistantMass.grams(500),
  KitchenTask? result,
}) async {}

@AssistantControl(
  id: 'kitchen_timer_toggle',
  title: 'Kitchen Timer',
  subtitle: 'Pinned recipe timer',
  systemImage: 'timer',
  toggleSnapshotCollection: 'Recipe',
  toggleField: 'pinned',
)
@AssistantAction(title: 'Toggle Kitchen Timer', dialog: 'Timer toggled.')
Future<void> toggleKitchenTimer(
  bool value, {
  KitchenTask? linkedTask,
  AssistantCurrency? limit,
}) async {}

@AssistantControl(
  id: 'quick_clean',
  title: 'Quick Clean',
  systemImage: 'sparkles',
)
@AssistantAction(title: 'Quick Clean', dialog: 'Started clean-up.')
Future<void> quickClean() async {}

@AssistantWidgetConfig(
  id: 'pinned_recipes_widget',
  title: 'Pinned Recipes',
  description: 'Choose recipes and mode for your Home Screen widget.',
)
void configureRecipesWidget({
  List<Recipe> pinned = const [],
  PrepMode mode = PrepMode.quick,
  int maxItems = 3,
}) {}

@AssistantFocusFilter(
  title: 'Kitchen Focus',
  description: 'Filter tasks during Kitchen Focus.',
  summary: 'Allowed tasks: {allowed}',
  filterCriteriaParam: 'allowed',
)
Future<void> applyKitchenFocus({
  List<KitchenTask> allowed = const [],
  PrepMode? mode,
}) async {}

@AssistantAction(
  title: 'Due Today Quick Tasks',
  description: 'Finds open tasks due today.',
)
const dueTodayTasks = SnapshotAnswer<KitchenTask>(
  where: {'done': false},
  filters: [
    SnapshotFilter.isToday('due'),
    SnapshotFilter.contains('title', 'prep'),
  ],
  sortBy: 'due',
  item: '{title}',
  dialog: 'Today: {items}.',
  empty: 'Nothing due today.',
);
''';

    final dir = Directory.systemTemp.createTempSync('cross_track_integration_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final runtimeConfigFile = File('../assistant_actions/.dart_tool/package_config.json').absolute;
    final hasFlutterConfig = runtimeConfigFile.existsSync();
    final configFile = hasFlutterConfig ? runtimeConfigFile : File('.dart_tool/package_config.json').absolute;
    final pkgConfig = jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
    final configDirUri = Uri.directory(configFile.parent.path);
    final packages = <Map<String, Object?>>[
      for (final pkg in (pkgConfig['packages'] as List).cast<Map<String, Object?>>())
        if (pkg['name'] != 'assistant_actions' && pkg['name'] != 'mira_kitchen')
          {
            ...pkg,
            'rootUri': configDirUri.resolve(pkg['rootUri'] as String).toString(),
          },
      {
        'name': 'assistant_actions',
        'rootUri': Directory('../assistant_actions').absolute.uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.6',
      },
      {
        'name': 'mira_kitchen',
        'rootUri': dir.absolute.uri.toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.6',
      },
    ];

    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: mira_kitchen\nenvironment:\n  sdk: ^3.6.0\n');
    final dartTool = Directory('${dir.path}/.dart_tool')..createSync(recursive: true);
    File('${dartTool.path}/package_config.json').writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': packages}));
    final libDir = Directory('${dir.path}/lib')..createSync(recursive: true);
    final entry = File('${libDir.path}/assistant_actions.dart')..writeAsStringSync(source);

    final collection = AnalysisContextCollection(includedPaths: [dir.absolute.path]);
    final resolved = await collection.contextFor(entry.absolute.path).currentSession.getResolvedLibrary(entry.absolute.path);
    expect(resolved, isA<ResolvedLibraryResult>());
    final model = (await ModelReader(_FakeBuildStep()).read((resolved as ResolvedLibraryResult).element))!;

    final dartOut = writeDart(model);
    final mainSwift = SwiftWriter(model).write();
    final shortcutsSwift = writeAppShortcuts(model);
    final widgetsSwift = writeAppWidgets(model);

    // Verify cross-track synergies in generated Dart:
    expect(dartOut, contains('required FutureOr<a0.KitchenTask?> Function(String id) findKitchenTask,'));
    expect(dartOut, contains('required FutureOr<a0.Recipe?> Function(String id) findRecipe,'));
    expect(dartOut, contains("'schedulePrep.undo': (args) async {"));
    expect(dartOut, contains('await a0.undoSchedulePrep(_u0, _u1, budget: _u2, flourMass: _u3, result: _u4);'));
    expect(dartOut, contains('a0.KitchenTask: (v) => v is String ? findKitchenTask(v) : null,'),
        reason: 'decoders include schema entity parameters for AssistantCall.requestValue / disambiguate');
    expect(dartOut, contains('static Future<bool> schedulePrep('),
        reason: 'plain action donation with schema entity + currency + measurements');
    expect(dartOut, contains('static Future<bool> createReminder(KitchenTaskValues values)'),
        reason: 'schema entity intent donations coexist with plain action donations');
    expect(dartOut, contains('static Future<bool> updateReminder(String id, KitchenTaskValues changes)'));
    expect(dartOut, contains('static Future<bool> deleteReminders(String id)'));

    // Verify cross-track synergies in generated Swift:
    expect(mainSwift, contains('extension SchedulePrepAction: AssistantPromptingIntent {'));
    expect(mainSwift, contains('let found = try await KitchenTaskEntityQuery().entities(for: ids)'));
    expect(mainSwift, contains('extension SchedulePrepAction: UndoableIntent {}'));
    expect(mainSwift, contains('public struct SchedulePrepActionTool: FoundationModels.Tool {'));
    expect(mainSwift, contains('public struct AssistantCurrencyToolValue: Sendable {'));
    expect(mainSwift, contains('public struct AssistantMeasurementToolValue: Sendable {'));
    expect(mainSwift, contains('public struct DueTodayTasksActionTool: FoundationModels.Tool {'));
    expect(mainSwift, contains('public var appContext: FocusFilterAppContext {'));
    expect(mainSwift, contains('let current = try await ApplyKitchenFocusFocusFilter.current'));
    expect(widgetsSwift, contains('public struct ConfigureRecipesWidgetWidgetIntent: WidgetConfigurationIntent {'));
    expect(widgetsSwift, contains('public struct KitchenTimerToggleControlWidget: ControlWidget {'));
    expect(widgetsSwift, contains('public struct QuickCleanControlWidget: ControlWidget {'));

    // Typecheck entry + generated `assistant_actions.g.dart` with the Dart analyzer (and `flutter analyze` when available).
    final genFile = File('${libDir.path}/assistant_actions.g.dart')..writeAsStringSync(dartOut);
    final genCollection = AnalysisContextCollection(includedPaths: [dir.absolute.path]);
    final errRes = await genCollection.contextFor(genFile.absolute.path).currentSession.getErrors(genFile.absolute.path);
    expect(errRes, isA<ErrorsResult>());
    final severe = (errRes as ErrorsResult)
        .diagnostics
        .where((e) => !e.diagnosticCode.lowerCaseName.contains('uri_does_not_exist'))
        .toList();
    expect(severe, isEmpty,
        reason: 'assistant_actions.g.dart failed analyzer:\n${severe.join('\n')}\n--- DART ---\n$dartOut');

    if (hasFlutterConfig) {
      try {
        final analyzeRes = Process.runSync('flutter', ['analyze', '--no-pub'], workingDirectory: dir.path);
        expect(analyzeRes.exitCode, 0,
            reason: 'flutter analyze failed:\n${analyzeRes.stdout}\n${analyzeRes.stderr}\n--- DART ---\n$dartOut');
      } on ProcessException {
        // Pure-Dart CI runners without Flutter still run AnalysisContextCollection error checks above.
      }
    }

    // Typecheck generated Swift (runtime module + main app module + Runner shortcuts + standalone widget extension)
    // across BOTH macOS and iOS Simulator SDKs!
    if (Platform.isMacOS) {
      final swiftDir = Directory('${dir.path}/swift')..createSync(recursive: true);
      final runtimeDir = Directory('../assistant_actions/darwin/assistant_actions/Sources/assistant_actions').absolute.path;
      final widgetsSrcDir = Directory('../assistant_actions/darwin/widgets').absolute.path;
      const runtimeFiles = [
        'AssistantAppGroup.swift',
        'AssistantValues.swift',
        'AssistantInbox.swift',
        'AssistantSnapshot.swift',
        'AssistantQuery.swift',
        'AssistantSpotlight.swift',
        'AssistantMatch.swift',
        'AssistantComparison.swift',
        'AssistantRichValues.swift',
        'AssistantHostCalls.swift',
        'AssistantReply.swift',
        'AssistantDialog.swift',
        'AssistantInteraction.swift',
        'AssistantCardView.swift',
        'AssistantCardStore.swift',
        'AssistantActivityAttributes.swift',
        'AssistantLiveActivityIntent.swift',
        'AssistantLiveActivities.swift',
        'AssistantShortcutParameters.swift',
        'AssistantBridge.swift',
        'AssistantApi.g.swift',
        'AssistantBackground.swift',
        'AssistantLiveCall.swift',
        'AssistantLiveIntents.swift',
        'AssistantFileIDs.swift',
        'AssistantUndo.swift',
        'AssistantContext.swift',
        'AssistantVisualIntelligence.swift',
        'AssistantPlatformViews.swift',
      ];
      final appSwiftFile = File('${swiftDir.path}/AssistantActions.g.swift')..writeAsStringSync(mainSwift);
      final shortcutsFile = File('${swiftDir.path}/AssistantShortcuts.g.swift')..writeAsStringSync(shortcutsSwift);
      final widgetsFile = File('${swiftDir.path}/AssistantWidgets.g.swift')..writeAsStringSync(widgetsSwift);

      for (final (sdk, libTarget, appTarget, isIOS) in const [
        ('macosx', 'arm64-apple-macosx14.0', 'arm64-apple-macosx14.4', false),
        ('iphonesimulator', 'arm64-apple-ios17.0-simulator', 'arm64-apple-ios17.4-simulator', true),
      ]) {
        final sdkOut = Directory('${swiftDir.path}/$sdk')..createSync(recursive: true);

        final runtimeRes = Process.runSync('xcrun', [
          '--sdk',
          sdk,
          'swiftc',
          '-emit-module',
          '-module-name',
          'assistant_actions',
          '-target',
          libTarget,
          '-emit-module-path',
          '${sdkOut.path}/assistant_actions.swiftmodule',
          for (final f in runtimeFiles) '$runtimeDir/$f',
        ]);
        expect(runtimeRes.exitCode, 0, reason: '[$sdk] runtime module failed:\n${runtimeRes.stderr}');

        final appRes = Process.runSync('xcrun', [
          '--sdk',
          sdk,
          'swiftc',
          '-emit-module',
          '-module-name',
          'assistant_actions_app',
          '-target',
          libTarget,
          '-I',
          sdkOut.path,
          '-emit-module-path',
          '${sdkOut.path}/assistant_actions_app.swiftmodule',
          appSwiftFile.path,
        ]);
        expect(appRes.exitCode, 0,
            reason: '[$sdk] AssistantActions.g.swift failed:\n${appRes.stderr}\n--- SWIFT ---\n$mainSwift');

        final shortcutsRes = Process.runSync('xcrun', [
          '--sdk',
          sdk,
          'swiftc',
          '-typecheck',
          '-module-name',
          'Runner',
          '-target',
          appTarget,
          '-I',
          sdkOut.path,
          shortcutsFile.path,
        ]);
        expect(shortcutsRes.exitCode, 0,
            reason: '[$sdk] AssistantShortcuts.g.swift failed:\n${shortcutsRes.stderr}');

        final extRes = Process.runSync('xcrun', [
          '--sdk',
          sdk,
          'swiftc',
          '-typecheck',
          '-parse-as-library',
          '-module-name',
          'AssistantWidgetsExtension',
          '-target',
          libTarget,
          '$runtimeDir/AssistantAppGroup.swift',
          '$runtimeDir/AssistantActivityAttributes.swift',
          '$runtimeDir/AssistantLiveActivityIntent.swift',
          if (isIOS) '$widgetsSrcDir/AssistantLiveActivityWidget.swift',
          '$widgetsSrcDir/AssistantWidgets.swift',
          widgetsFile.path,
        ]);
        expect(extRes.exitCode, 0,
            reason: '[$sdk] AssistantWidgets extension failed:\n${extRes.stderr}\n--- WIDGETS ---\n$widgetsSwift');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
