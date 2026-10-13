/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// Answers every request with a status and no body.
struct EmptyBodyTransport: ClientTransport {
   /// The status to answer with.
   let status: Int
   /// Replies without a body.
   func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
      (HTTPResponse(status: .init(code: status)), nil)
   }
}

/// The defaults used when the server, the store or a caller leaves a value out.
@Suite struct FallbackTests {
   /// A `/me` with a blog listed twice under one id.
   static let caller = #"""
      {"canPost":true,"author":{"id":1,"name":"A"},
       "blogs":[{"id":1,"slug":"quick-bits","name":"Q","isDefault":true},{"id":1,"slug":"again","name":"R","isDefault":false}]}
      """#

   @Test func photosWithoutOrderOrIdKeepTheirPlace() {
      var record = BlogPostRecord()
      record.media = [BlogPostMediaRecord(mediaId: 2, url: "b"), BlogPostMediaRecord(mediaId: 1, url: "a")]
      #expect(APIMapping.post(record, blogSlugs: [:], tagNames: [:]).media.count == 2)
   }

   @Test func emptyLimitsUseTheBackendDefaults() throws {
      #expect(try JSONDecoder().decode(PhotoLimits.self, from: Data("{}".utf8)) == .fallback)
   }

   @Test func aProcessAnswerWithoutABodyDoesNotDecode() async {
      let service = fixtureService(EmptyBodyTransport(status: 200))
      await #expect(throws: DecodingError.self) { try await service.me() }
   }

   @Test func queriesWithoutRecordsAreEmptyAndDuplicateBlogsCollapse() async throws {
      let transport = FixtureTransport([
         "me": .init(status: 200, body: Data(Self.caller.utf8)), "queryBlogTag": .init(status: 200, body: Data("{}".utf8)),
         "queryBlogPost": .init(status: 200, body: Data(#"{"records":[{"id":5,"blogId":1,"content":"x"}]}"#.utf8)),
      ])
      let service = fixtureService(transport)
      #expect(try await service.tags(matching: "", blog: nil).isEmpty)
      #expect(try await service.myPosts().items.first?.blog == Post.defaultBlogSlug)
   }

   @Test func updatingADraftWithoutAnAuthorKeepsTheStoredOneAndPublishesNow() async throws {
      let clock = TestClock()
      let backend = MockBackend(directory: nil, now: clock.provider)
      let (service, _) = try await makeSignedInService(backend)
      let draft = try await service.createPost(PostComposition(body: "draft", status: .draft).draft())
      #expect(draft.publishedAt == nil)
      let live = try await service.updatePost(id: draft.id, PostComposition(body: "now live").draft(), ifMatch: draft.version)
      #expect(live.authorId == draft.authorId)
      #expect(live.status == .published)
      #expect(live.publishedAt == clock.now)
   }

   @Test func theFakeDerivesFromMissingValues() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      var noContent = MockCaller.record("x")
      noContent.content = nil
      let refused = try await caller.call("createBlogPost", json: noContent)
      #expect(caller.error(refused).message == "Missing value in required field: content")
      let post = try await caller.create(MockCaller.record("body", title: "Named"))
      let path = "/v2/blogPost/\(post.id ?? 0)"
      _ = try await caller.call("updateBlogPost", path: path, raw: Data(#"{"slug":null,"shortName":null}"#.utf8))
      let updated = try caller.decode(Components.Schemas.BlogPost.self, try await caller.call("getBlogPost", path: path))
      #expect(updated.shortName == "")
      #expect(updated.siteUrl == nil)
   }

   @Test func theFakeTransportCopesWithOddRequests() async throws {
      let transport = MockTransport(backend: MockBackend(directory: nil))
      let base = URL(literal: "https://mock.api.kof22.invalid")
      for path in [nil, "/v2/blog/query?flag&pageSize=1", "%%"] as [String?] {
         let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
         let (response, _) = try await transport.send(request, body: nil, baseURL: base, operationID: "queryBlog")
         #expect(response.status.code == MockBackend.Status.okay)
      }
   }

   @Test func editingABarePostStartsWithEmptyFields() {
      let bare = Post(
         id: 1, blogId: 1, blog: "quick-bits", status: .draft, title: "", slug: "s", body: "b",
         media: [PostPhoto(mediaId: 3, url: "https://cdn/3.jpg")], version: "v")
      let composition = PostComposition(post: bare)
      #expect(composition.description.isEmpty)
      #expect(composition.metaTitle.isEmpty)
      #expect(composition.metaDescription.isEmpty)
      #expect(composition.metaKeywords.isEmpty)
      #expect(composition.photos.first?.altText == "")
      #expect(composition.photos.first?.caption == "")
      #expect(composition.featuredPhotoID == nil)
   }

   @Test func aKeptBlankTitleTakesTheSlugFromTheSuggestion() {
      let details = PostDetails(title: "Suggested", name: "", shortName: "", description: "", metaTitle: "", metaDescription: "", keywords: [])
      let result = PostComposition(body: "b").applying(details, keeping: [.title])
      #expect(result.title.isEmpty)
      #expect(result.slug == "suggested")
   }
}
