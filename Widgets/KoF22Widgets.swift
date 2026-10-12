/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import AppIntents
import SwiftUI
import WidgetKit

/// Entry point of the widget extension: the Home/Lock Screen widget and the Control.
@main
struct KoF22WidgetBundle: WidgetBundle {
   /// Every widget and control the extension provides.
   var body: some Widget {
      QuickComposeWidget()
      ComposeControl()
   }
}

/// Control Center / Lock Screen / Action Button: open the composer.
struct ComposeControl: ControlWidget {
   /// A single button that runs `OpenComposeIntent`.
   var body: some ControlWidgetConfiguration {
      StaticControlConfiguration(kind: "com.kof22.post.compose") {
         ControlWidgetButton(action: OpenComposeIntent()) {
            Label("New Field Note", systemImage: "square.and.pencil")
         }
      }
      .displayName("New Field Note")
      .description("Open KoF22 Postr ready to write.")
   }
}

/// Timeline entry for the quick-compose widget. The widget is static, so the entry
/// carries only the date WidgetKit requires.
struct QuickComposeEntry: TimelineEntry {
   /// When the entry applies.
   let date: Date
}

/// Supplies a single, never-refreshing entry: the widget content does not change.
struct QuickComposeProvider: TimelineProvider {
   /// Placeholder shown while the widget loads.
   func placeholder(in context: Context) -> QuickComposeEntry { QuickComposeEntry(date: .now) }

   /// Snapshot for the widget gallery.
   func getSnapshot(in context: Context, completion: @escaping (QuickComposeEntry) -> Void) { completion(QuickComposeEntry(date: .now)) }

   /// One entry with a `.never` policy, since nothing on the widget changes over time.
   func getTimeline(in context: Context, completion: @escaping (Timeline<QuickComposeEntry>) -> Void) {
      completion(Timeline(entries: [QuickComposeEntry(date: .now)], policy: .never))
   }
}

/// Home and Lock Screen shortcut into the composer.
struct QuickComposeWidget: Widget {
   /// Deep link that opens the app on the composer.
   private static let composeURL = WidgetURL.make("com.kof22.post://compose")

   /// Static configuration for the small Home Screen and accessory families.
   var body: some WidgetConfiguration {
      StaticConfiguration(kind: "QuickCompose", provider: QuickComposeProvider()) { _ in
         QuickComposeView()
            .widgetURL(Self.composeURL)
            .containerBackground(for: .widget) { WidgetPalette.background }
      }
      .configurationDisplayName("Quick post")
      .description("Start a Field Note.")
      .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
   }
}

/// Colours of the terminal-style widget, matching the app theme. The widget extension
/// does not link the UI kit, so they are repeated here.
enum WidgetPalette {
   /// sRGB components of the zinc-950 background.
   private static let backgroundRGB = (red: 0.035, green: 0.035, blue: 0.043)
   /// sRGB components of the emerald prompt colour.
   private static let promptRGB = (red: 0.204, green: 0.827, blue: 0.6)

   /// Near-black terminal background.
   static let background = Color(red: backgroundRGB.red, green: backgroundRGB.green, blue: backgroundRGB.blue)
   /// Prompt green used for `$` and the cursor.
   static let prompt = Color(red: promptRGB.red, green: promptRGB.green, blue: promptRGB.blue)
   /// Opacity of the window-control dots.
   static let dotOpacity = 0.8
}

/// Builds the widget's constant URLs without force-unwrapping.
enum WidgetURL {
   /// Returns the URL for a literal fixed at compile time; a malformed literal is a
   /// programming error and stops with a message.
   static func make(_ literal: StaticString) -> URL {
      guard let url = URL(string: "\(literal)") else {
         preconditionFailure("Invalid URL literal: \(literal)")
      }
      return url
   }
}

/// The widget face: a small terminal window on Home Screen and compact text on the
/// Lock Screen accessory families.
struct QuickComposeView: View {
   /// Vertical spacing between the rows of the small widget.
   private static let rowSpacing: CGFloat = 6
   /// Spacing between the window-control dots.
   private static let dotSpacing: CGFloat = 4
   /// Diameter of each window-control dot.
   private static let dotSize: CGFloat = 7

   /// The family the widget is being rendered for.
   @Environment(\.widgetFamily) private var family

   /// Picks the layout for the current family.
   var body: some View {
      switch family {
      case .accessoryCircular:
         ZStack {
            AccessoryWidgetBackground()
            Text("$_").font(.system(.title3, design: .monospaced, weight: .bold))
         }
         .accessibilityLabel("New Field Note")
      case .accessoryRectangular:
         VStack(alignment: .leading) {
            Text("kof22").font(.system(.caption, design: .monospaced)).widgetAccentable()
            Text("$ post_").font(.system(.headline, design: .monospaced, weight: .bold))
         }
      case .accessoryInline:
         Label("New Field Note", systemImage: "square.and.pencil")
      default:
         terminal
      }
   }

   /// The small Home Screen widget: window dots, prompt and blog name.
   private var terminal: some View {
      VStack(alignment: .leading, spacing: Self.rowSpacing) {
         HStack(spacing: Self.dotSpacing) {
            ForEach([Color.red, .yellow, .green], id: \.self) {
               Circle().fill($0.opacity(WidgetPalette.dotOpacity)).frame(width: Self.dotSize, height: Self.dotSize)
            }
         }
         Spacer()
         Text("james@kof22:~").font(.system(.caption2, design: .monospaced)).foregroundStyle(.gray)
         HStack(spacing: 0) {
            Text("$ ").foregroundStyle(WidgetPalette.prompt)
            Text("post").foregroundStyle(.white)
            Text("_").foregroundStyle(WidgetPalette.prompt)
         }
         .font(.system(.title3, design: .monospaced, weight: .bold))
         Text("Field Notes").font(.system(.caption, design: .monospaced)).foregroundStyle(.gray)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
   }
}
