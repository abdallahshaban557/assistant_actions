// Native platform views backing `AssistantSiriTip` and `AssistantShortcutsLink`,
// plus the `"shortcuts.open"` host call for `AssistantActions.openShortcutsApp()`.

import AppIntents
import Foundation
import SwiftUI

#if os(iOS) && canImport(UIKit)
  import UIKit
#elseif os(macOS) && canImport(AppKit)
  import AppKit
#endif

#if os(iOS) && canImport(Flutter)
  import Flutter
#elseif os(macOS) && canImport(FlutterMacOS)
  import FlutterMacOS
#endif

/// Implemented by generated code (`@objc(AssistantActionsAppIntents)`) so
/// `AssistantSiriTip` can resolve an `AppIntent` instance and display metadata
/// by action id.
@objc public protocol AssistantIntentProvider {
  @MainActor static func intent(forActionId actionId: String) -> Any?
  @MainActor static func shortcutPhrase(forActionId actionId: String) -> String?
  @MainActor static func actionTitle(forActionId actionId: String) -> String?
}

@MainActor
public enum AssistantPlatformViews {
  public static let siriTipViewType = "assistant_actions/siri_tip"
  public static let shortcutsLinkViewType = "assistant_actions/shortcuts_link"
  static let providerClassName = "AssistantActionsAppIntents"

  public static func provider() -> AssistantIntentProvider.Type? {
    NSClassFromString(providerClassName) as? AssistantIntentProvider.Type
  }

  @discardableResult
  public static func openShortcutsApp() -> Bool {
    guard let url = URL(string: "shortcuts://") else { return false }
    #if os(iOS) && canImport(UIKit)
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    #elseif os(macOS) && canImport(AppKit)
      return NSWorkspace.shared.open(url)
    #else
      return false
    #endif
  }

  static func registerHostCalls() {
    AssistantHostCalls.register("shortcuts.open") { _ in openShortcutsApp() }
  }

  #if os(iOS) && canImport(Flutter)
    static func register(with registrar: FlutterPluginRegistrar) {
      registrar.register(AssistantSiriTipFactory(), withId: siriTipViewType)
      registrar.register(AssistantShortcutsLinkFactory(), withId: shortcutsLinkViewType)
    }
  #elseif os(macOS) && canImport(FlutterMacOS)
    static func register(with registrar: FlutterPluginRegistrar) {
      registrar.register(AssistantMacSiriTipFactory(), withId: siriTipViewType)
      registrar.register(AssistantMacShortcutsLinkFactory(), withId: shortcutsLinkViewType)
    }
  #endif
}

#if os(iOS) && canImport(Flutter)
  private final class AssistantSiriTipFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
      withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
      let dict = (args as? [String: Any]) ?? [:]
      return MainActor.assumeIsolated {
        AssistantSiriTipPlatformView(frame: frame, params: dict)
      }
    }
  }

  private final class AssistantSiriTipPlatformView: NSObject, FlutterPlatformView {
    private let container: UIView

    @MainActor
    init(frame: CGRect, params: [String: Any]) {
      let actionId = params["actionId"] as? String ?? ""
      let isVisible = (params["isVisible"] as? Bool) ?? true
      let styleName = params["style"] as? String ?? "automatic"
      let tipStyle: SiriTipViewStyle =
        switch styleName {
        case "light": .light
        case "dark": .dark
        default: .automatic
        }
      let tipView = SiriTipUIView(style: tipStyle)
      tipView.frame = frame
      tipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      if isVisible, let candidate = AssistantPlatformViews.provider()?.intent(forActionId: actionId) as? any AppIntent {
        Self.attachIntent(tipView, intent: candidate)
      } else {
        tipView.isHidden = true
      }
      self.container = tipView
      super.init()
    }

    func view() -> UIView { container }

    @MainActor
    private static func attachIntent<I: AppIntent>(_ view: SiriTipUIView, intent: I) {
      view.setIntent(intent: intent)
    }
  }

  private final class AssistantShortcutsLinkFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
      withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
      let dict = (args as? [String: Any]) ?? [:]
      return MainActor.assumeIsolated {
        AssistantShortcutsLinkPlatformView(frame: frame, params: dict)
      }
    }
  }

  private final class AssistantShortcutsLinkPlatformView: NSObject, FlutterPlatformView {
    private let controller: UIViewController
    private let hostedView: UIView

    @MainActor
    init(frame: CGRect, params: [String: Any]) {
      let styleName = params["style"] as? String ?? "automatic"
      let linkStyle: ShortcutsLinkStyle =
        switch styleName {
        case "automaticOutline": .automaticOutline
        case "light": .light
        case "lightOutline": .lightOutline
        case "dark": .dark
        case "darkOutline": .darkOutline
        default: .automatic
        }
      let hosting = UIHostingController(rootView: ShortcutsLink().shortcutsLinkStyle(linkStyle))
      hosting.view.frame = frame
      hosting.view.backgroundColor = .clear
      hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      self.controller = hosting
      self.hostedView = hosting.view
      super.init()
    }

    func view() -> UIView { hostedView }
  }
#elseif os(macOS) && canImport(FlutterMacOS)
  private final class AssistantMacSiriTipFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
      FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
      let dict = (args as? [String: Any]) ?? [:]
      return MainActor.assumeIsolated {
        let actionId = dict["actionId"] as? String ?? ""
        let isVisible = (dict["isVisible"] as? Bool) ?? true
        let styleName = dict["style"] as? String ?? "automatic"
        let provider = AssistantPlatformViews.provider()
        let hasIntent = provider?.intent(forActionId: actionId) != nil
        let phrase = provider?.shortcutPhrase(forActionId: actionId)
        let title = provider?.actionTitle(forActionId: actionId)
        return NSHostingView(
          rootView: AssistantMacSiriTipBanner(
            phrase: phrase,
            title: title,
            isVisible: isVisible && hasIntent,
            style: styleName))
      }
    }
  }

  private struct AssistantMacSiriTipBanner: View {
    let phrase: String?
    let title: String?
    let isVisible: Bool
    let style: String

    var body: some View {
      if isVisible {
        let prompt = phrase ?? title ?? "Siri"
        HStack(spacing: 10) {
          Image(systemName: "waveform.circle.fill")
            .font(.title2)
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text("Siri")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Say \"\(prompt)\"")
              .font(.callout.weight(.medium))
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .preferredColorScheme(style == "dark" ? .dark : style == "light" ? .light : nil)
      }
    }
  }

  private final class AssistantMacShortcutsLinkFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
      FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
      let dict = (args as? [String: Any]) ?? [:]
      let styleName = dict["style"] as? String ?? "automatic"
      return MainActor.assumeIsolated {
        NSHostingView(rootView: AssistantMacShortcutsLinkView(style: styleName))
      }
    }
  }

  private struct AssistantMacShortcutsLinkView: View {
    let style: String

    var body: some View {
      Button {
        AssistantPlatformViews.openShortcutsApp()
      } label: {
        Label("Open in Shortcuts", systemImage: "square.stack.3d.up.fill")
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
      }
      .buttonStyle(.bordered)
      .preferredColorScheme(style.hasPrefix("dark") ? .dark : style.hasPrefix("light") ? .light : nil)
    }
  }
#endif
