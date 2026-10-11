import AppIntents
import Foundation

/// Opens the app on the composer. Compiled into the app and the widget extension
/// (the Control runs it), so it only leaves a note in the shared defaults; the app
/// reads it when it becomes active.
struct OpenComposeIntent: AppIntent {
   static let title: LocalizedStringResource = "New Field Note"
   static let description = IntentDescription("Open KoF22 Post ready to write.")
   static let openAppWhenRun = true

   func perform() async throws -> some IntentResult {
      UserDefaults(suiteName: "group.com.kof22.post")?.set("compose", forKey: "pendingRoute")
      return .result()
   }
}
