import AppIntents
import Foundation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// What's on screen, for Siri and Apple Intelligence: Dart's
/// `AssistantActions.showing(item)` makes the item the `appEntityIdentifier`
/// of an `NSUserActivity` on the app's key window, so "remind me about this"
/// or "summarize this" mean it.
///
/// Generated code registers, per collection, how an id becomes the
/// `EntityIdentifier` of its App Entity type (`AssistantActionsAppHostCalls`).
@MainActor
public enum AssistantContext {
  /// Makes the identifier of the item with an id, or nil when the entity
  /// type isn't available on this OS.
  public typealias Identify = @MainActor (String) -> EntityIdentifier?

  private static var identifiers: [String: Identify] = [:]

  /// The activity of what's shown now.
  private(set) static var current: NSUserActivity?

  /// `<bundle id>.assistant_actions.showing`.
  public static var activityType: String {
    "\(Bundle.main.bundleIdentifier ?? "app").assistant_actions.showing"
  }

  /// Registers how items of [collection] are identified.
  public static func register(_ collection: String, _ identify: @escaping Identify) {
    identifiers[collection] = identify
  }

  /// Registers the `context.*` host calls Dart's `AssistantActions` makes.
  static func registerHostCalls() {
    AssistantHostCalls.register("context.showing") { args in
      guard let collection = args["collection"] as? String, let id = args["id"] as? String else { return false }
      return show(collection: collection, id: id)
    }
    AssistantHostCalls.register("context.stopShowing") { _ in
      stopShowing()
      return nil
    }
  }

  /// The activity naming the item, or nil when its collection isn't known
  /// or the OS is older than iOS 18.2 / macOS 15.2.
  static func activity(collection: String, id: String) -> NSUserActivity? {
    guard #available(iOS 18.2, macOS 15.2, *), let identifier = identifiers[collection]?(id) else { return nil }
    let activity = NSUserActivity(activityType: activityType)
    activity.appEntityIdentifier = identifier
    return activity
  }

  /// Shows the item: attaches its activity to the key window and makes it
  /// current. Returns whether it was attached.
  static func show(collection: String, id: String) -> Bool {
    guard let activity = activity(collection: collection, id: id) else { return false }
    stopShowing()
    current = activity
    let attached = attach(activity)
    activity.becomeCurrent()
    return attached
  }

  static func stopShowing() {
    guard let activity = current else { return }
    current = nil
    if let responder = responder(), responder.userActivity === activity { responder.userActivity = nil }
    activity.resignCurrent()
    activity.invalidate()
  }

  private static func attach(_ activity: NSUserActivity) -> Bool {
    guard let responder = responder() else { return false }
    responder.userActivity = activity
    return true
  }

  #if os(iOS)
    /// The key window's root view controller (the Flutter view).
    private static func responder() -> UIResponder? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
      return scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
    }
  #elseif os(macOS)
    /// The key (or main) window's content view controller (the Flutter view).
    private static func responder() -> NSResponder? {
      let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
      return window?.contentViewController ?? window
    }
  #endif
}
