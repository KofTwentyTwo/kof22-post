/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// The spec allows bearer tokens on `/v1/me` and below only.
@Suite struct BearerScopeTests {
   let serverURL = URL(literal: "https://api.kof22.com")

   @Test(arguments: ["/v1/me", "/v1/me?x=1", "/v1/me/posts", "/v1/me/posts/4?expand=1", "/v1/me/uploads/u1/complete"])
   func authoringPathsCarryTheBearer(path: String) {
      #expect(AuthMiddleware.needsBearer(path))
   }

   @Test(arguments: ["/versions.json", "/v1/post/query?pageSize=3", "/v1/blog/query", "/v1/men", "/v1/meta/me", "/me", "", nil])
   func otherPathsDoNot(path: String?) {
      #expect(!AuthMiddleware.needsBearer(path))
   }

   @Test func onlyMeRequestsAreSentWithTheToken() async throws {
      let transport = FixtureTransport([
         "getApiVersions": try .okay("versions"), "getMe": try .okay("me"), "queryBlog": try .okay("blog-query"),
         "getPost": try .okay("post-1"),
      ])
      let service = SiteService(serverURL: serverURL, transport: transport, auth: StubAuthSession(signedIn: true), uploader: URLSessionUploadPerformer())
      _ = try await service.versions()
      _ = try await service.me()
      _ = try await service.reads.blogs()
      _ = try await service.reads.post(id: 1)
      #expect(transport.authorization(for: "getApiVersions") == [nil])
      #expect(transport.authorization(for: "getMe") == ["Bearer stub-access-1"])
      #expect(transport.authorization(for: "queryBlog") == [nil])
      #expect(transport.authorization(for: "getPost") == [nil])
   }

   @Test func readsWorkWhileSignedOut() async throws {
      let transport = FixtureTransport(["getApiVersions": try .okay("versions"), "queryTag": try .okay("tag-query")])
      let service = SiteService(serverURL: serverURL, transport: transport, auth: StubAuthSession(), uploader: URLSessionUploadPerformer())
      #expect(try await service.versions().currentVersion == "v1")
      #expect(try await service.reads.tags(blogId: 2).count == 5)
   }

   @Test func a401OnAnAnonymousRequestNeverRefreshes() async throws {
      let unauthorized = #"{"error":{"code":"unauthorized","message":"No","status":401}}"#
      let transport = FixtureTransport(["getApiVersions": .init(status: 401, body: Data(unauthorized.utf8))])
      let auth = StubAuthSession(signedIn: true)
      let service = SiteService(serverURL: serverURL, transport: transport, auth: auth, uploader: URLSessionUploadPerformer())
      await #expect(throws: APIError.self) { try await service.versions() }
      #expect(transport.requests.count == 1)
      #expect(try await auth.accessToken() == "stub-access-1")
   }

   @Test func middlewareLeavesAnonymousRequestsUntouched() async throws {
      let auth = StubAuthSession()
      let request = HTTPRequest(method: .get, scheme: "https", authority: "api.kof22.com", path: "/v1/post/query?pageSize=3")
      let (response, _) = try await AuthMiddleware(auth: auth)
         .intercept(request, body: nil, baseURL: serverURL, operationID: "queryPost") { sent, _, _ in
            #expect(sent.headerFields[.authorization] == nil)
            return (HTTPResponse(status: .unauthorized), nil)
         }
      #expect(response.status == .unauthorized)
   }

   @Test func liveServiceTakesAnUploader() {
      let service = SiteService.live(auth: StubAuthSession(), uploader: MockUploadPerformer(backend: MockBackend(directory: nil)))
      #expect(service.uploader is MockUploadPerformer)
   }
}
