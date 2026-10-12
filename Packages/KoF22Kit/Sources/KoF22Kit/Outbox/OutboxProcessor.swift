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
///   - creates and upload tickets carry idempotency keys derived from the item;
///   - uploaded `mediaId`s are written back before the post call, so a retry
///     never uploads a photo twice;
///   - updates send `If-Match`, and a 412 stops for the user instead of overwriting.
public actor OutboxProcessor {
   /// Supplies the service for the current sign-in, or nil when there is none.
   public typealias ServiceProvider = @Sendable () async -> SiteService?

   /// The outbox store; every state change goes through it.
   private let store: OutboxStore
   /// Supplies the API service at the start of each pass.
   private let service: ServiceProvider
   /// Reports successes and stops to the user.
   private let notifier: any OutboxNotifier
   /// Where queued photos are kept.
   private let photosDirectory: URL
   /// Scratch space for photos prepared for upload.
   private let workDirectory: URL
   /// The clock, injected so tests control backoff deadlines.
   private let now: @Sendable () -> Date
   /// The pass in progress, if any.
   private var current: Task<Void, Never>?
   /// Set when a drain arrives during a pass, asking for one more.
   private var rerun = false
   /// The server's limits, fetched once per processor before the first upload.
   private var limits: AuthoringLimits?

   /// Attempts before an item stops retrying on its own.
   public static let maxAutomaticAttempts = 6
   /// Delay before the first automatic retry; it doubles with each attempt.
   static let initialBackoff: TimeInterval = 5
   /// Factor by which the retry delay grows per attempt.
   static let backoffGrowth: Double = 2
   /// Longest delay between automatic retries (15 minutes).
   static let maximumBackoff: TimeInterval = 900
   /// Characters of the photo id used in its upload idempotency key.
   static let photoKeyLength = 8
   /// Status used for an item that cannot be sent as stored (missing id or version).
   static let badRequestStatus = 400
   /// Status of a delete whose post is already gone.
   static let notFoundStatus = 404
   /// Status used when a queued photo's file has disappeared from the device.
   static let goneStatus = 410

   /// Creates a processor. `photosDirectory` and `now` are injectable for tests.
   public init(
      store: OutboxStore, service: @escaping ServiceProvider, notifier: any OutboxNotifier = SilentNotifier(),
      photosDirectory: URL = SharedContainer.photosDirectory,
      now: @escaping @Sendable () -> Date = { .now }
   ) {
      self.store = store
      self.service = service
      self.notifier = notifier
      self.photosDirectory = photosDirectory
      self.workDirectory = FileManager.default.temporaryDirectory.appending(path: "kof22-upload", directoryHint: .isDirectory)
      self.now = now
   }

   /// The automatic retry delay after `attempt` failures: 5 s, doubling, capped.
   static func backoff(attempt: Int) -> TimeInterval {
      min(pow(backoffGrowth, Double(max(attempt - 1, 0))) * initialBackoff, maximumBackoff)
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
         post = try await service.createPost(composition.createBody(), idempotencyKey: item.idempotencyKey)
      }
      else {
         guard let postID = item.serverPostID, let ifMatch = item.ifMatch else {
            throw APIError(status: Self.badRequestStatus, code: "bad_request", message: "Missing post id or version")
         }
         let (update, clearLink) = composition.updateBody()
         post = try await service.updatePost(id: postID, update, clearLink: clearLink, ifMatch: ifMatch)
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

   /// Uploads the photos that have no media id yet, saving each media id as soon as
   /// it is known so a retry continues where this attempt stopped.
   private func uploadPhotos(_ item: OutboxSnapshot, service: SiteService) async throws -> PostComposition {
      var composition = item.composition
      let pending = composition.photos.indices.filter { !composition.photos[$0].isUploaded }
      guard !pending.isEmpty else { return composition }
      let limits = try await currentLimits(service)
      for (done, index) in pending.enumerated() {
         let photo = composition.photos[index]
         try await store.update(item.id) {
            $0.phase = "Uploading photo \(done + 1) of \(pending.count)"
            $0.progress = Double(done) / Double(pending.count + 1)
         }
         guard let source = photo.localURL(in: photosDirectory), FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw APIError(status: Self.goneStatus, code: "photo_missing", message: "A photo for this post is no longer on the device")
         }
         let prepared = try MediaProcessor.prepare(
            source: source, keepLocation: composition.keepLocation,
            acceptedTypes: limits.photoContentTypes, maxBytes: limits.maxPhotoBytes, workDirectory: workDirectory
         )
         defer {
            ////////////////////////////////////////////////////////////////
            // A temporary copy; a leftover is cleared with the temp dir. //
            ////////////////////////////////////////////////////////////////
            try? FileManager.default.removeItem(at: prepared.fileURL)
         }
         /////////////////////////////////////////////////////////////////////////////////
         // The attempt number keeps a retry after an expired ticket from replaying it. //
         /////////////////////////////////////////////////////////////////////////////////
         let key = "\(item.idempotencyKey)-p-\(photo.id.uuidString.prefix(Self.photoKeyLength))-a\(item.attempts)"
         let ticket = try await service.createUpload(
            UploadCreate(fileName: prepared.fileURL.lastPathComponent, contentType: prepared.contentType, byteSize: prepared.byteSize),
            idempotencyKey: key
         )
         try await service.putUpload(fileURL: prepared.fileURL, ticket: ticket)
         let media = try await service.completeUpload(
            id: ticket.uploadId,
            UploadComplete(altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank, keepLocation: composition.keepLocation)
         )
         composition.photos[index].attach(media)
         let saved = composition
         try await store.update(item.id) { $0.composition = saved }
      }
      return composition
   }

   /// The server's limits, fetched on first use and then reused.
   private func currentLimits(_ service: SiteService) async throws -> AuthoringLimits {
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
         retryDelay = after ?? Self.backoff(attempt: attempts)
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
