/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import OpenAPIRuntime

/// Dates as the Site API sends them. The live server writes ISO 8601 with microseconds
/// (`2026-10-11T12:36:21.332554Z`), which the runtime's default transcoder rejects, while
/// the mock and older payloads use whole seconds. Decoding accepts both; encoding writes
/// whole seconds, which every endpoint accepts.
struct SiteDateTranscoder: DateTranscoder {
   /// Whole-second ISO 8601, used for encoding and as the decoding fallback.
   static let wholeSeconds = Date.ISO8601FormatStyle()
   /// ISO 8601 with a fractional-seconds part of any length.
   static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

   /// Writes `date` as whole-second ISO 8601 in UTC.
   func encode(_ date: Date) throws -> String { Self.wholeSeconds.format(date) }

   /// Reads ISO 8601 with or without fractional seconds.
   func decode(_ text: String) throws -> Date {
      do {
         return try Self.fractionalSeconds.parse(text)
      }
      catch {
         ////////////////////////////////////////////////////////////
         // no fractional part is the other valid form; its parse  //
         // error is the one surfaced when neither form matches.   //
         ////////////////////////////////////////////////////////////
         return try Self.wholeSeconds.parse(text)
      }
   }

   /// A JSON decoder whose dates follow the same rules, for payloads decoded outside the
   /// generated client (query records).
   static func jsonDecoder() -> JSONDecoder {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .custom { decoder in
         let text = try decoder.singleValueContainer().decode(String.self)
         return try Self().decode(text)
      }
      return decoder
   }
}
