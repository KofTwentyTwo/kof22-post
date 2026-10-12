/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// The real `URLSession` code paths, driven through `StubURLProtocol`.
@Suite struct URLSessionPathTests {
   func stubURL(_ reply: StubReply, path: String = "/") throws -> (URL, String) {
      let host = StubRoutes.shared.register(reply)
      return (try #require(URL(string: "https://\(host)\(path)")), host)
   }

   @Test func loaderReturnsBodyAndHTTPResponse() async throws {
      let (url, _) = try stubURL(.http(status: 201, body: "created"))
      let (data, response) = try await HTTPLoaders.urlSession(StubURLProtocol.makeSession())(URLRequest(url: url))
      #expect(data == Data("created".utf8))
      #expect(response.statusCode == 201)
   }

   @Test func loaderRejectsResponsesThatAreNotHTTP() async throws {
      let (url, _) = try stubURL(.nonHTTP)
      await #expect(throws: URLError(.badServerResponse)) {
         try await HTTPLoaders.urlSession(StubURLProtocol.makeSession())(URLRequest(url: url))
      }
   }

   @Test func uploadPutsTheFileWithTheTicketHeaders() async throws {
      let (url, host) = try stubURL(.http(status: 200, body: ""), path: "/bucket/photo.jpg")
      let file = TestImages.temporaryDirectory().appending(path: "photo.jpg")
      try Data("jpeg bytes".utf8).write(to: file)
      let performer = URLSessionUploadPerformer(session: StubURLProtocol.makeSession())
      try await performer.put(fileURL: file, to: url, headers: ["Content-Type": "image/jpeg"])
      let request = try #require(StubRoutes.shared.requests(for: host).first)
      #expect(request.httpMethod == "PUT")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
      #expect(request.timeoutInterval == URLSessionUploadPerformer.uploadTimeout)
   }

   @Test func rejectedUploadCarriesTheStorageMessage() async throws {
      let (url, _) = try stubURL(.http(status: 403, body: "Signature expired"))
      let file = TestImages.temporaryDirectory().appending(path: "photo.jpg")
      try Data("jpeg bytes".utf8).write(to: file)
      let performer = URLSessionUploadPerformer(session: StubURLProtocol.makeSession())
      let error = await #expect(throws: APIError.self) { try await performer.put(fileURL: file, to: url, headers: [:]) }
      #expect(error?.status == 403)
      #expect(error?.code == "upload_put_failed")
      #expect(error?.message == "Signature expired")
   }

   @Test func rejectedUploadWithABinaryBodyGetsAGenericMessage() async throws {
      let (url, _) = try stubURL(.httpData(status: 500, body: Data([0xFF, 0xFE, 0xFD])))
      let file = TestImages.temporaryDirectory().appending(path: "photo.jpg")
      try Data("jpeg bytes".utf8).write(to: file)
      let performer = URLSessionUploadPerformer(session: StubURLProtocol.makeSession())
      let error = await #expect(throws: APIError.self) { try await performer.put(fileURL: file, to: url, headers: [:]) }
      #expect(error?.message == "Upload failed")
   }

   @Test func uploadRejectsResponsesThatAreNotHTTP() async throws {
      let (url, _) = try stubURL(.nonHTTP)
      let file = TestImages.temporaryDirectory().appending(path: "photo.jpg")
      try Data("jpeg bytes".utf8).write(to: file)
      let performer = URLSessionUploadPerformer(session: StubURLProtocol.makeSession())
      await #expect(throws: URLError(.badServerResponse)) { try await performer.put(fileURL: file, to: url, headers: [:]) }
   }

   @Test func defaultUploadPerformerUsesTheSharedSession() {
      #expect(URLSessionUploadPerformer().session === URLSession.shared)
   }
}

@Suite struct SiteServiceSetupTests {
   @Test func liveServiceIsBuiltWithoutTouchingTheNetwork() {
      let auth = AuthSession(mode: .live, store: MemorySecureStore())
      let service = SiteService.live(auth: auth)
      #expect(service.uploader is URLSessionUploadPerformer)
   }

   @Test func versionsNeedNoSignIn() async throws {
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      let service = SiteService.mock(backend: MockBackend(directory: nil), auth: auth)
      let versions = try await service.versions()
      #expect(versions.supportedVersions.contains("v1"))
      await #expect(throws: AuthError.signedOut) { try await service.me() }
   }

   @Test func uploadTicketWithoutAUsableURLIsRejected() async throws {
      let (service, _, _) = try await makeMockService()
      let ticket = UploadTicket(
         uploadId: "u1", uploadUrl: "", method: .put, headers: .init(), expiresAt: .now, maxBytes: 1_024, completeUrl: "")
      let file = TestImages.temporaryDirectory().appending(path: "photo.jpg")
      await #expect(throws: URLError(.badURL)) { try await service.putUpload(fileURL: file, ticket: ticket) }
   }
}

/// Collects what a test transport was sent, across concurrent calls.
final class SentRequests: @unchecked Sendable {
   /// One request as the transport saw it.
   struct Attempt {
      /// The `Authorization` header value.
      let token: String
      /// The request body.
      let body: Data
   }

   /// Guards `attempts`.
   private let lock = NSLock()
   /// Every request in order.
   private var attempts: [Attempt] = []

   /// Records one request and returns how many have been seen.
   func record(_ token: String, _ body: Data) -> Int {
      lock.withLock {
         attempts.append(Attempt(token: token, body: body))
         return attempts.count
      }
   }

   /// The requests seen so far.
   var all: [Attempt] { lock.withLock { attempts } }
}

@Suite struct MiddlewareEdgeTests {
   let request = HTTPRequest(method: .get, scheme: "https", authority: "api.kof22.com", path: "/v1/me")
   let baseURL = URL(literal: "https://api.kof22.com")

   @Test func rejectedTokenIsRefreshedAndTheSameBodyReplayed() async throws {
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: NoWebAuthenticator())
      let sent = SentRequests()
      let post = HTTPRequest(method: .post, scheme: "https", authority: "api.kof22.com", path: "/v1/me/posts")
      let (response, _) = try await AuthMiddleware(auth: auth)
         .intercept(post, body: HTTPBody(#"{"body":"hello"}"#), baseURL: baseURL, operationID: "createPost") { request, body, _ in
            let bytes = try await Data(collecting: try #require(body), upTo: .max)
            let count = sent.record(request.headerFields[.authorization] ?? "", bytes)
            return (HTTPResponse(status: count == 1 ? .unauthorized : .created), nil)
         }
      #expect(response.status == .created)
      let attempts = sent.all
      #expect(attempts.count == 2)
      #expect(attempts[0].token != attempts[1].token)
      #expect(attempts.allSatisfy { $0.body == Data(#"{"body":"hello"}"#.utf8) })
   }

   @Test func oversizedErrorBodyStillYieldsATypedError() async throws {
      let huge = HTTPBody(Data(count: ErrorEnvelopeMiddleware.maximumErrorBodyBytes * 2))
      let error = await #expect(throws: APIError.self) {
         _ = try await ErrorEnvelopeMiddleware()
            .intercept(request, body: nil, baseURL: baseURL, operationID: "getMe") { _, _, _ in
               (HTTPResponse(status: .internalServerError), huge)
            }
      }
      #expect(error?.status == 500)
      #expect(error?.code == "http_500")
   }

   @Test func errorWithoutABodyUsesTheStatus() async throws {
      let error = await #expect(throws: APIError.self) {
         _ = try await ErrorEnvelopeMiddleware()
            .intercept(request, body: nil, baseURL: baseURL, operationID: "getMe") { _, _, _ in
               (HTTPResponse(status: .notFound), nil)
            }
      }
      #expect(error?.code == "http_404")
   }

   @Test func explicitNullLeavesBodiesWithoutTheSentinelAlone() {
      let plain = Data(#"{"body":"b"}"#.utf8)
      #expect(ExplicitNullMiddleware.rewrite(plain) == plain)
      let array = Data(#"["__kof22_null__"]"#.utf8)
      #expect(ExplicitNullMiddleware.rewrite(array) == array)
      let notJSON = Data("not json".utf8)
      #expect(ExplicitNullMiddleware.rewrite(notJSON) == notJSON)
   }

   @Test func explicitNullOnlyTouchesPostUpdates() async throws {
      let body = Data(#"{"linkUrl":"__kof22_null__"}"#.utf8)
      let (_, forwarded) = try await ExplicitNullMiddleware()
         .intercept(request, body: HTTPBody(body), baseURL: baseURL, operationID: "createPost") { _, body, _ in
            (HTTPResponse(status: .ok), body)
         }
      let sent = try await Data(collecting: try #require(forwarded), upTo: .max)
      #expect(sent == body)
   }
}

@Suite struct OAuthEdgeTests {
   @Test func serverFailureCarriesTheProviderDescription() async {
      let stub = StubLoader([(500, #"{"error":"server_error","error_description":"Try later"}"#)])
      await #expect(throws: AuthError.server(status: 500, message: "Try later")) {
         try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
      }
   }

   @Test func failureWithoutOAuthBodyGetsAGenericMessage() async {
      let stub = StubLoader([(502, "<html>bad gateway</html>")])
      await #expect(throws: AuthError.server(status: 502, message: "Token request failed")) {
         try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
      }
   }

   @Test func tokenLifetimeDefaultsWhenTheProviderOmitsIt() async throws {
      let stub = StubLoader([(200, #"{"access_token":"a1","id_token":"i1"}"#)])
      let now = Date(timeIntervalSince1970: 5_000)
      let tokens = try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1", now: now)
      #expect(tokens.expiresAt == now.addingTimeInterval(OAuthClient.defaultTokenLifetime))
      #expect(tokens.idToken == "i1")
   }

   @Test func revocationFailureDoesNotStopSignOut() async {
      let attempts = StubLoader([])
      let failing: HTTPLoader = { request in
         _ = try await attempts.loader(request)
         throw URLError(.notConnectedToInternet)
      }
      await OAuthClient(config: .kof22, load: failing).revoke("token", hint: "access_token")
      #expect(attempts.requestCount == 1)
      #expect(attempts.requests.first?.timeoutInterval == OAuthClient.revokeTimeout)
   }

   @Test func callbackWithoutCodeIsRejected() {
      let client = OAuthClient(config: .kof22, load: StubLoader([]).loader)
      let url = URL(literal: "com.kof22.post://oauth/callback?state=abc&code=")
      #expect(throws: AuthError.missingCode) { try client.code(fromCallback: url, expectedState: "abc") }
   }

   @Test func formValuesAreStrictlyEncoded() {
      #expect(OAuthClient.formEncode("kof22:publish a+b") == "kof22%3Apublish%20a%2Bb")
      #expect(OAuthClient.formEncode("-._~AZaz09") == "-._~AZaz09")
      #expect(OAuthClient.formEncode("café") == "caf%C3%A9")
   }

   @Test func callbackWithoutQueryFailsTheStateCheck() {
      let client = OAuthClient(config: .kof22, load: StubLoader([]).loader)
      #expect(throws: AuthError.stateMismatch) {
         try client.code(fromCallback: URL(literal: "com.kof22.post://oauth/callback"), expectedState: "abc")
      }
   }

   @Test func deniedSignInWithoutDescriptionReportsTheErrorCode() {
      let client = OAuthClient(config: .kof22, load: StubLoader([]).loader)
      let url = URL(literal: "com.kof22.post://oauth/callback?error=access_denied&state=abc")
      #expect(throws: AuthError.authorizationDenied("access_denied")) { try client.code(fromCallback: url, expectedState: "abc") }
   }
}
