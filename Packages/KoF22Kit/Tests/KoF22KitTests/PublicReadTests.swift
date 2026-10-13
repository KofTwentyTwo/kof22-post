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
   @Test func repeatedReadsAreServedFromTheCache() async throws {
      let transport = FixtureTransport(["queryBlog": try .okay("blog-query"), "queryBlogPost": try .okay("blog-post-query")])
      let reads = fixtureService(transport).reads
      _ = try await reads.blogs()
      _ = try await reads.blogs()
      #expect(transport.requests.count == 1)
      _ = try await reads.blogs(forceRefresh: true)
      #expect(transport.requests.count == 2)
      let page = try await reads.posts(blogId: 1)
      let post = try await reads.post(id: try #require(page.records.first?.id))
      #expect(post == page.records.first)
      #expect(transport.requests.count == 3)
   }

   @Test func recordedLiveRepliesDecode() async throws {
      let transport = FixtureTransport(["queryBlog": try .okay("blog-query"), "queryBlogPost": try .okay("blog-post-query")])
      let reads = fixtureService(transport).reads
      let blogs = try await reads.blogs()
      #expect(blogs.contains { $0.slug == Post.defaultBlogSlug })
      let page = try await reads.posts(blogId: 1)
      #expect(!page.records.isEmpty)
      #expect(page.records.allSatisfy { $0.isPublished == true && $0.slug != nil && $0.modifyDate != nil })
   }

   @Test func queriesAskForNewestPublishedPostsOfOneBlog() async throws {
      let transport = FixtureTransport(["queryBlogPost": try .okay("blog-post-query")])
      _ = try await fixtureService(transport).reads.posts(blogId: 2, pageNo: 2, pageSize: 3)
      let path = try #require(transport.requests.first?.request.path)
      let items = URLComponents(string: path)?.queryItems ?? []
      #expect(items.contains(URLQueryItem(name: "blogId", value: "2")))
      #expect(items.contains(URLQueryItem(name: "isPublished", value: "true")))
      #expect(items.contains(URLQueryItem(name: "pageNo", value: "2")))
      #expect(items.contains(URLQueryItem(name: "pageSize", value: "3")))
      #expect(items.contains(URLQueryItem(name: "orderBy", value: "publishDate DESC, id DESC")))
   }

   @Test func pagingDefaultsWhenTheServerOmitsIt() async throws {
      let body = Data(#"{"records":[{"id":5,"name":"x"}]}"#.utf8)
      let reads = fixtureService(FixtureTransport(["queryBlogTag": .init(status: 200, body: body)])).reads
      #expect(try await reads.tags(blogId: 1).map(\.id) == [5])
      let empty = fixtureService(FixtureTransport(["queryBlogPost": .init(status: 200, body: Data("{}".utf8))])).reads
      let page = try await empty.posts(blogId: 1)
      #expect(page.records.isEmpty)
      #expect(page.pageNo == 1)
      #expect(!page.hasMore)
   }

   @Test func recordsThatDoNotDecodeFailTheRead() async {
      let body = Data(#"{"records":[{"id":"not a number"}]}"#.utf8)
      let reads = fixtureService(FixtureTransport(["queryBlog": .init(status: 200, body: body)])).reads
      await #expect(throws: DecodingError.self) { try await reads.blogs() }
   }

   @Test func readsCarryTheToken() async throws {
      let transport = FixtureTransport(["queryBlog": try .okay("blog-query")])
      _ = try await fixtureService(transport).reads.blogs()
      #expect(transport.authorization(for: "queryBlog") == ["Bearer token-1"])
   }
}

@Suite struct MockReadTests {
   /// Reads and a raw caller over one fresh fake.
   func makeReads() async throws -> (PublicReadService, MockCaller) {
      let backend = MockBackend(directory: try KitFiles.makeDirectory())
      let (service, _) = try await makeSignedInService(backend)
      return (service.reads, MockCaller(backend: backend))
   }

   @Test func blogsComeFromTheSeed() async throws {
      let (reads, _) = try await makeReads()
      let blogs = try await reads.blogs()
      #expect(blogs.map(\.slug) == MockBackend.blogs.map(\.slug))
      #expect(blogs.first?.shortName == "Quick Bits")
   }

   @Test func onlyPublishedPostsAreListedNewestFirst() async throws {
      let (reads, caller) = try await makeReads()
      var fresh = MockCaller.record("Fresh off the press")
      fresh.publishDate = .now.addingTimeInterval(60)
      let created = try await caller.create(fresh)
      _ = try await caller.create(MockCaller.record("Still a draft", published: false))
      let page = try await reads.posts(blogId: 1)
      #expect(page.records.first?.id == created.id)
      #expect(page.records.allSatisfy { $0.content != "Still a draft" })
      #expect(page.count == page.records.count)
   }

   @Test func aPostReadByIdCarriesItsTagsAndPhotos() async throws {
      let (reads, caller) = try await makeReads()
      let file = try KitFiles.makeDirectory().appending(path: "p.jpg")
      try KitFiles.writeImage(to: file)
      let media = try await caller.upload(file: file, altText: "alt")
      var record = MockCaller.record("Body text", title: "With everything")
      record.tags = [Components.Schemas.BlogPostTagInt(blogTagId: 1_000)]
      record.media = [Components.Schemas.BlogPostMedia(caption: "c", mediaId: Int(media.mediaId), sortOrder: 0)]
      record.linkUrl = "https://example.com/x"
      let created = try await caller.create(record)
      let post = try await reads.post(id: try #require(created.id))
      #expect(post.title == "With everything")
      #expect(post.slug == "with-everything")
      #expect(post.siteUrl == "https://www.kof22.com/blogs/quick-bits/with-everything")
      #expect(post.tags?.first?.blogTagId == 1_000)
      #expect(post.media?.first?.caption == "c")
      #expect(post.media?.first?.altText == "alt")
      #expect(post.media?.first?.url?.hasPrefix("file:") == true)
   }

   @Test func pagesSplitTheList() async throws {
      let (reads, caller) = try await makeReads()
      for index in 0..<3 { _ = try await caller.create(MockCaller.record("Post \(index)")) }
      let total = try await reads.posts(blogId: 1, pageSize: 1_000).records.count
      let first = try await reads.posts(blogId: 1, pageNo: 1, pageSize: 2)
      let second = try await reads.posts(blogId: 1, pageNo: 2, pageSize: 2)
      #expect(first.records.count == 2)
      #expect(first.hasMore == (total > 2))
      #expect(Set(first.records.compactMap(\.id)).isDisjoint(with: second.records.compactMap(\.id)))
      #expect(try await reads.posts(blogId: 2).records.isEmpty)
   }

   @Test func unknownPostsAreNotFound() async throws {
      let (reads, _) = try await makeReads()
      let error = await #expect(throws: APIError.self) { try await reads.post(id: 99_999) }
      #expect(error?.status == 404)
   }

   @Test func tagsAreFilteredByBlogAndSorted() async throws {
      let (reads, _) = try await makeReads()
      let blogTwo = try await reads.tags(blogId: 2)
      #expect(!blogTwo.isEmpty)
      #expect(blogTwo.allSatisfy { $0.blogId == 2 })
      #expect(blogTwo.compactMap(\.name) == blogTwo.compactMap(\.name).sorted())
   }
}
