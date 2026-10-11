import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// Exercises the generated client + hand-written layer against the mock contract.
@Suite struct SiteServiceTests {
   @Test func meListsBlogsAndLimits() async throws {
      let (service, _, _) = try await makeMockService()
      let me = try await service.me()
      #expect(me.defaultBlog == "quick-bits")
      #expect(me.blogs.map(\.slug) == ["quick-bits", "deep-thoughts"])
      #expect(me.limits.maxPhotosPerPost == 20)
   }

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

   @Test func validationErrorsCarryDetails() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) {
         try await service.createPost(PostCreate(title: String(repeating: "t", count: 101), body: "x"), idempotencyKey: "k-validation")
      }
      #expect(error?.status == 422)
      #expect(error?.details.first?.field == "title")
      #expect(ErrorClassifier.disposition(for: error!) == .permanent)
   }

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
      #expect(ErrorClassifier.disposition(for: stale!) == .conflict)
   }

   @Test func listPagesWithCursor() async throws {
      let (service, _, _) = try await makeMockService()
      for n in 0..<5 { _ = try await service.createPost(PostCreate(body: "post \(n)"), idempotencyKey: "k-page-\(n)-xx") }
      let first = try await service.myPosts(limit: 4)
      #expect(first.items.count == 4)
      let second = try await service.myPosts(cursor: first.nextCursor, limit: 4)
      #expect(second.nextCursor == nil)
      #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
      let drafts = try await service.myPosts(status: .draft)
      #expect(drafts.items.allSatisfy { $0.status == .draft })
   }

   @Test func deleteRemovesThePost() async throws {
      let (service, _, _) = try await makeMockService()
      let post = try await service.createPost(PostCreate(body: "bye"), idempotencyKey: "k-delete-1")
      try await service.deletePost(id: post.id, ifMatch: post.version)
      let error = await #expect(throws: APIError.self) { try await service.post(id: post.id) }
      #expect(error?.status == 404)
   }

   @Test func tagAutocompleteOrdersPrefixMatchesFirst() async throws {
      let (service, _, _) = try await makeMockService()
      _ = try await service.createPost(PostCreate(body: "x", tags: ["Unixy", "MiniUnix"]), idempotencyKey: "k-tags-1")
      let names = try await service.tags(matching: "uni", blog: "quick-bits").map(\.name)
      #expect(names == ["Unix", "Unixy", "MiniUnix"])
   }

   @Test func heicUploadIsRefusedLikeProduction() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) {
         try await service.createUpload(UploadCreate(fileName: "a.heic", contentType: .imageHeic, byteSize: 10), idempotencyKey: "k-heic-1")
      }
      #expect(error?.status == 415)
      #expect(error?.code == "heic_conversion_unavailable")
   }

   @Test func linkPreviewRejectsNonHTTP() async throws {
      let (service, _, _) = try await makeMockService()
      let error = await #expect(throws: APIError.self) { try await service.linkPreview(for: "file:///etc/passwd") }
      #expect(error?.code == "link_not_allowed")
      #expect(try await service.linkPreview(for: "https://www.apple.com/").title?.contains("apple.com") == true)
   }

   @Test func offlineIsRetryable() async throws {
      let (service, backend, _) = try await makeMockService()
      await backend.setSimulateOffline(true)
      let error = await #expect(throws: URLError.self) { try await service.me() }
      #expect(ErrorClassifier.disposition(for: error!) == .retryLater(after: nil))
   }
}

@Suite struct MiddlewareTests {
   /// Replies 401 to the first request and records the bearer tokens it saw.
   final class UnauthorizedOnceTransport: ClientTransport, @unchecked Sendable {
      let lock = NSLock()
      var tokens: [String] = []

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
         let me = try MockBackend.encoder.encode(await MockBackend(directory: nil).me())
         return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(me))
      }
   }

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

   @Test func explicitNullRewritesSentinel() throws {
      let input = Data(#"{"body":"b","linkUrl":"__kof22_null__"}"#.utf8)
      let output = try JSONSerialization.jsonObject(with: ExplicitNullMiddleware.rewrite(input)) as! [String: Any]
      #expect(output["linkUrl"] is NSNull)
      #expect(output["body"] as? String == "b")
   }

   @Test func etagsAreQuotedOnTheWire() {
      #expect(SiteService.quoted("abc") == "\"abc\"")
      #expect(SiteService.quoted("\"abc\"") == "\"abc\"")
      #expect(SiteService.quoted("*") == "*")
   }
}

@Suite struct WireFormatTests {
   final class CapturingTransport: ClientTransport, @unchecked Sendable {
      var ifMatch: String?
      func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
         ifMatch = request.headerFields[HTTPField.Name("If-Match")!]
         return (HTTPResponse(status: .noContent), nil)
      }
   }

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
