import Foundation
import KoF22API

/// A non-2xx response decoded from the Site API error envelope
/// `{"error":{"code","message","status","details"}}`.
public struct APIError: Error, Sendable, Equatable, LocalizedError {
   public struct Detail: Sendable, Equatable {
      public let field: String
      public let issue: String
   }

   public let status: Int
   public let code: String
   public let message: String
   public let details: [Detail]
   public let retryAfter: TimeInterval?
   /// Sent with 412 so the client can retry against the current version.
   public let currentETag: String?

   public init(
      status: Int, code: String, message: String, details: [Detail] = [],
      retryAfter: TimeInterval? = nil, currentETag: String? = nil
   ) {
      self.status = status
      self.code = code
      self.message = message
      self.details = details
      self.retryAfter = retryAfter
      self.currentETag = currentETag
   }

   public var errorDescription: String? {
      guard !details.isEmpty else { return message }
      return message + ": " + details.map { "\($0.field) \($0.issue)" }.joined(separator: ", ")
   }

   /// Worth retrying the same request later.
   public var isTransient: Bool {
      status == 408 || status == 429 || status >= 500 || code == "idempotency_in_progress"
   }

   static func decode(status: Int, data: Data, retryAfter: String?, etag: String?) -> APIError {
      let envelope = try? JSONDecoder().decode(Components.Schemas._Error.self, from: data)
      let body = envelope?.error
      return APIError(
         status: status,
         code: body?.code ?? "http_\(status)",
         message: body?.message ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
         details: body?.details?.map { Detail(field: $0.field, issue: $0.issue) } ?? [],
         retryAfter: retryAfter.flatMap(TimeInterval.init),
         currentETag: etag
      )
   }
}

/// How the outbox should react to a failure.
public enum FailureDisposition: Equatable, Sendable {
   case retryLater(after: TimeInterval?)
   case needsSignIn
   case conflict
   case permanent
}

public enum ErrorClassifier {
   public static func disposition(for error: any Error) -> FailureDisposition {
      switch error {
      case let error as APIError:
         if error.status == 401 { return .needsSignIn }
         if error.status == 412 { return .conflict }
         if error.isTransient { return .retryLater(after: error.retryAfter) }
         return .permanent
      case let error as AuthError:
         switch error {
         case .sessionExpired, .signedOut: return .needsSignIn
         case .server(let status, _) where status >= 500: return .retryLater(after: nil)
         default: return .permanent
         }
      case is URLError, is CancellationError:
         return .retryLater(after: nil)
      default:
         return .permanent
      }
   }

   public static func message(for error: any Error) -> String {
      switch error {
      case let error as APIError: error.errorDescription ?? error.message
      case AuthError.sessionExpired, AuthError.signedOut: "Signed out. Sign in again to send."
      case let error as URLError: error.code == .notConnectedToInternet ? "Offline" : error.localizedDescription
      default: error.localizedDescription
      }
   }
}
