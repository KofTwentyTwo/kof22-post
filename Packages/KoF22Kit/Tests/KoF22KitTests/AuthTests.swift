/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// Tests for the PKCE verifier and challenge.
@Suite struct PKCETests {
   /// The S256 challenge matches the worked example in RFC 7636, appendix B.
   @Test func challengeMatchesRFC7636Example() {
      let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
   }

   /// A generated verifier is at least 43 characters of the URL-safe alphabet.
   @Test func generatedVerifierIsURLSafeAndLongEnough() {
      let verifier = PKCE.generate().verifier
      #expect(verifier.count >= 43)
      #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
   }
}

/// Tests for the OAuth client: authorization URL, callback parsing and token requests.
@Suite struct OAuthClientTests {
   /// A client whose network loader is never expected to be called.
   let client = OAuthClient(config: .kof22, load: StubLoader([]).loader)

   /// The authorization URL carries the client ID, redirect URI, PKCE challenge, scopes and state.
   @Test func authorizationURLCarriesPKCEAndScopes() throws {
      let pkce = PKCE(verifier: "verifier-verifier-verifier-verifier-verifier")
      let url = client.authorizationURL(pkce: pkce, state: "abc")
      let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
      let queryItems = try #require(components.queryItems)
      let items = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
      #expect(url.absoluteString.hasPrefix("https://auth.kof22.com/application/o/authorize/"))
      #expect(items["client_id"] == "kof22-post-ios")
      #expect(items["redirect_uri"] == "com.kof22.post://oauth/callback")
      #expect(items["code_challenge"] == pkce.challenge)
      #expect(items["code_challenge_method"] == "S256")
      #expect(items["scope"] == "openid profile email offline_access kof22:publish")
      #expect(items["state"] == "abc")
   }

   /// A callback whose state differs from the one sent is rejected.
   @Test func callbackRejectsWrongState() throws {
      let url = try #require(URL(string: "com.kof22.post://oauth/callback?code=xyz&state=other"))
      #expect(throws: AuthError.stateMismatch) { try client.code(fromCallback: url, expectedState: "abc") }
   }

   /// An `error` in the callback surfaces as a denial with the server's description.
   @Test func callbackSurfacesAuthorizationError() throws {
      let url = try #require(URL(string: "com.kof22.post://oauth/callback?error=access_denied&error_description=Nope&state=abc"))
      #expect(throws: AuthError.authorizationDenied("Nope")) { try client.code(fromCallback: url, expectedState: "abc") }
   }

   /// The code exchange sends the verifier without a client secret and parses the token response.
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

   /// A refresh response without a new refresh token keeps the old one.
   @Test func refreshKeepsOldRefreshTokenWhenNotRotated() async throws {
      let stub = StubLoader([(200, #"{"access_token":"a2","expires_in":60}"#)])
      let tokens = try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
      #expect(tokens.refreshToken == "r1")
   }

   /// `invalid_grant` on refresh is reported as an expired session.
   @Test func invalidGrantMeansSessionExpired() async {
      let stub = StubLoader([(400, #"{"error":"invalid_grant"}"#)])
      await #expect(throws: AuthError.sessionExpired) {
         try await OAuthClient(config: .kof22, load: stub.loader).refresh("r1")
      }
   }
}

/// Tests for the live auth session: sign-in, concurrent refresh, persistence and sign-out.
@Suite struct AuthSessionTests {
   /// Completes the browser step by echoing the request's state back with a fixed code.
   struct CallbackAuthenticator: WebAuthenticator {
      /// Returns the redirect URL the authorization server would send.
      func authenticate(url: URL, callbackScheme: String) async throws -> URL {
         let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
         let stateItem = try #require(components.queryItems?.first { $0.name == "state" })
         let state = try #require(stateItem.value)
         return try #require(URL(string: "\(callbackScheme)://oauth/callback?code=the-code&state=\(state)"))
      }
   }

   /// Sign-in stores tokens; two concurrent callers share a single refresh; a new session reloads them.
   @Test func liveSignInStoresTokensAndRefreshesOnceForConcurrentCallers() async throws {
      let stub = StubLoader([
         (200, #"{"access_token":"a1","refresh_token":"r1","expires_in":30}"#),
         (200, #"{"access_token":"a2","refresh_token":"r2","expires_in":1800}"#),
      ])
      let store = MemorySecureStore()
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
      try await session.signIn(using: CallbackAuthenticator())
      #expect(stub.form(0)["code"] == "the-code")

      ///////////////////////////////////////////////////////////////////
      // Expires within the leeway, so both callers need a refresh;    //
      // only one happens.                                             //
      ///////////////////////////////////////////////////////////////////
      async let first = session.accessToken()
      async let second = session.accessToken()
      let tokens = try await [first, second]
      #expect(tokens == ["a2", "a2"])
      #expect(stub.requestCount == 2)
      #expect(stub.form(1)["refresh_token"] == "r1")

      ///////////////////////////////////////////////////////////////////
      // Persisted: a new session reads the same tokens.               //
      ///////////////////////////////////////////////////////////////////
      let reloaded = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
      #expect(try await reloaded.accessToken() == "a2")
   }

   /// Sign-out revokes the tokens at the server and forgets them locally.
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

/// Tests for tokens shared through the Keychain between the app and its extensions.
@Suite struct CrossProcessAuthTests {
   /// A failed refresh is not a sign-out when another process has already stored rotated tokens.
   @Test func usesTokensRotatedByAnotherProcessInsteadOfSigningOut() async throws {
      let store = MemorySecureStore()
      let expired = TokenSet(accessToken: "old", refreshToken: "r-old", idToken: nil, expiresAt: .now.addingTimeInterval(-10))
      try store.save(JSONEncoder().encode(expired), for: "tokens.live")
      ///////////////////////////////////////////////////////////////////
      // The refresh with the stale token fails; meanwhile the         //
      // extension stored new tokens.                                  //
      ///////////////////////////////////////////////////////////////////
      let rotated = TokenSet(accessToken: "fresh", refreshToken: "r-new", idToken: nil, expiresAt: .now.addingTimeInterval(1800))
      let loader: HTTPLoader = { request in
         try store.save(JSONEncoder().encode(rotated), for: "tokens.live")
         let url = try #require(request.url)
         let response = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
         return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
      }
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: loader), store: store)
      #expect(try await session.accessToken() == "fresh")
      #expect(await session.isSignedIn)
   }

   /// Tokens refreshed by another process are used without a network refresh.
   @Test func picksUpTokensRefreshedByAnotherProcess() async throws {
      let store = MemorySecureStore()
      let expired = TokenSet(accessToken: "old", refreshToken: "r1", idToken: nil, expiresAt: .now.addingTimeInterval(-10))
      try store.save(JSONEncoder().encode(expired), for: "tokens.live")
      let stub = StubLoader([])
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: stub.loader), store: store)
      ///////////////////////////////////////////////////////////////////
      // Loads the expired copy into memory.                           //
      ///////////////////////////////////////////////////////////////////
      _ = await session.isSignedIn
      let fresh = TokenSet(accessToken: "fresh", refreshToken: "r2", idToken: nil, expiresAt: .now.addingTimeInterval(1800))
      try store.save(JSONEncoder().encode(fresh), for: "tokens.live")
      #expect(try await session.accessToken() == "fresh")
      #expect(stub.requestCount == 0)
   }
}
