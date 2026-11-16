// Written once by `dart run assistant_actions:install --widgets`; it's yours
// to edit, and later runs leave it alone.
//
// The widget extension's entry point. It draws the Live Activities Dart
// starts (`AssistantLiveActivityWidget`) and includes any `@AssistantControl`
// controls generated into `apple/AssistantWidgets.g.swift`
// (`assistantControlsBundle`). Add your own widgets (using any
// `@AssistantWidgetConfig` intents from `AssistantWidgets.g.swift`) to the
// bundle below.

import SwiftUI
import WidgetKit

@main
struct AssistantWidgets: WidgetBundle {
  var body: some Widget {
    #if os(iOS)
      AssistantLiveActivityWidget()
    #endif
    assistantControlsBundle
  }
}
