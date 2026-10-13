/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Observation
import SwiftData

/// Holds the service currently in use so the outbox always sends with the
/// active backend and the signed-in session.
actor ServiceBox {
   /// The signed-in service, or nil while signed out.
   var service: SiteService?

   /// Replaces the current service.
   func set(_ service: SiteService?) { self.service = service }
}

/// The tabs of the signed-in shell.
public enum AppTab: String, Hashable, Sendable {
   /// The composer.
   case compose
   /// Queued, failed and recently sent posts.
   case outbox
   /// Posts already on kof22.com.
   case posts
   /// Account, permissions and backend settings.
   case settings
}

/// Composition root shared by the app, Share Extension and App Intents.
@MainActor
@Observable
public final class AppModel {
   /// Which process owns the model, which decides storage, backend and notifications.
   public enum Context: Sendable {
      /// The iPhone app.
      case app
      /// The Share Extension: no local notifications.
      case shareExtension
      /// UI tests: mock backend in a fresh temporary directory, in-memory store.
      case uiTest
   }

   /// Blog used when neither settings nor the account name a default.
   static let fallbackBlogSlug = Post.defaultBlogSlug
   /// Shown when `/me` reports an account that is not allowed to post.
   static let cannotPostMessage =
      "This KoF22 account can't publish. It needs the kof22:publish scope and a publisher group, and its email must belong to an author."
   /// Simulated network latency of the mock backend, in milliseconds.
   private static let mockLatencyMilliseconds = 350
   /// Shown when the on-disk store cannot be opened.
   private static let storageFallbackMessage = "Local storage could not be opened; queued posts will not survive a restart."

   /// The process this model serves.
   public let context: Context
   /// Settings shared with the extensions through the app group.
   public let settings: SharedSettings
   /// The SwiftData container behind the outbox and post cache.
   public let container: ModelContainer
   /// The outbox and post cache.
   public let store: OutboxStore
   /// Sends queued posts with the current service.
   public let processor: OutboxProcessor
   /// Whether the app talks to the mock or the live API.
   public private(set) var mode: BackendMode
   /// The session for the current backend.
   public private(set) var auth: AuthSession
   /// The Site API client for the current backend.
   public private(set) var service: SiteService
   /// The on-device mock backend, kept even in live mode so switching is instant.
   public private(set) var mockBackend: MockBackend
   /// Whether a session is active.
   public private(set) var isSignedIn = false
   ////////////////////////////////////////////////////////////////////////
   // `me` mirrors the API's `/me` resource and is public API used by    //
   // other targets, so it keeps its short name.                         //
   ////////////////////////////////////////////////////////////////////////
   /// The signed-in account, its blogs and authoring limits; nil until loaded.
   public private(set) var me: Me?  // swiftlint:disable:this identifier_name
   /// Semantic version reported by the API, shown in Settings.
   public private(set) var apiVersion: String?
   /// Why the signed-in account cannot publish (a 403 from `/me`, or `canPost` false),
   /// or nil when it can. The root view shows a dedicated screen while this is set.
   public private(set) var cannotPublishReason: String?
   /// Authors the account can choose for a post, by name; empty until loaded (the
   /// composer then shows the account's own author).
   public internal(set) var authors: [AuthorRef] = []
   /// The latest error to show the user, or nil.
   public var lastError: String?
   /// The selected tab of the signed-in shell.
   public var selectedTab: AppTab = .compose
   /// Text/links handed to the composer by a Shortcut or deep link.
   public var pendingComposition: PostComposition?
   /// Whether the mock backend pretends to be offline.
   public var simulateOffline = false

   /// The service the outbox reads before each send.
   private let box = ServiceBox()
   /// Where tokens are kept: the Keychain, or memory under UI tests.
   private let secureStore: any SecureStore
   /// Where the mock backend keeps its posts and photos.
   private let mockDirectory: URL

   /// Photo rules from the account, or the backend's defaults before it loads.
   public var limits: PhotoLimits { me?.limits ?? .fallback }
   /// Blogs the account can post to, or the demo list before it loads.
   public var blogs: [BlogRef] { me?.blogs ?? MockBackend.demoBlogs }
   /// The blog last posted to, else the account default, else Quick Bits.
   public var defaultBlog: String { settings.lastBlogSlug ?? me?.defaultBlog ?? Self.fallbackBlogSlug }

   /// Builds the store, backends and outbox for `context`. A store that cannot be opened
   /// does not stop the app: it falls back to memory and sets `lastError`.
   public init(context: Context = .app) {
      self.context = context
      let defaults: UserDefaults? = context == .uiTest ? UserDefaults(suiteName: "uitest-\(UUID().uuidString)") : nil
      settings = SharedSettings(defaults: defaults)
      if context == .uiTest {
         settings.backendMode = .mock
         secureStore = MemorySecureStore()
         mockDirectory = FileManager.default.temporaryDirectory.appending(path: "uitest-mock-\(UUID().uuidString)")
      }
      else {
         secureStore = KeychainStore()
         mockDirectory = SharedContainer.mockDirectory
      }
      let opened = Self.openContainer(inMemory: context == .uiTest)
      container = opened.container
      let store = OutboxStore(modelContainer: opened.container)
      self.store = store
      let mode = settings.backendMode
      self.mode = mode
      let latency: Duration = context == .uiTest ? .zero : .milliseconds(Self.mockLatencyMilliseconds)
      let backend = MockBackend(directory: mockDirectory, latency: latency)
      mockBackend = backend
      let auth = AuthSession(mode: mode, store: secureStore)
      self.auth = auth
      service = Self.makeService(mode: mode, backend: backend, auth: auth, context: context)
      let box = box
      let sharedSettings = settings
      processor = OutboxProcessor(
         store: store,
         service: { await box.service },
         notifier: context == .shareExtension || context == .uiTest ? SilentNotifier() : LocalNotifier(),
         uploadSize: { sharedSettings.uploadSize }
      )
      if opened.isFallback {
         lastError = Self.storageFallbackMessage
      }
   }

   /// Session identifier for the Share Extension's background uploads; an extension
   /// must not reuse the app's session identifier.
   static let shareExtensionUploadSession = "com.kof22.post.uploads.share"

   /// Builds the service for `mode`. Live photo uploads use a background URLSession so
   /// they survive suspension (ADR-0007); UI tests never reach the network.
   static func makeService(mode: BackendMode, backend: MockBackend, auth: AuthSession, context: Context) -> SiteService {
      switch (mode, context) {
      case (.mock, _), (_, .uiTest):
         return .mock(backend: backend, auth: auth)
      case (.live, .shareExtension):
         return .live(auth: auth, uploader: BackgroundUploadPerformer.performer(for: shareExtensionUploadSession))
      case (.live, .app):
         return .live(auth: auth, uploader: BackgroundUploadPerformer.shared)
      }
   }

   /// Anonymous reads of published content (blogs, posts, tags), cached briefly.
   public var reads: PublicReadService { service.reads }

   /// Opens the SwiftData container. When the requested store fails, it falls back to an
   /// in-memory store and reports `isFallback` so the caller can tell the user.
   private static func openContainer(inMemory: Bool) -> (container: ModelContainer, isFallback: Bool) {
      do {
         return (try PersistenceStack.makeContainer(inMemory: inMemory), false)
      }
      catch {
         Log.storage.error("Local store could not be opened: \(error.localizedDescription, privacy: .public)")
      }
      do {
         return (try PersistenceStack.makeContainer(inMemory: true), true)
      }
      catch {
         Log.storage.error("In-memory store could not be opened: \(error.localizedDescription, privacy: .public)")
      }
      do {
         let scratch = FileManager.default.temporaryDirectory.appending(path: "fallback-\(UUID().uuidString).store")
         return (try PersistenceStack.makeContainer(url: scratch), true)
      }
      catch {
         /////////////////////////////////////////////////////////////////////////
         // Every store, including a fresh in-memory one, failed. That can only //
         // mean the schema itself is invalid: a build defect, not user state.  //
         /////////////////////////////////////////////////////////////////////////
         Log.storage.fault("No store could be opened: \(error.localizedDescription, privacy: .public)")
         preconditionFailure("SwiftData rejected the schema: \(error)")
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

   /// Signs in through `authenticator`, then loads the account and starts the outbox.
   /// A cancelled sheet leaves no message; any other failure sets `lastError`.
   public func signIn(using authenticator: any WebAuthenticator) async {
      lastError = nil
      do {
         try await auth.signIn(using: authenticator)
         isSignedIn = true
         await box.set(service)
         await refreshMe()
         if context == .app { await LocalNotifier.requestAuthorization() }
         kickOutbox()
      }
      catch AuthError.cancelled {
         Log.auth.info("Sign-in cancelled by the user")
      }
      catch {
         Log.auth.warning("Sign-in failed: \(error.localizedDescription, privacy: .public)")
         lastError = "Sign-in failed: \(ErrorClassifier.message(for: error))"
      }
   }

   /// Ends the session and stops the outbox from sending. Queued posts stay queued.
   public func signOut() async {
      await auth.signOut()
      await box.set(nil)
      isSignedIn = false
      me = nil
      authors = []
      cannotPublishReason = nil
   }

   /// Reloads the account and API version. An expired session signs out; other failures
   /// keep the last loaded account and only report when there is none.
   public func refreshMe() async {
      do {
         let account = try await service.me()
         me = account
         cannotPublishReason = account.canPost ? nil : Self.cannotPostMessage
         lastError = nil
      }
      catch {
         Log.api.warning("Account could not be loaded: \(error.localizedDescription, privacy: .public)")
         if ErrorClassifier.isForbidden(error) {
            cannotPublishReason = ErrorClassifier.message(for: error)
         }
         else if ErrorClassifier.disposition(for: error) == .needsSignIn {
            await signOut()
            lastError = "Your session expired. Sign in again."
         }
         else if me == nil {
            lastError = "Could not load your account: \(ErrorClassifier.message(for: error))"
         }
         return
      }
      await refreshAuthors()
      await refreshAPIVersion()
   }

   /// Reads the API version for Settings. It is informational, so a failure only clears
   /// the value (Settings shows a dash) and is logged.
   private func refreshAPIVersion() async {
      do {
         apiVersion = try await service.versions().appVersion
      }
      catch {
         apiVersion = nil
         Log.api.notice("API version could not be read: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// Switching backends signs out of the other one; queued items stay queued.
   public func setMode(_ newMode: BackendMode) async {
      guard newMode != mode else { return }
      await signOut()
      settings.backendMode = newMode
      mode = newMode
      auth = AuthSession(mode: newMode, store: secureStore)
      service = Self.makeService(mode: newMode, backend: mockBackend, auth: auth, context: context)
      await bootstrap()
   }

   /// Turns the mock backend's offline simulation on or off; back online, the outbox
   /// sends right away.
   public func setSimulateOffline(_ value: Bool) async {
      simulateOffline = value
      await mockBackend.setSimulateOffline(value)
      if !value { kickOutbox() }
   }

   /// Erases the mock backend's posts and photos and reloads the account.
   public func resetMockData() async {
      await mockBackend.reset()
      await refreshMe()
   }

   /// Starts sending queued posts in the background.
   public func kickOutbox() {
      Task { await processor.drain() }
   }

   /// Queues a post and starts sending. Returns the outbox id.
   @discardableResult
   public func submit(
      _ composition: PostComposition, operation: OutboxOperation = .create, serverPostID: Int64? = nil,
      ifMatch: String? = nil, replacingDraft draftID: UUID? = nil
   ) async throws -> UUID {
      settings.lastBlogSlug = composition.blog
      let id = try await store.enqueue(
         composition, operation: operation, serverPostID: serverPostID,
         ifMatch: ifMatch, replacing: draftID)
      kickOutbox()
      ///////////////////////////////////////////////////////////////
      // cached site reads would hide the new post until the cache //
      // expired, so they are dropped as soon as a post is queued. //
      ///////////////////////////////////////////////////////////////
      await service.reads.cache.removeAll()
      return id
   }

   /// Handles deep links in the app's URL scheme: selects a tab and, for `compose`, prefills
   /// text and a link from the query.
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
         let route = defaults.string(forKey: "pendingRoute")
      else { return }
      defaults.removeObject(forKey: "pendingRoute")
      guard let url = URL(string: "\(SharedIDs.urlScheme)://\(route)") else {
         Log.ui.warning("Ignored a pending route that is not a valid URL")
         return
      }
      open(url: url)
   }

   /// Resolves photo URLs, including the mock backend's local files.
   public func photoURL(_ string: String?) -> URL? {
      guard let string else { return nil }
      if let file = mockBackend.fileURL(forMockMedia: string, directory: mockDirectory) { return file }
      return URL(string: string)
   }
}

/// Authors for the composer's picker.
extension AppModel {
   /// Loads the authors for the composer's picker. Only the picker needs them, so a
   /// failure keeps the account's own author as the only choice and is logged.
   func refreshAuthors() async {
      do {
         authors = try await service.authors()
      }
      catch {
         authors = []
         Log.api.notice("Authors could not be loaded: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// The authors to offer: the loaded list, or just the account's own author.
   public var authorChoices: [AuthorRef] {
      if !authors.isEmpty { return authors }
      return me?.author.map { [$0] } ?? []
   }
}
