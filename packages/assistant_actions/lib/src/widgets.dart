/// In-app Siri and Shortcuts discovery widgets (`AssistantSiriTip` and
/// `AssistantShortcutsLink`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Visual theme for [AssistantSiriTip], matching App Intents'
/// `SiriTipViewStyle`.
enum AssistantSiriTipStyle {
  automatic,
  light,
  dark,
}

/// Visual theme for [AssistantShortcutsLink], matching App Intents'
/// `ShortcutsLinkStyle`.
enum AssistantShortcutsLinkStyle {
  automatic,
  automaticOutline,
  light,
  lightOutline,
  dark,
  darkOutline,
}

/// Embeds Apple's native Siri Tip banner for the generated App Intent with
/// [actionId] (`SiriTipUIView` on iOS via [UiKitView], `NSHostingView` on
/// macOS via [AppKitView]).
///
/// [actionId] is the Dart function or variable name of an `@AssistantAction`
/// (or a turned-on schema intent id such as `'camera.startCapture'`).
///
/// ```dart
/// AssistantSiriTip(actionId: 'pinNote')
/// ```
class AssistantSiriTip extends StatelessWidget {
  const AssistantSiriTip({
    super.key,
    required this.actionId,
    this.isVisible = true,
    this.style = AssistantSiriTipStyle.automatic,
    this.height = 76,
  });

  /// Platform view type registered by `AssistantPlatformViews.swift`.
  static const viewType = 'assistant_actions/siri_tip';

  /// Id of the generated action intent to suggest.
  final String actionId;

  /// Whether the tip is visible. When false, renders nothing.
  final bool isVisible;

  /// Color style of the tip banner.
  final AssistantSiriTipStyle style;

  /// Height reserved for the native tip view.
  final double height;

  /// Creation parameters sent to the native platform view factory.
  @visibleForTesting
  Map<String, Object?> get creationParams => {
        'actionId': actionId,
        'isVisible': isVisible,
        'style': style.name,
      };

  @override
  Widget build(BuildContext context) {
    if (!isVisible || kIsWeb) return const SizedBox.shrink();
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => SizedBox(
          key: ValueKey('$actionId:${style.name}:$isVisible'),
          height: height,
          child: UiKitView(
            viewType: viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
      TargetPlatform.macOS => SizedBox(
          key: ValueKey('$actionId:${style.name}:$isVisible'),
          height: height,
          child: AppKitView(
            viewType: viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Embeds Apple's "Open in Shortcuts" button (`ShortcutsLink` via
/// `UIHostingController` on iOS and `NSHostingView` on macOS).
///
/// ```dart
/// const AssistantShortcutsLink()
/// ```
class AssistantShortcutsLink extends StatelessWidget {
  const AssistantShortcutsLink({
    super.key,
    this.style = AssistantShortcutsLinkStyle.automatic,
    this.height = 44,
  });

  /// Platform view type registered by `AssistantPlatformViews.swift`.
  static const viewType = 'assistant_actions/shortcuts_link';

  /// Color and outline style of the Shortcuts button.
  final AssistantShortcutsLinkStyle style;

  /// Height reserved for the native button view.
  final double height;

  /// Creation parameters sent to the native platform view factory.
  @visibleForTesting
  Map<String, Object?> get creationParams => {
        'style': style.name,
      };

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => SizedBox(
          key: ValueKey(style.name),
          height: height,
          child: UiKitView(
            viewType: viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
      TargetPlatform.macOS => SizedBox(
          key: ValueKey(style.name),
          height: height,
          child: AppKitView(
            viewType: viewType,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          ),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
