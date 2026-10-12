/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

@Suite struct ReadCacheTests {
   @Test func servesFreshEntriesAndDropsExpiredOnes() async {
      let clock = TestClock()
      let cache = ReadCache(timeToLive: 60, now: clock.provider)
      await cache.store("hello", for: "k")
      clock.advance(by: 59)
      #expect(await cache.value(for: "k", as: String.self) == "hello")
      clock.advance(by: 1)
      #expect(await cache.value(for: "k", as: String.self) == nil)
      clock.advance(by: -10)
      #expect(await cache.value(for: "k", as: String.self) == nil)
   }

   @Test func wrongTypeAndMissingKeysMiss() async {
      let cache = ReadCache()
      await cache.store(42, for: "n")
      #expect(await cache.value(for: "n", as: String.self) == nil)
      #expect(await cache.value(for: "none", as: Int.self) == nil)
      #expect(cache.timeToLive == ReadCache.defaultTimeToLive)
   }

   @Test func removeAllForgetsEverything() async {
      let cache = ReadCache()
      await cache.store(1, for: "a")
      await cache.removeAll()
      #expect(await cache.value(for: "a", as: Int.self) == nil)
   }
}

@Suite struct ReadPageTests {
   @Test func hasMoreFollowsTheCount() {
      #expect(ReadPage<SiteTag>(records: [], count: 41, pageNo: 2, pageSize: 20).hasMore)
      #expect(!ReadPage<SiteTag>(records: [], count: 40, pageNo: 2, pageSize: 20).hasMore)
      #expect(ReadPage<SiteTag>(records: [], count: 40, pageNo: 2, pageSize: 20).nextPageNo == 3)
   }

   @Test func withoutACountAFullPageMeansMore() {
      let tag = SiteTag(id: 1)
      #expect(ReadPage(records: [tag], count: nil, pageNo: 1, pageSize: 1).hasMore)
      #expect(!ReadPage(records: [tag], count: nil, pageNo: 1, pageSize: 2).hasMore)
   }
}

@Suite struct PublicReadServiceCachingTests {
   let serverURL = URL(literal: "https://api.kof22.com")

   @Test func repeatedReadsAreServedFromTheCache() async throws {
      let transport = FixtureTransport(["queryBlog": try .okay("blog-query"), "queryPost": try .okay("post-query")])
      let service = PublicReadService(serverURL: serverURL, transport: transport)
      _ = try await service.blogs()
      _ = try await service.blogs()
      #expect(transport.requests.count == 1)
      _ = try await service.blogs(forceRefresh: true)
      #expect(transport.requests.count == 2)
      let page = try await service.posts(blogId: 2)
      let post = try await service.post(id: try #require(page.records.first?.id))
      #expect(post == page.records.first)
      #expect(transport.requests.count == 3)
   }

   @Test func queriesAskForNewestPublishedPostsOfOneBlog() async throws {
      let transport = FixtureTransport(["queryPost": try .okay("post-query")])
      _ = try await PublicReadService(serverURL: serverURL, transport: transport).posts(blogId: 2, pageNo: 2, pageSize: 3)
      let path = try #require(transport.requests.first?.request.path)
      let items = URLComponents(string: path)?.queryItems ?? []
      #expect(items.contains(URLQueryItem(name: "blogId", value: "2")))
      #expect(items.contains(URLQueryItem(name: "pageNo", value: "2")))
      #expect(items.contains(URLQueryItem(name: "pageSize", value: "3")))
      #expect(items.contains(URLQueryItem(name: "orderBy", value: "publishDate DESC, id DESC")))
   }

   @Test func pagingDefaultsWhenTheServerOmitsIt() async throws {
      let body = Data(#"{"records":[{"id":5,"name":"x"}]}"#.utf8)
      let service = PublicReadService(serverURL: serverURL, transport: FixtureTransport(["queryTag": .init(status: 200, body: body)]))
      #expect(try await service.tags(blogId: 1).map(\.id) == [5])
      let empty = PublicReadService(serverURL: serverURL, transport: FixtureTransport(["queryPost": .init(status: 200, body: Data("{}".utf8))]))
      let page = try await empty.posts(blogId: 1)
      #expect(page.records.isEmpty)
      #expect(page.pageNo == 1)
      #expect(!page.hasMore)
   }

   @Test func recordsThatDoNotDecodeFailTheRead() async {
      let body = Data(#"{"records":[{"id":"not a number"}]}"#.utf8)
      let service = PublicReadService(serverURL: serverURL, transport: FixtureTransport(["queryBlog": .init(status: 200, body: body)]))
      await #expect(throws: DecodingError.self) { try await service.blogs() }
   }

   @Test func liveServiceIsBuiltWithoutTouchingTheNetwork() async {
      let cache = ReadCache()
      let service = PublicReadService.live(cache: cache)
      #expect(service.cache === cache)
   }
}

@Suite struct MockReadTests {
   func makeReads() async throws -> (PublicReadService, MockCaller) {
      let backend = MockBackend(directory: try KitFiles.makeDirectory())
      return (PublicReadService.mock(backend: backend), MockCaller(backend: backend))
   }

   @Test func blogsComeFromTheSeed() async throws {
      let (reads, _) = try await makeReads()
      let blogs = try await reads.blogs()
      #expect(blogs.map(\.slug) == MockBackend.blogs.map(\.slug))
      #expect(blogs.first?.shortName == "Quick Bits")
   }

   @Test func onlyPublishedPostsAreListedNewestFirst() async throws {
      let (reads, caller) = try await makeReads()
      let created = try await caller.create(PostCreate(body: "Fresh off the press", status: .published))
      _ = try await caller.create(PostCreate(body: "Still a draft"))
      let page = try await reads.posts(blogId: 1)
      #expect(page.records.first?.id == Int(created.id))
      #expect(page.records.allSatisfy { $0.content != "Still a draft" })
      #expect(page.count == page.records.count)
   }

   @Test func postsAreMappedToThePublicShape() async throws {
      let (reads, caller) = try await makeReads()
      let file = try KitFiles.makeDirectory().appending(path: "p.jpg")
      try KitFiles.writeImage(to: file)
      let media = try await caller.upload(file: file)
      let created = try await caller.create(
         PostCreate(
            title: "With everything", body: "Body text", status: .published, tags: ["#Raspberry Pi", "brand-new"],
            locationLabel: "Shop", linkUrl: "https://example.com/x", media: [MediaAttachment(mediaId: media.mediaId, caption: "c")]))
      let post = try await reads.post(id: Int(created.id))
      #expect(post.title == "With everything")
      #expect(post.content == "Body text")
      #expect(post.slug == created.slug)
      #expect(post.publishDate != nil)
      #expect(post.linkUrl == "https://example.com/x")
      #expect(post.locationLabel == "Shop")
      #expect(post.tags?.count == 2)
      #expect(post.media?.first?.sortOrder == 0)
      #expect(post.media?.first?.caption == "c")
      #expect(post.media?.first?.url?.hasPrefix("file:") == true)
      let tagIDs = Set(try await reads.tags(blogId: 1).compactMap(\.id))
      #expect(post.tags?.allSatisfy { tagIDs.contains($0.tagId ?? -1) } == true)
   }

   @Test func pagesSplitTheList() async throws {
      let (reads, caller) = try await makeReads()
      for index in 0..<3 { _ = try await caller.create(PostCreate(body: "Post \(index)", status: .published)) }
      let total = try await reads.posts(blogId: 1, pageSize: 1000).records.count
      let first = try await reads.posts(blogId: 1, pageNo: 1, pageSize: 2)
      let second = try await reads.posts(blogId: 1, pageNo: 2, pageSize: 2)
      #expect(first.records.count == 2)
      #expect(first.hasMore == (total > 2))
      #expect(Set(first.records.compactMap(\.id)).isDisjoint(with: second.records.compactMap(\.id)))
      #expect(try await reads.posts(blogId: 2).records.isEmpty)
   }

   @Test func draftsAndUnknownPostsAreNotFound() async throws {
      let (reads, caller) = try await makeReads()
      let draft = try await caller.create(PostCreate(body: "Hidden"))
      let error = await #expect(throws: APIError.self) { try await reads.post(id: Int(draft.id)) }
      #expect(error?.code == "not_found")
      let notNumber = try await caller.call("getPost", path: "/v1/post/abc")
      #expect(try caller.errorCode(notNumber) == "not_found")
      let noID = try await caller.call("getPost", path: "/")
      #expect(try caller.errorCode(noID) == "not_found")
   }

   @Test func tagsAreFilteredByBlogOrListedForAll() async throws {
      let (reads, caller) = try await makeReads()
      let blogTwo = try await reads.tags(blogId: 2)
      #expect(blogTwo.allSatisfy { $0.blogId == 2 })
      #expect(blogTwo.compactMap(\.name) == blogTwo.compactMap(\.name).sorted())
      let all = try caller.decode(QueryEnvelope<SiteTag>.self, try await caller.call("queryTag", path: "/v1/tag/query"))
      #expect((all.records?.count ?? 0) > blogTwo.count)
      #expect(all.pageSize == MockBackend.readDefaultPageSize)
   }

   @Test(arguments: [["pageNo": "0"], ["pageSize": "0"], ["pageSize": "1001"], ["pageSize": "many"]])
   func invalidPagingIsABadRequest(query: [String: String]) async throws {
      let (_, caller) = try await makeReads()
      let response = try await caller.call("queryBlog", path: "/v1/blog/query", query: query)
      #expect(response.status == 400)
      #expect(try caller.errorCode(response) == "bad_request")
   }
}
