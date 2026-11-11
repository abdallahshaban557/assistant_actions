import AppIntents
import Foundation

/// Siri conversations the generated intents have: confirming before they
/// run, and asking which of several items the user meant.
extension AppIntent {
  /// Asks [question] and returns if the user agrees; throws (ending the
  /// intent) if not. [destructive] labels the button "Delete".
  ///
  /// iOS 17 and macOS 14 have no confirmation with a question, so they ask
  /// Siri's own "Do you want to continue?".
  @MainActor
  public func assistantConfirm(_ question: String, destructive: Bool = false) async throws {
    if #available(iOS 18.0, macOS 15.0, *) {
      let action: ConfirmationActionName =
        destructive
        ? .custom(acceptLabel: "Delete", acceptAlternatives: ["Remove"], denyLabel: "Cancel", denyAlternatives: [],
          destructive: true)
        : .continue
      try await requestConfirmation(actionName: action, dialog: IntentDialog(stringLiteral: question))
    } else {
      try await requestConfirmation()
    }
  }

  /// The one of [items] the user picks, asked with [prompt]: Siri lists
  /// their titles. Needs iOS 26 or macOS 26; earlier, the first. Nil when
  /// there are none; throws if the user cancels.
  @MainActor
  public func assistantChoose<Item: AppEntity>(among items: [Item], prompt: String?) async throws -> Item? {
    guard items.count > 1 else { return items.first }
    guard #available(iOS 26.0, macOS 26.0, *) else { return items.first }
    let options = items.map { IntentChoiceOption(title: $0.displayRepresentation.title) }
    let choice = try await requestChoice(
      between: options + [.cancel], dialog: prompt.map { IntentDialog(stringLiteral: $0) })
    guard let index = options.firstIndex(of: choice) else { throw CancellationError() }
    return items[index]
  }
}
