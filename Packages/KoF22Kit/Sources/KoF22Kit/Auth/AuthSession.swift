/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Presents the browser sign-in and returns the redirect URL. The app implements it
/// with `WebAuthenticationSession`; tests use a stub.
public protocol WebAuthenticator: Sendable {
   /// Opens `url` and returns the redirect to `callbackScheme`.
   func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Owns the token set for one backend mode: sign-in, silent refresh (single flight),
/// and sign-out with revocation. Tokens live in the Keychain only.
public actor AuthSession {
   /// Refresh this long before the access token expires.
   static let refreshLeeway: TimeInterval = 60

   /// Mock tokens last 30 days so the mock backend never asks to sign in again.
   static let mockTokenLifetime: TimeInterval = 2_592_000

   /// 16 random bytes make the OAuth `state` unguessable.
   static let stateByteCount = 16

   /// Which backend the tokens are for; each mode has its own Keychain item.
   public let mode: BackendMode
   /// Talks to the token endpoint.
   private let oauth: OAuthClient
   /// Where the token set is persisted.
   private let store: any SecureStore
   /// The clock, injected so tests control expiry.
   private let now: @Sendable () -> Date
   /// The tokens in memory, loaded lazily from the store.
   private var tokens: TokenSet?
   /// Whether `tokens` reflects the store.
   private var loaded = false
   /// The refresh in flight, shared by concurrent callers.
   private var refreshTask: Task<TokenSet, any Error>?
   /// Bumped on sign-out so a refresh that finishes afterwards is discarded.
   private var generation = 0

   /// Creates a session; nothing is read from the store until tokens are first needed.
   public init(
      mode: BackendMode,
      oauth: OAuthClient = OAuthClient(config: .kof22),
      store: any SecureStore = KeychainStore(),
      now: @escaping @Sendable () -> Date = { .now }
   ) {
      self.mode = mode
      self.oauth = oauth
      self.store = store
      self.now = now
   }

   /// The Keychain account for this mode's tokens.
   private var account: String { "tokens.\(mode.rawValue)" }

   /// The tokens, reading the store on first use. An unreadable store or a corrupt item
   /// counts as signed out.
   private func current() -> TokenSet? {
      if !loaded {
         loaded = true
         tokens = readStoredTokens()
      }
      return tokens
   }

   /// Reads and decodes the stored token set, logging why when that fails.
   private func readStoredTokens() -> TokenSet? {
      let data: Data?
      do {
         data = try store.load(account)
      }
      catch {
         Log.auth.warning("Reading stored tokens failed: \(error.localizedDescription, privacy: .public)")
         return nil
      }
      guard let data else { return nil }
      do {
         return try JSONDecoder().decode(TokenSet.self, from: data)
      }
      catch {
         Log.auth.warning("Stored tokens are unreadable: \(error.localizedDescription, privacy: .public)")
         return nil
      }
   }

   /// Keeps `newTokens` in memory and in the store, or removes them when nil. A store
   /// failure is logged; the in-memory copy still serves this process.
   private func persist(_ newTokens: TokenSet?) {
      tokens = newTokens
      loaded = true
      do {
         if let newTokens {
            try store.save(JSONEncoder().encode(newTokens), for: account)
         }
         else {
            try store.delete(account)
         }
      }
      catch {
         Log.auth.warning("Storing tokens failed: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// True when there are tokens, even expired ones that can still be refreshed.
   public var isSignedIn: Bool { current() != nil }

   /// Signs in through the browser with PKCE. In mock mode it stores local tokens
   /// without showing anything.
   public func signIn(using authenticator: any WebAuthenticator) async throws {
      if mode == .mock {
         persist(Self.mockTokens(refreshToken: "mock-refresh", issuedAt: now()))
         return
      }
      let pkce = PKCE.generate()
      let state = PKCE.randomURLSafeString(byteCount: Self.stateByteCount)
      let callback = try await authenticator.authenticate(
         url: oauth.authorizationURL(pkce: pkce, state: state),
         callbackScheme: oauth.config.callbackScheme
      )
      let code = try oauth.code(fromCallback: callback, expectedState: state)
      persist(try await oauth.exchange(code: code, pkce: pkce, now: now()))
   }

   /// A long-lived token set for the mock backend.
   private static func mockTokens(refreshToken: String, issuedAt: Date) -> TokenSet {
      TokenSet(
         accessToken: "mock-access-\(UUID().uuidString)",
         refreshToken: refreshToken,
         idToken: nil,
         expiresAt: issuedAt.addingTimeInterval(mockTokenLifetime)
      )
   }

   /// Re-reads the Keychain: the app and the Share Extension share tokens, and
   /// the other process may have refreshed (and rotated) them.
   private func reloadFromStore() -> TokenSet? {
      loaded = false
      return current()
   }

   /// A non-expired access token, refreshing silently when needed.
   public func accessToken() async throws -> String {
      guard var tokens = current() else { throw AuthError.signedOut }
      if !tokens.expires(within: Self.refreshLeeway, now: now()) { return tokens.accessToken }
      guard let stored = reloadFromStore() else { throw AuthError.signedOut }
      tokens = stored
      if !tokens.expires(within: Self.refreshLeeway, now: now()) { return tokens.accessToken }
      return try await refreshed().accessToken
   }

   /// Called after a 401: refresh once even if the token looks valid.
   public func forceRefresh(rejected token: String) async throws -> String {
      guard let tokens = reloadFromStore() else { throw AuthError.signedOut }
      if tokens.accessToken != token { return tokens.accessToken }
      return try await refreshed().accessToken
   }

   /// Refreshes once for all concurrent callers. A refresh that finishes after sign-out
   /// is discarded, and a rejected refresh token first checks whether another process
   /// already rotated it.
   private func refreshed() async throws -> TokenSet {
      if let refreshTask { return try await refreshTask.value }
      guard let refreshToken = current()?.refreshToken else {
         persist(nil)
         throw AuthError.sessionExpired
      }
      let mode = mode
      let oauth = oauth
      let instant = now()
      let startedGeneration = generation
      let task = Task<TokenSet, any Error> {
         if mode == .mock {
            return Self.mockTokens(refreshToken: refreshToken, issuedAt: instant)
         }
         return try await oauth.refresh(refreshToken, now: instant)
      }
      refreshTask = task
      defer { refreshTask = nil }
      do {
         let newTokens = try await task.value
         guard startedGeneration == generation else { throw AuthError.signedOut }
         persist(newTokens)
         return newTokens
      }
      catch AuthError.sessionExpired {
         ////////////////////////////////////////////////////////////
         // another process may have rotated the refresh token     //
         // while this one used the old one.                       //
         ////////////////////////////////////////////////////////////
         if let latest = reloadFromStore(), latest.refreshToken != refreshToken {
            return latest
         }
         persist(nil)
         throw AuthError.sessionExpired
      }
   }

   /// Forgets the tokens and, for the live backend, revokes them at the provider.
   public func signOut() async {
      generation += 1
      refreshTask = nil
      let tokens = current()
      persist(nil)
      guard mode == .live, let tokens else { return }
      if let refresh = tokens.refreshToken {
         await oauth.revoke(refresh, hint: "refresh_token")
      }
      await oauth.revoke(tokens.accessToken, hint: "access_token")
   }
}
