/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import BackgroundTasks
import KoF22UI
import Network
import SwiftUI
import UserNotifications

/// Process-wide services shared by the SwiftUI scene, the App Intents and the
/// background task handler, so every entry point talks to the same model and store.
@MainActor
enum AppServices {
   /// True when the UI tests launched the app with `-uitest`, which swaps in the mock backend.
   static let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")

   /// The single app model, built for the UI-test context or the real app context.
   static let shared = AppModel(context: isUITest ? .uiTest : .app)
}

/// Entry point of KoF22 Post. Wires the root view to the shared model, keeps the outbox
/// moving across scene-phase changes and registers the background refresh handler.
@main
struct KoF22PostApp: App {
   /// Bridges the UIKit delegate so notification taps can be routed into the app.
   @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
   /// Current scene phase, observed to send queued posts and schedule refreshes.
   @Environment(\.scenePhase) private var scenePhase
   /// The shared app model.
   private let app = AppServices.shared
   /// Network monitor that retries the outbox when connectivity returns.
   private let connectivity = Connectivity()

   /// The main window: the root view plus the scene-phase and background-task hooks.
   var body: some Scene {
      WindowGroup {
         RootView(authenticator: BrowserAuthenticator())
            .environment(app)
            .modelContainer(app.container)
            .task {
               await app.bootstrap()
               connectivity.start { app.kickOutbox() }
            }
            .onOpenURL { app.open(url: $0) }
      }
      .onChange(of: scenePhase) { _, phase in
         switch phase {
         case .active:
            app.consumePendingRoute()
            app.kickOutbox()
         case .background:
            finishOutboxInBackground()
            OutboxRefresh.schedule()
         default:
            break
         }
      }
      .backgroundTask(.appRefresh(SharedIDs.backgroundTask)) {
         await AppServices.shared.processor.drain()
         await MainActor.run { OutboxRefresh.schedule() }
      }
   }

   /// Keeps sending for the time iOS grants after the app leaves the screen.
   private func finishOutboxInBackground() {
      var taskID = UIBackgroundTaskIdentifier.invalid
      taskID = UIApplication.shared.beginBackgroundTask(withName: "outbox") {
         UIApplication.shared.endBackgroundTask(taskID)
      }
      Task {
         await app.processor.drain()
         UIApplication.shared.endBackgroundTask(taskID)
      }
   }
}

/// Schedules background app-refresh wake-ups so queued posts are retried while the
/// app is not on screen.
enum OutboxRefresh {
   /// Minutes to wait before iOS may wake the app to retry the outbox.
   private static let retryMinutes = 15.0
   /// Seconds in a minute, for converting `retryMinutes` to a `TimeInterval`.
   private static let secondsPerMinute = 60.0

   /// Asks iOS for a later wake-up while posts are still queued.
   static func schedule() {
      Task {
         let pending: Int
         do {
            pending = try await AppServices.shared.store.pendingCount()
         }
         catch {
            Log.outbox.warning(
               "Could not count queued posts: \(error.localizedDescription, privacy: .public)")
            return
         }
         guard pending > 0 else { return }
         let request = BGAppRefreshTaskRequest(identifier: SharedIDs.backgroundTask)
         request.earliestBeginDate = Date.now.addingTimeInterval(Self.retryMinutes * Self.secondsPerMinute)
         do {
            try BGTaskScheduler.shared.submit(request)
         }
         catch {
            Log.outbox.warning(
               "Could not schedule outbox refresh: \(error.localizedDescription, privacy: .public)")
         }
      }
   }
}

/// Sends the outbox as soon as the network comes back.
final class Connectivity: @unchecked Sendable {
   /// The system path monitor that reports network status changes.
   private let monitor = NWPathMonitor()
   /// Whether the last reported path was usable; starts true so launch is not a "reconnect".
   private var wasSatisfied = true

   /// Starts monitoring and calls `onReconnect` on the main actor each time the network
   /// changes from unavailable to available.
   func start(onReconnect: @escaping @MainActor () -> Void) {
      monitor.pathUpdateHandler = { [weak self] path in
         guard let self else { return }
         let satisfied = path.status == .satisfied
         if satisfied && !self.wasSatisfied { Task { @MainActor in onReconnect() } }
         self.wasSatisfied = satisfied
      }
      monitor.start(queue: DispatchQueue(label: "com.kof22.post.connectivity"))
   }
}

/// UIKit application delegate. Its only job is notification handling: it shows banners
/// while the app is in the foreground and routes notification taps to their URL.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
   /// Registers this delegate with the notification center at launch.
   func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
   ) -> Bool {
      UNUserNotificationCenter.current().delegate = self
      return true
   }

   /// Shows notifications as banners even while the app is in the foreground.
   nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification
   ) async
      -> UNNotificationPresentationOptions
   {
      [.banner, .list]
   }

   /// Opens the URL carried by a tapped notification: app URLs route inside the app,
   /// anything else (a published post) opens in the system browser.
   nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
      guard let string = response.notification.request.content.userInfo["url"] as? String,
         let url = URL(string: string)
      else { return }
      await MainActor.run {
         if url.scheme == SharedIDs.urlScheme {
            AppServices.shared.open(url: url)
         }
         else {
            UIApplication.shared.open(url)
         }
      }
   }
}
