import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Routes generated-client requests to `MockBackend` without any networking.
public struct MockTransport: ClientTransport {
   let backend: MockBackend

   public init(backend: MockBackend) { self.backend = backend }

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
      let data = try await collect(body, upTo: 8 << 20)

      let response = try await backend.handle(
         operation: operationID, method: request.method.rawValue, path: components?.path ?? "/",
         query: query, headers: headers, body: data
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
   let backend: MockBackend

   public init(backend: MockBackend) { self.backend = backend }

   public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      if await backend.simulateOffline { throw URLError(.notConnectedToInternet) }
      try await backend.receiveUpload(id: url.lastPathComponent, from: fileURL)
   }
}
