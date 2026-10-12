/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// Exercises the generated client + hand-written layer against the mock contract.
@Suite struct SiteServiceTests {
   /// The mock profile lists both blogs, the default blog and the photo limit.
   @Test func meListsBlogsAndLimits() async throws {
      let (service, _, _) = try await makeMockService()
      let profile = try await service.me()
      #expect(profile.defaultBlog == "quick-bits")
      #expect(profile.blogs.map(\.slug) == ["quick-bits", "deep-thoughts"])
      #expect(profile.limits.maxPhotosPerPost == 20)
   }

   /// Creating a post derives a plain-text title from the Markdown, dedupes tags and publishes it.
   @Test func createDerivesTitleAndPublishes() async throws {
      let (service, _, _) = try await makeMockService()
      let post = try await service.createPost(
         PostCreate(body: "## Hello *world*\nmore", status: .published, tags: ["#Swift", "swift"]),
         idempotencyKey: "test-create-derives-title"
      )
      #expect(post.title == "Hello world")
      #expect(post.status == .published)
      #expect(post.tags == ["Swift"])
      #expect(post.url?.hasPrefix("https://www.kof22.com/blogs/quick-bits/") == true)
   }

   /// Reusing an idempotency key replays the same post, and reusing it with a different body is refused.
   @Test func idempotentCreateReplaysTheSamePost() async throws {
      let (service, _, _) = try await makeMockService()
      let body = PostCreate(body: "once", status: .published)
      let first = try await service.createPost(body, idempotencyKey: "same-key-123")
      let second = try await service.createPost(body, idempotencyKey: "same-key-123")
      #expect(first.id == second.id)
      let reused = await #expect(throws: APIError.self) {
         try await service.createPost(PostCreate(body: "different"), idempotencyKey: "same-key-123")
      }
      #expect(reused?.code == "idempotency_key_reused")
   }

   /// A 422 response carries the failing field and is classified as permanent.
   @Test func validationErrorsCarryDetails() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) {
         try await service.createPost(PostCreate(title: String(repeating: "t", count: 101), body: "x"), idempotencyKey: "k-validation")
      }
      #expect(error?.status == 422)
      #expect(error?.details.first?.field == "title")
      let validation = try #require(error)
      #expect(ErrorClassifier.disposition(for: validation) == .permanent)
   }

   /// Scheduling without `publishAt` is rejected; with a future time it is accepted.
   @Test func scheduleNeedsAFutureTime() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) {
         try await service.createPost(PostCreate(body: "later", status: .scheduled), idempotencyKey: "k-schedule")
      }
      #expect(error?.details.first?.field == "publishAt")
      let post = try await service.createPost(
         PostCreate(body: "later", status: .scheduled, publishAt: .now.addingTimeInterval(3600)), idempotencyKey: "k-schedule-2"
      )
      #expect(post.status == .scheduled)
   }

   /// Updates need the current ETag; a stale one yields 412 with the current ETag and a conflict disposition.
   @Test func updateRequiresCurrentETag() async throws {
      let (service, _, _) = try await makeMockService()
      let post = try await service.createPost(PostCreate(body: "v1", linkUrl: "https://example.com/a"), idempotencyKey: "k-etag-1")
      #expect(post.link?.url == "https://example.com/a")
      let updated = try await service.updatePost(id: post.id, PostUpdate(body: "v2"), clearLink: true, ifMatch: post.version)
      #expect(updated.body == "v2")
      #expect(updated.link == nil)
      #expect(updated.version != post.version)

      let stale = await #expect(throws: APIError.self) {
         try await service.updatePost(id: post.id, PostUpdate(body: "v3"), ifMatch: post.version)
      }
      #expect(stale?.status == 412)
      #expect(stale?.currentETag == "\"\(updated.version)\"")
      let conflict = try #require(stale)
      #expect(ErrorClassifier.disposition(for: conflict) == .conflict)
   }

   /// Cursor paging returns disjoint pages and ends with a nil cursor; the status filter applies.
   @Test func listPagesWithCursor() async throws {
      let (service, _, _) = try await makeMockService()
      for index in 0..<5 {
         _ = try await service.createPost(PostCreate(body: "post \(index)"), idempotencyKey: "k-page-\(index)-xx")
      }
      let first = try await service.myPosts(limit: 4)
      #expect(first.items.count == 4)
      let second = try await service.myPosts(cursor: first.nextCursor, limit: 4)
      #expect(second.nextCursor == nil)
      #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
      let drafts = try await service.myPosts(status: .draft)
      #expect(drafts.items.allSatisfy { $0.status == .draft })
   }

   /// A deleted post is gone: fetching it returns 404.
   @Test func deleteRemovesThePost() async throws {
      let (service, _, _) = try await makeMockService()
      let post = try await service.createPost(PostCreate(body: "bye"), idempotencyKey: "k-delete-1")
      try await service.deletePost(id: post.id, ifMatch: post.version)
      let error = await #expect(throws: APIError.self) { try await service.post(id: post.id) }
      #expect(error?.status == 404)
   }

   /// Tag autocomplete lists prefix matches before substring matches.
   @Test func tagAutocompleteOrdersPrefixMatchesFirst() async throws {
      let (service, _, _) = try await makeMockService()
      _ = try await service.createPost(PostCreate(body: "x", tags: ["Unixy", "MiniUnix"]), idempotencyKey: "k-tags-1")
      let names = try await service.tags(matching: "uni", blog: "quick-bits").map(\.name)
      #expect(names == ["Unix", "Unixy", "MiniUnix"])
   }

   /// HEIC uploads are refused with 415, matching the production server.
   @Test func heicUploadIsRefusedLikeProduction() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) {
         try await service.createUpload(UploadCreate(fileName: "a.heic", contentType: .imageHeic, byteSize: 10), idempotencyKey: "k-heic-1")
      }
      #expect(error?.status == 415)
      #expect(error?.code == "heic_conversion_unavailable")
   }

   /// Link previews refuse non-HTTP URLs and resolve a web page title.
   @Test func linkPreviewRejectsNonHTTP() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) { try await service.linkPreview(for: "file:///etc/passwd") }
      #expect(error?.code == "link_not_allowed")
      #expect(try await service.linkPreview(for: "https://www.apple.com/").title?.contains("apple.com") == true)
   }

   /// A simulated offline backend raises a URL error that is classified as retry-later.
   @Test func offlineIsRetryable() async throws {
      let (service, backend, _) = try await makeMockService()
      await backend.setSimulateOffline(true)
      let error = await #expect(throws: URLError.self) { try await service.me() }
      let offline = try #require(error)
      #expect(ErrorClassifier.disposition(for: offline) == .retryLater(after: nil))
   }
}

/// Tests for the client middlewares: token refresh on 401, explicit nulls and ETag quoting.
@Suite struct MiddlewareTests {
   /// Replies 401 to the first request and records the bearer tokens it saw.
   final class UnauthorizedOnceTransport: ClientTransport, @unchecked Sendable {
      /// Guards `tokens`, which concurrent requests append to.
      let lock = NSLock()
      /// The `Authorization` header of each request, in order.
      var tokens: [String] = []

      /// Answers the first call with 401 and every later call with the mock profile.
      func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
         let count = lock.withLock {
            tokens.append(request.headerFields[.authorization] ?? "")
            return tokens.count
         }
         if count == 1 {
            return (
               HTTPResponse(status: .unauthorized, headerFields: [.contentType: "application/json"]),
               HTTPBody(#"{"error":{"code":"unauthorized","message":"expired","status":401}}"#)
            )
         }
         let profile = try MockBackend.encoder.encode(await MockBackend(directory: nil).me())
         return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(profile))
      }
   }

   /// A 401 makes the client refresh the token once and replay the request with the new token.
   @Test func unauthorizedTriggersOneRefreshAndReplay() async throws {
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: NoWebAuthenticator())
      let transport = UnauthorizedOnceTransport()
      let service = SiteService(
         serverURL: AppConfig.mockAPIBaseURL, transport: transport, auth: auth,
         uploader: MockUploadPerformer(backend: MockBackend(directory: nil)))
      _ = try await service.me()
      #expect(transport.tokens.count == 2)
      #expect(transport.tokens[0] != transport.tokens[1])
      #expect(transport.tokens.allSatisfy { $0.hasPrefix("Bearer mock-access-") })
   }

   /// The null sentinel is rewritten to a JSON `null`, other fields are left alone.
   @Test func explicitNullRewritesSentinel() throws {
      let input = Data(#"{"body":"b","linkUrl":"__kof22_null__"}"#.utf8)
      let output = try #require(try JSONSerialization.jsonObject(with: ExplicitNullMiddleware.rewrite(input)) as? [String: Any])
      #expect(output["linkUrl"] is NSNull)
      #expect(output["body"] as? String == "b")
   }

   /// ETags are wrapped in quotes once, and the `*` wildcard is left as is.
   @Test func etagsAreQuotedOnTheWire() {
      #expect(SiteService.quoted("abc") == "\"abc\"")
      #expect(SiteService.quoted("\"abc\"") == "\"abc\"")
      #expect(SiteService.quoted("*") == "*")
   }
}

/// Tests for headers as they appear on the wire.
@Suite struct WireFormatTests {
   /// Records the `If-Match` header of the last request and replies 204.
   final class CapturingTransport: ClientTransport, @unchecked Sendable {
      /// The `If-Match` header seen on the last request.
      var ifMatch: String?

      /// Captures `If-Match` and answers with No Content.
      func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
         let name = try #require(HTTPField.Name("If-Match"))
         ifMatch = request.headerFields[name]
         return (HTTPResponse(status: .noContent), nil)
      }
   }

   /// An unquoted ETag is sent in quotes exactly once in `If-Match`.
   @Test func ifMatchIsSentVerbatim() async throws {
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: NoWebAuthenticator())
      let transport = CapturingTransport()
      let service = SiteService(
         serverURL: AppConfig.mockAPIBaseURL, transport: transport, auth: auth,
         uploader: MockUploadPerformer(backend: MockBackend(directory: nil)))
      try await service.deletePost(id: 1, ifMatch: "0123456789abcdef0123")
      #expect(transport.ifMatch == "\"0123456789abcdef0123\"")
   }
}
