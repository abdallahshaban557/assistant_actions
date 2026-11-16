// Shared App Group container discovery for the app and its widget / control
// extensions.
//
// `dart run assistant_actions:install --widgets` copies this file into the
// widget extension too, so keep it Foundation-only.

import Foundation

/// Implemented by generated code (`@objc(AssistantActionsAppGroup)`) when
/// `@AssistantActionsApp(appGroup: ...)` is set in Dart.
@objc public protocol AssistantAppGroupProvider {
  static var appGroupIdentifier: String? { get }
}

/// Resolves the shared App Group container and `UserDefaults` suite used by
/// `AssistantSnapshot`, `AssistantInbox`, and `AssistantSpotlight`.
///
/// Discovery order:
/// 1. Explicit override set via [configure] (used by tests or custom hosts).
/// 2. Generated `AssistantActionsAppGroup` class (`@AssistantActionsApp(appGroup:)`).
/// 3. `Info.plist` key `AssistantAppGroup` (so widget/control extensions in
///    the same App Group can also discover it via Info.plist).
///
/// Falls back seamlessly to `Application Support` and `UserDefaults.standard`
/// when no App Group is configured or when the OS cannot resolve the group
/// container URL.
public enum AssistantAppGroup {
  public static let infoPlistKey = "AssistantAppGroup"
  static let providerClassName = "AssistantActionsAppGroup"

  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var hasOverride = false
    var overrideIdentifier: String?
    var overrideContainerURL: URL?
  }

  private static let storage = Storage()

  /// Explicitly sets (or clears, when nil) the App Group identifier, with an
  /// optional custom [containerURL] directory for isolated unit tests.
  public static func configure(_ identifier: String?, containerURL: URL? = nil) {
    storage.lock.lock()
    defer { storage.lock.unlock() }
    storage.hasOverride = true
    storage.overrideIdentifier = normalized(identifier)
    storage.overrideContainerURL = containerURL
  }

  /// Clears any override set by [configure], restoring automatic discovery.
  public static func reset() {
    storage.lock.lock()
    defer { storage.lock.unlock() }
    storage.hasOverride = false
    storage.overrideIdentifier = nil
    storage.overrideContainerURL = nil
  }

  /// The active App Group identifier, or nil when none is configured.
  public static var identifier: String? {
    storage.lock.lock()
    let hasOverride = storage.hasOverride
    let overrideId = storage.overrideIdentifier
    storage.lock.unlock()

    if hasOverride { return overrideId }
    if let provider = NSClassFromString(providerClassName) as? AssistantAppGroupProvider.Type,
      let generated = normalized(provider.appGroupIdentifier)
    {
      return generated
    }
    if let plistValue = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
      let fromPlist = normalized(plistValue)
    {
      return fromPlist
    }
    return nil
  }

  /// Shared App Group container root URL, or nil when unconfigured / unavailable.
  public static func containerURL() -> URL? {
    guard let group = identifier else { return nil }
    storage.lock.lock()
    let customURL = storage.hasOverride ? storage.overrideContainerURL : nil
    storage.lock.unlock()
    if let customURL { return customURL }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
  }

  /// Directory where `assistant_actions` stores entity snapshot JSON files:
  /// `<AppGroupContainer>/assistant_actions` when an App Group container is
  /// available, falling back to `<Application Support>/assistant_actions`.
  public static func directoryURL(create: Bool = false) throws -> URL {
    let base: URL
    if let shared = containerURL() {
      base = shared
    } else {
      base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
    }
    let dir = base.appendingPathComponent("assistant_actions", isDirectory: true)
    if create {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  /// `UserDefaults(suiteName:)` for the configured App Group, falling back to
  /// `UserDefaults.standard` when nil.
  public static var userDefaults: UserDefaults {
    guard let group = identifier, let suite = UserDefaults(suiteName: group) else {
      return .standard
    }
    return suite
  }

  private static func normalized(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty,
      !trimmed.hasPrefix("$(")
    else { return nil }
    return trimmed
  }
}
