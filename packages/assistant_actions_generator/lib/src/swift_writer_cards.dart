part of 'swift_writer.dart';

/// Interactive result cards. From iOS 26 / macOS 26 an intent shows its
/// Dart reply's card through a `SnippetIntent` (`AssistantCardSnippetIntent`),
/// so the card's buttons (`AssistantCardButtonIntent`, `Button(intent:)`) run
/// Dart and update it. Earlier, the card is a plain `ShowsSnippetView`
/// without buttons.
///
/// Both intents are generated here, not in the runtime, because Apple's
/// metadata processor only registers intents of the app plugin's module.
extension _Cards on SwiftWriter {
  static const _cardFloor = <String, num>{'iOS': 26, 'macOS': 26};

  /// Whether an intent available from [floor] always runs where snippet
  /// intents exist: the app's deployment target or [floor] is 26 on both
  /// platforms.
  bool _snippetIntents(Map<String, num>? floor) {
    final f = floor == null ? const <String, num>{'iOS': 0, 'macOS': 0} : SwiftWriter._norm(floor);
    return _Modern._platforms.every((p) => app.deployment[p] >= 26 || f[p]! >= 26);
  }

  /// The snippet protocol of a reply's result type: `ShowsSnippetIntent`
  /// when it always has one. Otherwise none, so `perform` can return a
  /// snippet intent from 26 and a snippet view before (an opaque result type
  /// with limited availability, SE-0360).
  String? _replySnippet(Map<String, num>? floor) => _snippetIntents(floor) ? 'ShowsSnippetIntent' : null;

  /// The `return` lines ending a `perform` that shows Dart's `reply.card`,
  /// with [value] and [dialog] (Swift expressions; [dialog] a `String`).
  String _replyReturn({String? value, String? dialog, Map<String, num>? floor}) {
    _cards = true;
    _imports.add('SwiftUI');
    String result(String snippet) => '.result(${[
          if (value != null) 'value: $value',
          if (dialog != null) 'dialog: IntentDialog(stringLiteral: $dialog)',
          snippet,
        ].join(', ')})';
    final intent = result('snippetIntent: AssistantCardSnippetIntent(reply.card)');
    if (_snippetIntents(floor)) return '    return $intent\n';
    return '    if #available(iOS 26.0, macOS 26.0, *) {\n'
        '      return $intent\n'
        '    } else {\n'
        '      return ${result('view: AssistantCardView(reply.card)')}\n'
        '    }\n';
  }

  /// The snippet and button intents, when an intent shows a Dart card.
  void _cardIntents() {
    if (!_cards) return;
    final availability = _availability(_cardFloor);
    // Buttons run Dart like any live intent: in the background on iOS with
    // `@AssistantBackground()`, else bringing the app forward if need be.
    final modes = {'iOS': _background ? _Mode.background : _Mode.dynamic, 'macOS': _Mode.dynamic};
    final forward = _foregroundLines(modes, activateOnMac: false);
    _out.writeln('''
/// The result card of a Dart `AssistantReply`, as an interactive snippet: Siri
/// performs it to show the card, and again after one of its buttons ran.
$availability
public struct AssistantCardSnippetIntent: SnippetIntent {
  public static let title: LocalizedStringResource = "Result Card"
  public static let isDiscoverable = false

  /// The card as Dart sent it (`AssistantCard.json`).
  @Parameter(title: "Card")
  public var card: String

  /// Which card this is, for `AssistantCardStore`.
  @Parameter(title: "Card ID")
  public var id: String

  public init() {}

  public init(_ card: AssistantCard?) {
    self.card = card?.json ?? ""
    id = UUID().uuidString
  }

  @MainActor
  public func perform() async throws -> some IntentResult & ShowsSnippetView {
    let card = AssistantCardStore.card(id, initial: card)
    return .result(view: AssistantCardView(card) { AssistantCardButtonIntent(\$0, card: id) })
  }
}

/// A result card's button: runs its Dart action, and keeps the card the
/// action replies with for the snippet to show.
$availability
public struct AssistantCardButtonIntent: AppIntent {
  public static let title: LocalizedStringResource = "Result Card Button"
  public static let isDiscoverable = false

${_modesMember(modes, access: 'public ')}  /// The Dart action's id.
  @Parameter(title: "Action")
  public var action: String

  /// Its arguments, as JSON text.
  @Parameter(title: "Arguments")
  public var args: String

  /// The card's id.
  @Parameter(title: "Card ID")
  public var card: String

  public init() {}

  public init(_ button: AssistantCard.Button, card: String) {
    action = button.action
    args = button.args
    self.card = card
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
${forward.isEmpty ? '' : '$forward\n'}    let reply = try await callDart(action, args: AssistantCardStore.args(args))
    AssistantCardStore.update(card, reply: reply)
    return .result()
  }
}

${_liveConformances('AssistantCardButtonIntent', _cardFloor, longRunning: false)}''');
  }
}
