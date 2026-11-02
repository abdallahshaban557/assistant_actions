import Foundation

/// Indexes a collection's entities in Spotlight. The generated code
/// implements it as `AssistantActionsAppSpotlight`, which the runtime finds by
/// name, so apps need no registration code.
@objc public protocol AssistantSpotlightIndexer {
  /// Indexes every current item of [collection] and removes [removedIDs]. With
  /// [clearFirst], removes all of the collection's entities first instead
  /// (nothing is known about what an earlier run indexed).
  func index(collection: String, removedIDs: [String], clearFirst: Bool) async throws
}

/// Keeps Spotlight in step with the published snapshot plus pending inbox
/// changes, so Siri's planner can find "my reminders in App" through
/// Spotlight's semantic index, not only through entity queries.
public enum AssistantSpotlight {
  static let indexerClassName = "AssistantActionsAppSpotlight"
  private static let keyPrefix = "assistant_actions.spotlight."

  /// Reindexes [collection] soon. Runs are serialised per collection.
  public static func update(_ collection: String) {
    Task { await Runner.shared.run(collection) }
  }

  /// What a run must remove, given the ids indexed last time ([previous], nil
  /// if unknown) and the ids there are now.
  static func plan(previous: [String]?, current: [String]) -> (removed: [String], clearFirst: Bool) {
    guard let previous else { return ([], true) }
    let now = Set(current)
    return (previous.filter { !now.contains($0) }, false)
  }

  static func indexer() -> AssistantSpotlightIndexer? {
    (NSClassFromString(indexerClassName) as? NSObject.Type)?.init() as? AssistantSpotlightIndexer
  }

  private actor Runner {
    static let shared = Runner()
    private var tails: [String: Task<Void, Never>] = [:]

    func run(_ collection: String) async {
      let previous = tails[collection]
      let task = Task {
        await previous?.value
        await AssistantSpotlight.reindex(collection)
      }
      tails[collection] = task
      await task.value
    }
  }

  private static func reindex(_ collection: String) async {
    guard let indexer = indexer() else { return }
    let key = keyPrefix + collection
    let current = AssistantSnapshot.records(collection).map(\.id)
    let plan = plan(previous: UserDefaults.standard.stringArray(forKey: key), current: current)
    do {
      try await indexer.index(collection: collection, removedIDs: plan.removed, clearFirst: plan.clearFirst)
      UserDefaults.standard.set(current, forKey: key)
    } catch {
      // Spotlight is best-effort; queries still work without it. Forget what
      // was indexed so the next run starts clean.
      UserDefaults.standard.removeObject(forKey: key)
      NSLog("assistant_actions: Spotlight indexing of %@ failed: %@", collection, "\(error)")
    }
  }
}
