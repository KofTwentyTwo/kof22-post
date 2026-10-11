import CryptoKit
import Foundation

/// RFC 7636 proof key. The verifier never leaves the device until the token exchange.
public struct PKCE: Sendable, Equatable {
   public let verifier: String
   public let challenge: String
   public let method = "S256"

   public init(verifier: String) {
      self.verifier = verifier
      self.challenge = Self.challenge(for: verifier)
   }

   public static func generate() -> PKCE {
      PKCE(verifier: randomURLSafeString(byteCount: 32))
   }

   public static func challenge(for verifier: String) -> String {
      Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
   }

   public static func randomURLSafeString(byteCount: Int) -> String {
      var generator = SystemRandomNumberGenerator()
      let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
      return Data(bytes).base64URLEncodedString()
   }
}

extension Data {
   func base64URLEncodedString() -> String {
      base64EncodedString()
         .replacingOccurrences(of: "+", with: "-")
         .replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: "=", with: "")
   }
}
