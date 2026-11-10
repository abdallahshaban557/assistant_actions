import Foundation

/// Keeps App Shortcut phrases that name entities ("Cook {recipe} in …") in
/// step with what Dart publishes, by calling the app's
/// `AppShortcutsProvider.updateAppShortcutParameters()`.
///
/// The provider must live in the app (Runner) target, so the generated
/// `apple/AssistantShortcuts.g.swift` adds `@objc(AssistantActionsAppShortcuts)`,
/// which the runtime finds by name, as it finds the Spotlight indexer. Apps
/// with no such phrases have no such class, and this does nothing.
public enum AssistantShortcutParameters {
  static let className = "AssistantActionsAppShortcuts"
  static var selector: Selector { NSSelectorFromString("updateAppShortcutParameters") }

  /// The generated class, if the app has one.
  static func provider(named name: String = className) -> NSObject.Type? {
    guard let type = NSClassFromString(name) as? NSObject.Type, type.responds(to: selector) else { return nil }
    return type
  }

  /// Updates the phrases soon. Publishing several collections at once
  /// updates them once.
  public static func update() {
    Task { await Coalescer.shared.request() }
  }

  /// Updates the phrases now. Returns whether the app has parameterized
  /// phrases to update.
  @discardableResult
  public static func updateNow() -> Bool {
    guard let type = provider() else { return false }
    _ = (type as AnyObject).perform(selector)
    return true
  }

  private actor Coalescer {
    static let shared = Coalescer()
    private var scheduled = false

    func request() async {
      guard !scheduled else { return }
      scheduled = true
      try? await Task.sleep(nanoseconds: 500_000_000)
      scheduled = false
      AssistantShortcutParameters.updateNow()
    }
  }
}
