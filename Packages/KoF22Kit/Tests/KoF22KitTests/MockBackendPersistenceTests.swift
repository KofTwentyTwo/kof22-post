/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The fake keeps its state in one JSON file shared by the app and its extensions.
@Suite struct MockBackendPersistenceTests {
   /// Ids of the seeded posts, oldest first.
   static let seededPosts = 2

   @Test func postsSurviveARestartAndOtherProcessesSeeThem() async throws {
      let directory = try KitFiles.makeDirectory()
      let writer = MockCaller(backend: MockBackend(directory: directory))
      let reader = MockCaller(backend: MockBackend(directory: directory))
      let post = try await writer.create(MockCaller.record("persisted"))
      let id = try #require(post.id)
      let fetched = try await reader.call("getBlogPost", path: "/v2/blogPost/\(id)")
      #expect(try reader.decode(Components.Schemas.BlogPost.self, fetched).content == "persisted")
      let restarted = MockCaller(backend: MockBackend(directory: directory))
      #expect(try await restarted.call("getBlogPost", path: "/v2/blogPost/\(id)").status == MockBackend.Status.okay)
   }

   @Test func anUnreadableStateFileFallsBackToTheSeed() async throws {
      let directory = try KitFiles.makeDirectory()
      try Data("{ broken".utf8).write(to: directory.appending(path: "state.json"))
      let caller = MockCaller(backend: MockBackend(directory: directory))
      let page = try caller.decode(QueryEnvelope<SitePost>.self, try await caller.call("queryBlogPost"))
      #expect(page.records?.count == Self.seededPosts)
   }

   @Test func aStateFileThatCannotBeWrittenKeepsServingFromMemory() async throws {
      let blocker = try KitFiles.makeDirectory().appending(path: "not-a-folder")
      try Data("file".utf8).write(to: blocker)
      let caller = MockCaller(backend: MockBackend(directory: blocker))
      let post = try await caller.create(MockCaller.record("memory only"))
      #expect(post.content == "memory only")
   }

   @Test func resetRestoresTheSeedAndDropsMedia() async throws {
      let directory = try KitFiles.makeDirectory()
      let caller = MockCaller(backend: MockBackend(directory: directory))
      let source = try KitFiles.makeDirectory().appending(path: "in.jpg")
      try KitFiles.writeImage(to: source)
      _ = try await caller.upload(file: source)
      _ = try await caller.create(MockCaller.record("temporary"))
      await caller.backend.reset()
      let page = try caller.decode(QueryEnvelope<SitePost>.self, try await caller.call("queryBlogPost"))
      #expect(page.records?.compactMap(\.isPublished).sorted { !$0 && $1 } == [false, true])
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "media").path(percentEncoded: false)))
      await MockBackend(directory: nil).reset()
   }

   @Test func seedDataHasSampleTagsAndPosts() {
      let state = MockBackend.seed(now: Date(timeIntervalSince1970: 0))
      #expect(state.tags.filter { $0.blogId == MockBackend.deepThoughtsID }.map(\.name) == ["Apple", "Unix"])
      #expect(state.posts.first?.siteUrl?.hasPrefix("https://www.kof22.com/blogs/quick-bits/") == true)
      #expect(state.posts.last?.siteUrl == nil)
      #expect(state.posts.allSatisfy { $0.tags?.count == 1 && $0.metaTitle != nil && $0.description != nil })
      #expect(MockBackend.timestampSlug(Date(timeIntervalSince1970: 0)) == "19700101-000000")
      #expect(MockBackend.demoBlogs.first?.isDefault == true)
   }

   @Test func theServiceListsTheSignedInAuthorsPosts() async throws {
      let backend = MockBackend(directory: nil)
      let (service, _) = try await makeSignedInService(backend)
      let page = try await service.myPosts(status: .published, limit: 1)
      #expect(page.items.count == 1)
      #expect(page.items.first?.status == .published)
      #expect(page.nextPage == 2)
      let drafts = try await service.myPosts(status: .draft)
      #expect(drafts.items.count == 1)
      #expect(drafts.nextPage == nil)
   }
}
