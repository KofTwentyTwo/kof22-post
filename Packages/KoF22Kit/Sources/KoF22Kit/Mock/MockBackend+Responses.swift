/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import CryptoKit
import Foundation

/// Request decoding, idempotent replay and the JSON and error-envelope responses.
extension MockBackend {
   /// Valid lengths of an `Idempotency-Key`.
   static let idempotencyKeyLength = 8...255
   /// Punctuation allowed in an `Idempotency-Key` besides letters and digits.
   static let idempotencyKeyPunctuation = "._:-"
   /// The API version reported in every JSON response.
   static let apiVersion = "1.0.0"

   /// Encodes responses the way the backend does: ISO 8601 dates, sorted keys.
   static let encoder: JSONEncoder = {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      return encoder
   }()

   /// Decodes request bodies and the saved state with ISO 8601 dates.
   static let decoder: JSONDecoder = {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return decoder
   }()

   /// Decodes a request body. A missing or malformed body yields nil, which every
   /// caller answers with 400 (or treats as defaults where all fields are optional),
   /// so the failure reaches the client instead of being dropped.
   static func decodeBody<Body: Decodable>(_ type: Body.Type, from body: Data?) -> Body? {
      /////////////////////////////////////////////////////
      // The caller turns nil into a 400 for the client. //
      /////////////////////////////////////////////////////
      return body.flatMap { try? decoder.decode(type, from: $0) }
   }

   /// Parses a request body as a JSON object, so PATCH can tell an absent field from
   /// an explicit `null`. Anything else yields nil and a 400.
   static func jsonObject(_ body: Data?) -> [String: Any]? {
      /////////////////////////////////////////////////////
      // The caller turns nil into a 400 for the client. //
      /////////////////////////////////////////////////////
      return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
   }

   /// Replays the recorded response when the same `Idempotency-Key` comes back with
   /// the same body, refuses it with a different body, and records new successes.
   func idempotent(_ operation: String, headers: [String: String], body: Data?, perform: () throws -> Response) throws -> Response {
      guard let key = headers["idempotency-key"] else { return try perform() }
      guard Self.idempotencyKeyLength.contains(key.count),
         key.allSatisfy({ $0.isLetter || $0.isNumber || Self.idempotencyKeyPunctuation.contains($0) })
      else {
         return try validation([.init(field: "Idempotency-Key", issue: "8-255 characters of [A-Za-z0-9._:-]")])
      }
      let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
      let slot = "\(operation):\(key)"
      if let replay = state.replays[slot] {
         guard replay.bodyHash == hash else {
            return try problem(Status.unprocessable, "idempotency_key_reused", "Idempotency-Key was used with a different body")
         }
         var headers = replay.headers
         headers["Idempotent-Replayed"] = "true"
         return Response(status: replay.status, body: replay.body, headers: headers)
      }
      let response = try perform()
      if Status.success.contains(response.status) {
         state.replays[slot] = Replay(bodyHash: hash, status: response.status, body: response.body, headers: response.headers)
      }
      return response
   }

   /// A JSON response with the version header and, when given, a quoted ETag.
   func json(_ status: Int, _ value: some Encodable, etag: String? = nil, extra: [String: String] = [:]) throws -> Response {
      var headers = extra
      headers["Content-Type"] = "application/json"
      headers["X-API-Version"] = Self.apiVersion
      if let etag { headers["ETag"] = "\"\(etag)\"" }
      return Response(status: status, body: try Self.encoder.encode(value), headers: headers)
   }

   /// An error envelope `{"error":{"code","message","status","details"}}`.
   func problem(_ status: Int, _ code: String, _ message: String, details: [APIError.Detail] = [], etag: String? = nil) throws -> Response {
      let body = Components.Schemas._Error(
         error: .init(
            code: code, message: message, status: status,
            details: details.isEmpty ? nil : details.map { .init(field: $0.field, issue: $0.issue) }
         ))
      return try json(status, body, etag: etag)
   }

   /// The 400 sent for a body that is missing or not the expected JSON object.
   func badBody() throws -> Response {
      try problem(Status.badRequest, "bad_request", "Body must be a JSON object")
   }

   /// A 422 listing every validation issue; the message names the first one.
   func validation(_ issues: [APIError.Detail]) throws -> Response {
      try problem(
         Status.unprocessable, "validation_failed", issues.first.map { "\($0.field) \($0.issue)" } ?? "Validation failed",
         details: issues)
   }
}
