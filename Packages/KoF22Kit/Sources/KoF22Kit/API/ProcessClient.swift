/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Calls the Site API v2 process endpoints the spec leaves untyped (`/me`,
/// `/media/createUpload`, `/media/completeUpload/{uploadId}`, `/blogPost/linkPreview`:
/// their bodies are `{"type":"object"}`). Requests run through the same transport and
/// middlewares as the generated client, so auth, refresh and error mapping are shared;
/// the payload types are the documented shapes (`APIModels.swift`).
struct ProcessClient: Sendable {
   /// The process names, used as operation ids.
   enum Operation {
      /// `GET /v2/me`.
      static let caller = "me"
      /// `POST /v2/media/createUpload`.
      static let createUpload = "createUpload"
      /// `POST /v2/media/completeUpload/{uploadId}`.
      static let completeUpload = "completeUpload"
      /// `POST /v2/blogPost/linkPreview`.
      static let linkPreview = "linkPreview"
      /// `GET /versions.json`.
      static let versions = "versions"
   }

   /// Largest process response read; these answers are small.
   static let maximumBodyBytes = 1 << 20

   /// The API host; paths carry the `/v2` prefix.
   let serverURL: URL
   /// Sends the requests.
   let transport: any ClientTransport
   /// Applied in order, the first one outermost, exactly as the generated client does.
   let middlewares: [any ClientMiddleware]

   /// Sends a request without a body and decodes the answer. `operation` is the
   /// process name, passed to middlewares and the transport as the operation id.
   func send<Response: Decodable>(_ method: HTTPRequest.Method, _ path: String, operation: String) async throws -> Response {
      try await send(method, path, operation: operation, data: nil)
   }

   /// Sends `body` as JSON and decodes the answer.
   func send<Response: Decodable>(
      _ method: HTTPRequest.Method, _ path: String, operation: String, body: some Encodable
   ) async throws -> Response {
      try await send(method, path, operation: operation, data: try JSONEncoder().encode(body))
   }

   /// Runs the middleware chain and the transport, then decodes a 2xx body (a non-2xx
   /// one has already become an `APIError` in `ErrorEnvelopeMiddleware`).
   private func send<Response: Decodable>(
      _ method: HTTPRequest.Method, _ path: String, operation operationID: String, data: Data?
   ) async throws -> Response {
      var request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
      request.headerFields[.accept] = "application/json"
      if data != nil { request.headerFields[.contentType] = "application/json" }
      let (_, body) = try await unwrappingClientErrors {
         try await run(request, body: data.map(HTTPBody.init), operationID: operationID, index: 0)
      }
      let bytes = try await collect(body, upTo: Self.maximumBodyBytes) ?? Data()
      return try SiteService.decoder.decode(Response.self, from: bytes)
   }

   /// Calls middleware `index`, whose `next` is the rest of the chain, ending in the
   /// transport.
   private func run(_ request: HTTPRequest, body: HTTPBody?, operationID: String, index: Int) async throws -> (HTTPResponse, HTTPBody?) {
      guard index < middlewares.count else {
         return try await transport.send(request, body: body, baseURL: serverURL, operationID: operationID)
      }
      return try await middlewares[index].intercept(request, body: body, baseURL: serverURL, operationID: operationID) { request, body, _ in
         try await run(request, body: body, operationID: operationID, index: index + 1)
      }
   }
}
