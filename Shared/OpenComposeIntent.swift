/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import AppIntents
import Foundation
import OSLog

/// Opens the app on the composer. Compiled into the app and the widget extension
/// (the Control runs it), so it only leaves a note in the shared defaults; the app
/// reads it when it becomes active.
struct OpenComposeIntent: AppIntent {
   /// Name shown in Shortcuts, Siri and the Control Center gallery.
   static let title: LocalizedStringResource = "New Field Note"
   /// Explanation shown under the action in Shortcuts.
   static let description = IntentDescription("Open KoF22 Postr ready to write.")
   /// The composer lives in the app, so running the intent brings the app forward.
   static let openAppWhenRun = true

   /// App group shared by the app and its extensions.
   private static let appGroup = "group.com.kof22.post"
   /// Shared-defaults key the app reads to decide which screen to show on activation.
   private static let routeKey = "pendingRoute"
   /// Route value that asks the app to open the composer.
   private static let composeRoute = "compose"
   /// Logger for this file; the widget extension does not link the kit's `Log`.
   private static let logger = Logger(subsystem: "com.kof22.post", category: "intents")

   /// Records the compose route in the shared defaults for the app to pick up.
   func perform() async throws -> some IntentResult {
      guard let defaults = UserDefaults(suiteName: Self.appGroup) else {
         Self.logger.error("App group defaults \(Self.appGroup, privacy: .public) are unavailable")
         return .result()
      }
      defaults.set(Self.composeRoute, forKey: Self.routeKey)
      return .result()
   }
}
