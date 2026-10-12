/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

@Suite struct AuthSessionEdgeTests {
   let now = Date(timeIntervalSince1970: 1_000_000)

   func encoded(_ tokens: TokenSet) throws -> Data {
      try JSONEncoder().encode(tokens)
   }

   func session(_ store: any SecureStore, mode: BackendMode = .live, loader: StubLoader = StubLoader([])) -> AuthSession {
      let fixedNow = now
      return AuthSession(mode: mode, oauth: OAuthClient(config: .kof22, load: loader.loader), store: store, now: { fixedNow })
   }

   @Test func unreadableKeychainCountsAsSignedOut() async {
      let auth = session(ScriptedSecureStore(loadFails: true))
      #expect(await auth.isSignedIn == false)
      await #expect(throws: AuthError.signedOut) { try await auth.accessToken() }
   }

   @Test func corruptStoredTokensCountAsSignedOut() async {
      let store = ScriptedSecureStore()
      store.seed(Data("not json".utf8), for: "tokens.live")
      #expect(await session(store).isSignedIn == false)
   }

   @Test func signInSurvivesAKeychainThatCannotSave() async throws {
      let auth = session(ScriptedSecureStore(saveFails: true), mode: .mock)
      try await auth.signIn(using: NoWebAuthenticator())
      #expect(await auth.isSignedIn)
      #expect(try await auth.accessToken().hasPrefix("mock-access-"))
   }

   @Test func mockTokensLastThirtyDays() async throws {
      let store = ScriptedSecureStore()
      try await session(store, mode: .mock).signIn(using: NoWebAuthenticator())
      let saved = try JSONDecoder().decode(TokenSet.self, from: try #require(store.stored("tokens.mock")))
      #expect(saved.expiresAt == now.addingTimeInterval(AuthSession.mockTokenLifetime))
      #expect(saved.refreshToken == "mock-refresh")
   }

   @Test func signOutSurvivesAKeychainThatCannotDelete() async throws {
      let store = ScriptedSecureStore(deleteFails: true)
      let auth = session(store, mode: .mock)
      try await auth.signIn(using: NoWebAuthenticator())
      await auth.signOut()
      #expect(await auth.isSignedIn == false)
   }

   @Test func expiredTokensWithoutRefreshTokenEndTheSession() async throws {
      let store = ScriptedSecureStore()
      let expired = TokenSet(accessToken: "old", refreshToken: nil, idToken: nil, expiresAt: now.addingTimeInterval(-1))
      store.seed(try encoded(expired), for: "tokens.live")
      let auth = session(store)
      await #expect(throws: AuthError.sessionExpired) { try await auth.accessToken() }
      #expect(await auth.isSignedIn == false)
      #expect(store.stored("tokens.live") == nil)
   }

   @Test func rejectedRefreshTokenEndsTheSessionWhenNothingRotated() async throws {
      let store = ScriptedSecureStore()
      let expired = TokenSet(accessToken: "old", refreshToken: "r1", idToken: nil, expiresAt: now.addingTimeInterval(-1))
      store.seed(try encoded(expired), for: "tokens.live")
      let loader = StubLoader([(400, #"{"error":"invalid_grant"}"#)])
      let auth = session(store, loader: loader)
      await #expect(throws: AuthError.sessionExpired) { try await auth.accessToken() }
      #expect(await auth.isSignedIn == false)
      #expect(loader.requestCount == 1)
   }

   @Test func mockRefreshKeepsTheRefreshToken() async throws {
      let store = ScriptedSecureStore()
      let expired = TokenSet(accessToken: "old", refreshToken: "mock-refresh", idToken: nil, expiresAt: now.addingTimeInterval(-1))
      store.seed(try encoded(expired), for: "tokens.mock")
      let token = try await session(store, mode: .mock).accessToken()
      #expect(token.hasPrefix("mock-access-"))
      let saved = try JSONDecoder().decode(TokenSet.self, from: try #require(store.stored("tokens.mock")))
      #expect(saved.refreshToken == "mock-refresh")
   }

   @Test func forceRefreshReturnsATokenAnotherProcessAlreadyReplaced() async throws {
      let store = ScriptedSecureStore()
      let current = TokenSet(accessToken: "newer", refreshToken: "r2", idToken: nil, expiresAt: now.addingTimeInterval(3_600))
      store.seed(try encoded(current), for: "tokens.live")
      let loader = StubLoader([])
      #expect(try await session(store, loader: loader).forceRefresh(rejected: "older") == "newer")
      #expect(loader.requestCount == 0)
   }

   @Test func forceRefreshWithoutTokensMeansSignedOut() async {
      await #expect(throws: AuthError.signedOut) { try await session(ScriptedSecureStore()).forceRefresh(rejected: "any") }
   }

   @Test func signOutOfTheLiveBackendRevokesTheAccessTokenEvenWithoutRefreshToken() async throws {
      let store = ScriptedSecureStore()
      let tokens = TokenSet(accessToken: "a1", refreshToken: nil, idToken: nil, expiresAt: now.addingTimeInterval(3_600))
      store.seed(try encoded(tokens), for: "tokens.live")
      let loader = StubLoader([(200, "{}")])
      await session(store, loader: loader).signOut()
      #expect(loader.requestCount == 1)
      #expect(loader.form(0)["token"] == "a1")
      #expect(loader.form(0)["token_type_hint"] == "access_token")
   }
}
