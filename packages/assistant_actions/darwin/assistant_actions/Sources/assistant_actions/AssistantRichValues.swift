import AppIntents
import Foundation
import UniformTypeIdentifiers

#if canImport(GeoToolbox)
  import GeoToolbox
#endif

/// A value the generated code encodes itself, such as a schema union.
public protocol AssistantEncodable {
  /// The value as Dart receives it (JSON types only).
  var assistantValue: Any { get }
}

/// Thrown by a generated `Transferable` export when the item has no value
/// for the member it exports (a journal entry without a location).
public enum AssistantTransferError: Error, CustomStringConvertible {
  case noValue(String)

  public var description: String {
    switch self {
    case .noValue(let member): return "The item has no \(member)"
    }
  }
}

/// People, places, files and recurrence rules cross to Dart as small maps
/// (see `values.dart`); unions as `{case, kind, value}`.
extension AssistantValues {
  public static func encode<T: AssistantEncodable>(_ value: T?) -> Any { value?.assistantValue ?? NSNull() }

  /// A union case: its name, the schema kind of its value, and the value.
  public static func encodeCase(_ name: String, kind: String, _ value: Any) -> Any {
    ["case": name, "kind": kind, "value": value]
  }

  /// The case name and raw value of a union Dart sent.
  public static func unionCase(_ value: Any?) -> (name: String, value: Any?)? {
    guard let map = value as? [String: Any], let name = map["case"] as? String else { return nil }
    return (name, map["value"])
  }

  // ── People ──

  public static func encode(_ person: IntentPerson?) -> Any {
    guard let person else { return NSNull() }
    var map: [String: Any] = [:]
    switch person.name {
    case .displayName(let name): map["name"] = name
    case .components(let components): map["name"] = PersonNameComponentsFormatter().string(from: components)
    default: break
    }
    switch person.handle?.value {
    case .emailAddress(let email): map["email"] = email
    case .phoneNumber(let phone): map["phone"] = phone
    case .applicationDefined(let id): map["id"] = id
    default: break
    }
    switch person.identifier {
    case .contact(let id), .applicationDefined(let id): map["id"] = id
    default: break
    }
    if person.isMe { map["isMe"] = true }
    return map
  }

  public static func person(_ value: Any?) -> IntentPerson? {
    guard let map = value as? [String: Any] else { return nil }
    let handle: IntentPerson.Handle? =
      (map["email"] as? String).map { IntentPerson.Handle(emailAddress: $0) }
      ?? (map["phone"] as? String).map { IntentPerson.Handle(phoneNumber: $0) }
    let id = map["id"] as? String
    return IntentPerson(
      identifier: id.map { .applicationDefined($0) } ?? .unknown,
      name: (map["name"] as? String).map { .displayName($0) } ?? .unknown,
      handle: handle,
      isMe: map["isMe"] as? Bool ?? false)
  }

  // ── Files ──

  /// Copies [file] into Application Support (`assistant_actions/files/`), so
  /// Dart can read it even when the call is queued, and returns its path.
  public static func encode(_ file: IntentFile?) -> Any {
    guard let file else { return NSNull() }
    return saveFile(named: file.filename, type: file.type) { destination in
      if let source = file.fileURL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
      } else {
        try file.data.write(to: destination)
      }
    }
  }

  /// Writes a file Dart will read into a new folder in Application Support
  /// (`assistant_actions/files/<uuid>/`) with [write], and returns it as an
  /// `AssistantFile` map (or NSNull if writing failed).
  public static func saveFile(named name: String, type: UTType?, write: (URL) throws -> Void) -> Any {
    do {
      let folder = try FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("assistant_actions/files/\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let name = name.isEmpty ? "file" : name
      let destination = folder.appendingPathComponent(name)
      try write(destination)
      var map: [String: Any] = ["path": destination.path, "name": name]
      if let type { map["type"] = type.identifier }
      return map
    } catch {
      return NSNull()
    }
  }

  /// The items a Dart handler returned as `[{collection, id}]` (the
  /// registry's `visualSearch`), in order.
  public static func references(_ reply: String?) -> [(collection: String, id: String)] {
    ((json(reply) as? [Any]) ?? []).compactMap { item in
      guard let map = item as? [String: Any], let collection = map["collection"] as? String,
        let id = map["id"] as? String
      else { return nil }
      return (collection, id)
    }
  }

  // ── Text ──

  /// A text summary of an item, for `Transferable` exports and predictions:
  /// [parts] (encoded values) that are text, or people and places as their
  /// names, one per line, skipping empty and repeated ones.
  public static func text(_ parts: [Any], separator: String = "\n") -> String {
    var seen: [String] = []
    for part in parts {
      let text: String?
      switch part {
      case let string as String: text = string
      case let map as [String: Any]:
        text = (map["name"] as? String) ?? (map["address"] as? String) ?? (map["email"] as? String)
          ?? (map["phone"] as? String)
      default: text = nil
      }
      let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty && !seen.contains(trimmed) { seen.append(trimmed) }
    }
    return seen.joined(separator: separator)
  }

  public static func file(_ value: Any?) -> IntentFile? {
    guard let map = value as? [String: Any], let path = map["path"] as? String else { return nil }
    return IntentFile(
      fileURL: URL(fileURLWithPath: path), filename: map["name"] as? String,
      type: (map["type"] as? String).flatMap { UTType($0) })
  }

  // ── Recurrence rules ──

  /// Foundation's `Codable` form of the rule.
  @available(iOS 18.0, macOS 15.0, *)
  public static func encode(_ rule: Calendar.RecurrenceRule?) -> Any {
    guard let rule, let data = try? JSONEncoder().encode(rule),
      let json = try? JSONSerialization.jsonObject(with: data)
    else { return NSNull() }
    return json
  }

  @available(iOS 18.0, macOS 15.0, *)
  public static func recurrence(_ value: Any?) -> Calendar.RecurrenceRule? {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    return try? JSONDecoder().decode(Calendar.RecurrenceRule.self, from: data)
  }

  // ── Places ──

  #if canImport(GeoToolbox)
    @available(iOS 26.0, macOS 26.0, *)
    public static func encode(_ place: PlaceDescriptor?) -> Any {
      guard let place else { return NSNull() }
      var map: [String: Any] = [:]
      if let name = place.commonName { map["name"] = name }
      for representation in place.representations {
        switch representation {
        case .address(let address): map["address"] = address
        case .coordinate(let c):
          map["latitude"] = c.latitude
          map["longitude"] = c.longitude
        case .deviceLocation(let location):
          map["latitude"] = location.coordinate.latitude
          map["longitude"] = location.coordinate.longitude
        @unknown default: break
        }
      }
      return map
    }

    @available(iOS 26.0, macOS 26.0, *)
    public static func place(_ value: Any?) -> PlaceDescriptor? {
      guard let map = value as? [String: Any] else { return nil }
      var representations: [PlaceDescriptor.PlaceRepresentation] = []
      if let latitude = map["latitude"] as? Double, let longitude = map["longitude"] as? Double {
        representations.append(.coordinate(.init(latitude: latitude, longitude: longitude)))
      }
      if let address = map["address"] as? String { representations.append(.address(address)) }
      if representations.isEmpty { return nil }
      return PlaceDescriptor(representations: representations, commonName: map["name"] as? String)
    }
  #endif
}
