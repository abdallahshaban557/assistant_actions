import Foundation

/// Undo for what Siri did through generated `UndoableIntent`s: each undo
/// queues the inverse in [AssistantInbox], which Dart applies like any other
/// change or call.
///
/// * a create is undone by deleting the item;
/// * an update by setting the fields it changed back to their published
///   values (clearing the ones that had none);
/// * a delete by creating the item again, with its id and published fields;
/// * any other intent by calling its `<action>.undo` handler with the same
///   arguments.
public enum AssistantUndo {
  /// The inbox items that undo creating [id].
  public static func create(_ collection: String, id: String) -> [[String: Any]] {
    [["kind": "delete", "collection": collection, "id": id]]
  }

  /// The inbox items that undo updating [fields] and clearing [cleared] on
  /// the item that was [before] (nil if it wasn't published).
  public static func update(
    _ collection: String, id: String, before: AssistantRecord?, fields: [String: Any], cleared: [String]
  ) -> [[String: Any]] {
    var restored: [String: Any] = [:]
    var clear: [String] = []
    for name in Set(fields.keys).union(cleared).sorted() {
      if let old = before?.fields[name], !(old is NSNull) { restored[name] = old } else { clear.append(name) }
    }
    return [["kind": "update", "collection": collection, "id": id, "fields": restored, "cleared": clear]]
  }

  /// The inbox items that undo deleting [records].
  public static func delete(_ collection: String, records: [AssistantRecord]) -> [[String: Any]] {
    records.map { ["kind": "create", "collection": collection, "id": $0.id, "fields": $0.fields] }
  }

  /// The inbox item that undoes a call to [action].
  public static func call(_ action: String, args: [String: Any]) -> [[String: Any]] {
    [["kind": "call", "action": "\(action).undo", "args": args]]
  }

  /// The published items of [collection] with [ids], before a change.
  public static func records(_ collection: String, ids: [String]) -> [AssistantRecord] {
    let wanted = Set(ids)
    return AssistantSnapshot.records(collection).filter { wanted.contains($0.id) }
  }

  /// Registers undoing with [items] (from the functions above) on
  /// [manager], named [name]. [changed] runs after the items are queued
  /// (generated code passes `AssistantBridge.shared.inboxChanged`).
  public static func register(
    _ manager: UndoManager?, _ name: String, _ items: [[String: Any]],
    changed: @escaping @Sendable @MainActor () -> Void
  ) {
    guard let manager, JSONSerialization.isValidJSONObject(items),
      let data = try? JSONSerialization.data(withJSONObject: items)
    else { return }
    let json = String(decoding: data, as: UTF8.self)
    manager.registerUndo(withTarget: Target.shared) { _ in
      apply(json)
      Task { @MainActor in changed() }
    }
    manager.setActionName(name)
  }

  /// Queues the inbox items in [json].
  static func apply(_ json: String) {
    let items = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    for item in items {
      let collection = item["collection"] as? String ?? ""
      let id = item["id"] as? String ?? ""
      switch item["kind"] as? String {
      case "create": AssistantInbox.create(collection, id: id, fields: item["fields"] as? [String: Any] ?? [:])
      case "update":
        AssistantInbox.update(
          collection, id: id, fields: item["fields"] as? [String: Any] ?? [:],
          cleared: item["cleared"] as? [String] ?? [])
      case "delete": AssistantInbox.delete(collection, id: id)
      case "call":
        AssistantInbox.call(item["action"] as? String ?? "", args: item["args"] as? [String: Any] ?? [:])
      default: continue
      }
    }
  }

  /// UndoManager needs an object to register undos with.
  private final class Target: Sendable {
    static let shared = Target()
  }
}
