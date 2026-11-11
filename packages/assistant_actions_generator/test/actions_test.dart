// Plain actions, App Enums, results and App Shortcuts, built from models
// directly (the reader's checks run in the example app's build).
import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

final _lib = Uri.parse('package:app/assistant_actions.dart');
final _models = Uri.parse('package:app/models.dart');

final _recipe = EntityModel(
  className: 'Recipe',
  library: _models,
  title: 'Recipe',
  idField: 'id',
  titleGetter: 'name',
  fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
);

final _meal = AppEnumModel(className: 'Meal', library: _models, title: 'Meal', cases: const [
  AppEnumCase(name: 'dinner', title: 'Dinner'),
  AppEnumCase(name: 'snack', title: 'Late-night snack', synonyms: ['snack']),
]);

const _mealType = ValueType(ValueKind.enumeration, appEnum: 'Meal');

ActionModel _action(
  String name, {
  List<ParamModel> params = const [],
  ResultModel? result,
  RunsModel runs = RunsModel.withFlutter,
  String? dialog,
  ShortcutModel? shortcut,
  List<String> keywords = const [],
  bool discoverable = true,
  bool reply = false,
  String? confirm,
  bool liveActivity = false,
  FocusFilterModel? focusFilter,
}) =>
    ActionModel(
      functionName: name,
      library: _lib,
      title: name,
      runs: runs,
      params: params,
      returnsString: false,
      result: result,
      dialog: dialog,
      shortcut: shortcut,
      searchKeywords: keywords,
      isDiscoverable: discoverable,
      returnsReply: reply,
      confirm: confirm,
      liveActivity: liveActivity,
      focusFilter: focusFilter,
    );

/// "Plan {meal} with {recipe}", a deferred action taking an entity and an
/// App Enum with a default.
ActionModel _plan() => _action(
      'planMeal',
      runs: RunsModel.deferred,
      dialog: 'Planned {recipe} for {meal}.',
      keywords: const ['menu'],
      params: [
        ParamModel(name: 'recipe', title: 'Recipe', named: false, entity: _recipe),
        ParamModel(
            name: 'meal', title: 'Meal', named: true, value: _mealType, swiftDefault: '.dinner', defaultDart: 'Meal.dinner'),
      ],
      shortcut: const ShortcutModel(
          phrases: ['Cook {recipe} for {meal} in {app}'], shortTitle: 'Plan', systemImage: 'fork.knife'),
    );

AppModel _app({
  List<ActionModel> actions = const [],
  List<SchemaEntityModel> schemaEntities = const [],
  List<SchemaDomainModel> domains = const [],
  List<IntentShortcutModel> intentShortcuts = const [],
  Map<String, DomainCatalog> catalogs = const {},
  String? tileColor,
}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: [_recipe],
      schemaEntities: schemaEntities,
      schemaDomains: domains,
      catalogs: catalogs,
      appEnums: {'Meal': _meal},
      intentShortcuts: intentShortcuts,
      shortcutTileColor: tileColor,
    );

/// Mira's tasks as `reminders.reminder`.
SchemaEntityModel _tasks() {
  final reminders = _load('reminders');
  final schema = reminders.entities['reminders.reminder']!;
  return SchemaEntityModel(
    className: 'TaskItem',
    library: _models,
    catalog: reminders,
    schema: schema,
    idField: 'id',
    mapping: const {'title': FieldModel('title', ValueType(ValueKind.string))},
    intents: const [],
    containers: {
      'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
    },
  );
}

SchemaDomainModel _camera() {
  final camera = _load('camera');
  return SchemaDomainModel(className: 'CameraHandler', catalog: camera, intents: camera.domainIntents);
}

Map<String, OpenEnumModel> get _cameraEnums => {
      for (final (id, name) in [
        ('camera.captureMode', 'Mode'),
        ('camera.captureDevice', 'Lens'),
        ('camera.captureDuration', 'Delay'),
      ])
        id: OpenEnumModel(schema: id, className: name, library: _models, cases: const ['photo', 'video']),
    };

String block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

void main() {
  group('App Enums', () {
    test('become public AppEnums with titles and synonyms', () {
      final swift = SwiftWriter(_app()).write();
      final e = block(swift, 'public enum MealEnum: String, AppEnum {');
      expect(e, contains('  case dinner\n  case snack\n'));
      expect(e, contains('public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"'));
      expect(e, contains('.dinner: "Dinner",'));
      expect(e, contains('.snack: DisplayRepresentation(title: "Late-night snack", synonyms: ["snack"]),'));
    });

    test('parameters default to a case, and Dart falls back to the same default', () {
      final app = _app(actions: [_plan()]);
      final action = block(SwiftWriter(app).write(), 'public struct PlanMealAction');
      expect(action, contains('@Parameter(title: "Meal", default: .dinner)\n  public var meal: MealEnum\n'));
      expect(action, contains('"meal": AssistantValues.encode(meal),'));
      expect(action, contains(r'for \(String(localized: meal.localizedStringResource)).'),
          reason: 'dialogs say the case title');
      final dart = writeDart(app);
      expect(dart, contains("import 'package:app/models.dart' show Meal;"));
      expect(dart, contains("final _meal = AssistantValue.enumeration(Meal.values, args['meal']) ?? Meal.dinner;"));
    });

    test('schema enums are declared, public and raise availability', () {
      final app = AppModel(
        appName: 'Mira',
        actions: [
          _action('setState', params: [
            ParamModel(
                name: 'state', title: 'State', named: true, value: const ValueType(ValueKind.enumeration, enumRef: 'clock.timerState')),
          ]),
        ],
        entities: const [],
        schemaEntities: const [],
        catalogs: {'clock': _load('clock')},
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@AppEnum(schema: .clock.timerState)\npublic enum ClockTimerStateEnum: String {'));
      expect(swift, contains('  public static let caseDisplayRepresentations: [ClockTimerStateEnum'));
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\npublic struct SetStateAction'));
      expect(writeDart(app), contains("import 'package:assistant_actions/schemas/clock.dart' show ClockTimerState;"));
    });
  });

  group('parameters', () {
    test('lists, durations, people, files and places', () {
      final app = _app(actions: [
        _action('share', params: [
          ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
          ParamModel(name: 'tags', title: 'Tags', named: true, value: const ValueType(ValueKind.string, list: true)),
          ParamModel(name: 'length', title: 'Length', named: true, value: const ValueType(ValueKind.duration, nullable: true)),
          ParamModel(name: 'who', title: 'Who', named: true, value: const ValueType(ValueKind.person, nullable: true)),
          ParamModel(name: 'photos', title: 'Photos', named: true, value: const ValueType(ValueKind.file, list: true)),
          ParamModel(name: 'where', title: 'Where', named: true, value: const ValueType(ValueKind.place)),
        ]),
      ]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('import GeoToolbox'));
      final action = block(swift, 'public struct ShareAction');
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\npublic struct ShareAction'),
          reason: 'PlaceDescriptor is iOS 26');
      expect(action, contains('public var recipes: [RecipeEntity]'));
      expect(action, contains('public var tags: [String]'));
      expect(action, contains('public var length: Measurement<UnitDuration>?'),
          reason: 'Duration only works as a parameter from iOS 26');
      expect(action, contains('public var who: IntentPerson?'));
      expect(action, contains('public var photos: [IntentFile]'));
      expect(action, contains('public var `where`: PlaceDescriptor'));
      expect(action, contains(r'"recipes": recipes.map(\.id),'));
      expect(action, contains(r'"tags": tags.map { AssistantValues.encode($0) },'));
      expect(action, contains('"where": AssistantValues.encode(`where`),'));
      final dart = writeDart(app);
      expect(dart, contains("final _recipes = [for (final id in AssistantValue.list(args['recipes'], "
          'AssistantValue.string) ?? const <String>[]) if (await findRecipe(id) case final e?) e];'));
      expect(dart, contains("AssistantValue.list(args['tags'], (v) => AssistantValue.string(v))"));
      expect(dart, contains("final _length = AssistantValue.duration(args['length']);"));
      expect(dart, contains("AssistantValue.list(args['photos'], (v) => AssistantValue.file(v))"));
    });

    test('a default Swift can\'t state makes the Swift parameter optional', () {
      final app = _app(actions: [
        _action('wait', params: [
          ParamModel(
              name: 'length',
              title: 'Length',
              named: true,
              value: const ValueType(ValueKind.duration),
              defaultDart: 'const Duration(microseconds: 300000000)'),
        ]),
      ]);
      expect(SwiftWriter(app).write(), contains('public var length: Measurement<UnitDuration>?\n'));
      expect(writeDart(app),
          contains("final _length = AssistantValue.duration(args['length']) ?? const Duration(microseconds: 300000000);"));
    });

    test('search keywords and hidden actions', () {
      final swift = SwiftWriter(_app(actions: [_plan(), _action('secret', discoverable: false)])).write();
      expect(swift, contains('IntentDescription("planMeal", searchKeywords: ["menu"])'),
          reason: 'keywords without a description describe it with the title');
      expect(block(swift, 'public struct SecretAction'), contains('public static let isDiscoverable = false'));
      expect(block(swift, 'public struct PlanMealAction'), isNot(contains('isDiscoverable')));
    });
  });

  group('results', () {
    test('values return through ReturnsValue, with the dialog Dart gives', () {
      final app = _app(actions: [
        _action('count', result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
        _action('names', result: const ResultModel(value: ValueType(ValueKind.string, list: true))),
      ]);
      final swift = SwiftWriter(app).write();
      final count = block(swift, 'public struct CountAction');
      expect(count, contains('some IntentResult & ReturnsValue<Int> & ProvidesDialog'));
      expect(count, contains('let result = AssistantValues.result(reply)'));
      expect(count, contains('guard let value = AssistantValues.int(result.value) else {'));
      expect(count, contains('return .result(value: value, dialog: IntentDialog(stringLiteral: result.dialog ?? "Done."))'));
      final names = block(swift, 'public struct NamesAction');
      expect(names, contains('ReturnsValue<[String]>'));
      expect(names, contains(r'(AssistantValues.items(result.value) ?? []).compactMap { AssistantValues.string($0) }'));
      final dart = writeDart(app);
      expect(dart, contains('final result = await a0.count();\n      return AssistantValue.encodeResult(result.value, dialog: result.dialog);'));
      expect(dart, contains('return AssistantValue.encodeResult(result);'));
    });

    test('entities return by id and are looked up in the snapshot, in order', () {
      final app = _app(actions: [
        _action('quickest', result: ResultModel(entity: _recipe, nullable: true, wrapped: true)),
        _action('all', result: ResultModel(entity: _recipe, list: true)),
      ]);
      final swift = SwiftWriter(app).write();
      final quickest = block(swift, 'public struct QuickestAction');
      expect(quickest, contains('ReturnsValue<RecipeEntity?>'));
      expect(quickest, contains('let value = try await RecipeEntityQuery().entities(for: ids).first'));
      final all = block(swift, 'public struct AllAction');
      expect(all, contains(r'let value = ids.compactMap { id in found.first { $0.id == id } }'));
      final dart = writeDart(app);
      expect(dart, contains('AssistantValue.encodeResult(result.value?.id, dialog: result.dialog)'));
      expect(dart, contains('AssistantValue.encodeResult([for (final e in result) e.id])'));
    });

    test('schema entities make the action, the entity and what it reaches public', () {
      final tasks = _tasks();
      final app = _app(
        actions: [_action('nextTask', result: ResultModel(schemaEntity: tasks, nullable: true))],
        schemaEntities: [tasks],
        catalogs: {'reminders': tasks.catalog},
      );
      final swift = SwiftWriter(app).write();
      expect(swift, contains('@available(iOS 27.0, macOS 27.0, *)\npublic struct NextTaskAction'));
      expect(swift, contains('@AppEntity(schema: .reminders.reminder)\npublic struct TaskItemEntity {'));
      expect(block(swift, 'public struct TaskItemEntity {'), contains('  public static let defaultQuery'));
      final query = block(swift, 'public struct TaskItemEntityQuery');
      expect(query, contains('  public init() {}'));
      expect(query, contains('  public func entities(for identifiers: [String])'));
      expect(query, contains('  private func all()'), reason: 'private members stay private');
      expect(swift, contains('public struct RemindersListEntity {'), reason: 'members reach the list');
    });
  });

  group('App Shortcuts', () {
    test('phrases name entity and enum parameters; entity phrases refresh on publish', () {
      final shortcuts = writeShortcuts(_app(actions: [_plan()], tileColor: 'grape'));
      expect(shortcuts, contains(r'phrases: ["Cook \(\.$recipe) for \(\.$meal) in \(.applicationName)"],'));
      expect(shortcuts, contains('static var shortcutTileColor: ShortcutTileColor { .grape }'));
      expect(shortcuts, contains('@objc(AssistantActionsAppShortcuts)'));
      expect(shortcuts, contains('AssistantShortcuts.updateAppShortcutParameters()'));
    });

    test('without entity phrases there is nothing to refresh', () {
      final shortcuts = writeShortcuts(_app(actions: [
        _action('count',
            shortcut: const ShortcutModel(phrases: ['Count in {app}'], shortTitle: 'Count', systemImage: 'number')),
      ]));
      expect(shortcuts, isNot(contains('AssistantActionsAppShortcuts')));
      expect(shortcuts, isNot(contains('shortcutTileColor')));
      expect(shortcuts, isNot(contains('import Foundation')));
    });

    test('schema intents are shortcuts behind #available, made public for the Runner', () {
      final camera = _camera();
      final start = camera.intents.firstWhere((i) => i.id == 'camera.startCapture');
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [camera],
        catalogs: {'camera': camera.catalog},
        openEnums: _cameraEnums,
        intentShortcuts: [
          IntentShortcutModel(
            className: 'CameraHandler',
            intent: start,
            shortcut: const ShortcutModel(
                phrases: ['Take a {captureMode} with {app}'], shortTitle: 'Camera', systemImage: 'camera'),
          ),
        ],
      );
      final shortcuts = writeShortcuts(app);
      expect(shortcuts, contains('iOS 17.4 / macOS 14.4'));
      expect(shortcuts, contains('    if #available(iOS 18.0, macOS 15.0, *) {\n      AppShortcut(\n'
          '        intent: CameraStartCaptureIntent(),\n'
          r'        phrases: ["Take a \(\.$captureMode) with \(.applicationName)"],'));
      final swift = SwiftWriter(app).write();
      final intent = block(swift, 'public struct CameraStartCaptureIntent');
      expect(intent, contains('  public init() {}'));
      expect(intent, contains('  public var captureMode: CameraCaptureModeEnum'));
      expect(intent, contains('  public func perform()'));
      expect(swift, contains('public enum CameraCaptureModeEnum: String {'));
      expect(swift, contains('  public static let caseDisplayRepresentations: [CameraCaptureModeEnum'));
      expect(swift, contains('\nstruct CameraStopCaptureIntent {'), reason: 'other intents stay internal');
    });

    test('an entity intent makes the entity it returns public', () {
      final tasks = _tasks();
      final create = tasks.catalog.intentsFor(tasks.schema).firstWhere((e) => e.$1.id == 'reminders.createReminder');
      final owner = SchemaEntityModel(
        className: tasks.className,
        library: tasks.library,
        catalog: tasks.catalog,
        schema: tasks.schema,
        idField: 'id',
        mapping: tasks.mapping,
        intents: [create],
        containers: tasks.containers,
      );
      final app = _app(schemaEntities: [owner], catalogs: {'reminders': tasks.catalog}, intentShortcuts: [
        IntentShortcutModel(
          className: 'TaskItem',
          intent: create.$1,
          owner: owner,
          shortcut: const ShortcutModel(phrases: ['Add a task in {app}'], shortTitle: 'New', systemImage: 'plus'),
        ),
      ]);
      final swift = SwiftWriter(app).write();
      expect(swift, contains('public struct TaskItemCreateReminderIntent {\n  public init() {}'));
      expect(swift, contains('public struct TaskItemEntity {'));
    });

    test('public unions are Sendable, as the public types holding them must be', () {
      final audio = _load('audio');
      final add = audio.domainIntents.firstWhere((i) => i.id == 'audio.addToLibrary');
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [SchemaDomainModel(className: 'AudioHandler', catalog: audio, intents: [add])],
        catalogs: {'audio': audio},
        openEnums: {
          for (final e in audio.enums.values)
            if (e.cases.isEmpty) e.id: OpenEnumModel(schema: e.id, className: 'E', library: _models, cases: const ['one']),
        },
        intentShortcuts: [
          IntentShortcutModel(
            className: 'AudioHandler',
            intent: add,
            shortcut: const ShortcutModel(phrases: ['Save in {app}'], shortTitle: 'Save', systemImage: 'plus'),
          ),
        ],
      );
      expect(SwiftWriter(app).write(), contains('@UnionValue\npublic enum AudioAudioItemUnion: Sendable {'));
    });

    test('iOS-only intents are left out on macOS', () {
      final assistant = _load('assistant');
      final domain = SchemaDomainModel(className: 'AssistantHandler', catalog: assistant, intents: assistant.domainIntents);
      final app = AppModel(
        appName: 'Mira',
        actions: const [],
        entities: const [],
        schemaEntities: const [],
        schemaDomains: [domain],
        catalogs: {'assistant': assistant},
        intentShortcuts: [
          IntentShortcutModel(
            className: 'AssistantHandler',
            intent: domain.intents.firstWhere((i) => i.id == 'assistant.activate'),
            shortcut: const ShortcutModel(phrases: ['Start {app}'], shortTitle: 'Start', systemImage: 'play'),
          ),
        ],
      );
      expect(writeShortcuts(app), contains('    #if os(iOS)\n      if #available(iOS 26.2, *) {\n'));
    });

    test('system.open shortcuts open one entity class', () {
      final system = _load('system');
      final domain = SchemaDomainModel(
          className: 'SystemHandler', catalog: system, intents: [system.domainIntents.firstWhere((i) => i.id == 'system.open')]);
      final app = _app(domains: [domain], catalogs: {'system': system}, intentShortcuts: [
        IntentShortcutModel(
          className: 'Recipe',
          intent: domain.intents.single,
          openClass: 'Recipe',
          shortcut: const ShortcutModel(phrases: ['Open {target} in {app}'], shortTitle: 'Open', systemImage: 'book'),
        ),
      ]);
      final shortcuts = writeShortcuts(app);
      expect(shortcuts, contains('intent: OpenRecipeIntent(),'));
      expect(shortcuts, contains(r'"Open \(\.$target) in \(.applicationName)"'));
      expect(shortcuts, contains('@objc(AssistantActionsAppShortcuts)'));
      expect(SwiftWriter(app).write(), contains('public struct OpenRecipeIntent: ForegroundContinuableIntent {\n  public init() {}'));
    });
  });

  group('with Siri interaction and system surfaces', () {
    test('an AssistantReply<T> returns T to Shortcuts and shows its card', () {
      final app = _app(actions: [
        _action('pick', reply: true, result: ResultModel(entity: _recipe, wrapped: true)),
        _action('count', reply: true, result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
      ]);
      final swift = SwiftWriter(app).write();
      final pick = block(swift, 'public struct PickAction');
      expect(pick, contains('some IntentResult & ReturnsValue<RecipeEntity> & ProvidesDialog & ShowsSnippetView'));
      expect(pick, contains('let reply = AssistantReply(json: try await callDart("pick", args: args))'));
      expect(pick, contains('let candidates = try await RecipeEntityQuery().entities(for: reply.ids)'));
      expect(pick, contains('guard let value = try await assistantChoose(among: candidates, prompt: reply.prompt) else {'),
          reason: 'AssistantReply.choose asks which item');
      expect(pick, contains('return .result(value: value, dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), '
          'view: AssistantCardView(reply.card))'));
      final count = block(swift, 'public struct CountAction');
      expect(count, contains('ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView'));
      expect(count, contains('guard let value = AssistantValues.int(reply.value) else {'));
      final dart = writeDart(app);
      expect(dart, contains('final reply = await a0.pick();\n      return AssistantReply.encodeValue(reply, reply.value?.id);'));
      expect(dart, contains('return AssistantReply.encodeValue(reply, reply.value);'));
    });

    test('an AssistantReply<void> keeps its dialog and card only', () {
      final swift = SwiftWriter(_app(actions: [_action('show', reply: true)])).write();
      final show = block(swift, 'public struct ShowAction');
      expect(show, contains('some IntentResult & ProvidesDialog & ShowsSnippetView {'));
      expect(show, isNot(contains('ReturnsValue')));
      expect(writeDart(_app(actions: [_action('show', reply: true)])), contains('return AssistantReply.encode(await a0.show());'));
    });

    test('confirmations say the new parameter types', () {
      final app = _app(actions: [
        _action('plan',
            runs: RunsModel.deferred,
            confirm: 'Plan {recipes} for {meal}?',
            params: [
              ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
              ParamModel(name: 'meal', title: 'Meal', named: true, value: _mealType),
            ]),
      ]);
      final plan = block(SwiftWriter(app).write(), 'public struct PlanAction');
      expect(plan, contains(r'try await assistantConfirm("Plan \(recipes.map(\.title).formatted()) for '
          r'\(String(localized: meal.localizedStringResource))?")'));
      expect(plan.indexOf('assistantConfirm'), lessThan(plan.indexOf('AssistantInbox.call')),
          reason: 'asked before anything is queued');
    });

    test('Live Activity actions keep their perform and conformance', () {
      final swift = SwiftWriter(_app(actions: [_action('stop', liveActivity: true, runs: RunsModel.deferred)])).write();
      expect(swift, contains('if AssistantBridge.shared.isReady {'));
      expect(swift, contains('extension StopAction: LiveActivityIntent {}'));
    });

    test('Focus filters take App Enums and say them in their summary', () {
      final app = _app(actions: [
        _action('applyFocus',
            runs: RunsModel.deferred,
            focusFilter: const FocusFilterModel(summary: 'Meals: {meal}'),
            params: [
              ParamModel(name: 'meal', title: 'Meal', named: true, value: _mealType, swiftDefault: '.dinner', defaultDart: 'Meal.dinner'),
            ]),
      ]);
      final filter = block(SwiftWriter(app).write(), 'public struct ApplyFocusFocusFilter: SetFocusFilterIntent');
      expect(filter, contains('@Parameter(title: "Meal", default: .dinner)\n  public var meal: MealEnum\n'));
      expect(filter, contains(r'let summary: String = "Meals: \(String(localized: meal.localizedStringResource))"'));
      expect(filter, contains('"meal": AssistantValues.encode(meal),'));
    });
  });

  group('donations and predictions', () {
    final share = _action('share', params: [
      ParamModel(name: 'recipes', title: 'Recipes', named: true, entity: _recipe, entityList: true),
      ParamModel(name: 'tags', title: 'Tags', named: true, value: const ValueType(ValueKind.string, list: true)),
      ParamModel(name: 'length', title: 'Length', named: true, value: const ValueType(ValueKind.duration, nullable: true)),
      ParamModel(name: 'who', title: 'Who', named: true, value: const ValueType(ValueKind.person, nullable: true)),
      ParamModel(name: 'where', title: 'Where', named: true, value: const ValueType(ValueKind.place)),
    ]);

    test('donated values decode into every parameter type', () {
      final swift = SwiftWriter(_app(actions: [_plan(), share])).write();
      final donate = block(swift, '  private static func donateAction(');
      expect(donate, contains(
          '      if let value = AssistantValues.string(values["meal"]).flatMap(MealEnum.init(rawValue:)) { intent.meal = value }'));
      expect(donate, contains('    case "share":\n      guard #available(iOS 26.0, macOS 26.0, *) else { return false }'),
          reason: 'PlaceDescriptor is iOS 26, like the action');
      expect(donate, contains(r'guard let recipesValue = AssistantValues.strings(values["recipes"])?.compactMap({ id in '
          r'AssistantSnapshot.records("Recipe").first(where: { $0.id == id }) }).map({ $0.map(RecipeEntity.init(record:)) })'));
      expect(donate, contains(r'guard let tagsValue = AssistantValues.items(values["tags"])?.compactMap({ AssistantValues.string($0) })'));
      expect(donate, contains(
          r'intent.length = AssistantValues.double(values["length"]).map({ Measurement(value: $0, unit: UnitDuration.seconds) })'));
      expect(donate, contains('intent.who = AssistantValues.person(values["who"])'));
      expect(donate, contains('guard let whereValue = AssistantValues.place(values["where"]) else { return false }'));
      final prediction = block(swift, 'extension ShareAction: PredictableIntent {');
      expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension ShareAction: PredictableIntent {'));
      expect(prediction, contains(r'recipes.map(\.title).joined(separator: ", "), tags.map { $0 }.joined(separator: ", "), '
          r'length.map { $0.formatted() } ?? ""'));
    });

    test('AssistantDonations mirrors each function, defaults included', () {
      final dart = writeDart(_app(actions: [_plan(), share]));
      expect(dart, contains('static Future<bool> planMeal(a1.Recipe recipe, {Meal meal = Meal.dinner}) =>'));
      expect(dart, contains("AssistantActions.donateAction('planMeal', {'recipe': recipe.id, 'meal': AssistantValue.encodeEnum(meal)});"));
      expect(dart, contains('static Future<bool> share({required List<a1.Recipe> recipes, required List<String> tags, '
          'Duration? length, AssistantPerson? who, required AssistantPlace where}) =>'));
      expect(dart, contains("'recipes': [for (final e in recipes) e.id],"));
      expect(dart, contains("'length': AssistantValue.encodeDuration(length),"));
    });

    test('Focus filters are set by the system, so are neither donated nor predicted', () {
      final filter = _action('applyFocus', focusFilter: const FocusFilterModel(), params: [
        ParamModel(name: 'quiet', title: 'Quiet', named: true, value: const ValueType(ValueKind.boolean)),
      ]);
      final app = _app(actions: [filter]);
      expect(SwiftWriter(app).write(), isNot(contains('PredictableIntent')));
      expect(writeDart(app), isNot(contains('AssistantDonations')));
    });
  });
}
