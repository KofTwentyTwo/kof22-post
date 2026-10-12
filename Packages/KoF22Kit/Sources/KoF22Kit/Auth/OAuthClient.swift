/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Performs one HTTP request. Injected so tests never touch the network.
public typealias HTTPLoader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Ready-made `HTTPLoader`s.
public enum HTTPLoaders {
   /// A loader on `session` that rejects responses which are not HTTP.
   public static func urlSession(_ session: URLSession = .shared) -> HTTPLoader {
      { request in
         let (data, response) = try await session.data(for: request)
         guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
         return (data, http)
      }
   }
}

/// The tokens from one sign-in, persisted as JSON in the Keychain.
public struct TokenSet: Codable, Sendable, Equatable {
   /// The bearer token sent to the Site API.
   public var accessToken: String
   /// Used to get a new access token; nil when the provider did not issue one.
   public var refreshToken: String?
   /// The OpenID Connect identity token, kept for completeness.
   public var idToken: String?
   /// When the access token stops being accepted.
   public var expiresAt: Date

   /// Creates a token set.
   public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date) {
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.idToken = idToken
      self.expiresAt = expiresAt
   }

   /// True when the access token expires less than `interval` after `now`, so callers
   /// can refresh ahead of time instead of sending a token that is about to lapse.
   func expires(within interval: TimeInterval, now: Date) -> Bool {
      expiresAt.timeIntervalSince(now) < interval
   }
}

/// Why signing in or refreshing failed.
public enum AuthError: Error, Equatable, Sendable {
   /// The owner closed the sign-in sheet.
   case cancelled
   /// The redirect's `state` does not match the request, so it is not ours.
   case stateMismatch
   /// The redirect carried no authorization code.
   case missingCode
   /// The provider refused, with its description of why.
   case authorizationDenied(String)
   /// The refresh token is no longer valid; the user has to sign in again.
   case sessionExpired
   /// There are no tokens at all.
   case signedOut
   /// The token endpoint failed with a status other than `invalid_grant`.
   case server(status: Int, message: String)
}

/// Authorization Code + PKCE against Authentik. Stateless; `AuthSession` owns tokens.
public struct OAuthClient: Sendable {
   /// Revocation is best effort and must not hold up sign-out.
   static let revokeTimeout: TimeInterval = 5

   /// Lifetime assumed when the token response leaves out `expires_in`.
   static let defaultTokenLifetime: TimeInterval = 300

   /// Status codes the token endpoint uses for success.
   static let successStatusCodes = 200..<300

   /// The endpoints, client id and scopes.
   public let config: OAuthConfig
   /// Performs the HTTP requests.
   let load: HTTPLoader

   /// Creates a client; tests inject `load` so no request reaches the network.
   public init(config: OAuthConfig, load: @escaping HTTPLoader = HTTPLoaders.urlSession()) {
      self.config = config
      self.load = load
   }

   /// The URL that starts the browser sign-in.
   public func authorizationURL(pkce: PKCE, state: String) -> URL {
      config.authorizeURL.appending(queryItems: [
         URLQueryItem(name: "response_type", value: "code"),
         URLQueryItem(name: "client_id", value: config.clientID),
         URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
         URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
         URLQueryItem(name: "state", value: state),
         URLQueryItem(name: "code_challenge", value: pkce.challenge),
         URLQueryItem(name: "code_challenge_method", value: pkce.method),
      ])
   }

   /// Extracts the authorization code from the redirect, checking `state`.
   public func code(fromCallback url: URL, expectedState: String) throws -> String {
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let value = { (name: String) in items.first { $0.name == name }?.value }
      if let error = value("error") {
         throw AuthError.authorizationDenied(value("error_description") ?? error)
      }
      guard value("state") == expectedState else { throw AuthError.stateMismatch }
      guard let code = value("code"), !code.isEmpty else { throw AuthError.missingCode }
      return code
   }

   /// Trades the authorization code and PKCE verifier for tokens.
   public func exchange(code: String, pkce: PKCE, now: Date = .now) async throws -> TokenSet {
      try await tokenRequest(
         [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI.absoluteString,
            "client_id": config.clientID,
            "code_verifier": pkce.verifier,
         ], previousRefreshToken: nil, now: now)
   }

   /// Gets new tokens with a refresh token. The old refresh token is kept when the
   /// provider does not rotate it.
   public func refresh(_ refreshToken: String, now: Date = .now) async throws -> TokenSet {
      try await tokenRequest(
         [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
         ], previousRefreshToken: refreshToken, now: now)
   }

   /// Best effort (RFC 7009); sign-out proceeds even if this fails.
   public func revoke(_ token: String, hint: String) async {
      var request = formRequest(
         config.revokeURL,
         [
            "token": token, "token_type_hint": hint, "client_id": config.clientID,
         ])
      request.timeoutInterval = Self.revokeTimeout
      do {
         _ = try await load(request)
      }
      catch {
         Log.auth.warning("Revoking the \(hint, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// Posts a form to the token endpoint. `invalid_grant` means the refresh token is
   /// dead and becomes `sessionExpired`; other failures become `server`.
   private func tokenRequest(_ form: [String: String], previousRefreshToken: String?, now: Date) async throws -> TokenSet {
      let (data, response) = try await load(formRequest(config.tokenURL, form))
      guard Self.successStatusCodes.contains(response.statusCode) else {
         ///////////////////////////////////////////////////////////
         // an error body that is not OAuth JSON is expected from //
         // proxies; the generic message below covers it.         //
         ///////////////////////////////////////////////////////////
         let error = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
         if error?.error == "invalid_grant" { throw AuthError.sessionExpired }
         throw AuthError.server(
            status: response.statusCode,
            message: error?.errorDescription ?? error?.error ?? "Token request failed"
         )
      }
      let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
      return TokenSet(
         accessToken: token.accessToken,
         refreshToken: token.refreshToken ?? previousRefreshToken,
         idToken: token.idToken,
         expiresAt: now.addingTimeInterval(token.expiresIn ?? Self.defaultTokenLifetime)
      )
   }

   /// A form-encoded POST that asks for JSON back, with keys sorted so requests are
   /// stable for tests and logs.
   private func formRequest(_ url: URL, _ form: [String: String]) -> URLRequest {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody =
         form
         .sorted { $0.key < $1.key }
         .map { "\($0.key)=\(Self.formEncode($0.value))" }
         .joined(separator: "&")
         .data(using: .utf8)
      return request
   }

   /// The RFC 3986 unreserved characters, the only bytes a form value sends as is.
   static let unreservedBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

   /// Percent-encodes every UTF-8 byte except RFC 3986 unreserved characters, as
   /// `application/x-www-form-urlencoded` requires for values such as `kof22:publish`.
   static func formEncode(_ value: String) -> String {
      value.utf8.map { byte in
         unreservedBytes.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
      }
      .joined()
   }
}

/// The token endpoint's success body.
private struct OAuthTokenResponse: Decodable {
   /// Maps the snake_case wire names.
   enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
      case refreshToken = "refresh_token"
      case idToken = "id_token"
   }

   /// The new access token.
   let accessToken: String
   /// Seconds until the access token expires.
   let expiresIn: Double?
   /// A rotated refresh token, when the provider issued one.
   let refreshToken: String?
   /// The identity token.
   let idToken: String?
}

/// The token endpoint's error body (RFC 6749 section 5.2).
private struct OAuthErrorResponse: Decodable {
   /// Maps the snake_case wire names.
   enum CodingKeys: String, CodingKey {
      case error
      case errorDescription = "error_description"
   }

   /// The OAuth error code, such as `invalid_grant`.
   let error: String
   /// The provider's explanation.
   let errorDescription: String?
}
