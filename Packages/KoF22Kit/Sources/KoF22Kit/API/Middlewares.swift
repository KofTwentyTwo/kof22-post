import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns any non-2xx response into an `APIError` built from the error envelope, so
/// callers only ever see success outputs or a typed error.
struct ErrorEnvelopeMiddleware: ClientMiddleware {
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      let (response, responseBody) = try await next(request, body, baseURL)
      guard response.status.code >= 400 else { return (response, responseBody) }
      let data = try? await collect(responseBody, upTo: 1 << 20)
      throw APIError.decode(
         status: response.status.code,
         data: data ?? Data(),
         retryAfter: response.headerFields[.retryAfter],
         etag: response.headerFields[.eTag]
      )
   }
}

/// Adds the bearer token and, on a 401, refreshes once and replays the request.
struct AuthMiddleware: ClientMiddleware {
   let auth: AuthSession

   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      guard operationID != "getApiVersions" else { return try await next(request, body, baseURL) }
      // Buffer the body so it can be sent twice.
      let bytes = try await collect(body, upTo: 4 << 20)
      let token = try await auth.accessToken()
      let response = try await next(request.authorized(token), bytes.map(HTTPBody.init), baseURL)
      guard response.0.status.code == 401 else { return response }
      let fresh = try await auth.forceRefresh(rejected: token)
      return try await next(request.authorized(fresh), bytes.map(HTTPBody.init), baseURL)
   }
}

/// The generator cannot encode an explicit JSON `null`, but `PATCH /v1/me/posts/{id}`
/// needs `"linkUrl": null` to remove a link. `SiteService` marks that intent with a
/// sentinel value which this middleware rewrites to `null`.
struct ExplicitNullMiddleware: ClientMiddleware {
   static let sentinel = "__kof22_null__"

   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      guard operationID == "updatePost", let body else { return try await next(request, body, baseURL) }
      let data = try await Data(collecting: body, upTo: 4 << 20)
      let rewritten = Self.rewrite(data)
      return try await next(request, HTTPBody(rewritten), baseURL)
   }

   static func rewrite(_ data: Data) -> Data {
      guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
      var changed = false
      for (key, value) in object where (value as? String) == sentinel {
         object[key] = NSNull()
         changed = true
      }
      guard changed, let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
         return data
      }
      return out
   }
}

/// The runtime URI-encodes header values, which turns a quoted ETag into
/// `%22...%22`. `If-Match` must reach the server verbatim.
struct RawHeaderMiddleware: ClientMiddleware {
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      var request = request
      if let value = request.headerFields[.ifMatch], let decoded = value.removingPercentEncoding {
         request.headerFields[.ifMatch] = decoded
      }
      return try await next(request, body, baseURL)
   }
}

/// Optional.map cannot take an async closure.
func collect(_ body: HTTPBody?, upTo limit: Int) async throws -> Data? {
   guard let body else { return nil }
   return try await Data(collecting: body, upTo: limit)
}

extension HTTPRequest {
   func authorized(_ token: String) -> HTTPRequest {
      var copy = self
      copy.headerFields[.authorization] = "Bearer \(token)"
      return copy
   }
}

extension HTTPField.Name {
   static let eTag = HTTPField.Name("ETag")!
   static let ifMatch = HTTPField.Name("If-Match")!
   static let idempotencyKey = HTTPField.Name("Idempotency-Key")!
   static let idempotentReplayed = HTTPField.Name("Idempotent-Replayed")!
   static let retryAfter = HTTPField.Name("Retry-After")!
   static let apiVersion = HTTPField.Name("X-API-Version")!
}
