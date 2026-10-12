/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import KoF22API

/// A non-2xx response decoded from the Site API error envelope
/// `{"error":{"code","message","status","details"}}`.
public struct APIError: Error, Sendable, Equatable, LocalizedError {
   /// One field-level problem from a validation failure, so the composer can point at the
   /// field the server rejected.
   public struct Detail: Sendable, Equatable {
      /// The request field the server rejected, such as `title` or `publishAt`.
      public let field: String
      /// The server's short description of what is wrong with the field.
      public let issue: String
   }

   /// The HTTP status code of the response.
   public let status: Int
   /// The machine-readable error code from the envelope, or `http_<status>` when the body
   /// was not an envelope.
   public let code: String
   /// The human-readable message from the envelope, or the standard reason phrase.
   public let message: String
   /// Field-level problems, present on validation failures.
   public let details: [Detail]
   /// Seconds the server asked the client to wait before retrying (`Retry-After`).
   public let retryAfter: TimeInterval?
   /// Sent with 412 so the client can retry against the current version.
   public let currentETag: String?

   /// Creates an error directly; used by the mock backend and by local checks that want
   /// to fail the same way the server would.
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

   /// The message followed by each field problem, so a validation failure reads as one
   /// sentence in the outbox.
   public var errorDescription: String? { summary }

   /// The message with each field problem appended, never nil.
   var summary: String {
      guard !details.isEmpty else { return message }
      return message + ": " + details.map { "\($0.field) \($0.issue)" }.joined(separator: ", ")
   }

   /// Worth retrying the same request later: timeouts, rate limiting, server faults and an
   /// idempotent request that is still being processed.
   public var isTransient: Bool {
      status == HTTPResponse.Status.requestTimeout.code
         || status == HTTPResponse.Status.tooManyRequests.code
         || status >= HTTPResponse.Status.internalServerError.code
         || code == "idempotency_in_progress"
   }

   /// Builds an error from a raw response. A body that is not the envelope (a proxy page,
   /// an empty body) still yields a usable error built from the status code.
   static func decode(status: Int, data: Data, retryAfter: String?, etag: String?) -> Self {
      ////////////////////////////////////////////////////////////
      // a body that is not the envelope is expected (proxies,  //
      // empty bodies); the status code alone is the fallback.  //
      ////////////////////////////////////////////////////////////
      let envelope = try? JSONDecoder().decode(Components.Schemas._Error.self, from: data)
      let body = envelope?.error
      return Self(
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
   /// Try again later, after the server's `Retry-After` when it sent one.
   case retryLater(after: TimeInterval?)
   /// The session is gone; the item waits until the owner signs in again.
   case needsSignIn
   /// The post changed on the server since it was loaded (412).
   case conflict
   /// Retrying the same request cannot succeed.
   case permanent
}

/// Maps any error the send pipeline can throw to an outbox reaction and a short message,
/// so the outbox does not need to know about each error type.
public enum ErrorClassifier {
   /// Decides whether a failed send should be retried, needs sign-in, is a conflict, or
   /// has failed for good. Network errors and cancellation are always retried.
   public static func disposition(for error: any Error) -> FailureDisposition {
      switch error {
      case let error as APIError:
         if error.status == HTTPResponse.Status.unauthorized.code { return .needsSignIn }
         if error.status == HTTPResponse.Status.preconditionFailed.code { return .conflict }
         if error.isTransient { return .retryLater(after: error.retryAfter) }
         return .permanent
      case let error as AuthError:
         switch error {
         case .sessionExpired, .signedOut: return .needsSignIn
         case .server(let status, _) where status >= HTTPResponse.Status.internalServerError.code: return .retryLater(after: nil)
         default: return .permanent
         }
      case is URLError, is CancellationError:
         return .retryLater(after: nil)
      default:
         return .permanent
      }
   }

   /// A short message for the outbox row and notifications.
   public static func message(for error: any Error) -> String {
      switch error {
      case let error as APIError: error.summary
      case AuthError.sessionExpired, AuthError.signedOut: "Signed out. Sign in again to send."
      case let error as URLError: error.code == .notConnectedToInternet ? "Offline" : error.localizedDescription
      default: error.localizedDescription
      }
   }
}
