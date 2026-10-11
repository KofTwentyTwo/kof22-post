import AppIntents
import SwiftUI
import WidgetKit

@main
struct KoF22WidgetBundle: WidgetBundle {
   var body: some Widget {
      QuickComposeWidget()
      ComposeControl()
   }
}

/// Control Center / Lock Screen / Action Button: open the composer.
struct ComposeControl: ControlWidget {
   var body: some ControlWidgetConfiguration {
      StaticControlConfiguration(kind: "com.kof22.post.compose") {
         ControlWidgetButton(action: OpenComposeIntent()) {
            Label("New Field Note", systemImage: "square.and.pencil")
         }
      }
      .displayName("New Field Note")
      .description("Open KoF22 Post ready to write.")
   }
}

struct QuickComposeEntry: TimelineEntry {
   let date: Date
}

struct QuickComposeProvider: TimelineProvider {
   func placeholder(in context: Context) -> QuickComposeEntry { QuickComposeEntry(date: .now) }
   func getSnapshot(in context: Context, completion: @escaping (QuickComposeEntry) -> Void) { completion(QuickComposeEntry(date: .now)) }
   func getTimeline(in context: Context, completion: @escaping (Timeline<QuickComposeEntry>) -> Void) {
      completion(Timeline(entries: [QuickComposeEntry(date: .now)], policy: .never))
   }
}

/// Home and Lock Screen shortcut into the composer.
struct QuickComposeWidget: Widget {
   var body: some WidgetConfiguration {
      StaticConfiguration(kind: "QuickCompose", provider: QuickComposeProvider()) { _ in
         QuickComposeView()
            .widgetURL(URL(string: "com.kof22.post://compose"))
            .containerBackground(for: .widget) { Color(red: 0.035, green: 0.035, blue: 0.043) }
      }
      .configurationDisplayName("Quick post")
      .description("Start a Field Note.")
      .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
   }
}

struct QuickComposeView: View {
   @Environment(\.widgetFamily) private var family
   private let green = Color(red: 0.204, green: 0.827, blue: 0.6)

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
         VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
               ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 7, height: 7) }
            }
            Spacer()
            Text("james@kof22:~").font(.system(.caption2, design: .monospaced)).foregroundStyle(.gray)
            HStack(spacing: 0) {
               Text("$ ").foregroundStyle(green)
               Text("post").foregroundStyle(.white)
               Text("_").foregroundStyle(green)
            }
            .font(.system(.title3, design: .monospaced, weight: .bold))
            Text("Field Notes").font(.system(.caption, design: .monospaced)).foregroundStyle(.gray)
         }
         .frame(maxWidth: .infinity, alignment: .leading)
      }
   }
}
