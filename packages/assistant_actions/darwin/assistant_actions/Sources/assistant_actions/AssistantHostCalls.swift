import Foundation

/// Swift features Dart calls by name, over the one Pigeon `invoke` FFI method
/// (no platform channels), so new features don't change the FFI surface.
///
/// The runtime registers its handlers when the plugin registers. Generated
/// code registers its own through `AssistantActionsAppHostCalls`, which the
/// runtime finds by name, as it finds the Spotlight indexer.
@MainActor
public enum AssistantHostCalls {
  /// Takes the decoded arguments and returns a JSON value (or nil).
  public typealias Handler = @MainActor ([String: Any]) throws -> Any?

  private static var handlers: [String: Handler] = [:]
  private static var loadedGenerated = false

  /// Registers [handler] for [method], replacing any earlier one.
  public static func register(_ method: String, _ handler: @escaping Handler) {
    handlers[method] = handler
  }

  /// Runs [method] with [argsJson] and returns its result as JSON.
  public static func invoke(_ method: String, argsJson: String) throws -> String? {
    loadGenerated()
    guard let handler = handlers[method] else {
      throw AssistantHostCallError.unknownMethod(method)
    }
    let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
    guard let result = try handler(args), !(result is NSNull) else { return nil }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
  }

  /// Lets generated code (`@objc(AssistantActionsAppHostCalls)` with a
  /// `registerAll()` class method) add its handlers, once.
  static func loadGenerated() {
    guard !loadedGenerated else { return }
    loadedGenerated = true
    if let type = NSClassFromString("AssistantActionsAppHostCalls") as? AssistantHostCallsProvider.Type {
      type.registerAll()
    }
  }
}

/// Implemented by generated code to add host calls.
@objc public protocol AssistantHostCallsProvider {
  @MainActor static func registerAll()
}

public enum AssistantHostCallError: Error, CustomStringConvertible {
  case unknownMethod(String)

  public var description: String {
    switch self {
    case .unknownMethod(let method): return "No Swift handler for \(method)"
    }
  }
}
