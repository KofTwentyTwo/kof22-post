/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The mock keeps its state in one JSON file shared by the app and its extensions.
@Suite struct MockBackendPersistenceTests {
   @Test func postsSurviveARestartAndOtherProcessesSeeThem() async throws {
      let directory = try KitFiles.makeDirectory()
      let writer = MockCaller(backend: MockBackend(directory: directory))
      let reader = MockCaller(backend: MockBackend(directory: directory))
      let post = try await writer.create(PostCreate(body: "persisted"))
      let fetched = try await reader.call("getMyPost", path: "/v1/me/posts/\(post.id)")
      #expect(try reader.decode(Post.self, fetched).body == "persisted")
      let restarted = MockCaller(backend: MockBackend(directory: directory))
      #expect(try await restarted.call("getMyPost", path: "/v1/me/posts/\(post.id)").status == 200)
   }

   @Test func postsWithoutAChangeDateListLast() async throws {
      let directory = try KitFiles.makeDirectory()
      var state = MockBackend.seed(now: Date(timeIntervalSince1970: 1_000))
      state.posts[0].updatedAt = nil
      state.posts[1].updatedAt = nil
      try MockBackend.encoder.encode(state).write(to: directory.appending(path: "state.json"))
      let caller = MockCaller(backend: MockBackend(directory: directory))
      let fresh = try await caller.create(PostCreate(body: "dated"))
      let page = try caller.decode(PostPage.self, try await caller.call("listMyPosts"))
      #expect(page.items.map(\.id) == [fresh.id, 2, 1])
   }

   @Test func anUnreadableStateFileFallsBackToTheSeed() async throws {
      let directory = try KitFiles.makeDirectory()
      try Data("{ broken".utf8).write(to: directory.appending(path: "state.json"))
      let caller = MockCaller(backend: MockBackend(directory: directory))
      let page = try caller.decode(PostPage.self, try await caller.call("listMyPosts"))
      #expect(page.items.count == 2)
   }

   @Test func aStateFileThatCannotBeWrittenKeepsServingFromMemory() async throws {
      let blocker = try KitFiles.makeDirectory().appending(path: "not-a-folder")
      try Data("file".utf8).write(to: blocker)
      let caller = MockCaller(backend: MockBackend(directory: blocker))
      let post = try await caller.create(PostCreate(body: "memory only"))
      #expect(try await caller.call("getMyPost", path: "/v1/me/posts/\(post.id)").status == 200)
   }

   @Test func resetRestoresTheSeedAndDropsMedia() async throws {
      let directory = try KitFiles.makeDirectory()
      let caller = MockCaller(backend: MockBackend(directory: directory))
      let source = try KitFiles.makeDirectory().appending(path: "in.jpg")
      try KitFiles.writeImage(to: source)
      _ = try await caller.upload(file: source)
      _ = try await caller.create(PostCreate(body: "temporary"))
      await caller.backend.reset()
      let page = try caller.decode(PostPage.self, try await caller.call("listMyPosts"))
      #expect(page.items.map(\.status).sorted { $0.rawValue < $1.rawValue } == [.draft, .published])
      #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "media").path(percentEncoded: false)))
      await MockBackend(directory: nil).reset()
   }

   @Test func seedDataHasSampleTagsAndPosts() {
      let state = MockBackend.seed(now: Date(timeIntervalSince1970: 0))
      #expect(state.tags.filter { $0.blogId == 2 }.map(\.name) == ["Apple", "Unix"])
      #expect(state.posts.first?.url?.hasPrefix("https://www.kof22.com/blogs/quick-bits/") == true)
      #expect(state.nextPostId == 3)
   }

   @Test func textRulesMatchTheBackend() {
      #expect(MockBackend.matches("\"a\", W/\"b\"", version: "b"))
      #expect(MockBackend.matches("*", version: "anything"))
      #expect(!MockBackend.matches("\"a\"", version: "b"))
      #expect(MockBackend.newVersion().count == 20)
      #expect(MockBackend.blankToNil(" \n ") == nil)
      #expect(MockBackend.deriveTitle(String(repeating: "word ", count: 30)).count <= 100)
      #expect(MockBackend.slugify(String(repeating: "a", count: 90)).count == 80)
      #expect(MockBackend.timestampSlug(Date(timeIntervalSince1970: 0)) == "19700101-000000")
   }

   @Test func transportPassesQueryAndHeadersThrough() async throws {
      let backend = MockBackend(directory: nil)
      let (service, _) = try await makeSignedInService(backend)
      let page = try await service.myPosts(status: .published, limit: 1)
      #expect(page.items.count == 1)
      #expect(page.items.first?.status == .published)
   }
}
