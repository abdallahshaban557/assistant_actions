// Interactive result cards: from iOS 26 / macOS 26 a Dart reply's card is a
// SnippetIntent whose buttons run Dart; earlier, a static snippet view.
import 'package:assistant_actions_generator/src/model.dart';
import 'package:assistant_actions_generator/src/swift_writer.dart';
import 'package:test/test.dart';

ActionModel _action(String name, {bool reply = true, ResultModel? result}) => ActionModel(
      functionName: name,
      library: Uri.parse('package:app/actions.dart'),
      title: name,
      runs: RunsModel.withFlutter,
      params: const [],
      returnsString: false,
      returnsReply: reply,
      result: result,
    );

AppModel _app(List<ActionModel> actions,
        {DeploymentTarget deployment = DeploymentTarget.minimum, bool background = false}) =>
    AppModel(
      appName: 'Mira',
      actions: actions,
      entities: const [],
      schemaEntities: const [],
      deployment: deployment,
      background: background
          ? BackgroundModel(
              functionName: 'appRegistry',
              library: Uri.parse('package:app/store.dart'),
              entrypointLibrary: Uri.parse('package:app/assistant_actions.g.dart'),
              applyQueued: false,
            )
          : null,
    );

/// The declaration starting at [start], up to its closing brace.
String _block(String swift, String start) {
  final from = swift.indexOf(start);
  expect(from, isNot(-1), reason: '$start is generated');
  return swift.substring(from, swift.indexOf('\n}\n', from) + 2);
}

void main() {
  test('below 26 a reply shows a static card, and from 26 an interactive one', () {
    final swift = SwiftWriter(_app([_action('show')])).write();
    final show = _block(swift, 'public struct ShowAction');
    // SE-0360: one opaque result type, a different result in each branch.
    expect(show, contains('some IntentResult & ProvidesDialog {'));
    expect(show, isNot(contains('ShowsSnippet')));
    expect(
        show,
        contains('    if #available(iOS 26.0, macOS 26.0, *) {\n'
            '      return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), '
            'snippetIntent: AssistantCardSnippetIntent(reply.card))\n'
            '    } else {\n'
            '      return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), view: AssistantCardView(reply.card))\n'
            '    }\n'));
    expect(swift, contains('import SwiftUI\n'));
  });

  test('a deployment target of 26 always shows the snippet intent', () {
    final swift =
        SwiftWriter(_app([_action('show')], deployment: const DeploymentTarget(iOS: 26, macOS: 26))).write();
    final show = _block(swift, 'public struct ShowAction');
    expect(show, contains('some IntentResult & ProvidesDialog & ShowsSnippetIntent {'));
    expect(show, contains('    return .result(dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), '
        'snippetIntent: AssistantCardSnippetIntent(reply.card))\n  }'));
    expect(show, isNot(contains('#available')));
    expect(show, isNot(contains('AssistantCardView')));
  });

  test('one platform below 26 keeps both branches', () {
    final swift =
        SwiftWriter(_app([_action('show')], deployment: const DeploymentTarget(iOS: 26, macOS: 14))).write();
    expect(_block(swift, 'public struct ShowAction'), contains('if #available(iOS 26.0, macOS 26.0, *) {'));
  });

  test('values come back with the card', () {
    final swift = SwiftWriter(_app([
      _action('count', result: const ResultModel(value: ValueType(ValueKind.integer), wrapped: true)),
    ])).write();
    final count = _block(swift, 'public struct CountAction');
    expect(count, contains('some IntentResult & ReturnsValue<Int> & ProvidesDialog {'));
    expect(count, contains('return .result(value: value, dialog: IntentDialog(stringLiteral: reply.dialog ?? "Done."), '
        'snippetIntent: AssistantCardSnippetIntent(reply.card))'));
  });

  test('the snippet and button intents are generated in the app module', () {
    final swift = SwiftWriter(_app([_action('show')])).write();
    final snippet = _block(swift, 'public struct AssistantCardSnippetIntent: SnippetIntent');
    expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\npublic struct AssistantCardSnippetIntent: SnippetIntent {'));
    expect(snippet, contains('public static let isDiscoverable = false'));
    expect(snippet, contains('@Parameter(title: "Card")\n  public var card: String'));
    expect(snippet, contains('@Parameter(title: "Card ID")\n  public var id: String'));
    expect(snippet, contains('public func perform() async throws -> some IntentResult & ShowsSnippetView {'));
    expect(snippet, contains('let card = AssistantCardStore.card(id, initial: card)'));
    expect(snippet, contains(r'AssistantCardView(card) { AssistantCardButtonIntent($0, card: id) }'));

    final button = _block(swift, 'public struct AssistantCardButtonIntent: AppIntent');
    expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\npublic struct AssistantCardButtonIntent: AppIntent {'));
    expect(button, contains('public static let isDiscoverable = false'));
    expect(button, contains('public static let supportedModes: IntentModes = .foreground(.dynamic)'));
    expect(button, isNot(contains('ForegroundContinuableIntent')), reason: 'deprecated from 26');
    expect(button, contains('try await continueInForeground(alwaysConfirm: false)'));
    expect(button, contains('let reply = try await callDart(action, args: AssistantCardStore.args(args))\n'
        '    AssistantCardStore.update(card, reply: reply)\n'
        '    return .result()'));
    expect(swift, contains('@available(iOS 26.0, macOS 26.0, *)\nextension AssistantCardButtonIntent: ProgressReportingIntent {}'));
    expect(swift, contains('#if compiler(>=6.4)\n@available(iOS 26.4, macOS 26.4, *)\n'
        'extension AssistantCardButtonIntent: CancellableIntent {}\n#endif'));
  });

  test('with @AssistantBackground() a press runs Dart without opening the app on iOS', () {
    final swift = SwiftWriter(_app([_action('show')], background: true)).write();
    final button = _block(swift, 'public struct AssistantCardButtonIntent: AppIntent');
    expect(button, contains('  #if os(iOS)\n  public static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]\n  #endif'));
    expect(button, contains('if !(await AssistantBackground.shared.prepare()), UIApplication.shared.applicationState != .active {'));
    expect(button, contains('  #if os(macOS)\n  public static let supportedModes: IntentModes = .foreground(.dynamic)\n  #endif'));
  });

  test('apps without replies get no card intents', () {
    final swift = SwiftWriter(_app([_action('show', reply: false)])).write();
    expect(swift, isNot(contains('AssistantCard')));
    expect(swift, isNot(contains('import SwiftUI')));
  });
}
