/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The fake's table operations, query syntax and authoring rules.
@Suite struct MockBackendTableTests {
   /// A caller over a fresh in-memory fake.
   static func caller(clock: TestClock = TestClock(.now)) -> MockCaller {
      MockCaller(backend: MockBackend(directory: nil, now: clock.provider))
   }

   /// The records of a query reply.
   static func records<Record: Codable>(
      _ type: Record.Type, _ caller: MockCaller, _ operation: String, _ query: [String: String]
   )
      async throws -> [Record]
   {
      try caller.decode(QueryEnvelope<Record>.self, try await caller.call(operation, query: query)).records ?? []
   }

   @Test func blankIdentityFieldsAreDerived() async throws {
      let caller = Self.caller()
      let titled = try await caller.create(MockCaller.record("body", title: "A Typed Title"))
      #expect(titled.slug == "a-typed-title")
      #expect(titled.name == "A Typed Title")
      #expect(titled.shortName == "a-typed-title")
      let untitled = try await caller.create(MockCaller.record("First line\nrest"))
      #expect(untitled.title == "First line")
      #expect(untitled.slug?.count == "yyyyMMdd-HHmmss".count)
      let again = try await caller.create(MockCaller.record("other", title: "A Typed Title"))
      #expect(again.slug == "a-typed-title-2")
   }

   @Test func writesThatBreakTheRulesAreRefused() async throws {
      let caller = Self.caller()
      _ = try await caller.create(MockCaller.record("taken", title: "Taken"))
      var missing = MockCaller.record("x")
      missing.readTime = nil
      var unknownBlog = MockCaller.record("x")
      unknownBlog.blogId = 99
      var longName = MockCaller.record("x")
      longName.name = String(repeating: "n", count: PostFieldLimits.name + 1)
      var duplicate = MockCaller.record("x")
      duplicate.slug = "taken"
      var badImage = MockCaller.record("x")
      badImage.featuredMediaId = 404
      let expected = [
         (missing, "Missing value in required field: readTime"), (unknownBlog, "Unknown blog"),
         (longName, "The value for name is too long"), (duplicate, "Another record already exists with this Slug and Blog"),
         (badImage, "The featured image must be an active image of this site"),
      ]
      for (record, message) in expected {
         let response = try await caller.call("createBlogPost", json: record)
         #expect(response.status == MockBackend.Status.badRequest)
         #expect(caller.error(response).message == message)
      }
      #expect(try await caller.call("createBlogPost", raw: Data("x".utf8)).status == MockBackend.Status.badRequest)
   }

   @Test func updatesMergeClearAndCheck() async throws {
      let caller = Self.caller()
      var record = MockCaller.record("body", title: "Title")
      record.locationLabel = "Here"
      let post = try await caller.create(record)
      let id = try #require(post.id)
      let path = "/v2/blogPost/\(id)"
      let cleared = try await caller.call("updateBlogPost", path: path, raw: Data(#"{"locationLabel":null,"title":"","content":"New first"}"#.utf8))
      #expect(cleared.status == MockBackend.Status.noContent)
      let updated = try caller.decode(Components.Schemas.BlogPost.self, try await caller.call("getBlogPost", path: path))
      #expect(updated.locationLabel == nil)
      #expect(updated.title == "New first")
      #expect(updated.name == "Title")
      let tooLong = try await caller.call("updateBlogPost", path: path, raw: Data(#"{"slug":"\#(String(repeating: "s", count: 101))"}"#.utf8))
      #expect(tooLong.status == MockBackend.Status.badRequest)
      #expect(try await caller.call("updateBlogPost", path: path, raw: Data("[1]".utf8)).status == MockBackend.Status.badRequest)
      #expect(try await caller.call("updateBlogPost", path: "/v2/blogPost/1", raw: Data("{}".utf8)).status == MockBackend.Status.notFound)
      #expect(try await caller.call("deleteBlogPost", path: "/v2/blogPost/1").status == MockBackend.Status.notFound)
      #expect(try await caller.call("deleteBlogPost", path: path).status == MockBackend.Status.noContent)
   }

   @Test func tagsNeedANameAndABlog() async throws {
      let caller = Self.caller()
      let created = try await caller.call("createBlogTag", json: Components.Schemas.BlogTag(blogId: 1, name: "New Tag"))
      #expect(created.status == MockBackend.Status.created)
      let tags = try await Self.records(Components.Schemas.BlogTag.self, caller, "queryBlogTag", ["name": "New Tag"])
      #expect(tags.first?.slug == "new-tag")
      #expect(try await caller.call("createBlogTag", json: Components.Schemas.BlogTag(name: "No blog")).status == MockBackend.Status.badRequest)
   }

   @Test func filtersSupportTheQuerySyntax() async throws {
      let caller = Self.caller()
      let cases: [([String: String], [Int])] = [
         (["blogId": "2", "orderBy": "name DESC"], [1_006, 1_005]), (["id": "IN 1000,1001,9"], [1_000, 1_001]),
         (["name": "LIKE pro%"], [1_002]), (["name": "!Apple", "blogId": "2"], [1_006]), (["slug": "EMPTY"], []),
         (["description": "EMPTY", "blogId": "1", "orderBy": "blogId"], [1_000, 1_001, 1_002, 1_003, 1_004]),
         (["name": "LIKE swift"], [1_003]), (["blogId": "1", "pageNo": "2", "pageSize": "2"], [1_002, 1_003]),
      ]
      for (query, ids) in cases {
         #expect(try await Self.records(Components.Schemas.BlogTag.self, caller, "queryBlogTag", query).compactMap(\.id) == ids)
      }
      #expect(MockBackend.matches(nil, "LIKE a%") == false)
      #expect(MockBackend.fields(of: "not an object").isEmpty)
      #expect(MockBackend.lessThan("b", "c"))
   }

   @Test func everyTableAnswersReadsById() async throws {
      let caller = Self.caller()
      let reads = [
         ("getBlog", "/v2/blog/1"), ("getAuthor", "/v2/author/2"), ("getSite", "/v2/site/1"), ("querySite", "/"), ("queryAuthor", "/"),
         ("queryBlog", "/"),
      ]
      for (operation, path) in reads {
         #expect(try await caller.call(operation, path: path).status == MockBackend.Status.okay)
      }
      #expect(try await caller.call("getMedia", path: "/v2/media/1").status == MockBackend.Status.notFound)
      #expect(try await caller.call("dropTable").status == MockBackend.Status.notFound)
      #expect(try await caller.call("versions").status == MockBackend.Status.okay)
   }

   @Test func scheduledPostsArePublishedOnTime() async throws {
      let clock = TestClock(.now)
      let caller = Self.caller(clock: clock)
      var record = MockCaller.record("soon", published: false)
      record.scheduledPublishAt = clock.now.addingTimeInterval(60)
      let post = try await caller.create(record)
      #expect(post.isPublished == false)
      clock.advance(by: 120)
      let live = try caller.decode(Components.Schemas.BlogPost.self, try await caller.call("getBlogPost", path: "/v2/blogPost/\(post.id ?? 0)"))
      #expect(live.isPublished == true)
      #expect(live.scheduledPublishAt == nil)
      #expect(live.siteUrl?.hasSuffix("/blogs/quick-bits/\(post.slug ?? "")") == true)
   }
}

/// The fake's upload and link-preview processes.
@Suite struct MockBackendUploadTests {
   @Test func ticketsAreCheckedLikeProduction() async throws {
      let caller = MockBackendTableTests.caller()
      #expect(try await caller.call("createUpload", raw: Data("x".utf8)).status == MockBackend.Status.badRequest)
      let gif = try await caller.call("createUpload", json: UploadRequest(fileName: "a.gif", contentType: "image/gif", byteSize: 1))
      #expect(caller.error(gif).code == "unsupported_media_type")
      let huge = try await caller.call("createUpload", json: UploadRequest(fileName: "a.jpg", contentType: "image/jpeg", byteSize: .max))
      #expect(caller.error(huge).code == "image_too_large")
   }

   @Test func completingTwiceAnswersTheSameMedia() async throws {
      let caller = MockBackendTableTests.caller()
      let file = try KitFiles.makeDirectory().appending(path: "a.png")
      try KitFiles.writeImage(to: file, type: .png)
      let ticket = try caller.decode(
         UploadTicket.self, try await caller.call("createUpload", json: UploadRequest(fileName: "a.png", contentType: "image/png", byteSize: 1)))
      let path = "/v2/media/completeUpload/\(ticket.uploadId)"
      #expect(caller.error(try await caller.call("completeUpload", path: path, raw: nil)).code == "upload_not_received")
      try await caller.backend.receiveUpload(id: ticket.uploadId, from: file)
      let first = try caller.decode(MediaItem.self, try await caller.call("completeUpload", path: path, raw: nil))
      let second = try caller.decode(MediaItem.self, try await caller.call("completeUpload", path: path, raw: nil))
      #expect(first == second)
      #expect(first.mimeType == "image/png")
      #expect(first.url.hasPrefix("mock-media:"))
      #expect(try await caller.call("getMedia", path: "/v2/media/\(first.mediaId)").status == MockBackend.Status.okay)
      #expect(caller.error(try await caller.call("completeUpload", path: "/v2/media/completeUpload/none", raw: nil)).code == "not_found")
   }

   @Test func expiredAndUnknownUploadsAreRefused() async throws {
      let clock = TestClock(.now)
      let caller = MockBackendTableTests.caller(clock: clock)
      let file = try KitFiles.makeDirectory().appending(path: "a.jpg")
      try KitFiles.writeImage(to: file)
      await #expect(throws: APIError.self) { try await caller.backend.receiveUpload(id: "unknown", from: file) }
      let ticket = try caller.decode(
         UploadTicket.self, try await caller.call("createUpload", json: UploadRequest(fileName: "a.jpg", contentType: "image/jpeg", byteSize: 1)))
      clock.advance(by: MockBackend.uploadLifetime + 1)
      await #expect(throws: APIError.self) { try await caller.backend.receiveUpload(id: ticket.uploadId, from: file) }
      let expired = try await caller.call("completeUpload", path: "/v2/media/completeUpload/\(ticket.uploadId)", raw: nil)
      #expect(caller.error(expired).code == "upload_expired")
   }

   @Test func filesThatAreNotImagesAreRefused() async throws {
      let caller = MockBackendTableTests.caller()
      let file = try KitFiles.makeDirectory().appending(path: "a.jpg")
      try Data("not an image".utf8).write(to: file)
      let ticket = try caller.decode(
         UploadTicket.self, try await caller.call("createUpload", json: UploadRequest(fileName: "a.jpg", contentType: "image/jpeg", byteSize: 1)))
      try await caller.backend.receiveUpload(id: ticket.uploadId, from: file)
      try await caller.backend.receiveUpload(id: ticket.uploadId, from: file)
      let response = try await caller.call("completeUpload", path: "/v2/media/completeUpload/\(ticket.uploadId)", raw: nil)
      #expect(caller.error(response).code == "unsupported_media_type")
   }

   @Test func linkPreviewsAcceptOnlyWebLinks() async throws {
      let caller = MockBackendTableTests.caller()
      let page = try caller.decode(LinkPreview.self, try await caller.call("linkPreview", json: ["url": "https://example.com/story"]))
      #expect(page.title == "story")
      let root = try caller.decode(LinkPreview.self, try await caller.call("linkPreview", json: ["url": "https://example.com"]))
      #expect(root.title == "example.com")
      for body in [["url": "ftp://example.com"], ["url": "https://"], ["link": "x"]] {
         #expect(caller.error(try await caller.call("linkPreview", json: body)).code == "link_not_allowed")
      }
   }
}
