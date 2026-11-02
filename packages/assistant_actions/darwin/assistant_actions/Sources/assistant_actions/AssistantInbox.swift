import Foundation

/// Changes and calls the generated intents made while Dart wasn't there to
/// take them, waiting for `AssistantActions` to apply them.
///
/// Kept in UserDefaults, one JSON string per item, so intents never write
/// files Dart owns. Items are applied in order, so an update after a create
/// in the same batch sees the created item.
public enum AssistantInbox {
  private static let key = "assistant_actions.inbox"

  /// Queues a call to a `Runs.deferred` action.
  public static func call(_ action: String, args: [String: Any]) {
    append(["kind": "call", "action": action, "args": args])
  }

  /// Queues a new item for [collection] and returns the id Swift gave it, so
  /// later updates or deletes from Siri can find it before Dart has run.
  @discardableResult
  public static func create(_ collection: String, fields: [String: Any]) -> String {
    let id = UUID().uuidString.lowercased()
    append(["kind": "create", "collection": collection, "id": id, "fields": fields])
    return id
  }

  /// Queues changed [fields] for an item; [cleared] names fields set to null.
  public static func update(
    _ collection: String, id: String, fields: [String: Any], cleared: [String] = []
  ) {
    append([
      "kind": "update", "collection": collection, "id": id, "fields": fields, "cleared": cleared,
    ])
  }

  public static func delete(_ collection: String, id: String) {
    append(["kind": "delete", "collection": collection, "id": id])
  }

  /// Queued items for [collection], oldest first.
  public static func pending(_ collection: String) -> [[String: Any]] {
    stored().compactMap(decode).filter { $0["collection"] as? String == collection }
  }

  /// Returns every queued item as JSON and clears the queue.
  static func drain() -> [String] {
    let items = stored()
    UserDefaults.standard.removeObject(forKey: key)
    return items
  }

  private static func append(_ item: [String: Any]) {
    var entry = item
    entry["createdAt"] = Date().timeIntervalSince1970
    guard JSONSerialization.isValidJSONObject(entry),
      let data = try? JSONSerialization.data(withJSONObject: entry),
      let json = String(data: data, encoding: .utf8)
    else { return }
    UserDefaults.standard.set(stored() + [json], forKey: key)
    // Siri's own changes show in Spotlight before Dart applies them.
    if let collection = item["collection"] as? String { AssistantSpotlight.update(collection) }
  }

  private static func stored() -> [String] {
    UserDefaults.standard.stringArray(forKey: key) ?? []
  }

  private static func decode(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
