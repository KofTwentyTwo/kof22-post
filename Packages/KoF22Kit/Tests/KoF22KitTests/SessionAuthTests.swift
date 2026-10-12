/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// Lets a loader reach the session it serves, which is created after the loader.
final class SessionBox: @unchecked Sendable {
   /// Guards `stored`.
   private let lock = NSLock()
   /// The session, once created.
   private var stored: AuthSession?
   /// What the loader observed, in order.
   private var notes: [String] = []

   /// The session, once set.
   var session: AuthSession? {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
   }

   /// Appends an observation.
   func note(_ text: String) { lock.withLock { notes.append(text) } }

   /// The observations so far.
   var observed: [String] { lock.withLock { notes } }
}

/// A loader reply for `request` with `status` and `body`.
func reply(_ request: URLRequest, status: Int, body: String) throws -> (Data, HTTPURLResponse) {
   let url = try #require(request.url)
   let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
   return (Data(body.utf8), response)
}

@Suite struct SignOutOrderTests {
   let start = Date(timeIntervalSince1970: 2_000_000)

   func seeded(_ store: ScriptedSecureStore, expiresIn: TimeInterval) throws {
      let tokens = TokenSet(accessToken: "a1", refreshToken: "r1", idToken: nil, expiresAt: start.addingTimeInterval(expiresIn))
      store.seed(try JSONEncoder().encode(tokens), for: "tokens.live")
   }

   @Test func revokesBeforeClearingTheKeychain() async throws {
      let store = ScriptedSecureStore()
      try seeded(store, expiresIn: 3_600)
      let box = SessionBox()
      let loader: HTTPLoader = { request in
         let form = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
         box.note("revoke \(form.contains("token=r1") ? "refresh" : "access"), keychain \(store.stored("tokens.live") == nil ? "empty" : "full")")
         if let session = box.session {
            box.note("signed in: \(await session.isSignedIn)")
            do {
               _ = try await session.forceRefresh(rejected: "a1")
            }
            catch {
               box.note("reload: \(error)")
            }
         }
         return try reply(request, status: 200, body: "{}")
      }
      let fixed = start
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: loader), store: store, now: { fixed })
      box.session = session
      await session.signOut()
      #expect(
         box.observed == [
            "revoke refresh, keychain full", "signed in: false", "reload: signedOut",
            "revoke access, keychain full", "signed in: false", "reload: signedOut",
         ])
      #expect(store.stored("tokens.live") == nil)
      #expect(await session.isSignedIn == false)
   }

   @Test func refreshFinishingAfterSignOutIsDiscarded() async throws {
      let store = ScriptedSecureStore()
      try seeded(store, expiresIn: -1)
      let box = SessionBox()
      let loader: HTTPLoader = { request in
         guard request.url?.absoluteString == OAuthConfig.kof22.tokenURL.absoluteString else {
            return try reply(request, status: 200, body: "{}")
         }
         await box.session?.signOut()
         return try reply(request, status: 200, body: #"{"access_token":"late","refresh_token":"r2","expires_in":1800}"#)
      }
      let fixed = start
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: loader), store: store, now: { fixed })
      box.session = session
      await #expect(throws: AuthError.signedOut) { try await session.accessToken() }
      #expect(store.stored("tokens.live") == nil)
      #expect(await session.isSignedIn == false)
   }

   @Test func rejectedRefreshClearsTheTokens() async throws {
      let store = ScriptedSecureStore()
      try seeded(store, expiresIn: -1)
      let loader = StubLoader([(400, #"{"error":"invalid_grant","error_description":"expired"}"#)])
      let fixed = start
      let session = AuthSession(mode: .live, oauth: OAuthClient(config: .kof22, load: loader.loader), store: store, now: { fixed })
      await #expect(throws: AuthError.sessionExpired) { try await session.accessToken() }
      #expect(store.stored("tokens.live") == nil)
   }

   @Test func revocationUsesAShortTimeout() {
      #expect(OAuthClient.revokeTimeout <= 5)
   }
}

@Suite struct StubAuthSessionTests {
   @Test func signsInInstantlyAndRefreshesWithANewToken() async throws {
      let auth = StubAuthSession()
      #expect(await auth.isSignedIn == false)
      await #expect(throws: AuthError.signedOut) { try await auth.accessToken() }
      try await auth.signIn(using: NoWebAuthenticator())
      #expect(await auth.isSignedIn)
      let first = try await auth.accessToken()
      let second = try await auth.forceRefresh(rejected: first)
      #expect(first != second)
      #expect(try await auth.forceRefresh(rejected: "older") == second)
      await auth.signOut()
      #expect(await auth.isSignedIn == false)
   }

   @Test func canStartSignedIn() async throws {
      #expect(try await StubAuthSession(signedIn: true).accessToken() == "stub-access-1")
   }

   @Test func failsSignInWhenToldTo() async throws {
      let auth = StubAuthSession(signInFailure: .cancelled)
      await #expect(throws: AuthError.cancelled) { try await auth.signIn(using: NoWebAuthenticator()) }
      #expect(await auth.isSignedIn == false)
      await auth.setSignInFailure(nil)
      try await auth.signIn(using: NoWebAuthenticator())
      #expect(await auth.isSignedIn)
   }

   @Test func reportsAnExpiredSessionAndForgetsTheToken() async throws {
      let auth = StubAuthSession(signedIn: true, sessionExpired: true)
      await #expect(throws: AuthError.sessionExpired) { try await auth.accessToken() }
      #expect(await auth.isSignedIn == false)
      try await auth.signIn(using: NoWebAuthenticator())
      #expect(try await auth.accessToken().hasPrefix("stub-access-"))
      await auth.setSessionExpired(true)
      await #expect(throws: AuthError.sessionExpired) { try await auth.forceRefresh(rejected: "any") }
   }

   @Test func expiredStubSessionNeedsSignInThroughTheService() async throws {
      let auth = StubAuthSession(signedIn: true, sessionExpired: true)
      let service = SiteService.mock(backend: MockBackend(directory: nil), auth: auth)
      let error = await #expect(throws: AuthError.self) { try await service.me() }
      #expect(error.map(ErrorClassifier.disposition(for:)) == .needsSignIn)
   }

   @Test func authSessionIsASessionAuthenticator() async throws {
      let auth: any SessionAuthenticating = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: NoWebAuthenticator())
      #expect(await auth.isSignedIn)
   }
}
