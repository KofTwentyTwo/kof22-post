/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import Testing

@testable import KoF22Kit

/// The mock must follow the Site API v1 contract rule by rule, so the app behaves
/// the same against it as against the live backend.
@Suite struct MockBackendContractTests {
   /// A mock with files on disk and a controllable clock.
   static func makeCaller(clock: TestClock = TestClock()) throws -> (MockCaller, URL) {
      let directory = try KitFiles.makeDirectory()
      return (MockCaller(backend: MockBackend(directory: directory, now: clock.provider)), directory)
   }

   @Test func unknownOperationIsNotFound() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let response = try await caller.call("deleteEverything")
      #expect(response.status == 404)
      #expect(try caller.errorCode(response) == "not_found")
   }

   @Test func transportHandlesRequestsWithoutAPathOrQueryValues() async throws {
      let transport = MockTransport(backend: MockBackend(directory: nil))
      let noPath = HTTPRequest(method: .get, scheme: nil, authority: nil, path: nil)
      let (missing, _) = try await transport.send(noPath, body: nil, baseURL: URL(literal: "https://mock.invalid"), operationID: "nothing")
      #expect(missing.status.code == 404)
      let unparsable = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "http://[bad")
      let (unrouted, _) = try await transport.send(unparsable, body: nil, baseURL: URL(literal: "https://mock.invalid"), operationID: "nothing")
      #expect(unrouted.status.code == 404)
      let flagged = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/v1/me/posts?status")
      let (refused, _) = try await transport.send(flagged, body: nil, baseURL: URL(literal: "https://mock.invalid"), operationID: "listMyPosts")
      #expect(refused.status.code == 400)
   }

   @Test func anEmptyIssueListStillReadsAsAValidationFailure() async throws {
      let backend = MockBackend(directory: nil)
      let caller = MockCaller(backend: backend)
      let response = try await backend.validation([])
      #expect(try caller.decode(Components.Schemas._Error.self, response).error.message == "Validation failed")
   }

   @Test func versionsReportV1WithTheVersionHeader() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let response = try await caller.call("getApiVersions")
      #expect(response.headers["X-API-Version"] == "1.0.0")
      #expect(try caller.decode(APIVersions.self, response).currentVersion == "v1")
   }

   @Test func latencyDelaysButStillAnswers() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil, latency: .milliseconds(1)))
      #expect(try await caller.call("getMe").status == 200)
   }

   @Test func offlineFailsEveryRequestAndUpload() async throws {
      let backend = MockBackend(directory: nil)
      await backend.setSimulateOffline(true)
      await #expect(throws: URLError.self) { try await MockCaller(backend: backend).call("getMe") }
      let performer = MockUploadPerformer(backend: backend)
      await #expect(throws: URLError.self) {
         try await performer.put(fileURL: URL(filePath: "/dev/null"), to: URL(literal: "https://mock.invalid/x"), headers: [:])
      }
   }

   @Test func mockMediaURLsResolveOnlyForTheMockScheme() {
      let backend = MockBackend(directory: nil)
      let base = URL(filePath: "/tmp/mock")
      #expect(backend.fileURL(forMockMedia: "https://example.com/a.jpg", directory: base) == nil)
      #expect(backend.fileURL(forMockMedia: "mock-media:media-1.jpg", directory: base)?.lastPathComponent == "media-1.jpg")
   }

   // MARK: - Listing

   @Test func listRejectsUnknownStatusAndBadCursors() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let undated = try await caller.call("listMyPosts")
      #expect(undated.status == 200)
      let badStatus = try await caller.call("listMyPosts", query: ["status": "archived"])
      #expect(badStatus.status == 400)
      for cursor in ["%%%", Data("abc".utf8).base64EncodedString(), Data("-3".utf8).base64EncodedString()] {
         let response = try await caller.call("listMyPosts", query: ["cursor": cursor])
         #expect(response.status == 400)
      }
   }

   @Test func listPagesNewestFirstAndClampsTheLimit() async throws {
      let clock = TestClock()
      let (caller, _) = try Self.makeCaller(clock: clock)
      for index in 0..<3 {
         clock.advance(by: 60)
         _ = try await caller.create(PostCreate(body: "post \(index)"))
      }
      let first = try caller.decode(PostPage.self, try await caller.call("listMyPosts", query: ["limit": "0"]))
      #expect(first.items.map(\.body) == ["post 2"])
      let cursor = try #require(first.nextCursor)
      let rest = try caller.decode(PostPage.self, try await caller.call("listMyPosts", query: ["cursor": cursor, "limit": "999"]))
      #expect(rest.items.count == 4)
      #expect(rest.nextCursor == nil)
      let drafts = try caller.decode(PostPage.self, try await caller.call("listMyPosts", query: ["status": "draft"]))
      #expect(drafts.items.allSatisfy { $0.status == .draft })
   }

   // MARK: - Create

   @Test func createWithoutAJSONBodyIsABadRequest() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let response = try await caller.call("createPost", raw: Data("not json".utf8))
      #expect(response.status == 400)
      #expect(try await caller.call("createPost", raw: nil).status == 400)
      #expect(try await caller.call("createPost", headers: ["idempotency-key": "k-no-body-1"], raw: nil).status == 400)
   }

   @Test func createValidatesEveryTextLimit() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let cases: [(PostCreate, String)] = [
         (PostCreate(body: "  "), "body"),
         (PostCreate(body: String(repeating: "b", count: 10_001)), "body"),
         (PostCreate(title: String(repeating: "t", count: 101), body: "x"), "title"),
         (PostCreate(body: "x", locationLabel: String(repeating: "l", count: 201)), "locationLabel"),
         (PostCreate(blog: "nope", body: "x"), "blog"),
         (PostCreate(body: "x", tags: (0...10).map { "tag\($0)" }), "tags"),
         (PostCreate(body: "x", tags: ["#", String(repeating: "g", count: 51), "!!!"]), "tags"),
         (PostCreate(body: "x", linkUrl: "http://localhost/admin"), "linkUrl"),
         (PostCreate(body: "x", media: [MediaAttachment(mediaId: 999)]), "media"),
         (PostCreate(body: "x", media: (0...20).map { MediaAttachment(mediaId: Int64($0)) }), "media"),
      ]
      for (input, field) in cases {
         let response = try await caller.call("createPost", json: input)
         #expect(response.status == 422)
         #expect(try caller.errorCode(response) == "validation_failed")
         #expect(try caller.firstIssueField(response) == field)
      }
   }

   @Test func schedulingNeedsATimeWithinTheAllowedWindow() async throws {
      let clock = TestClock()
      let caller = MockCaller(backend: MockBackend(directory: nil, now: clock.provider))
      let tooSoon = PostCreate(body: "x", status: .scheduled, publishAt: clock.now.addingTimeInterval(10))
      let tooLate = PostCreate(body: "x", status: .scheduled, publishAt: clock.now.addingTimeInterval(367 * 86_400))
      for input in [PostCreate(body: "x", status: .scheduled), tooSoon, tooLate] {
         let response = try await caller.call("createPost", json: input)
         #expect(try caller.firstIssueField(response) == "publishAt")
      }
   }

   @Test func scheduledPostsPublishWhenTheirTimeComes() async throws {
      let clock = TestClock()
      let caller = MockCaller(backend: MockBackend(directory: nil, now: clock.provider))
      let publishAt = clock.now.addingTimeInterval(3_600)
      let post = try await caller.create(PostCreate(body: "later", status: .scheduled, publishAt: publishAt))
      #expect(post.status == .scheduled)
      #expect(post.url == nil)
      clock.advance(by: 7_200)
      let promoted = try caller.decode(Post.self, try await caller.call("getMyPost", path: "/v1/me/posts/\(post.id)"))
      #expect(promoted.status == .published)
      #expect(promoted.publishedAt == publishAt)
      #expect(promoted.url != nil)
   }

   @Test func explicitTitlesGiveUniqueSlugs() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let first = try await caller.create(PostCreate(title: "Same Title", body: "one", status: .published))
      let second = try await caller.create(PostCreate(title: "Same Title", body: "two"))
      let third = try await caller.create(PostCreate(title: "Same Title", body: "three"))
      #expect([first.slug, second.slug, third.slug] == ["same-title", "same-title-2", "same-title-3"])
      #expect(first.url == "https://www.kof22.com/blogs/quick-bits/same-title")
      let symbols = try await caller.create(PostCreate(title: "!!!", body: "symbols only"))
      #expect(symbols.title == "!!!")
      #expect(!symbols.slug.isEmpty)
   }

   @Test func createAnswersWithLocationAndETag() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let response = try await caller.call(
         "createPost", headers: ["idempotency-key": "k-location-1"],
         json: PostCreate(body: "x", locationLabel: "  ", linkUrl: ""))
      #expect(response.status == 201)
      let post = try caller.decode(Post.self, response)
      #expect(response.headers["Location"] == "https://api.kof22.com/v1/me/posts/\(post.id)")
      #expect(response.headers["ETag"] == "\"\(post.version)\"")
      #expect(post.locationLabel == nil)
      #expect(post.link == nil)
   }

   // MARK: - Idempotency

   @Test func idempotencyKeysAreValidatedAndReplayed() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let badKey = try await caller.call("createPost", headers: ["idempotency-key": "short"], json: PostCreate(body: "x"))
      #expect(try caller.firstIssueField(badKey) == "Idempotency-Key")
      let spaces = try await caller.call("createPost", headers: ["idempotency-key": "has spaces in it"], json: PostCreate(body: "x"))
      #expect(spaces.status == 422)

      let refused = try await caller.call("createPost", headers: ["idempotency-key": "k-replay-1"], json: PostCreate(body: " "))
      #expect(refused.status == 422)
      let created = try await caller.call("createPost", headers: ["idempotency-key": "k-replay-1"], json: PostCreate(body: "ok"))
      #expect(created.status == 201)
      let replayed = try await caller.call("createPost", headers: ["idempotency-key": "k-replay-1"], json: PostCreate(body: "ok"))
      #expect(replayed.headers["Idempotent-Replayed"] == "true")
      #expect(replayed.body == created.body)
   }

}

/// Reading, updating and deleting posts, and the tag and link endpoints.
extension MockBackendContractTests {

   @Test func readingAMissingPostIsNotFound() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      #expect(try await caller.call("getMyPost", path: "/v1/me/posts/9999").status == 404)
      #expect(try await caller.call("getMyPost", path: "/v1/me/posts/abc").status == 404)
   }

   @Test func updateChecksExistencePreconditionAndBody() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let post = try await caller.create(PostCreate(body: "v1"))
      let path = "/v1/me/posts/\(post.id)"
      #expect(try await caller.call("updatePost", path: "/v1/me/posts/9999", headers: ["if-match": "*"], json: PostUpdate()).status == 404)
      #expect(try await caller.call("updatePost", path: path, json: PostUpdate(body: "v2")).status == 428)
      let stale = try await caller.call("updatePost", path: path, headers: ["if-match": "\"old\""], json: PostUpdate(body: "v2"))
      #expect(stale.status == 412)
      #expect(stale.headers["ETag"] == "\"\(post.version)\"")
      #expect(try await caller.call("updatePost", path: path, headers: ["if-match": "*"], raw: Data("[1]".utf8)).status == 400)
      #expect(try await caller.call("updatePost", path: path, headers: ["if-match": "*"], raw: nil).status == 400)
   }

   @Test func updateAppliesOnlyTheFieldsSent() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let post = try await caller.create(PostCreate(body: "# Original", tags: ["Swift"], linkUrl: "https://example.com"))
      let path = "/v1/me/posts/\(post.id)"
      let change = PostUpdate(
         blog: "deep-thoughts", title: "  ", body: "New body", tags: ["Fresh"], locationLabel: "Lisbon",
         linkUrl: "https://www.apple.com/")
      let response = try await caller.call("updatePost", path: path, headers: ["if-match": "W/\"\(post.version)\""], json: change)
      let updated = try caller.decode(Post.self, response)
      #expect(updated.blog == "deep-thoughts")
      #expect(updated.title == "New body")
      #expect(updated.tags == ["Fresh"])
      #expect(updated.locationLabel == "Lisbon")
      #expect(updated.link?.title == "apple.com (mock preview)")
      #expect(updated.version != post.version)

      let cleared = try await caller.call(
         "updatePost", path: path, headers: ["if-match": updated.version], raw: Data(#"{"linkUrl":null,"media":[]}"#.utf8))
      #expect(try caller.decode(Post.self, cleared).link == nil)

      let nulls = try await caller.call(
         "updatePost", path: path, headers: ["if-match": "*"], raw: Data(#"{"title":null,"tags":null,"media":null}"#.utf8))
      let reset = try caller.decode(Post.self, nulls)
      #expect(reset.title == "New body")
      #expect(reset.tags.isEmpty)
      let nullBody = try await caller.call("updatePost", path: path, headers: ["if-match": "*"], raw: Data(#"{"body":null}"#.utf8))
      #expect(try caller.firstIssueField(nullBody) == "body")
   }

   @Test func updateRefusesInvalidFieldsWithoutChangingThePost() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let post = try await caller.create(PostCreate(body: "keep me"))
      let path = "/v1/me/posts/\(post.id)"
      let cases: [(PostUpdate, String)] = [
         (PostUpdate(body: ""), "body"),
         (PostUpdate(title: String(repeating: "t", count: 101)), "title"),
         (PostUpdate(blog: "nope"), "blog"),
         (PostUpdate(media: [MediaAttachment(mediaId: 42)]), "media"),
         (PostUpdate(status: .scheduled), "publishAt"),
      ]
      for (change, field) in cases {
         let response = try await caller.call("updatePost", path: path, headers: ["if-match": "*"], json: change)
         #expect(response.status == 422)
         #expect(try caller.firstIssueField(response) == field)
      }
      let unchanged = try caller.decode(Post.self, try await caller.call("getMyPost", path: path))
      #expect(unchanged.body == "keep me")
      #expect(unchanged.version == post.version)
   }

   @Test func statusChangesPublishOnceAndDraftRemovesTheURL() async throws {
      let clock = TestClock()
      let caller = MockCaller(backend: MockBackend(directory: nil, now: clock.provider))
      let post = try await caller.create(PostCreate(body: "status"))
      let path = "/v1/me/posts/\(post.id)"
      let published = try caller.decode(
         Post.self, try await caller.call("updatePost", path: path, headers: ["if-match": "*"], json: PostUpdate(status: .published)))
      #expect(published.publishedAt == clock.now)
      clock.advance(by: 60)
      let again = try caller.decode(
         Post.self, try await caller.call("updatePost", path: path, headers: ["if-match": "*"], json: PostUpdate(status: .published)))
      #expect(again.publishedAt == published.publishedAt)
      let draft = try caller.decode(
         Post.self, try await caller.call("updatePost", path: path, headers: ["if-match": "*"], json: PostUpdate(status: .draft)))
      #expect(draft.url == nil)
      #expect(draft.publishedAt == nil)
   }

   @Test func deleteHonoursIfMatchWhenGiven() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let post = try await caller.create(PostCreate(body: "bye"))
      let path = "/v1/me/posts/\(post.id)"
      #expect(try await caller.call("deletePost", path: "/v1/me/posts/9999").status == 404)
      #expect(try await caller.call("deletePost", path: path, headers: ["if-match": "\"stale\""]).status == 412)
      let deleted = try await caller.call("deletePost", path: path, headers: ["if-match": ""])
      #expect(deleted.status == 204)
      #expect(deleted.body == nil)
   }

   @Test func tagAutocompleteDefaultsToTheDefaultBlog() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let all = try caller.decode(Components.Schemas.TagList.self, try await caller.call("listMyTags", query: ["blog": "unknown"]))
      #expect(all.items.map(\.name) == ["Apple", "Linux", "Programming", "Swift", "Unix"])
      let limited = try caller.decode(Components.Schemas.TagList.self, try await caller.call("listMyTags", query: ["q": "#a", "limit": "1"]))
      #expect(limited.items.map(\.name) == ["Apple"])
      let inside = try caller.decode(Components.Schemas.TagList.self, try await caller.call("listMyTags", query: ["q": "i"]))
      #expect(inside.items.map(\.name) == ["Linux", "Programming", "Swift", "Unix"])
   }

   @Test func linkPreviewNeedsABodyAndAPublicURL() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      #expect(try await caller.call("getLinkPreview", raw: nil).status == 400)
      let refused = try await caller.call("getLinkPreview", json: Components.Schemas.LinkPreviewRequest(url: "https:///nohost"))
      #expect(try caller.errorCode(refused) == "link_not_allowed")
      let preview = try await caller.call("getLinkPreview", json: Components.Schemas.LinkPreviewRequest(url: " https://kof22.com/a "))
      #expect(try caller.decode(LinkPreview.self, preview).title == "kof22.com (mock preview)")
   }
}
