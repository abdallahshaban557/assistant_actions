// Writer tests for Siri conversations: confirmations, spoken results
// (`dialogs`), Dart replies with result cards, and choosing between items.
import 'dart:convert';
import 'dart:io';

import 'package:assistant_actions_generator/src/catalog.dart';
import 'package:assistant_actions_generator/src/dart_writer.dart';
import 'package:assistant_actions_generator/src/interaction.dart';
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/schema_library.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

DomainCatalog _load(String domain) => DomainCatalog.fromJson(
    (jsonDecode(File('../assistant_actions/lib/src/catalog/$domain.json').readAsStringSync()) as Map).cast());

/// Mira's tasks as `reminders.reminder`, with every intent and [interactions].
SchemaEntityModel _tasks([Interactions interactions = Interactions.none]) {
  final reminders = _load('reminders');
  final schema = reminders.entities['reminders.reminder']!;
  return SchemaEntityModel(
    className: 'TaskItem',
    library: Uri.parse('package:app/models.dart'),
    catalog: reminders,
    schema: schema,
    idField: 'id',
    mapping: const {
      'title': FieldModel('title', ValueType(ValueKind.string)),
      'dueDate': FieldModel('due', ValueType(ValueKind.dateTime, nullable: true)),
      'isCompleted': FieldModel('done', ValueType(ValueKind.boolean)),
    },
    intents: reminders.intentsFor(schema),
    containers: {
      'list': const FixedInstance(schema: 'reminders.list', id: 'mira', strings: {'name': 'Mira'}, nested: {}),
    },
    interactions: interactions,
  );
}

SchemaEntityModel _adopt(String id, Map<String, FieldModel> mapping, String className,
    [Interactions interactions = Interactions.none]) {
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
    interactions: interactions,
  );
}

AppModel _app({List<SchemaEntityModel> entities = const [], List<SchemaDomainModel> domains = const [],
        List<ActionModel> actions = const [], Map<String, OpenEnumModel> openEnums = const {}}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: const [],
      schemaEntities: entities,
      schemaDomains: domains,
      catalogs: {for (final d in domains) d.domain: d.catalog},
      openEnums: openEnums,
    );

/// The Swift from [start] to the end of its top-level declaration.
String _block(String swift, String start) {
  final i = swift.indexOf(start);
  expect(i, isNonNegative, reason: start);
  return swift.substring(i, swift.indexOf('\n}\n', i));
}

/// Camera with its app-defined enums, and [interactions].
AppModel _camera(Interactions interactions) {
  final catalog = _load('camera');
  return _app(
    domains: [
      SchemaDomainModel(
          className: 'CameraHandler', catalog: catalog, intents: catalog.domainIntents, interactions: interactions),
    ],
    openEnums: {
      for (final (id, name) in [
        ('camera.captureMode', 'Mode'),
        ('camera.captureDevice', 'Lens'),
        ('camera.captureDuration', 'Delay'),
      ])
        id: OpenEnumModel(schema: id, className: name, library: Uri.parse('package:app/camera.dart'), cases: const ['photo']),
    },
  );
}

final _recipe = EntityModel(
  className: 'Recipe',
  library: Uri.parse('package:app/models.dart'),
  title: 'Recipe',
  idField: 'id',
  titleGetter: 'name',
  fields: const [FieldModel('name', ValueType(ValueKind.string))],
);

void main() {
  group('confirmations', () {
    test('deletes ask "Delete …?" first, naming the items, before anything is queued', () {
      final swift = SwiftWriter(_app(entities: [_tasks()])).write();
      final delete = _block(swift, 'struct TaskItemDeleteRemindersIntent');
      expect(
          delete,
          contains('    try await assistantConfirm("Delete \\(AssistantDialog.items(self.entities.map { item in item.title }))?", '
              'destructive: true)\n    for item in entities {'));
      expect(delete, contains('func perform() async throws -> some IntentResult {'), reason: 'no dialog asked for');
      expect(_block(swift, 'struct TaskItemCreateReminderIntent'), isNot(contains('assistantConfirm')));
    });

    test('confirmDeletes: false deletes at once; confirm gives any intent a question', () {
      final swift = SwiftWriter(_app(entities: [
        _tasks(const Interactions(confirmDeletes: false, confirm: {'updateReminder': 'Change {target}?'})),
      ])).write();
      expect(_block(swift, 'struct TaskItemDeleteRemindersIntent'), isNot(contains('assistantConfirm')));
      expect(_block(swift, 'struct TaskItemUpdateReminderIntent'),
          contains('    try await assistantConfirm("Change \\(self.target.title)?")\n    var fields'));
    });

    test('a delete listed in confirm asks that question, still destructive', () {
      final swift = SwiftWriter(_app(entities: [
        _tasks(const Interactions(confirmDeletes: false, confirm: {'deleteReminders': 'Remove {entities}?'})),
      ])).write();
      expect(_block(swift, 'struct TaskItemDeleteRemindersIntent'),
          contains('assistantConfirm("Remove \\(AssistantDialog.list(self.entities.map { item in item.title }))?", destructive: true)'));
    });

    test('queued calls confirm in Swift before queuing', () {
      final timer = _adopt('clock.timer', const {
        'duration': FieldModel('length', ValueType(ValueKind.duration)),
        'durationRemaining': FieldModel('left', ValueType(ValueKind.duration)),
        'label': FieldModel('label', ValueType(ValueKind.string, nullable: true)),
      }, 'Countdown', const Interactions(confirm: {'pauseTimer': 'Pause {timer}?'}, dialogs: {'pauseTimer': 'Paused.'}));
      final pause = _block(SwiftWriter(_app(entities: [timer])).write(), 'struct CountdownPauseTimerIntent');
      expect(pause, contains('func perform() async throws -> some IntentResult & ProvidesDialog {'));
      expect(
          pause,
          contains('    try await assistantConfirm("Pause \\((self.timer.label ?? ""))?")\n'
              '    AssistantInbox.call("Countdown.pauseTimer", args: args)'));
      expect(pause, contains('return .result(dialog: IntentDialog(stringLiteral: "Paused."))'));
    });

    test('plain actions confirm before queuing or calling Dart', () {
      final action = ActionModel(
        functionName: 'removeFromList',
        library: Uri.parse('package:app/actions.dart'),
        title: 'Remove',
        runs: RunsModel.deferred,
        params: [ParamModel(name: 'recipe', title: 'Recipe', named: false, entity: _recipe)],
        returnsString: false,
        dialog: 'Removed {recipe}.',
        confirm: 'Remove {recipe}?',
      );
      final swift = SwiftWriter(AppModel(appName: 'Mira', actions: [action], entities: [_recipe], schemaEntities: const []))
          .write();
      expect(_block(swift, 'public struct RemoveFromListAction'),
          contains('    try await assistantConfirm("Remove \\(recipe.title)?")\n    AssistantInbox.call("removeFromList"'));
    });
  });

  group('spoken results', () {
    test('dialogs make schema intents ProvidesDialog, reading parameters and the result', () {
      final swift = SwiftWriter(_app(entities: [
        _tasks(const Interactions(dialogs: {
          'createReminder': 'Added {title}, due {dueDate}, tagged {tags}.',
          'updateReminder': 'Updated {result}.',
          'deleteReminders': 'Deleted {entities}.',
        })),
      ])).write();
      final create = _block(swift, 'struct TaskItemCreateReminderIntent');
      expect(create, contains('func perform() async throws -> some ReturnsValue<TaskItemEntity> & ProvidesDialog {'));
      expect(create, contains('    let value = TaskItemEntity(record: AssistantRecord(id: id, title: "", fields: fields))\n'));
      expect(
          create,
          contains('return .result(value: value, dialog: IntentDialog(stringLiteral: "Added \\(self.title), due '
              '\\(AssistantDialog.text(self.dueDate)), tagged \\(AssistantDialog.list(self.tags.map { item in item }))."))'));
      final update = _block(swift, 'struct TaskItemUpdateReminderIntent');
      expect(update, contains('return .result(value: updated, dialog: IntentDialog(stringLiteral: "Updated \\(updated.title)."))'));
      final delete = _block(swift, 'struct TaskItemDeleteRemindersIntent');
      expect(delete, contains('func perform() async throws -> some IntentResult & ProvidesDialog {'));
      expect(delete, contains('assistantConfirm('), reason: 'deletes still confirm');
    });

    test('without dialogs, schema intents are unchanged', () {
      final swift = SwiftWriter(_app(entities: [_tasks()])).write();
      expect(_block(swift, 'struct TaskItemCreateReminderIntent'),
          contains('    return .result(value: TaskItemEntity(record: AssistantRecord(id: id, title: "", fields: fields)))'));
      expect(swift, isNot(contains('ProvidesDialog')));
      expect(swift, isNot(contains('import SwiftUI')));
    });

    test('enum and optional entity parameters read as words and titles', () {
      final swift = SwiftWriter(_camera(const Interactions(dialogs: {'startCapture': 'Taking a {captureMode}.'}))).write();
      final start = _block(swift, 'struct CameraStartCaptureIntent');
      expect(start, contains('func perform() async throws -> some IntentResult & ProvidesDialog {'));
      expect(start, contains('return .result(dialog: IntentDialog(stringLiteral: "Taking a \\(AssistantDialog.text(self.captureMode))."))'));
    });
  });

  group('replies', () {
    test('a live domain call can reply with a dialog and a result card', () {
      final app = _camera(const Interactions(replies: {'startCapture'}, dialogs: {'startCapture': 'Camera on.'}));
      final swift = SwiftWriter(app).write();
      expect(swift, contains('import SwiftUI\n'));
      final start = _block(swift, 'struct CameraStartCaptureIntent');
      expect(start, contains('func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {'));
      expect(start, contains('let reply = AssistantReply(json: try await callDart("camera.startCapture", args: args))'));
      expect(start, contains('return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Camera on."), view: AssistantCardView(reply.card))'));
      final dart = writeDart(app);
      expect(dart, contains('Future<AssistantReply<void>> startCapture({required Mode captureMode, Lens? device, Delay? timerDuration});'));
      expect(dart, contains("      return AssistantReply.encode(await camera.startCapture(captureMode: AssistantValue.enumeration(Mode.values, args['captureMode'])"));
      expect(dart, contains('Future<void> stopCapture();'), reason: 'only the intents listed reply');
    });

    test('a call that returns one item can ask which of several Dart found', () {
      final tab = _adopt('browser.tab', const {
        'name': FieldModel('name', ValueType(ValueKind.string)),
        'url': FieldModel('url', ValueType(ValueKind.uri, nullable: true)),
      }, 'Tab', const Interactions(replies: {'createTab'}, dialogs: {'createTab': 'Opened {result}.'}));
      final app = _app(entities: [tab]);
      final create = _block(SwiftWriter(app).write(), 'struct TabCreateTabIntent');
      expect(create, contains('func perform() async throws -> some ReturnsValue<TabEntity> & ProvidesDialog & ShowsSnippetView {'));
      expect(create, contains('let candidates = try await TabEntityQuery().entities(for: reply.ids)'));
      expect(create, contains('guard let value = try await assistantChoose(among: candidates, prompt: reply.prompt) else {'));
      expect(
          create,
          contains('return .result(value: value, dialog: IntentDialog(stringLiteral: reply.dialog ?? "Opened \\(value.name)."), '
              'view: AssistantCardView(reply.card))'));
      final dart = writeDart(app);
      expect(dart, contains('Future<AssistantReply<String>> createTab({Uri? url, required bool isPrivate});'));
      expect(dart, contains('AssistantReply.choose'), reason: 'documented on the method');
      expect(dart, contains('Future<void> closeTabs({required List<String> target});'));
    });

    test('record intents can reply too', () {
      final journal = _adopt('journal.entry', const {
        'message': FieldModel('text', ValueType(ValueKind.string)),
      }, 'JournalItem', const Interactions(replies: {'createAudioEntry'}));
      final app = _app(entities: [journal]);
      final record = _block(SwiftWriter(app).write(), 'struct JournalItemCreateAudioEntryIntent');
      // journal.entry needs iOS 26, so its card is always a snippet intent (with buttons).
      expect(record, contains('some IntentResult & ProvidesDialog & ShowsSnippetIntent {'));
      expect(record, contains('    return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), snippetIntent: AssistantCardSnippetIntent(reply.card))'));
      expect(record, contains('let reply = AssistantReply(json: try await callDart("JournalItem.startAudioEntry", args: [:]))'));
      final dart = writeDart(app);
      expect(dart, contains('Future<AssistantReply<void>> startAudioEntry();'));
      expect(dart, contains('      return AssistantReply.encode(await journalItem.startAudioEntry());'));
    });

    test('cardButtons opts a schema intent in to an interactive card below 26', () {
      final app = _camera(const Interactions(replies: {'startCapture'}, cardButtons: {'startCapture'}));
      final start = _block(SwiftWriter(app).write(), 'struct CameraStartCaptureIntent');
      expect(start, contains('func perform() async throws -> some IntentResult & ProvidesDialog {'));
      expect(
          start,
          contains('    if #available(iOS 26.0, macOS 26.0, *) {\n'
              '      return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), snippetIntent: AssistantCardSnippetIntent(reply.card))\n'
              '    } else {\n'
              '      return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), view: AssistantCardView(reply.card))\n'
              '    }'));
      expect(SwiftWriter(app).write(), contains('public struct AssistantCardSnippetIntent: SnippetIntent {'));
    });

    test('a live plain action can return an AssistantReply', () {
      final action = ActionModel(
        functionName: 'showRecipe',
        library: Uri.parse('package:app/actions.dart'),
        title: 'Show Recipe',
        runs: RunsModel.withFlutter,
        params: const [],
        returnsString: false,
        returnsReply: true,
      );
      final app = AppModel(appName: 'Mira', actions: [action], entities: const [], schemaEntities: const []);
      final swift = _block(SwiftWriter(app).write(), 'public struct ShowRecipeAction');
      expect(swift, contains('some IntentResult & ProvidesDialog & ShowsSnippetView {'));
      expect(swift, contains('return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), view: AssistantCardView(reply.card))'));
      expect(writeDart(app), contains('      return AssistantReply.encode(await a0.showRecipe());'));
    });
  });

  group('checks', () {
    final tasks = _tasks();
    String? check(Interactions ix) => checkInteractions(ix, tasks.intents, '@RemindersReminder');

    test('accepts parameters, lists, items and {result}', () {
      expect(
          check(const Interactions(
            dialogs: {'createReminder': 'Added {title} to {list}, due {dueDate}, tags {tags}: {result}.'},
            confirm: {'deleteReminders': 'Delete {entities}?'},
          )),
          isNull);
    });

    test('names an intent that is not turned on', () {
      expect(check(const Interactions(dialogs: {'createList': 'x'})),
          '@RemindersReminder: dialogs names createList, which is not an intent turned on here '
              '(createReminder, deleteReminders, updateReminder).');
    });

    test('a placeholder that is not a parameter', () {
      expect(check(const Interactions(dialogs: {'createReminder': 'Added {name}.'})),
          startsWith("@RemindersReminder: dialogs['createReminder'] uses {name}, which is not a parameter of reminders.createReminder (title, "));
    });

    test('a parameter Siri can\'t read out', () {
      expect(check(const Interactions(dialogs: {'createReminder': 'With {images}.'})),
          "@RemindersReminder: dialogs['createReminder'] uses {images}, a [file], which Siri can't read out. "
              'Use text, numbers, dates, durations, enums or items.');
    });

    test('{result} only in dialogs of intents that return an item', () {
      expect(check(const Interactions(confirm: {'createReminder': 'Add {result}?'})),
          contains('a confirmation comes before there is a result'));
      expect(check(const Interactions(dialogs: {'deleteReminders': 'Deleted {result}.'})),
          contains('reminders.deleteReminders returns no item'));
    });

    test('replies only on live intents', () {
      expect(check(const Interactions(replies: {'createReminder'})),
          contains('reminders.createReminder goes through the inbox and runs when the app next does'));
      final timer = _adopt('clock.timer', const {
        'duration': FieldModel('length', ValueType(ValueKind.duration)),
      }, 'Countdown');
      expect(checkInteractions(const Interactions(replies: {'pauseTimer'}), timer.intents, '@ClockTimer'),
          contains('clock.pauseTimer is queued'));
    });

    test('cardButtons only on intents that are turned on and reply', () {
      expect(check(const Interactions(cardButtons: {'createList'})),
          contains('cardButtons names createList, which is not an intent turned on here'));
      final camera = _load('camera');
      String? cameraCheck(Interactions ix) => checkInteractions(
          ix, [for (final i in camera.domainIntents) (i, IntentKind.call)], '@CameraIntents');
      expect(cameraCheck(const Interactions(cardButtons: {'startCapture'})),
          '@CameraIntents: cardButtons names startCapture, which is not in replies: only intents whose handler '
              'returns an AssistantReply have a card. Add it to replies too.');
      expect(cameraCheck(const Interactions(replies: {'startCapture'}, cardButtons: {'startCapture'})), isNull);
    });

    test('system.open takes none yet', () {
      final system = _load('system');
      final open = system.intents['system.open']!;
      expect(checkInteractions(const Interactions(dialogs: {'open': 'Opened.'}), [(open, IntentKind.call)], '@SystemIntents'),
          contains("system.open (open) can't have dialogs, confirm or replies yet"));
    });
  });

  test('schema annotations take the options their intents can use', () {
    final reminders = generateSchemaLibrary(_load('reminders'));
    final reminder = reminders.substring(reminders.indexOf('class RemindersReminder extends'));
    expect(reminder.substring(0, reminder.indexOf("super('reminders.reminder')")),
        allOf(contains('super.dialogs,'), contains('super.confirm,'), contains('super.confirmDeletes,'),
            isNot(contains('super.replies'))));
    final camera = generateSchemaLibrary(_load('camera'));
    expect(camera, contains('super.replies,'), reason: 'camera has live intents');
    expect(camera, isNot(contains('super.confirmDeletes')));
  });
}
