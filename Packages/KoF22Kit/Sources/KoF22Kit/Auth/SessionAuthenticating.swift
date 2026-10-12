/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// What the API layer needs from a sign-in session: whether someone is signed in, a
/// usable access token, a forced refresh after a 401, sign-in and sign-out.
/// `AuthSession` is the real implementation; `StubAuthSession` serves mock mode and tests.
public protocol SessionAuthenticating: Sendable {
   /// True when there are tokens, even expired ones that can still be refreshed.
   var isSignedIn: Bool { get async }

   /// A non-expired access token, refreshing silently when needed.
   func accessToken() async throws -> String

   /// Called after a 401: returns a token other than `token`, refreshing when needed.
   func forceRefresh(rejected token: String) async throws -> String

   /// Signs in, presenting the browser through `authenticator` when the session needs it.
   func signIn(using authenticator: any WebAuthenticator) async throws

   /// Ends the session and forgets its tokens.
   func signOut() async
}

extension AuthSession: SessionAuthenticating {}

/// A session that signs in instantly with fake tokens and never touches the network or
/// the Keychain. It drives mock mode and tests, and can be told to fail sign-in or to
/// report an expired session so every sign-in state of the UI can be exercised.
public actor StubAuthSession: SessionAuthenticating {
   /// The error the next sign-in throws, or nil for a successful sign-in.
   private var signInFailure: AuthError?
   /// When true, token requests end the session with `AuthError.sessionExpired`.
   private var expired: Bool
   /// The current fake access token, or nil when signed out.
   private var token: String?
   /// Counts issued tokens so each refresh returns a different one.
   private var issued = 0

   /// Creates a stub, optionally already signed in, failing sign-in with
   /// `signInFailure`, or with a session that has expired.
   public init(signedIn: Bool = false, signInFailure: AuthError? = nil, sessionExpired: Bool = false) {
      self.signInFailure = signInFailure
      self.expired = sessionExpired
      if signedIn {
         issued = 1
         token = Self.token(number: issued)
      }
   }

   /// The fake access token with sequence number `number`.
   private static func token(number: Int) -> String { "stub-access-\(number)" }

   /// Issues the next fake access token and makes it current.
   private func issue() -> String {
      issued += 1
      let next = Self.token(number: issued)
      token = next
      return next
   }

   /// Makes the next sign-in fail with `error`, or succeed when nil.
   public func setSignInFailure(_ error: AuthError?) { signInFailure = error }

   /// Makes token requests report an expired session (or work again when false).
   public func setSessionExpired(_ value: Bool) { expired = value }

   /// True while a fake token is held.
   public var isSignedIn: Bool { token != nil }

   /// The current token; throws `signedOut` without one, and `sessionExpired` (after
   /// forgetting the token, as `AuthSession` does) when the session is set to expire.
   public func accessToken() async throws -> String {
      guard let token else { throw AuthError.signedOut }
      if expired {
         self.token = nil
         throw AuthError.sessionExpired
      }
      return token
   }

   /// Issues a new token when `rejected` is the current one, like a real refresh.
   public func forceRefresh(rejected: String) async throws -> String {
      let current = try await accessToken()
      return current == rejected ? issue() : current
   }

   /// Signs in without showing anything, or throws the configured failure.
   public func signIn(using authenticator: any WebAuthenticator) async throws {
      if let signInFailure { throw signInFailure }
      expired = false
      _ = issue()
   }

   /// Forgets the token.
   public func signOut() async { token = nil }
}
