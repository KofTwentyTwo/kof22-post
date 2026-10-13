/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

/// Turns any non-2xx response into an `APIError` built from the error envelope, so
/// callers only ever see success outputs or a typed error.
struct ErrorEnvelopeMiddleware: ClientMiddleware {
   /// Error envelopes are small; anything larger is not worth decoding.
   static let maximumErrorBodyBytes = 1 << 20

   /// Passes successful responses through and throws `APIError` for 4xx and 5xx.
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      let (response, responseBody) = try await next(request, body, baseURL)
      guard response.status.code >= HTTPResponse.Status.badRequest.code else { return (response, responseBody) }
      var data = Data()
      do {
         data = try await collect(responseBody, upTo: Self.maximumErrorBodyBytes) ?? Data()
      }
      catch {
         ////////////////////////////////////////////////////////////
         // the status code still describes the failure, so an     //
         // unreadable body only loses the server's detail text.   //
         ////////////////////////////////////////////////////////////
         Log.api.warning("Error body for \(operationID, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
      }
      throw APIError.decode(
         status: response.status.code,
         data: data,
         retryAfter: response.headerFields[.retryAfter],
         etag: response.headerFields[.eTag]
      )
   }
}

/// Adds the bearer token to every request and, on a 401, refreshes once and replays the
/// request. Site API v2 serves the signed-in user's view (drafts included) to any
/// request that carries a token, and the app only talks to it while signed in.
struct AuthMiddleware: ClientMiddleware {
   /// Upper bound for a request body buffered for a possible replay.
   static let maximumReplayBodyBytes = 4 << 20

   /// The session that supplies and refreshes tokens.
   let auth: any SessionAuthenticating

   /// Sends the request with the current token and replays it once with a fresh token
   /// when the server rejects the first one.
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      //////////////////////////////////////////////////
      // buffer the body so it can be sent twice.     //
      //////////////////////////////////////////////////
      let bytes = try await collect(body, upTo: Self.maximumReplayBodyBytes)
      let token = try await auth.accessToken()
      let response = try await next(request.authorized(token), bytes.map(HTTPBody.init), baseURL)
      if response.0.status.code == HTTPResponse.Status.unauthorized.code {
         let fresh = try await auth.forceRefresh(rejected: token)
         return try await next(request.authorized(fresh), bytes.map(HTTPBody.init), baseURL)
      }
      return response
   }
}

/// The generator cannot encode an explicit JSON `null`, but a full-state
/// `PATCH /blogPost/{id}` must clear optional fields the user emptied. `SiteService` names
/// those fields in the task-local `fields` around the call and this middleware adds them
/// to the body as `null`.
struct ExplicitNullMiddleware: ClientMiddleware {
   /// The fields to send as `null` on the update made in the current task.
   @TaskLocal static var fields: Set<String> = []

   /// Upper bound for the update body read for rewriting.
   static let maximumBodyBytes = 4 << 20

   /// Adds the nulls to `updateBlogPost` bodies and leaves every other request alone.
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      let fields = Self.fields
      guard operationID == "updateBlogPost", !fields.isEmpty, let body else { return try await next(request, body, baseURL) }
      let data = try await Data(collecting: body, upTo: Self.maximumBodyBytes)
      return try await next(request, HTTPBody(Self.rewrite(data, nulls: fields)), baseURL)
   }

   /// Sets each of `nulls` to `null` in a JSON object body (keys that carry a value are
   /// left alone). Bodies that are not a JSON object are returned unchanged.
   static func rewrite(_ data: Data, nulls: Set<String>) -> Data {
      var object: [String: Any]
      do {
         guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
         object = parsed
      }
      catch {
         Log.api.warning("Update body is not JSON, sent unchanged: \(error.localizedDescription, privacy: .public)")
         return data
      }
      for key in nulls where object[key] == nil { object[key] = NSNull() }
      ////////////////////////////////////////////////////////////
      // re-serialising values JSONSerialization just parsed    //
      // cannot fail; the original body is the safe fallback.   //
      ////////////////////////////////////////////////////////////
      guard let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return data }
      return rewritten
   }
}

/// Holds the raw body of one response so code can read fields the generated types drop.
/// A read sets it as the task-local `current` around one call.
final class ResponseCapture: Sendable {
   /// The capture for the calls made in the current task, if any.
   @TaskLocal static var current: ResponseCapture?

   /// The captured body; empty until a response arrives.
   private let storage = Mutex(Data())

   /// The body captured last, or empty when none was.
   var data: Data { storage.withLock { $0 } }

   /// Keeps `data` as the captured body.
   func keep(_ data: Data) { storage.withLock { $0 = data } }
}

/// Copies the response body into `ResponseCapture.current` when a caller asked for it,
/// and hands the generated client an identical body to decode.
struct ResponseCaptureMiddleware: ClientMiddleware {
   /// Upper bound for a captured body; a page of posts with full content is far smaller.
   static let maximumBodyBytes = 16 << 20

   /// Captures the body of the response when a capture is set for this task.
   func intercept(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
      next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
   ) async throws -> (HTTPResponse, HTTPBody?) {
      let (response, responseBody) = try await next(request, body, baseURL)
      guard let capture = ResponseCapture.current, let responseBody else { return (response, responseBody) }
      let data = try await Data(collecting: responseBody, upTo: Self.maximumBodyBytes)
      capture.keep(data)
      return (response, HTTPBody(data))
   }
}

/// Runs a generated-client call and rethrows errors raised by middlewares (`APIError`,
/// `AuthError`, `URLError`) without the generator's `ClientError` wrapper.
func unwrappingClientErrors<T>(_ body: () async throws -> T) async throws -> T {
   do {
      return try await body()
   }
   catch let error as ClientError {
      throw error.underlyingError
   }
}

/// Collects an optional body into memory. It exists because `Optional.map` cannot take
/// an async closure.
func collect(_ body: HTTPBody?, upTo limit: Int) async throws -> Data? {
   guard let body else { return nil }
   return try await Data(collecting: body, upTo: limit)
}

extension HTTPRequest {
   /// A copy of the request carrying `token` as its bearer credential.
   func authorized(_ token: String) -> HTTPRequest {
      var copy = self
      copy.headerFields[.authorization] = "Bearer \(token)"
      return copy
   }
}
