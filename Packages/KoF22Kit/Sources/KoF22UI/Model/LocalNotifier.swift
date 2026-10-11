import Foundation
import UserNotifications

/// Local notifications when a queued post is published or needs attention.
public struct LocalNotifier: OutboxNotifier {
   public init() {}

   public static func requestAuthorization() async {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
   }

   public func posted(summary: String, status: PostStatus, url: String?) async {
      let verb =
         switch status {
         case .published: "Posted"
         case .scheduled: "Scheduled"
         case .draft: "Draft saved"
         }
      await deliver(title: verb, body: summary, url: url)
   }

   public func failed(summary: String, message: String) async {
      await deliver(title: "Couldn't post", body: "\(summary): \(message)", url: "\(SharedIDs.urlScheme)://outbox")
   }

   private func deliver(title: String, body: String, url: String?) async {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if let url { content.userInfo = ["url": url] }
      let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
      try? await UNUserNotificationCenter.current().add(request)
   }
}
