import Foundation
import Testing
@testable import KoF22Kit

@Suite struct PKCETests {
    @Test func challengeMatchesRFC7636Example() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE.generate().verifier
        #expect(verifier.count >= 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite struct OAuthClientTests {
    let client = OAuthClient(config: .kof22, load: StubLoader([]).loader)

    @Test func authorizationURLCarriesPKCEAndScopes() throws {
        let pkce = PKCE(verifier: "verifier-verifier-verifier-verifier-verifier")
        let url = client.authorizationURL(pkce: pkce, state: "abc")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://auth.kof22.com/application/o/authorize/"))
        #expect(items["client_id"] == "kof22-post-ios")
        #expect(items["redirect_uri"] == "com.kof22.post://oauth/callback")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["scope"] == "openid profile email offline_access kof22:publish")
        #expect(items["state"] == "abc")
    }

    @Test func callbackRejectsWrongState() {
        let url = URL(string: "com.kof22.post://oauth/callback?code=xyz&state=other")!
        #expect(throws: AuthError.stateMismatch) { try client.code(fromCallback: url, expectedState: "abc") }
    }

    @Test func callbackSurfacesAuthorizationError() {
        let url = URL(string: "com.kof22.post://oauth/callback?error=access_denied&error_description=Nope&state=abc")!
        #expect(throws: AuthError.authorizationDenied("Nope")) { try client.code(fromCallback: url, expectedState: "abc") }
    }

    @Test func exchangeSendsVerifierAndParsesTokens() async throws {
        let stub = StubLoader([(200, #"{"access_token":"a1","refresh_token":"r1","expires_in":1800,"token_type":"Bearer"}"#)])
        let client = OAuthClient(config: .kof22, load: stub.loader)
        let now = Date(timeIntervalSince1970: 1_000)
        let tokens = try await client.exchange(code: "c1", pkce: PKCE(verifier: "v1"), now: now)
        #expect(tokens == TokenSet(accessToken: "a1", refreshToken: "r1", idToken: nil, expiresAt: now.addingTimeInterval(1800)))
        let form = stub.form(0)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code_verifier"] == "v1")
        #expect(form["client_id"] == "kof22-post-ios")
        #expect(form["client_secret"] == nil)
    }

    @Test func refreshKeepsOldRefreshTokenWhenNotRotated() async throws {
        let stub = StubLoader([(200, #"{"access_token":"a2","expires_in":60}"#)])
        let tokens = try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
        #expect(tokens.refreshToken == "r1")
    }

    @Test func invalidGrantMeansSessionExpired() async {
        let stub = StubLoader([(400, #"{"error":"invalid_grant"}"#)])
        await #expect(throws: AuthError.sessionExpired) {
            try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
        }
    }
}

@Suite struct AuthSessionTests {
    struct CallbackAuthenticator: WebAuthenticator {
        func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: "\(callbackScheme)://oauth/callback?code=the-code&state=\(state)")!
        }
    }

    @Test func liveSignInStoresTokensAndRefreshesOnceForConcurrentCallers() async throws {
        let stub = StubLoader([
            (200, #"{"access_token":"a1","refresh_token":"r1","expires_in":30}"#),
            (200, #"{"access_token":"a2","refresh_token":"r2","expires_in":1800}"#),
        ])
        let store = MemorySecureStore()
        let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
        try await session.signIn(using: CallbackAuthenticator())
        #expect(stub.form(0)["code"] == "the-code")

        // Expires within the leeway, so both callers need a refresh; only one happens.
        async let first = session.accessToken()
        async let second = session.accessToken()
        let tokens = try await [first, second]
        #expect(tokens == ["a2", "a2"])
        #expect(stub.requestCount == 2)
        #expect(stub.form(1)["refresh_token"] == "r1")

        // Persisted: a new session reads the same tokens.
        let reloaded = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
        #expect(try await reloaded.accessToken() == "a2")
    }

    @Test func signOutRevokesAndForgetsTokens() async throws {
        let stub = StubLoader([(200, #"{"access_token":"a1","refresh_token":"r1","expires_in":1800}"#), (200, "{}"), (200, "{}")])
        let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: MemorySecureStore())
        try await session.signIn(using: CallbackAuthenticator())
        await session.signOut()
        #expect(await session.isSignedIn == false)
        #expect(stub.requests.dropFirst().allSatisfy { $0.url?.absoluteString == "https://auth.kof22.com/application/o/revoke/" })
        #expect(stub.form(1)["token"] == "r1")
        await #expect(throws: AuthError.signedOut) { try await session.accessToken() }
    }
}

@Suite struct CrossProcessAuthTests {
    @Test func usesTokensRotatedByAnotherProcessInsteadOfSigningOut() async throws {
        let store = MemorySecureStore()
        let expired = TokenSet(accessToken: "old", refreshToken: "r-old", idToken: nil, expiresAt: .now.addingTimeInterval(-10))
        try store.save(JSONEncoder().encode(expired), for: "tokens.live")
        // The refresh with the stale token fails; meanwhile the extension stored new tokens.
        let rotated = TokenSet(accessToken: "fresh", refreshToken: "r-new", idToken: nil, expiresAt: .now.addingTimeInterval(1800))
        let loader: HTTPLoader = { request in
            try store.save(JSONEncoder().encode(rotated), for: "tokens.live")
            return (Data(#"{"error":"invalid_grant"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: loader), store: store)
        #expect(try await session.accessToken() == "fresh")
        #expect(await session.isSignedIn)
    }

    @Test func picksUpTokensRefreshedByAnotherProcess() async throws {
        let store = MemorySecureStore()
        let expired = TokenSet(accessToken: "old", refreshToken: "r1", idToken: nil, expiresAt: .now.addingTimeInterval(-10))
        try store.save(JSONEncoder().encode(expired), for: "tokens.live")
        let stub = StubLoader([])
        let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
        _ = await session.isSignedIn  // loads the expired copy into memory
        let fresh = TokenSet(accessToken: "fresh", refreshToken: "r2", idToken: nil, expiresAt: .now.addingTimeInterval(1800))
        try store.save(JSONEncoder().encode(fresh), for: "tokens.live")
        #expect(try await session.accessToken() == "fresh")
        #expect(stub.requestCount == 0)
    }
}
