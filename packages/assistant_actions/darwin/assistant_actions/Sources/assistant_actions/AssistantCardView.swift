import AppIntents
import Foundation
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// The result card a generated intent shows (`ShowsSnippetView`) for a Dart
/// `AssistantCard`: an image or SF Symbol, the title and subtitle, then
/// label and value rows, and buttons in an interactive snippet. Shows
/// nothing without a card.
public struct AssistantCardView: View {
  let card: AssistantCard?
  let buttons: AnyView?

  /// [card] without its buttons.
  public init(_ card: AssistantCard?) {
    self.card = card
    buttons = nil
  }

  /// [card] with its buttons, each running the intent [intent] makes for it
  /// (`Button(intent:)`). For a `SnippetIntent`'s view: elsewhere, Siri
  /// doesn't run them.
  public init<Intent: AppIntent>(_ card: AssistantCard?, intent: (AssistantCard.Button) -> Intent) {
    self.card = card
    let items = (card?.buttons ?? []).map { ($0, intent($0)) }
    buttons =
      items.isEmpty
      ? nil
      : AnyView(
        HStack(spacing: 8) {
          ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Self.button(item.0, intent: item.1).frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.bordered))
  }

  public var body: some View {
    if let card {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 12) {
          Self.image(card)
          VStack(alignment: .leading, spacing: 2) {
            Text(card.title).font(.headline)
            if let subtitle = card.subtitle {
              Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        if !card.rows.isEmpty {
          Divider()
          ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
            HStack(alignment: .firstTextBaseline) {
              Text(row.label).foregroundStyle(.secondary)
              Spacer(minLength: 12)
              Text(row.value).multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
          }
        }
        if let buttons {
          buttons.padding(.top, 4)
        }
      }
      .padding()
    }
  }

  @ViewBuilder
  private static func button(_ button: AssistantCard.Button, intent: some AppIntent) -> some View {
    let role: ButtonRole? = button.destructive ? .destructive : nil
    if let symbol = button.systemImage {
      Button(role: role, intent: intent) {
        Label(button.title, systemImage: symbol).frame(maxWidth: .infinity)
      }
    } else {
      Button(role: role, intent: intent) {
        Text(button.title).frame(maxWidth: .infinity)
      }
    }
  }

  /// The card's image file, else its SF Symbol, else nothing. Snippets are
  /// drawn once, so the file is read now.
  @ViewBuilder
  private static func image(_ card: AssistantCard) -> some View {
    if let path = card.imagePath, let image = loadImage(path) {
      image.resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
    } else if let symbol = card.systemImage {
      Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36, height: 36)
    }
  }

  private static func loadImage(_ path: String) -> Image? {
    #if os(iOS)
      return UIImage(contentsOfFile: path).map { Image(uiImage: $0) }
    #elseif os(macOS)
      return NSImage(contentsOfFile: path).map { Image(nsImage: $0) }
    #else
      return nil
    #endif
  }
}
