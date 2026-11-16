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

  /// Asks [question] mid-call (`AssistantCall.confirm`) and returns `true` when
  /// the user agrees, or `false` if they cancel or dismiss.
  @MainActor
  public func assistantConfirmPrompt(_ question: String, actionLabel: String? = nil) async -> Bool {
    do {
      if #available(iOS 18.0, macOS 15.0, *) {
        let action: ConfirmationActionName
        if let label = actionLabel, !label.isEmpty {
          action = .custom(
            acceptLabel: LocalizedStringResource(stringLiteral: label),
            acceptAlternatives: [],
            denyLabel: "Cancel",
            denyAlternatives: [],
            destructive: false)
        } else {
          action = .continue
        }
        try await requestConfirmation(actionName: action, dialog: IntentDialog(stringLiteral: question))
      } else {
        try await requestConfirmation()
      }
      return true
    } catch {
      return false
    }
  }

  /// Asks the user to pick one of [choices] mid-call (`AssistantCall.choose`,
  /// iOS 26 / macOS 26) and returns the chosen option's `id`, or `nil` if the
  /// user cancels.
  @MainActor
  public func assistantChooseOption(_ choices: [[String: Any]], prompt: String) async throws -> String? {
    let valid = choices.compactMap { item -> (id: String, title: String, destructive: Bool)? in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      return (id, title, item["destructive"] as? Bool == true)
    }
    guard !valid.isEmpty else { return nil }
    guard #available(iOS 26.0, macOS 26.0, *) else { return valid[0].id }
    let options = valid.map {
      IntentChoiceOption(
        title: LocalizedStringResource(stringLiteral: $0.title),
        style: $0.destructive ? .destructive : .default)
    }
    let choice = try await requestChoice(
      between: options + [.cancel], dialog: IntentDialog(stringLiteral: prompt))
    guard let index = options.firstIndex(of: choice) else { return nil }
    return valid[index].id
  }
}
