// Written once by `dart run assistant_actions:install --widgets`; it's yours
// to edit, and later runs leave it alone.
//
// The widget extension's entry point. It draws the Live Activities Dart
// starts (AssistantLiveActivityWidget). Add your own widgets, and on iOS 18
// Control Center controls, to the bundle. Their App Intents must be compiled
// into this extension: it can't link Flutter or the generated
// assistant_actions_app plugin. See the assistant_actions README, "Controls
// and widgets".

import SwiftUI
import WidgetKit

@main
struct AssistantWidgets: WidgetBundle {
  var body: some Widget {
    AssistantLiveActivityWidget()
  }
}
