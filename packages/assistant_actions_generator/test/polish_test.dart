// Siri polish: `requiresUnlock` (authenticationPolicy), Shortcuts sentences
// (parameterSummary) and item images (DisplayRepresentation, Spotlight),
// built from models directly, plus the checks the reader runs.
import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/polish.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

final _lib = Uri.parse('package:app/assistant_actions.dart');
final _models = Uri.parse('package:app/models.dart');

EntityModel _recipe({UnlockModel? unlock, String? systemImage, FieldModel? image}) => EntityModel(
      className: 'Recipe',
      library: _models,
      title: 'Recipe',
      idField: 'id',
      titleGetter: 'name',
      fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
      unlock: unlock,
      systemImage: systemImage,
      image: image,
    );

SchemaEntityModel _tasks({UnlockModel? unlock, Map<String, String> summaries = const {}, String? systemImage}) {
  final reminders = _load('reminders');
  final schema = reminders.entities['reminders.reminder']!;
  return SchemaEntityModel(
    className: 'TaskItem',
    library: _models,
    catalog: reminders,
    schema: schema,
    idField: 'id',
    mapping: const {
      'title': FieldModel('title', ValueType(ValueKind.string)),
      'dueDate': FieldModel('due', ValueType(ValueKind.dateTime, nullable: true)),
    },
    intents: reminders.intentsFor(schema),
    containers: {
      'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
    },
    unlock: unlock,
    summaries: summaries,
    systemImage: systemImage,
  );
}

SchemaEntityModel _journal({UnlockModel? unlock, FieldModel? image, String? systemImage}) {
  final journal = _load('journal');
  final schema = journal.entities['journal.entry']!;
  return SchemaEntityModel(
    className: 'JournalItem',
    library: _models,
    catalog: journal,
    schema: schema,
    idField: 'id',
    mapping: const {
      'title': FieldModel('title', ValueType(ValueKind.string, nullable: true)),
      'message': FieldModel('text', ValueType(ValueKind.string)),
    },
    intents: journal.intentsFor(schema),
    containers: const {},
    unlock: unlock,
    image: image,
    systemImage: systemImage,
  );
}

ActionModel _action(String name,
        {List<ParamModel> params = const [], UnlockModel? unlock, String? summary, ResultModel? result}) =>
    ActionModel(
      functionName: name,
      library: _lib,
      title: name,
      runs: RunsModel.deferred,
      params: params,
      returnsString: false,
      dialog: 'Done.',
      unlock: unlock,
      summary: summary,
      result: result,
    );

List<ParamModel> _addParams(EntityModel recipe) => [
      ParamModel(name: 'recipe', title: 'Recipe', named: false, entity: recipe),
      ParamModel(name: 'servings', title: 'Servings', named: true, value: const ValueType(ValueKind.integer, nullable: true)),
    ];

AppModel _app({
  List<ActionModel> actions = const [],
  List<EntityModel>? entities,
  List<SchemaEntityModel> schemaEntities = const [],
  List<SchemaDomainModel> domains = const [],
  List<SnapshotActionModel> snapshots = const [],
  Map<String, AppEnumModel> appEnums = const {},
  UnlockModel unlock = UnlockModel.notRequired,
}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: entities ?? [_recipe()],
      schemaEntities: schemaEntities,
      schemaDomains: domains,
      snapshotActions: snapshots,
      catalogs: {for (final d in domains) d.domain: d.catalog},
      appEnums: appEnums,
      unlock: unlock,
    );

SchemaDomainModel _system() {
  final system = _load('system');
  return SchemaDomainModel(className: 'SystemHandler', catalog: system, intents: system.domainIntents);
}

SnapshotActionModel _quick({UnlockModel? unlock}) => SnapshotActionModel(
      name: 'quickRecipes',
      title: 'Quick Recipes',
      collection: 'Recipe',
      fields: const [FieldModel('minutes', ValueType(ValueKind.integer))],
      where: const {},
      limit: 3,
      item: '{title}',
      dialog: '{items}',
      empty: 'None.',
      separator: ', ',
      unlock: unlock,
    );

/// The Swift from [start] to the end of its top-level declaration.
String _block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

const _auth = 'static let authenticationPolicy: IntentAuthenticationPolicy = ';

void main() {
  group('requiresUnlock', () {
    test('the catalog keeps the least policy Apple\'s schemas allow', () {
      expect(_load('system').intents['system.open']!.authenticationPolicy, 2);
      expect(_load('journal').intents['journal.createEntry']!.authenticationPolicy, 2);
      expect(_load('reminders').intents['reminders.createReminder']!.authenticationPolicy, 0);
      expect(_load('reminders').intents['reminders.deleteReminders']!.authenticationPolicy, 1);
    });

    test('schema intents use at least the schema\'s policy, and Apple\'s default stays implicit', () {
      final open = _load('system').intents['system.open']!;
      final create = _load('reminders').intents['reminders.createReminder']!;
      expect(UnlockModel.required.forSchema(open), UnlockModel.onThisDevice);
      expect(UnlockModel.required.forSchema(create), UnlockModel.required);
      expect(UnlockModel.notRequired.forSchema(open), UnlockModel.notRequired);
      expect(UnlockModel.onThisDevice.forSchema(create), UnlockModel.onThisDevice);
    });

    test('nothing sets authenticationPolicy by default', () {
      final swift = SwiftWriter(_app(
        actions: [_action('add', params: _addParams(_recipe()))],
        schemaEntities: [_tasks(), _journal()],
        domains: [_system()],
        snapshots: [_quick()],
      )).write();
      expect(swift, isNot(contains('authenticationPolicy')));
    });

    test('the app default covers plain actions, snapshot answers and schema intents', () {
      final swift = SwiftWriter(_app(
        unlock: UnlockModel.required,
        actions: [_action('add', params: _addParams(_recipe()))],
        schemaEntities: [_tasks(), _journal()],
        domains: [_system()],
        snapshots: [_quick()],
      )).write();
      expect(_block(swift, 'public struct AddAction'), contains('  public $_auth.requiresAuthentication\n'));
      expect(_block(swift, 'public struct QuickRecipesAction'), contains('  public $_auth.requiresAuthentication\n'));
      expect(_block(swift, 'struct TaskItemCreateReminderIntent'), contains('  $_auth.requiresAuthentication\n'));
      // journal.* and system.open need the local device.
      expect(_block(swift, 'struct JournalItemCreateEntryIntent'), contains('  $_auth.requiresLocalDeviceAuthentication\n'));
      expect(_block(swift, 'struct JournalItemCreateAudioEntryIntent'),
          contains('  $_auth.requiresLocalDeviceAuthentication\n'));
      expect(_block(swift, 'struct OpenTaskItemIntent'), contains('  $_auth.requiresLocalDeviceAuthentication\n'));
      expect(_block(swift, 'struct OpenRecipeIntent'), contains('  $_auth.requiresLocalDeviceAuthentication\n'));
      expect(_block(swift, 'struct SystemSearchInAppIntent'), contains('  $_auth.requiresLocalDeviceAuthentication\n'));
    });

    test('an entity\'s setting covers its intents, and actions that take it unless they set their own', () {
      final recipe = _recipe(unlock: UnlockModel.onThisDevice);
      final swift = SwiftWriter(_app(
        entities: [recipe],
        actions: [
          _action('add', params: _addParams(recipe)),
          _action('peek', params: _addParams(recipe), unlock: UnlockModel.notRequired),
          _action('plain'),
        ],
        schemaEntities: [_tasks(unlock: UnlockModel.required)],
        domains: [_system()],
        snapshots: [_quick()],
      )).write();
      expect(_block(swift, 'public struct AddAction'), contains('$_auth.requiresLocalDeviceAuthentication'));
      expect(_block(swift, 'public struct PeekAction'), isNot(contains('authenticationPolicy')));
      expect(_block(swift, 'public struct PlainAction'), isNot(contains('authenticationPolicy')));
      expect(_block(swift, 'public struct QuickRecipesAction'), contains('$_auth.requiresLocalDeviceAuthentication'));
      expect(_block(swift, 'struct TaskItemUpdateReminderIntent'), contains('$_auth.requiresAuthentication'));
      expect(_block(swift, 'struct TaskItemDeleteRemindersIntent'), contains('$_auth.requiresAuthentication'));
      expect(_block(swift, 'struct OpenTaskItemIntent'), contains('$_auth.requiresLocalDeviceAuthentication'));
      // The domain's own intent follows the app's default.
      expect(_block(swift, 'struct SystemSearchInAppIntent'), isNot(contains('authenticationPolicy')));
    });

    test('a domain annotation sets its intents\' policy; a snapshot answer can set its own', () {
      final system = _system();
      final swift = SwiftWriter(_app(
        domains: [
          SchemaDomainModel(
              className: system.className, catalog: system.catalog, intents: system.intents, unlock: UnlockModel.required)
        ],
        snapshots: [_quick(unlock: UnlockModel.required)],
        entities: [_recipe(unlock: UnlockModel.onThisDevice)],
      )).write();
      expect(_block(swift, 'struct SystemSearchInAppIntent'), contains('$_auth.requiresLocalDeviceAuthentication'));
      expect(_block(swift, 'public struct QuickRecipesAction'), contains('$_auth.requiresAuthentication\n'));
    });

    test('a deep-linked entity\'s open intent sets it too', () {
      final recipe = EntityModel(
          className: 'Recipe',
          library: _models,
          title: 'Recipe',
          idField: 'id',
          titleGetter: 'name',
          fields: const [],
          url: 'cook://recipes/{id}',
          unlock: UnlockModel.required);
      final swift = SwiftWriter(_app(entities: [recipe], domains: [_system()])).write();
      expect(_block(swift, 'struct OpenRecipeIntent: URLRepresentableIntent'),
          contains('$_auth.requiresLocalDeviceAuthentication\n  var target: RecipeEntity'));
    });
  });

  group('Shortcuts summaries', () {
    test('a sentence naming every parameter', () {
      final swift = SwiftWriter(_app(actions: [
        _action('add', params: _addParams(_recipe()), summary: 'Add {recipe} for {servings} "people"'),
      ])).write();
      expect(
          _block(swift, 'public struct AddAction'),
          contains('  public static var parameterSummary: some ParameterSummary {\n'
              r'    Summary("Add \(\.$recipe) for \(\.$servings) \"people\"")'
              '\n  }\n'));
    });

    test('parameters the sentence leaves out are listed under it', () {
      final swift = SwiftWriter(_app(actions: [
        _action('add', params: _addParams(_recipe()), summary: 'Add {recipe}'),
      ])).write();
      expect(_block(swift, 'public struct AddAction'),
          contains(r'    Summary("Add \(\.$recipe)") {' '\n' r'      \.$servings' '\n    }\n'));
    });

    test('schema intents take theirs from summaries', () {
      final swift = SwiftWriter(_app(schemaEntities: [
        _tasks(summaries: {'createReminder': 'Add {title} to {list}', 'updateReminder': 'Change {target}'}),
      ])).write();
      final create = _block(swift, 'struct TaskItemCreateReminderIntent');
      expect(create, contains(r'    Summary("Add \(\.$title) to \(\.$list)") {' '\n' r'      \.$note' '\n'));
      expect(create, contains(r'      \.$section' '\n    }\n'));
      expect(_block(swift, 'struct TaskItemUpdateReminderIntent'), contains(r'Summary("Change \(\.$target)") {'));
      expect(_block(swift, 'struct TaskItemDeleteRemindersIntent'), isNot(contains('parameterSummary')));
    });

    test('summaryError names unknown and repeated parameters', () {
      expect(summaryError('Add {recipe} for {servings}', ['recipe', 'servings'], 'summary'), isNull);
      expect(summaryError('Add {dish}', ['recipe', 'servings'], 'summary'),
          'summary uses {dish}, which is not a parameter ({recipe}, {servings}).');
      expect(summaryError('Go {x}', [], 'summary'), 'summary uses {x}, which is not a parameter (there are none).');
      expect(summaryError('{recipe} and {recipe}', ['recipe'], 'summary'), contains('uses {recipe} twice'));
      expect(summaryError('Add {re cipe}', ['recipe'], 'summary'), contains('not a parameter name'));
      expect(summaryError('  ', ['recipe'], 'summary'), 'summary is empty.');
    });

    test('checkSummaries checks intents and their parameters', () {
      final tasks = _tasks();
      String? check(Map<String, String> s) => checkSummaries(s, tasks.intents, '@RemindersReminder');
      expect(check({'createReminder': 'Add {title} to {list}'}), isNull);
      expect(check({'createList': 'New'}), contains('summaries names createList, which is not an intent turned on here'));
      expect(check({'createReminder': 'Add {name}'}),
          startsWith("@RemindersReminder: summaries['createReminder'] (reminders.createReminder) uses {name}, "
              'which is not a parameter ({title}, {list},'));
      final open = _load('system').intents['system.open']!;
      expect(checkSummaries({'open': 'Open {target}'}, [(open, IntentKind.call)], '@SystemIntents'),
          contains('system.open (open) can\'t have a summary'));
    });

    test('schema libraries forward summaries and requiresUnlock', () {
      final reminders = generateSchemaLibrary(_load('reminders'));
      expect(reminders, contains('super.summaries,'));
      expect(reminders, contains('super.requiresUnlock,'));
      expect(reminders, contains('super.systemImage,'));
      final system = generateSchemaLibrary(_load('system'));
      expect(system, contains('super.summaries, super.requiresUnlock,'));
    });
  });

  group('item images', () {
    const cover = FieldModel('cover', ValueType(ValueKind.string, nullable: true));

    test('a type-wide SF Symbol', () {
      final swift = SwiftWriter(_app(entities: [_recipe(systemImage: 'fork.knife')])).write();
      expect(
          _block(swift, 'public struct RecipeEntity'),
          contains(r'DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" }, '
              'image: .init(systemName: "fork.knife"))'));
      expect(swift, isNot(contains('assistantDisplayImage')), reason: 'no helpers without an image field');
    });

    test('a per-item image crosses with the fields and shows in Siri and Spotlight', () {
      final app = _app(entities: [_recipe(systemImage: 'fork.knife', image: cover)]);
      final swift = SwiftWriter(app).write();
      final entity = _block(swift, 'public struct RecipeEntity');
      expect(entity, contains('  public let assistantImage: String?\n'));
      expect(entity, contains('    assistantImage = AssistantValues.string(record.fields["cover"])\n'));
      expect(entity, contains('image: assistantDisplayImage(assistantImage, systemName: "fork.knife"))'));
      expect(_block(swift, 'extension RecipeEntity: IndexedEntity'),
          contains('    attributes.thumbnailData = assistantImageData(assistantImage)\n'));
      expect(swift, contains('private func assistantImageData(_ value: String?) -> Data? {'));
      expect(swift, contains('private func assistantDisplayImage(_ value: String?, systemName: String?) -> DisplayRepresentation.Image? {'));
      expect(writeDart(app), contains("fields: (e) => {'minutes': e.minutes, 'cover': e.cover},"));
    });

    test('schema entities show theirs too', () {
      final app = _app(entities: const [], schemaEntities: [
        _journal(image: const FieldModel('photo', ValueType(ValueKind.uri, nullable: true)), systemImage: 'book'),
        _tasks(systemImage: 'checklist'),
      ]);
      final swift = SwiftWriter(app).write();
      final journal = _block(swift, 'struct JournalItemEntity {');
      expect(journal, contains('  let assistantImage: String?\n'));
      expect(journal, contains('    assistantImage = AssistantValues.string(record.fields["photo"])\n'));
      expect(journal, contains(r'DisplayRepresentation(title: "\((title ?? ""))", '
          'image: assistantDisplayImage(assistantImage, systemName: "book")) }'));
      expect(_block(swift, 'struct TaskItemEntity {'),
          contains(r'DisplayRepresentation(title: "\(title)", image: .init(systemName: "checklist")) }'));
      expect(_block(swift, 'extension JournalItemEntity: IndexedEntity'), contains('attributes.thumbnailData'));
      expect(writeDart(app), contains("'photo': e.photo?.toString(),"));
    });

    test('App Enum cases take an SF Symbol', () {
      final meal = AppEnumModel(className: 'Meal', library: _models, title: 'Meal', cases: const [
        AppEnumCase(name: 'dinner', title: 'Dinner', systemImage: 'fork.knife'),
        AppEnumCase(name: 'snack', title: 'Snack', synonyms: ['bite'], systemImage: 'moon.stars'),
        AppEnumCase(name: 'lunch', title: 'Lunch'),
      ]);
      final e = _block(SwiftWriter(_app(appEnums: {'Meal': meal})).write(), 'public enum MealEnum');
      expect(e, contains('.dinner: DisplayRepresentation(title: "Dinner", image: .init(systemName: "fork.knife")),'));
      expect(e, contains('.snack: DisplayRepresentation(title: "Snack", image: .init(systemName: "moon.stars"), '
          'synonyms: ["bite"]),'));
      expect(e, contains('.lunch: "Lunch",'));
    });

    test('systemImageError wants an SF Symbol name', () {
      expect(systemImageError('book'), isNull);
      expect(systemImageError('person.crop.circle.fill'), isNull);
      expect(systemImageError('Book'), contains('is not an SF Symbol name'));
      expect(systemImageError('fork knife'), contains('is not an SF Symbol name'));
      expect(systemImageError(''), contains('is not an SF Symbol name'));
    });
  });
}
