// Copied into the widget extension by `dart run assistant_actions:install
// --widgets`, which replaces it on every run: put your own widgets in
// AssistantWidgets.swift.
//
// Draws the Live Activities Dart starts with `AssistantLiveActivity.start`:
// an SF Symbol, the title and subtitle, a timer, a progress bar, and up to two
// interactive action buttons on the Lock Screen and in the Dynamic Island.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AssistantLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AssistantActivityAttributes.self) { context in
      AssistantActivityView(state: context.state)
        .padding()
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          AssistantActivityIcon(state: context.state).font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          AssistantActivityTimer(state: context.state).font(.title3)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title).font(.headline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            if let subtitle = context.state.subtitle {
              Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            AssistantActivityProgress(state: context.state)
            AssistantActivityButtons(state: context.state)
          }
        }
      } compactLeading: {
        AssistantActivityIcon(state: context.state)
      } compactTrailing: {
        if context.state.progress != nil {
          AssistantActivityProgress(state: context.state, circular: true)
        } else {
          AssistantActivityTimer(state: context.state).frame(maxWidth: 52)
        }
      } minimal: {
        AssistantActivityIcon(state: context.state)
      }
    }
  }
}

/// The Lock Screen presentation.
struct AssistantActivityView: View {
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        AssistantActivityIcon(state: state).font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text(state.title).font(.headline).lineLimit(1)
          if let subtitle = state.subtitle {
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer(minLength: 0)
        AssistantActivityTimer(state: state).font(.title3)
      }
      AssistantActivityProgress(state: state)
      AssistantActivityButtons(state: state)
    }
  }
}

/// Interactive buttons (up to 2) backed by `AssistantLiveActivityButtonIntent`.
struct AssistantActivityButtons: View {
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    let buttons = Array(state.buttons.prefix(2))
    if !buttons.isEmpty {
      HStack(spacing: 8) {
        ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
          Button(intent: AssistantLiveActivityButtonIntent(button)) {
            if let symbol = button.systemImage {
              Label(button.label, systemImage: symbol)
                .frame(maxWidth: .infinity)
            } else {
              Text(button.label)
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    }
  }
}

struct AssistantActivityIcon: View {
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    if let symbol = state.systemImage {
      Image(systemName: symbol)
    }
  }
}

/// Counts down to `timerEnd`, or up from `timerStart`.
struct AssistantActivityTimer: View {
  let state: AssistantActivityAttributes.ContentState

  var body: some View {
    if let end = state.timerEnd {
      Text(timerInterval: (state.timerStart ?? .now)...max(end, state.timerStart ?? .now), countsDown: true)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    } else if let start = state.timerStart {
      Text(start, style: .timer)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
  }
}

struct AssistantActivityProgress: View {
  let state: AssistantActivityAttributes.ContentState
  var circular = false

  var body: some View {
    if let progress = state.progress {
      if circular {
        ProgressView(value: progress).progressViewStyle(.circular)
      } else {
        ProgressView(value: progress)
      }
    }
  }
}
