import AppIntents
import Foundation

/// Maps the String ids Dart gives file entities (`files.file`) to Apple's
/// `FileEntityIdentifier`, and finds the published items Siri's identifiers
/// name. Generated file entities keep the Dart id as `dartID`.
///
/// In Dart a file item's id is its absolute path (or a `file://` URL).
/// Swift gives Siri a file identifier for it (a bookmark, so it follows the
/// file); ids that aren't paths of existing files become draft identifiers.
@available(iOS 18.0, macOS 15.0, *)
public enum AssistantFileIDs {
  /// The file URL a Dart id names, if it is a path or a `file://` URL.
  public static func url(_ id: String) -> URL? {
    if id.hasPrefix("file://") { return URL(string: id) }
    if id.hasPrefix("/") { return URL(fileURLWithPath: id) }
    return nil
  }

  /// The identifier Siri gets for Dart id [id].
  public static func identifier(_ id: String) -> FileEntityIdentifier {
    if let url = url(id), FileManager.default.fileExists(atPath: url.path),
      let file = try? FileEntityIdentifier.file(url: url)
    {
      return file
    }
    return .draft(identifier: id)
  }

  /// The path an identifier names (for a draft, its identifier), or nil.
  public static func path(_ identifier: FileEntityIdentifier) async -> String? {
    if let draft = identifier.draftIdentifier { return draft }
    guard let url = try? await identifier.fileURL else { return nil }
    return url.path
  }

  /// Compares paths the way the file system does: standardised, with
  /// symbolic links (`/var` → `/private/var`) resolved.
  static func key(_ id: String) -> String {
    guard let url = url(id) else { return id }
    return url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// The records [identifiers] name, in snapshot order.
  public static func records(_ records: [AssistantRecord], for identifiers: [FileEntityIdentifier]) async
    -> [AssistantRecord]
  {
    var wanted = Set<String>()
    for identifier in identifiers {
      if let path = await path(identifier) { wanted.insert(key(path)) }
    }
    return records.filter { wanted.contains(key($0.id)) }
  }
}
