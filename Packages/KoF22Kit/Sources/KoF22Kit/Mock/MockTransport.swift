/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Routes generated-client requests to `MockBackend` without any networking, so the
/// whole client stack (middlewares, error mapping) runs against the mock contract.
public struct MockTransport: ClientTransport {
   /// Largest request body the mock reads (8 MiB); post bodies are far smaller.
   static let maxRequestBytes = 8_388_608

   /// The backend that answers every request.
   let backend: MockBackend

   /// Creates a transport answering from `backend`.
   public init(backend: MockBackend) { self.backend = backend }

   /// Hands the request to the backend by operation id, with lower-cased header names
   /// and the query as a dictionary, and converts the reply back to HTTP types.
   public func send(
      _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
   ) async throws
      -> (HTTPResponse, HTTPBody?)
   {
      let components = URLComponents(string: request.path ?? "/")
      var query: [String: String] = [:]
      for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
      var headers: [String: String] = [:]
      for field in request.headerFields { headers[field.name.canonicalName.lowercased()] = field.value }
      let data = try await collect(body, upTo: Self.maxRequestBytes)

      let response = try await backend.handle(
         operation: operationID, path: components?.path ?? "/", query: query, headers: headers, body: data
      )
      var fields = HTTPFields()
      for (name, value) in response.headers {
         if let name = HTTPField.Name(name) { fields[name] = value }
      }
      return (HTTPResponse(status: .init(code: response.status), headerFields: fields), response.body.map(HTTPBody.init))
   }
}

/// Stands in for the presigned S3 PUT in mock mode.
public struct MockUploadPerformer: UploadPerformer {
   /// The backend that receives the uploaded bytes.
   let backend: MockBackend

   /// Creates an uploader that hands files to `backend`.
   public init(backend: MockBackend) { self.backend = backend }

   /// Copies the file into the backend under the upload id taken from the URL, or
   /// fails like a device with no connection while the mock is offline.
   public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      if await backend.simulateOffline { throw URLError(.notConnectedToInternet) }
      try await backend.receiveUpload(id: url.lastPathComponent, from: fileURL)
   }
}
