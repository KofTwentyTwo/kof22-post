import BackgroundTasks
import KoF22UI
import Network
import SwiftUI
import UserNotifications

@MainActor
enum AppServices {
    static let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")
    static let shared = AppModel(context: isUITest ? .uiTest : .app)
}

@main
struct KoF22PostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    private let app = AppServices.shared
    private let connectivity = Connectivity()

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

enum OutboxRefresh {
    /// Asks iOS for a later wake-up while posts are still queued.
    static func schedule() {
        Task {
            guard let pending = try? await AppServices.shared.store.pendingCount(), pending > 0 else { return }
            let request = BGAppRefreshTaskRequest(identifier: SharedIDs.backgroundTask)
            request.earliestBeginDate = Date.now.addingTimeInterval(15 * 60)
            try? BGTaskScheduler.shared.submit(request)
        }
    }
}

/// Sends the outbox as soon as the network comes back.
final class Connectivity: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true

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

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run {
            if url.scheme == SharedIDs.urlScheme {
                AppServices.shared.open(url: url)
            } else {
                UIApplication.shared.open(url)
            }
        }
    }
}
