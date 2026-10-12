/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import SwiftData

/// A Sendable copy of an `OutboxItem` for work off the main actor.
public struct OutboxSnapshot: Sendable, Equatable, Identifiable {
   /// The item's id.
   public var id: UUID
   /// What the item asks the server to do.
   public var operation: OutboxOperation
   /// Where the item is in its life.
   public var state: OutboxState
   /// The post content.
   public var composition: PostComposition
   /// The server's post id, when known.
   public var serverPostID: Int64?
   /// The version an update or delete is based on.
   public var ifMatch: String?
   /// The create's idempotency key.
   public var idempotencyKey: String
   /// Failed attempts since the last manual retry.
   public var attempts: Int
   /// Not sent before this instant.
   public var nextAttemptAt: Date?
   /// The last failure, worded for the user.
   public var lastError: String?
   /// Whether the server copy changed under an edit.
   public var isConflict: Bool
   /// The public URL once the post is live.
   public var resultURL: String?

   /// Copies the item's current values.
   init(_ item: OutboxItem) {
      id = item.id
      operation = item.operation
      state = item.state
      composition = item.composition
      serverPostID = item.serverPostID
      ifMatch = item.ifMatch
      idempotencyKey = item.idempotencyKey
      attempts = item.attempts
      nextAttemptAt = item.nextAttemptAt
      lastError = item.lastError
      isConflict = item.isConflict
      resultURL = item.resultURL
   }
}

/// All outbox writes go through this actor so the app, the processor and the
/// Share Extension never race on the same context.
@ModelActor
public actor OutboxStore {
   /// How long sent items stay listed before `pruneSent` drops them (7 days).
   public static let sentRetention: TimeInterval = 604_800

   /// The item with `id`, or nil when it has been deleted.
   private func item(_ id: UUID) throws -> OutboxItem? {
      try modelContext.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })).first
   }

   /// Queues a composition for sending and returns the item's id. When `draftID`
   /// names the composer's local draft, that draft becomes the queued item.
   @discardableResult
   public func enqueue(
      _ composition: PostComposition, operation: OutboxOperation, serverPostID: Int64? = nil,
      ifMatch: String? = nil, replacing draftID: UUID? = nil
   ) throws -> UUID {
      ////////////////////////////////////////////////////////////////////////
      // Only a local draft can be turned into a queued item; anything else //
      // is already on its way and must not be overwritten.                 //
      ////////////////////////////////////////////////////////////////////////
      if let draftID, let draft = try item(draftID), draft.state == .localDraft {
         draft.composition = composition
         draft.operationRaw = operation.rawValue
         draft.serverPostID = serverPostID
         draft.ifMatch = ifMatch
         draft.state = .queued
         draft.updatedAt = .now
         try modelContext.save()
         return draftID
      }
      let item = OutboxItem(
         operation: operation, state: .queued, composition: composition,
         serverPostID: serverPostID, ifMatch: ifMatch)
      modelContext.insert(item)
      try modelContext.save()
      return item.id
   }

   /// Autosave for the composer. Returns the draft's id.
   @discardableResult
   public func saveLocalDraft(_ composition: PostComposition, id: UUID?) throws -> UUID {
      if let id, let existing = try item(id), existing.state == .localDraft {
         existing.composition = composition
         existing.updatedAt = .now
         try modelContext.save()
         return id
      }
      let item = OutboxItem(operation: .create, state: .localDraft, composition: composition)
      modelContext.insert(item)
      try modelContext.save()
      return item.id
   }

   /// Deletes the item only while it is still a local draft (composer discard).
   public func deleteDraft(_ id: UUID) throws {
      guard let item = try item(id), item.state == .localDraft else { return }
      try delete(id)
   }

   /// Marks a due item as sending and returns its current state, or nil when it
   /// was deleted or changed state since it was listed.
   public func claim(_ id: UUID) throws -> OutboxSnapshot? {
      guard let item = try item(id), item.state == .queued || item.state == .sending else { return nil }
      item.state = .sending
      item.phase = "Sending"
      item.lastError = nil
      item.updatedAt = .now
      try modelContext.save()
      return OutboxSnapshot(item)
   }

   /// After a post changes on the server, later queued edits/deletes of the same
   /// post must use the new version instead of failing with 412.
   public func carryForward(postID: Int64, version: String, excluding id: UUID) throws {
      let queued = OutboxState.queued.rawValue
      let failed = OutboxState.failed.rawValue
      let descriptor = FetchDescriptor<OutboxItem>(
         predicate: #Predicate { ($0.stateRaw == queued || $0.stateRaw == failed) && $0.serverPostID == postID }
      )
      for item in try modelContext.fetch(descriptor) where item.id != id && item.operation != .create {
         item.ifMatch = version
         item.isConflict = false
      }
      try modelContext.save()
   }

   /// The item's current values, or nil when it has been deleted.
   public func snapshot(_ id: UUID) throws -> OutboxSnapshot? {
      try item(id).map(OutboxSnapshot.init)
   }

   /// Items ready to send now, oldest first. Items stuck in `sending` (the app was
   /// killed mid-send) are picked up again; idempotency keys make that safe.
   public func due(now: Date = .now) throws -> [OutboxSnapshot] {
      let queued = OutboxState.queued.rawValue
      let sending = OutboxState.sending.rawValue
      let descriptor = FetchDescriptor<OutboxItem>(
         predicate: #Predicate { $0.stateRaw == queued || $0.stateRaw == sending },
         sortBy: [SortDescriptor(\.createdAt)]
      )
      return try modelContext.fetch(descriptor)
         .filter { ($0.nextAttemptAt ?? .distantPast) <= now }
         .map(OutboxSnapshot.init)
   }

   /// The earliest backoff deadline of a queued item, for scheduling a background
   /// wake-up; nil when nothing is waiting.
   public func nextWakeDate() throws -> Date? {
      let queued = OutboxState.queued.rawValue
      let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == queued })
      return try modelContext.fetch(descriptor).compactMap(\.nextAttemptAt).min()
   }

   /// Applies `change` to the item and stamps `updatedAt`; does nothing when the
   /// item has been deleted.
   public func update(_ id: UUID, _ change: @Sendable (OutboxItem) -> Void) throws {
      guard let item = try item(id) else { return }
      change(item)
      item.updatedAt = .now
      try modelContext.save()
   }

   /// Manual retry from the Outbox screen.
   public func retry(_ id: UUID) throws {
      try update(id) { item in
         item.state = .queued
         item.attempts = 0
         item.nextAttemptAt = nil
         item.lastError = nil
      }
   }

   /// "Send now": everything queued or failed becomes due immediately.
   public func retryAll() throws {
      let queued = OutboxState.queued.rawValue
      let failed = OutboxState.failed.rawValue
      let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == queued || $0.stateRaw == failed })
      for item in try modelContext.fetch(descriptor) where !item.isConflict {
         item.state = .queued
         item.nextAttemptAt = nil
         item.attempts = 0
      }
      try modelContext.save()
   }

   /// Deletes the item and its local photo files (in `photosDirectory`, injectable for
   /// tests), whatever its state.
   public func delete(_ id: UUID, photosDirectory: URL = SharedContainer.photosDirectory) throws {
      guard let item = try item(id) else { return }
      for photo in item.composition.photos {
         if let url = photo.localURL(in: photosDirectory) {
            //////////////////////////////////////////////////////////////
            // Uploaded or already cleaned up photos have no file left. //
            //////////////////////////////////////////////////////////////
            try? FileManager.default.removeItem(at: url)
         }
      }
      modelContext.delete(item)
      try modelContext.save()
   }

   /// Drops sent items older than `age`, keeping the list short.
   public func pruneSent(olderThan age: TimeInterval = sentRetention, now: Date = .now) throws {
      let sent = OutboxState.sent.rawValue
      let cutoff = now.addingTimeInterval(-age)
      let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == sent && $0.updatedAt < cutoff })
      for item in try modelContext.fetch(descriptor) { modelContext.delete(item) }
      try modelContext.save()
   }

   /// Saves server copies of posts for offline viewing, replacing older copies.
   public func cache(_ posts: [Post]) throws {
      for post in posts {
         let id = post.id
         if let existing = try modelContext.fetch(FetchDescriptor<CachedPost>(predicate: #Predicate { $0.postID == id })).first {
            existing.update(from: post)
         }
         else {
            modelContext.insert(CachedPost(post: post))
         }
      }
      try modelContext.save()
   }

   /// Forgets the cached copy of a deleted post.
   public func removeCached(_ postID: Int64) throws {
      try modelContext.delete(model: CachedPost.self, where: #Predicate { $0.postID == postID })
      try modelContext.save()
   }

   /// Cached posts, most recently changed first; unreadable copies are skipped.
   public func cachedPosts() throws -> [Post] {
      try modelContext.fetch(FetchDescriptor<CachedPost>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
         .compactMap(\.post)
   }

   /// Items still to send or needing attention (not drafts, not sent), for the badge.
   public func pendingCount() throws -> Int {
      let sent = OutboxState.sent.rawValue
      let draft = OutboxState.localDraft.rawValue
      return try modelContext.fetchCount(
         FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw != sent && $0.stateRaw != draft }
         ))
   }
}
