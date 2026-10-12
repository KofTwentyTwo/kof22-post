/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import UserNotifications

/// Local notifications when a queued post is published or needs attention.
public struct LocalNotifier: OutboxNotifier {
   /// Creates a notifier that posts through the current notification center.
   public init() {}

   /// Asks for alert and sound permission. A refusal is not an error: posting still works
   /// without notifications, so the outcome is only logged.
   public static func requestAuthorization() async {
      do {
         let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         Log.ui.info("Notification permission granted: \(granted, privacy: .public)")
      }
      catch {
         Log.ui.warning("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// Announces that a post reached the server, with a verb that matches its status.
   public func posted(summary: String, status: PostStatus, url: String?) async {
      let verb =
         switch status {
         case .published: "Posted"
         case .scheduled: "Scheduled"
         case .draft: "Draft saved"
         }
      await deliver(title: verb, body: summary, url: url)
   }

   /// Announces that a post needs attention; tapping it opens the Outbox.
   public func failed(summary: String, message: String) async {
      await deliver(title: "Couldn't post", body: "\(summary): \(message)", url: "\(SharedIDs.urlScheme)://outbox")
   }

   /// Schedules an immediate notification. A notification that cannot be added is logged
   /// and dropped, because the Outbox already shows the same outcome.
   private func deliver(title: String, body: String, url: String?) async {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if let url { content.userInfo = ["url": url] }
      let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
      do {
         try await UNUserNotificationCenter.current().add(request)
      }
      catch {
         Log.ui.warning("Local notification could not be added: \(error.localizedDescription, privacy: .public)")
      }
   }
}
