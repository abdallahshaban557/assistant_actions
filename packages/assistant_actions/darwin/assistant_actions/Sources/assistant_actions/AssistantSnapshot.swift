import Foundation

/// One item of an entity collection, as Dart last published it.
public struct AssistantRecord {
  public let id: String
  public var title: String
  public var subtitle: String?
  /// Values keyed by Dart field name (see [AssistantValues] for encodings).
  public var fields: [String: Any]

  public init(id: String, title: String, subtitle: String? = nil, fields: [String: Any]) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.fields = fields
  }
}

/// Reads the entity snapshots Dart publishes with `AssistantActions.publish`,
/// so entity queries can answer without Flutter.
///
/// Changes queued in [AssistantInbox] but not yet applied by Dart are layered
/// on top, so an item Siri just created can be found, updated or deleted
/// before the app has run.
public enum AssistantSnapshot {
  /// Every record of [collection], newest queued creates first.
  public static func records(_ collection: String) -> [AssistantRecord] {
    var records = published(collection)
    for change in AssistantInbox.pending(collection) {
      guard let id = change["id"] as? String else { continue }
      let fields = change["fields"] as? [String: Any] ?? [:]
      switch change["kind"] as? String {
      case "create":
        records.insert(AssistantRecord(id: id, title: "", fields: fields), at: 0)
      case "update":
        guard let i = records.firstIndex(where: { $0.id == id }) else { continue }
        records[i].fields.merge(fields) { _, new in new }
        for name in change["cleared"] as? [String] ?? [] { records[i].fields[name] = nil }
      case "delete":
        records.removeAll { $0.id == id }
      default:
        continue
      }
    }
    return records
  }

  static func write(collection: String, json: String) throws {
    let url = try fileURL(collection, create: true)
    try Data(json.utf8).write(to: url, options: .atomic)
    AssistantSpotlight.update(collection)
  }

  private static func published(_ collection: String) -> [AssistantRecord] {
    guard let url = try? fileURL(collection, create: false),
      let data = try? Data(contentsOf: url),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let items = json["records"] as? [[String: Any]]
    else { return [] }
    return items.compactMap { item in
      guard let id = item["id"] as? String else { return nil }
      return AssistantRecord(
        id: id, title: item["title"] as? String ?? "", subtitle: item["subtitle"] as? String,
        fields: item["fields"] as? [String: Any] ?? [:])
    }
  }

  private static func fileURL(_ collection: String, create: Bool) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
    let dir = base.appendingPathComponent("assistant_actions", isDirectory: true)
    if create { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    return dir.appendingPathComponent("\(collection).json")
  }
}
