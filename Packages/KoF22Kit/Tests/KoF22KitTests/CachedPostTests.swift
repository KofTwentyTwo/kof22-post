/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import SwiftData
import Testing

@testable import KoF22Kit

/// The SwiftData models and the blob coding behind them.
@Suite struct CachedPostTests {
   /// A value JSON cannot encode (non-finite numbers are refused).
   struct Unencodable: Codable {
      /// Always infinite.
      var value = Double.infinity
   }

   /// A minimal server post.
   static func post(body: String, updatedAt: Date?) -> Post {
      Post(id: 1, blogId: 1, blog: "quick-bits", status: .published, title: body, slug: "s", body: body, updatedAt: updatedAt, version: "v")
   }

   @Test func codingFailuresAreReportedAsNil() {
      let previous = Data("previous".utf8)
      #expect(StoreCoding.encode(Unencodable(), otherwise: previous) == previous)
      #expect(StoreCoding.decode(Unencodable.self, from: Data("nope".utf8)) == nil)
      let encoded = StoreCoding.encode(PostComposition(body: "ok"), otherwise: Data())
      #expect(StoreCoding.decode(PostComposition.self, from: encoded)?.body == "ok")
   }

   @Test func cachedPostsRoundTripAndUpdate() {
      let updatedAt = Date(timeIntervalSince1970: 2_000)
      let cached = CachedPost(post: Self.post(body: "first", updatedAt: updatedAt))
      #expect(cached.post?.body == "first")
      #expect(cached.updatedAt == updatedAt)
      cached.update(from: Self.post(body: "second", updatedAt: nil))
      #expect(cached.post?.body == "second")
      #expect(cached.updatedAt > updatedAt)
      cached.data = Data("corrupt".utf8)
      #expect(cached.post == nil)
      let undated = CachedPost(post: Self.post(body: "undated", updatedAt: nil))
      #expect(undated.updatedAt > updatedAt)
   }

   @Test func outboxItemsDegradeGracefullyOnBadStoredValues() {
      let item = OutboxItem(operation: .update, state: .queued, composition: PostComposition(title: "Kept", body: "b"))
      #expect(item.idempotencyKey == "kof22post-\(item.id.uuidString.lowercased())")
      #expect(item.summary == "Kept")
      item.composition = PostComposition(body: "Renamed")
      #expect(item.summary == "Renamed")
      item.stateRaw = "archived"
      item.operationRaw = "merge"
      #expect(item.state == .failed)
      #expect(item.operation == .create)
      item.payload = Data("corrupt".utf8)
      #expect(item.composition == PostComposition())
   }

   @Test func theStoreOpensOnDisk() throws {
      let url = try KitFiles.makeDirectory().appending(path: "Test.store")
      let container = try PersistenceStack.makeContainer(url: url)
      let context = ModelContext(container)
      context.insert(OutboxItem(operation: .create, state: .localDraft, composition: PostComposition(body: "disk")))
      try context.save()
      #expect(try context.fetchCount(FetchDescriptor<OutboxItem>()) == 1)
   }
}
