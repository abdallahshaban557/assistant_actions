import AppIntents
import Foundation

/// How generated live intents call Dart: as an [AssistantLiveCall] that
/// reports progress into the intent's `progress`, is cancelled with the
/// intent (`CancellableIntent`, iOS 26.4 / macOS 26.4) and, for a
/// `LongRunningIntent` (iOS 27 / macOS 27), keeps running in the background.
extension ProgressReportingIntent {
  @MainActor
  public func callDart(_ action: String, args: [String: Any]) async throws -> String? {
    let call = AssistantLiveCall(progress: progress)
    let cancel = AssistantLiveIntentCancel(id: call.id)
    let run: () async throws -> String? = {
      try await call.run(action, args: args) { action, args in
        try await AssistantBridge.shared.perform(action, args: args)
      }
    }
    if #available(iOS 27.0, macOS 27.0, *) {
      if let intent = self as? any LongRunningIntent & CancellableIntent {
        return try await assistantLongRunning(intent, run: run, cancel: cancel)
      }
      if let intent = self as? any LongRunningIntent {
        return try await assistantLongRunning(intent, run: run)
      }
    }
    if #available(iOS 26.4, macOS 26.4, *), let intent = self as? any CancellableIntent {
      return try await assistantCancellable(intent, run: run, cancel: cancel)
    }
    return try await run()
  }
}

/// Tells Dart a call was cancelled. Sendable, for Siri's cancellation
/// handlers.
struct AssistantLiveIntentCancel: Sendable {
  let id: String

  func callAsFunction() {
    Task { @MainActor in
      _ = try? await AssistantBridge.shared.perform(AssistantLiveCall.cancelAction, args: ["call": id])
    }
  }
}

@available(iOS 26.4, macOS 26.4, *)
@MainActor
private func assistantCancellable<I: CancellableIntent>(
  _ intent: I, run: () async throws -> String?, cancel: AssistantLiveIntentCancel
) async throws -> String? {
  try await intent.withIntentCancellationHandler {
    try await run()
  } onCancel: { _ in
    cancel()
  }
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor
private func assistantLongRunning<I: LongRunningIntent & CancellableIntent>(
  _ intent: I, run: @escaping () async throws -> String?, cancel: AssistantLiveIntentCancel
) async throws -> String? {
  try await intent.performBackgroundTask(operation: run, onCancel: { _ in cancel() })
}

@available(iOS 27.0, macOS 27.0, *)
@MainActor
private func assistantLongRunning<I: LongRunningIntent>(
  _ intent: I, run: @escaping () async throws -> String?
) async throws -> String? {
  try await intent.performBackgroundTask(operation: run)
}
