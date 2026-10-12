/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// Reads the JSON files in `Fixtures/`: responses recorded once from the live API
/// (anonymous reads) and examples built from the spec (authoring endpoints).
enum Fixture {
   /// The bytes of `Fixtures/<name>.json`.
   static func data(_ name: String) throws -> Data {
      let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
      return try Data(contentsOf: url)
   }

   /// `Fixtures/<name>.json` with `field` added to the top-level object, or to every
   /// element of its `records` array, to prove unknown fields are ignored.
   static func injecting(_ field: String, into name: String, records: Bool = false) throws -> Data {
      var object = try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
      let extra: [String: Any] = ["addedIn": "1.9.0", "nested": ["a", "b"]]
      if records {
         let list = try #require(object["records"] as? [[String: Any]])
         object["records"] = list.map { record in record.merging([field: extra]) { current, _ in current } }
      }
      else {
         object[field] = extra
      }
      return try JSONSerialization.data(withJSONObject: object)
   }
}

/// A transport that answers each operation id with a fixed status and body and records
/// every request it was sent, so tests run the generated client's real encoding and
/// decoding without a network.
final class FixtureTransport: ClientTransport, @unchecked Sendable {
   /// One canned reply.
   struct Reply {
      /// The status of a successful read.
      static let okStatus = 200
      /// The HTTP status.
      let status: Int
      /// The JSON body.
      let body: Data

      /// A 200 reply carrying `Fixtures/<name>.json`.
      static func okay(_ name: String) throws -> Self { Self(status: okStatus, body: try Fixture.data(name)) }
   }

   /// Guards `sent`.
   private let lock = NSLock()
   /// The replies by operation id; anything else gets 404 without a body.
   private let replies: [String: Reply]
   /// The requests seen, with their operation ids.
   private var sent: [(operation: String, request: HTTPRequest)] = []

   /// Creates a transport answering `replies`.
   init(_ replies: [String: Reply]) { self.replies = replies }

   /// Every request seen so far, in order.
   var requests: [(operation: String, request: HTTPRequest)] { lock.withLock { sent } }

   /// The `Authorization` header of each request for `operation`.
   func authorization(for operation: String) -> [String?] {
      requests.filter { $0.operation == operation }.map { $0.request.headerFields[.authorization] }
   }

   /// Records the request and answers from the table.
   func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
      lock.withLock { sent.append((operationID, request)) }
      guard let reply = replies[operationID] else { return (HTTPResponse(status: .notFound), nil) }
      var fields = HTTPFields()
      fields[.contentType] = "application/json"
      return (HTTPResponse(status: .init(code: reply.status), headerFields: fields), HTTPBody(reply.body))
   }
}
