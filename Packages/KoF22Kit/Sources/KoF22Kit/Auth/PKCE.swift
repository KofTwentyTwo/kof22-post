/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import CryptoKit
import Foundation

/// RFC 7636 proof key. The verifier never leaves the device until the token exchange.
public struct PKCE: Sendable, Equatable {
   /// 32 random bytes give a 43-character verifier, the minimum RFC 7636 allows.
   static let verifierByteCount = 32

   /// The secret sent only with the token exchange.
   public let verifier: String
   /// The SHA-256 of the verifier, sent with the authorization request.
   public let challenge: String
   /// The challenge method; always S256, never plain.
   public let method = "S256"

   /// Derives the challenge for a known verifier.
   public init(verifier: String) {
      self.verifier = verifier
      self.challenge = Self.challenge(for: verifier)
   }

   /// A new proof key with a random verifier.
   public static func generate() -> Self {
      Self(verifier: randomURLSafeString(byteCount: verifierByteCount))
   }

   /// The base64url SHA-256 of the verifier (the S256 method).
   public static func challenge(for verifier: String) -> String {
      Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
   }

   /// `byteCount` random bytes from the system generator as unpadded base64url.
   public static func randomURLSafeString(byteCount: Int) -> String {
      var generator = SystemRandomNumberGenerator()
      let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
      return Data(bytes).base64URLEncodedString()
   }
}

extension Data {
   /// Base64url without padding (RFC 4648 section 5), as PKCE and OAuth state require.
   func base64URLEncodedString() -> String {
      base64EncodedString()
         .replacingOccurrences(of: "+", with: "-")
         .replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: "=", with: "")
   }
}
