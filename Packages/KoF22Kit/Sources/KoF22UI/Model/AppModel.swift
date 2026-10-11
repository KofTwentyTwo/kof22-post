import Foundation
import Observation
import SwiftData

/// Holds the service currently in use so the outbox always sends with the
/// active backend and the signed-in session.
actor ServiceBox {
    var service: SiteService?
    func set(_ service: SiteService?) { self.service = service }
}

public enum AppTab: String, Hashable, Sendable {
    case compose, outbox, posts, settings
}

/// Composition root shared by the app, Share Extension and App Intents.
@MainActor
@Observable
public final class AppModel {
    public enum Context: Sendable {
        case app
        case shareExtension
        /// UI tests: mock backend in a fresh temporary directory, in-memory store.
        case uiTest
    }

    public let context: Context
    public let settings: SharedSettings
    public let container: ModelContainer
    public let store: OutboxStore
    public let processor: OutboxProcessor
    public private(set) var mode: BackendMode
    public private(set) var auth: AuthSession
    public private(set) var service: SiteService
    public private(set) var mockBackend: MockBackend
    public private(set) var isSignedIn = false
    public private(set) var me: Me?
    public private(set) var apiVersion: String?
    public var lastError: String?
    public var selectedTab: AppTab = .compose
    /// Text/links handed to the composer by a Shortcut or deep link.
    public var pendingComposition: PostComposition?
    public var simulateOffline = false

    private let box = ServiceBox()
    private let secureStore: any SecureStore
    private let mockDirectory: URL

    public var limits: AuthoringLimits { me?.limits ?? .fallback }
    public var blogs: [BlogRef] { me?.blogs ?? MockBackend.blogs }
    public var defaultBlog: String { settings.lastBlogSlug ?? me?.defaultBlog ?? "quick-bits" }

    public init(context: Context = .app) {
        self.context = context
        let defaults: UserDefaults? = context == .uiTest ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)") : nil
        settings = SharedSettings(defaults: defaults)
        if context == .uiTest {
            settings.backendMode = .mock
            secureStore = MemorySecureStore()
            mockDirectory = FileManager.default.temporaryDirectory.appending(path: "uitest-mock-\(UUID().uuidString)")
        } else {
            secureStore = KeychainStore()
            mockDirectory = SharedContainer.mockDirectory
        }
        // A broken store must not brick the app; fall back to memory and say so.
        let persistent = try? PersistenceStack.makeContainer(inMemory: context == .uiTest)
        let container = persistent ?? (try! PersistenceStack.makeContainer(inMemory: true))
        self.container = container
        let store = OutboxStore(modelContainer: container)
        self.store = store
        let mode = settings.backendMode
        self.mode = mode
        let backend = MockBackend(directory: mockDirectory, latency: context == .uiTest ? .zero : .milliseconds(350))
        mockBackend = backend
        let auth = AuthSession(mode: mode, store: secureStore)
        self.auth = auth
        service = mode == .mock ? .mock(backend: backend, auth: auth) : .live(auth: auth)
        let box = box
        processor = OutboxProcessor(
            store: store,
            service: { await box.service },
            notifier: context == .shareExtension || context == .uiTest ? SilentNotifier() : LocalNotifier()
        )
        if persistent == nil {
            lastError = "Local storage could not be opened; queued posts will not survive a restart."
        }
    }

    /// Restores the session and starts sending anything queued.
    public func bootstrap() async {
        isSignedIn = await auth.isSignedIn
        await box.set(isSignedIn ? service : nil)
        guard isSignedIn else { return }
        await refreshMe()
        kickOutbox()
    }

    public func signIn(using authenticator: any WebAuthenticator) async {
        lastError = nil
        do {
            try await auth.signIn(using: authenticator)
            isSignedIn = true
            await box.set(service)
            await refreshMe()
            if context == .app { await LocalNotifier.requestAuthorization() }
            kickOutbox()
        } catch AuthError.cancelled {
            // User closed the sheet.
        } catch {
            lastError = "Sign-in failed: \(ErrorClassifier.message(for: error))"
        }
    }

    public func signOut() async {
        await auth.signOut()
        await box.set(nil)
        isSignedIn = false
        me = nil
    }

    public func refreshMe() async {
        do {
            me = try await service.me()
            apiVersion = try? await service.versions().versions.first?.semver
            lastError = nil
        } catch {
            if ErrorClassifier.disposition(for: error) == .needsSignIn {
                await signOut()
                lastError = "Your session expired. Sign in again."
            } else if me == nil {
                lastError = "Could not load your account: \(ErrorClassifier.message(for: error))"
            }
        }
    }

    /// Switching backends signs out of the other one; queued items stay queued.
    public func setMode(_ newMode: BackendMode) async {
        guard newMode != mode else { return }
        await signOut()
        settings.backendMode = newMode
        mode = newMode
        auth = AuthSession(mode: newMode, store: secureStore)
        service = newMode == .mock ? .mock(backend: mockBackend, auth: auth) : .live(auth: auth)
        await bootstrap()
    }

    public func setSimulateOffline(_ value: Bool) async {
        simulateOffline = value
        await mockBackend.setSimulateOffline(value)
        if !value { kickOutbox() }
    }

    public func resetMockData() async {
        await mockBackend.reset()
        await refreshMe()
    }

    public func kickOutbox() {
        Task { await processor.drain() }
    }

    /// Queues a post and starts sending. Returns the outbox id.
    @discardableResult
    public func submit(_ composition: PostComposition, operation: OutboxOperation = .create, serverPostID: Int64? = nil,
                       ifMatch: String? = nil, replacingDraft draftID: UUID? = nil) async throws -> UUID {
        settings.lastBlogSlug = composition.blog
        let id = try await store.enqueue(composition, operation: operation, serverPostID: serverPostID,
                                         ifMatch: ifMatch, replacing: draftID)
        kickOutbox()
        return id
    }

    public func open(url: URL) {
        guard url.scheme == SharedIDs.urlScheme else { return }
        switch url.host() {
        case "compose":
            selectedTab = .compose
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = items.first { $0.name == "text" }?.value ?? ""
            let link = items.first { $0.name == "link" }?.value ?? ""
            if !text.isEmpty || !link.isEmpty {
                pendingComposition = PostComposition(blog: defaultBlog, body: text, linkURL: link)
            }
        case "outbox": selectedTab = .outbox
        case "posts": selectedTab = .posts
        case "settings": selectedTab = .settings
        default: break
        }
    }

    /// Routes requested from another process (Control, widget) via shared defaults.
    public func consumePendingRoute() {
        guard let defaults = UserDefaults(suiteName: SharedIDs.appGroup),
              let route = defaults.string(forKey: "pendingRoute") else { return }
        defaults.removeObject(forKey: "pendingRoute")
        if let url = URL(string: "\(SharedIDs.urlScheme)://\(route)") { open(url: url) }
    }

    /// Resolves photo URLs, including the mock backend's local files.
    public func photoURL(_ string: String?) -> URL? {
        guard let string else { return nil }
        if let file = mockBackend.fileURL(forMockMedia: string, directory: mockDirectory) { return file }
        return URL(string: string)
    }
}
