/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The outbox store's state transitions and helpers.
@Suite struct OutboxStoreTests {
   /// A fresh in-memory store.
   static func makeStore() throws -> OutboxStore {
      OutboxStore(modelContainer: try PersistenceStack.makeContainer(inMemory: true))
   }

   /// A minimal server post for the cache.
   static func post(id: Int64, body: String, updatedAt: Date) -> Post {
      Post(
         id: id, blogId: 1, blog: "quick-bits", status: .draft, title: body, slug: "s\(id)", body: body, updatedAt: updatedAt,
         version: "v\(id)")
   }

   @Test func aDraftBecomesTheQueuedItem() async throws {
      let store = try Self.makeStore()
      let draft = try await store.saveLocalDraft(PostComposition(body: "first"), id: nil)
      let same = try await store.saveLocalDraft(PostComposition(body: "second"), id: draft)
      #expect(same == draft)
      #expect(try await store.pendingCount() == 0)
      let queued = try await store.enqueue(PostComposition(body: "final"), operation: .update, serverPostID: 7, ifMatch: "v", replacing: draft)
      #expect(queued == draft)
      let item = try #require(try await store.snapshot(draft))
      #expect(item.state == .queued)
      #expect(item.operation == .update)
      #expect(item.serverPostID == 7)
      #expect(try await store.pendingCount() == 1)
   }

   @Test func discardingADraftDeletesIt() async throws {
      let store = try Self.makeStore()
      let draft = try await store.saveLocalDraft(PostComposition(body: "discard me"), id: nil)
      try await store.deleteDraft(draft)
      #expect(try await store.snapshot(draft) == nil)
      try await store.deleteDraft(UUID())
   }

   @Test func claimSkipsItemsThatAreNotWaiting() async throws {
      let store = try Self.makeStore()
      let id = try await store.enqueue(PostComposition(body: "x"), operation: .create)
      let claimed = try #require(try await store.claim(id))
      #expect(claimed.state == .sending)
      try await store.update(id) { $0.state = .failed }
      #expect(try await store.claim(id) == nil)
      #expect(try await store.claim(UUID()) == nil)
      try await store.update(UUID()) { $0.state = .sent }
   }

   @Test func dueRespectsBackoffAndWakeDateReportsTheEarliest() async throws {
      let store = try Self.makeStore()
      let now = Date(timeIntervalSince1970: 1_000)
      let later = try await store.enqueue(PostComposition(body: "later"), operation: .create)
      let soon = try await store.enqueue(PostComposition(body: "soon"), operation: .create)
      try await store.update(later) { $0.nextAttemptAt = now.addingTimeInterval(600) }
      try await store.update(soon) { $0.nextAttemptAt = now.addingTimeInterval(60) }
      #expect(try await store.due(now: now).isEmpty)
      #expect(try await store.nextWakeDate() == now.addingTimeInterval(60))
      #expect(try await store.due(now: now.addingTimeInterval(120)).map(\.id) == [soon])
   }

   @Test func retryAllSkipsConflictsAndClearsBackoff() async throws {
      let store = try Self.makeStore()
      let plain = try await store.enqueue(PostComposition(body: "plain"), operation: .create)
      let conflict = try await store.enqueue(PostComposition(body: "conflict"), operation: .update, serverPostID: 1, ifMatch: "v")
      try await store.update(plain) { stored in
         stored.state = .failed
         stored.attempts = 3
         stored.nextAttemptAt = .distantFuture
      }
      try await store.update(conflict) { stored in
         stored.state = .failed
         stored.isConflict = true
      }
      try await store.retryAll()
      let retried = try #require(try await store.snapshot(plain))
      #expect(retried.state == .queued)
      #expect(retried.attempts == 0)
      #expect(retried.nextAttemptAt == nil)
      #expect(try await store.snapshot(conflict)?.state == .failed)
      try await store.retry(conflict)
      #expect(try await store.snapshot(conflict)?.state == .queued)
   }

   @Test func carryForwardUpdatesLaterEditsOnly() async throws {
      let store = try Self.makeStore()
      let sent = try await store.enqueue(PostComposition(body: "a"), operation: .update, serverPostID: 5, ifMatch: "v1")
      let laterEdit = try await store.enqueue(PostComposition(body: "b"), operation: .update, serverPostID: 5, ifMatch: "v1")
      let create = try await store.enqueue(PostComposition(body: "c"), operation: .create, serverPostID: 5)
      try await store.update(laterEdit) { stored in
         stored.state = .failed
         stored.isConflict = true
      }
      try await store.carryForward(postID: 5, version: "v2", excluding: sent)
      #expect(try await store.snapshot(sent)?.ifMatch == "v1")
      let edit = try #require(try await store.snapshot(laterEdit))
      #expect(edit.ifMatch == "v2")
      #expect(!edit.isConflict)
      #expect(try await store.snapshot(create)?.ifMatch == nil)
   }

   @Test func deleteRemovesTheItemAndItsPhotoFiles() async throws {
      let store = try Self.makeStore()
      let photos = try KitFiles.makeDirectory()
      let file = photos.appending(path: "p.jpg")
      try Data("x".utf8).write(to: file)
      let composition = PostComposition(photos: [ComposedPhoto(fileName: "p.jpg"), ComposedPhoto(mediaId: 3)])
      let id = try await store.enqueue(composition, operation: .create)
      try await store.delete(id, photosDirectory: photos)
      #expect(try await store.snapshot(id) == nil)
      #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
      try await store.delete(id, photosDirectory: photos)
   }

   @Test func pruneDropsOnlyOldSentItems() async throws {
      let store = try Self.makeStore()
      let old = try await store.enqueue(PostComposition(body: "old"), operation: .create)
      let waiting = try await store.enqueue(PostComposition(body: "waiting"), operation: .create)
      try await store.update(old) { $0.state = .sent }
      try await store.pruneSent(now: .now.addingTimeInterval(OutboxStore.sentRetention + 60))
      #expect(try await store.snapshot(old) == nil)
      #expect(try await store.snapshot(waiting) != nil)
   }

   @Test func cacheKeepsOneNewestCopyPerPost() async throws {
      let store = try Self.makeStore()
      let start = Date(timeIntervalSince1970: 1_000)
      try await store.cache([Self.post(id: 1, body: "one", updatedAt: start), Self.post(id: 2, body: "two", updatedAt: start.addingTimeInterval(10))])
      try await store.cache([Self.post(id: 1, body: "one edited", updatedAt: start.addingTimeInterval(20))])
      #expect(try await store.cachedPosts().map(\.body) == ["one edited", "two"])
      try await store.removeCached(1)
      #expect(try await store.cachedPosts().map(\.id) == [2])
   }
}
