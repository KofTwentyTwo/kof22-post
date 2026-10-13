/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Posts outcome notifications (the app uses local notifications).
public protocol OutboxNotifier: Sendable {
   /// A post was accepted by the server.
   func posted(summary: String, status: PostStatus, url: String?) async
   /// A post stopped and needs the user (it will not retry on its own).
   func failed(summary: String, message: String) async
}

/// A notifier that tells nobody, for extensions and tests.
public struct SilentNotifier: OutboxNotifier {
   /// Creates the notifier.
   public init() {}
   /// Ignores the success.
   public func posted(summary: String, status: PostStatus, url: String?) async {}
   /// Ignores the failure.
   public func failed(summary: String, message: String) async {}
}

/// Sends queued items: uploads photos (create ticket, PUT, complete), then creates,
/// updates or deletes the post. Every step is retry-safe:
///   - a create that is retried after a lost response finds the post the first attempt
///     made (`SiteService.createPost`) instead of creating a second one;
///   - an expired presigned URL restarts that photo's upload;
///   - uploaded `mediaId`s are written back before the post call, so a retry
///     never uploads a photo twice;
///   - updates and deletes check the post's version first, and a 412 stops for the
///     user instead of overwriting.
public actor OutboxProcessor {
   /// Supplies the service for the current sign-in, or nil when there is none.
   public typealias ServiceProvider = @Sendable () async -> SiteService?

   /// The outbox store; every state change goes through it.
   let store: OutboxStore
   /// Supplies the API service at the start of each pass.
   private let service: ServiceProvider
   /// Reports successes and stops to the user.
   private let notifier: any OutboxNotifier
   /// Where queued photos are kept.
   let photosDirectory: URL
   /// Photos prepared for upload. They stay until the photo's media id is recorded,
   /// because a background upload can outlive the process that started it.
   let workDirectory: URL
   /// The upload size preference, read at each upload so a change applies at once.
   let uploadSize: @Sendable () -> UploadSizePreference
   /// A random number in 0...1 for backoff jitter, injected so tests are deterministic.
   private let random: @Sendable () -> Double
   /// The clock, injected so tests control backoff deadlines.
   let now: @Sendable () -> Date
   /// The pass in progress, if any.
   private var current: Task<Void, Never>?
   /// Set when a drain arrives during a pass, asking for one more.
   private var rerun = false
   /// The server's photo rules, fetched once per processor before the first upload.
   private var limits: PhotoLimits?

   /// Attempts before an item stops retrying on its own.
   public static let maxAutomaticAttempts = 6
   /// Delay before the first automatic retry; it doubles with each attempt.
   static let initialBackoff: TimeInterval = 5
   /// Factor by which the retry delay grows per attempt.
   static let backoffGrowth: Double = 2
   /// Longest delay between automatic retries (15 minutes).
   static let maximumBackoff: TimeInterval = 900
   /// The smallest jitter factor: a delay is spread over 75%...125% of the base.
   static let minimumJitterFactor = 0.75
   /// The width of the jitter range around the base delay (±25%).
   static let jitterSpan = 0.5
   /// Prepared files left behind by deleted or abandoned items are removed after this
   /// long (7 days).
   static let workFileRetention: TimeInterval = 604_800
   /// Status used for an item that cannot be sent as stored (missing id or version).
   static let badRequestStatus = 400
   /// Status of a delete whose post is already gone.
   static let notFoundStatus = 404
   /// Status used when a queued photo's file has disappeared from the device.
   static let goneStatus = 410

   /// The shared folder for prepared photos, in the App Group so the app and the Share
   /// Extension see the same files.
   public static var defaultWorkDirectory: URL { SharedContainer.directory("Upload Work") }

   /// Creates a processor. `uploadSize` is read at each upload (the app passes the
   /// `SharedSettings` value); folders, the random source and the clock are injectable
   /// for tests.
   public init(
      store: OutboxStore, service: @escaping ServiceProvider, notifier: any OutboxNotifier = SilentNotifier(),
      photosDirectory: URL = SharedContainer.photosDirectory,
      workDirectory: URL = OutboxProcessor.defaultWorkDirectory,
      uploadSize: @escaping @Sendable () -> UploadSizePreference = { .original },
      random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
      now: @escaping @Sendable () -> Date = { .now }
   ) {
      self.store = store
      self.service = service
      self.notifier = notifier
      self.photosDirectory = photosDirectory
      self.workDirectory = workDirectory
      self.uploadSize = uploadSize
      self.random = random
      self.now = now
   }

   /// The base retry delay after `attempt` failures: 5 s, doubling, capped at 15 minutes.
   static func backoff(attempt: Int) -> TimeInterval {
      min(pow(backoffGrowth, Double(max(attempt - 1, 0))) * initialBackoff, maximumBackoff)
   }

   /// The base delay spread by ±25% with `random` (0...1, clamped), still capped at 15
   /// minutes, so many failed items do not all retry at the same instant.
   static func backoff(attempt: Int, random: Double) -> TimeInterval {
      let factor = minimumJitterFactor + jitterSpan * min(max(random, 0), 1)
      return min(backoff(attempt: attempt) * factor, maximumBackoff)
   }

   /// Sends everything that is due and returns when the outbox is idle. A call
   /// that arrives during a run asks for one more pass and waits for it, so
   /// background tasks, the Share Extension and intents can rely on the await.
   public func drain() async {
      if let current {
         rerun = true
         await current.value
         return
      }
      let task = Task { await self.runPasses() }
      current = task
      await task.value
   }

   /// Runs passes until no drain asked for another one.
   private func runPasses() async {
      repeat {
         rerun = false
         guard let service = await service() else { break }
         let items = await bestEffort("list due items", systemic: true, otherwise: []) { [store, now] in try await store.due(now: now()) }
         for item in items {
            await process(item, service: service)
         }
         await bestEffort("prune sent items", systemic: true) { [store] in try await store.pruneSent() }
         sweepWorkDirectory()
      } while rerun
      //////////////////////////////////////////////////////////////////
      // No suspension between the last `rerun` check and this reset. //
      //////////////////////////////////////////////////////////////////
      current = nil
   }

   /// Sends one item and records the outcome on it.
   func process(_ candidate: OutboxSnapshot, service: SiteService) async {
      ////////////////////////////////////////////////////////////////////////////
      // Re-read and claim: the user may have deleted or edited it since due(). //
      ////////////////////////////////////////////////////////////////////////////
      guard let item = await bestEffort("claim \(candidate.id)", otherwise: nil, { [store] in try await store.claim(candidate.id) }) else {
         return
      }
      do {
         switch item.operation {
         case .delete: try await sendDelete(item, service: service)
         case .create, .update: try await sendPost(item, service: service)
         }
      }
      catch {
         await recordFailure(item, error: error)
      }
   }

   /// Deletes the post. A post that is already gone counts as deleted.
   private func sendDelete(_ item: OutboxSnapshot, service: SiteService) async throws {
      guard let postID = item.serverPostID else {
         throw APIError(status: Self.badRequestStatus, code: "bad_request", message: "Missing post id")
      }
      do {
         try await service.deletePost(id: postID, ifMatch: item.ifMatch)
      }
      catch let error as APIError where error.status == Self.notFoundStatus {
         Log.outbox.info("Post \(postID, privacy: .public) was already deleted")
      }
      await bestEffort("forget cached post \(postID)") { [store] in try await store.removeCached(postID) }
      try await store.update(item.id) { stored in
         stored.state = .sent
         stored.phase = nil
         stored.progress = 1
      }
   }

   /// Uploads pending photos, then creates or updates the post, caches the result,
   /// hands the new version to later queued edits and removes the local photos.
   private func sendPost(_ item: OutboxSnapshot, service: SiteService) async throws {
      let composition = try await uploadPhotos(item, service: service)
      let post: Post
      if item.operation == .create {
         post = try await service.createPost(composition.draft())
      }
      else {
         guard let postID = item.serverPostID, let ifMatch = item.ifMatch else {
            throw APIError(status: Self.badRequestStatus, code: "bad_request", message: "Missing post id or version")
         }
         post = try await service.updatePost(id: postID, composition.draft(), ifMatch: ifMatch)
      }
      await bestEffort("cache post \(post.id)") { [store] in try await store.cache([post]) }
      await bestEffort("carry version of post \(post.id) forward") { [store] in
         try await store.carryForward(postID: post.id, version: post.version, excluding: item.id)
      }
      try await store.update(item.id) { stored in
         stored.state = .sent
         stored.phase = nil
         stored.progress = 1
         stored.serverPostID = post.id
         stored.ifMatch = post.version
         stored.resultURL = post.url
      }
      for photo in composition.photos {
         if let url = photo.localURL(in: photosDirectory) {
            ///////////////////////////////////////////////////////////
            // An earlier attempt may already have removed the file. //
            ///////////////////////////////////////////////////////////
            try? FileManager.default.removeItem(at: url)
         }
      }
      await notifier.posted(summary: composition.summary, status: post.status, url: post.url)
   }

   /// The server's photo rules, fetched on first use and then reused.
   func currentLimits(_ service: SiteService) async throws -> PhotoLimits {
      if let limits { return limits }
      let fetched = try await service.me().limits
      limits = fetched
      return fetched
   }

   /// Records a failed attempt: retryable failures are queued again with a backoff
   /// (or the server's `Retry-After`) until `maxAutomaticAttempts`; a 412 becomes a
   /// conflict for the user; everything else stops and notifies.
   private func recordFailure(_ item: OutboxSnapshot, error: any Error) async {
      let message = ErrorClassifier.message(for: error)
      let disposition = ErrorClassifier.disposition(for: error)
      let attempts = item.attempts + 1
      let instant = now()
      var retryDelay: TimeInterval?
      if case .retryLater(let after) = disposition, attempts < Self.maxAutomaticAttempts {
         retryDelay = after ?? Self.backoff(attempt: attempts, random: random())
      }
      Log.outbox.warning("Send of \(item.id, privacy: .public) failed (attempt \(attempts, privacy: .public)): \(message, privacy: .private)")
      let delay = retryDelay
      await bestEffort("record failure of \(item.id)") { [store] in
         try await store.update(item.id) { stored in
            stored.attempts = attempts
            stored.lastError = message
            stored.phase = nil
            if let delay {
               stored.state = .queued
               stored.nextAttemptAt = instant.addingTimeInterval(delay)
            }
            else if disposition == .conflict {
               stored.state = .failed
               stored.isConflict = true
               stored.lastError = "This post changed on the server since you opened it."
            }
            else {
               stored.state = .failed
            }
         }
      }
      if retryDelay == nil {
         await notifier.failed(summary: item.composition.summary, message: message)
      }
   }

   /// Resolves a 412 by taking the server's current version and sending again.
   public func overwrite(_ id: UUID) async {
      guard let service = await service(),
         let item = await bestEffort("read \(id) for overwrite", otherwise: nil, { [store] in try await store.snapshot(id) }),
         let postID = item.serverPostID
      else { return }
      do {
         let current = try await service.post(id: postID)
         try await store.update(id) { stored in
            stored.ifMatch = current.version
            stored.isConflict = false
            stored.state = .queued
            stored.attempts = 0
            stored.nextAttemptAt = nil
            stored.lastError = nil
         }
         await drain()
      }
      catch {
         await recordFailure(item, error: error)
      }
   }

   /// Runs a store call whose failure must not stop the outbox, logging the failure
   /// instead of dropping it.
   func bestEffort(_ action: String, systemic: Bool = false, _ body: @Sendable () async throws -> Void) async {
      await bestEffort(action, systemic: systemic, otherwise: (), body)
   }

   /// Runs a store call whose failure must not stop the outbox, and logs the failure
   /// instead of dropping it: `systemic` failures (the store cannot be read at all)
   /// log as errors, a failure affecting one item as a warning. Returns `fallback` on
   /// failure.
   func bestEffort<Value: Sendable>(
      _ action: String, systemic: Bool = false, otherwise fallback: Value, _ body: @Sendable () async throws -> Value
   ) async -> Value {
      do {
         return try await body()
      }
      catch {
         if systemic {
            Log.outbox.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
         }
         else {
            Log.outbox.warning("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
         }
         return fallback
      }
   }
}
