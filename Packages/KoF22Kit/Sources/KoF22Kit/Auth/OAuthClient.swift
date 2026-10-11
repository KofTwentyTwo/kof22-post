import Foundation

/// Performs one HTTP request. Injected so tests never touch the network.
public typealias HTTPLoader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTPLoaders {
   public static func urlSession(_ session: URLSession = .shared) -> HTTPLoader {
      { request in
         let (data, response) = try await session.data(for: request)
         guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
         return (data, http)
      }
   }
}

public struct TokenSet: Codable, Sendable, Equatable {
   public var accessToken: String
   public var refreshToken: String?
   public var idToken: String?
   public var expiresAt: Date

   public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date) {
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.idToken = idToken
      self.expiresAt = expiresAt
   }

   func expires(within interval: TimeInterval, now: Date) -> Bool {
      expiresAt.timeIntervalSince(now) < interval
   }
}

public enum AuthError: Error, Equatable, Sendable {
   case cancelled
   case stateMismatch
   case missingCode
   case authorizationDenied(String)
   /// The refresh token is no longer valid; the user has to sign in again.
   case sessionExpired
   case signedOut
   case server(status: Int, message: String)
}

/// Authorization Code + PKCE against Authentik. Stateless; `AuthSession` owns tokens.
public struct OAuthClient: Sendable {
   public let config: OAuthConfig
   let load: HTTPLoader

   public init(config: OAuthConfig, load: @escaping HTTPLoader = HTTPLoaders.urlSession()) {
      self.config = config
      self.load = load
   }

   public func authorizationURL(pkce: PKCE, state: String) -> URL {
      var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
      components.queryItems = [
         URLQueryItem(name: "response_type", value: "code"),
         URLQueryItem(name: "client_id", value: config.clientID),
         URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
         URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
         URLQueryItem(name: "state", value: state),
         URLQueryItem(name: "code_challenge", value: pkce.challenge),
         URLQueryItem(name: "code_challenge_method", value: pkce.method),
      ]
      return components.url!
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
      request.timeoutInterval = 10
      _ = try? await load(request)
   }

   private struct TokenResponse: Decodable {
      let access_token: String
      let expires_in: Double?
      let refresh_token: String?
      let id_token: String?
   }

   private struct ErrorResponse: Decodable {
      let error: String
      let error_description: String?
   }

   private func tokenRequest(_ form: [String: String], previousRefreshToken: String?, now: Date) async throws -> TokenSet {
      let (data, response) = try await load(formRequest(config.tokenURL, form))
      guard (200..<300).contains(response.statusCode) else {
         let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
         if error?.error == "invalid_grant" { throw AuthError.sessionExpired }
         throw AuthError.server(
            status: response.statusCode,
            message: error?.error_description ?? error?.error ?? "Token request failed"
         )
      }
      let token = try JSONDecoder().decode(TokenResponse.self, from: data)
      return TokenSet(
         accessToken: token.access_token,
         refreshToken: token.refresh_token ?? previousRefreshToken,
         idToken: token.id_token,
         expiresAt: now.addingTimeInterval(token.expires_in ?? 300)
      )
   }

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

   static func formEncode(_ value: String) -> String {
      var allowed = CharacterSet.alphanumerics
      allowed.insert(charactersIn: "-._~")
      return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
   }
}
