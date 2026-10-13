/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes

/// A non-2xx response decoded from a Site API v2 error body. The API's own processes
/// answer `{"error":{"code","message","status","details"}}`; table operations answer
/// `{"error":"message"}`, sometimes with a top-level `code` and `details`.
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

   /// Builds an error from a raw response. A body that is not one of the envelopes (a
   /// proxy page, an empty body) still yields a usable error built from the status code.
   static func decode(status: Int, data: Data, retryAfter: String?, etag: String?) -> Self {
      ////////////////////////////////////////////////////////////
      // a body that is not an envelope is expected (proxies,   //
      // empty bodies); the status code alone is the fallback.  //
      ////////////////////////////////////////////////////////////
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      let nested = root["error"] as? [String: Any]
      let code = (nested?["code"] as? String) ?? (root["code"] as? String)
      let message = (nested?["message"] as? String) ?? (root["error"] as? String)
      let rawDetails = (nested?["details"] as? [[String: Any]]) ?? (root["details"] as? [[String: Any]]) ?? []
      return Self(
         status: status,
         code: code ?? "http_\(status)",
         message: message ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
         details: rawDetails.compactMap { item in
            guard let field = item["field"] as? String else { return nil }
            return Detail(field: field, issue: item["issue"] as? String ?? "")
         },
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

   /// A short message for the outbox row, notifications and error banners.
   public static func message(for error: any Error) -> String {
      switch error {
      case let error as APIError: userMessage(for: error)
      case AuthError.sessionExpired, AuthError.signedOut: "Signed out. Sign in again to send."
      case let error as URLError: error.code == .notConnectedToInternet ? "Offline" : error.localizedDescription
      default: error.localizedDescription
      }
   }

   /// True when the server refused because this account may not publish (403
   /// `forbidden` or `insufficient_scope`), so the UI can say "this account can't
   /// publish" instead of offering a retry. A 403 from photo storage is not one.
   public static func isForbidden(_ error: any Error) -> Bool {
      guard let error = error as? APIError else { return false }
      return forbiddenCodes.contains(error.code)
   }

   /// The status storage returns for a presigned upload URL that has expired.
   static let storageExpiredStatus = 403

   /// The error codes that mean the account lacks permission to publish; `http_403` is a
   /// 403 whose body was not the error envelope.
   static let forbiddenCodes: Set<String> = ["forbidden", "insufficient_scope", "http_403"]

   /// Clear wording for each error code the Site API and its storage use. Codes not
   /// listed here fall back to the server's own message.
   static let codeMessages: [String: String] = [
      "unauthorized": "Your session has ended. Sign in again.",
      "forbidden": "This account can't publish to kof22.com.",
      "http_403": "This account can't publish to kof22.com.",
      "insufficient_scope": "This sign-in doesn't include permission to publish. Sign out and sign in again.",
      "not_found": "Not found. It may have been deleted.",
      "conflict": "The server reported a conflict. Try again.",
      "slug_conflict": "Another post already uses this address. Change the slug and try again.",
      "idempotency_in_progress": "The server is still working on this request. It will be retried.",
      "idempotency_key_reused": "This request was already sent with different content.",
      "delete_blocked": "This post can't be deleted right now.",
      "precondition_failed": "The post changed on the server since it was loaded.",
      "precondition_required": "The update was sent without the post's version. Reload the post and try again.",
      "payload_too_large": "This is too large to send.",
      "image_too_large": "The photo is too large.",
      "unsupported_media_type": "This file type isn't supported. Use JPEG, PNG or HEIC.",
      "heic_conversion_unavailable": "The server can't convert HEIC photos right now. Try again later.",
      "heic_conversion_failed": "The server couldn't convert this HEIC photo.",
      "rate_limited": "Too many requests right now. Try again shortly.",
      "link_not_allowed": "Only public http or https links can be used.",
      "upload_expired": "The photo upload expired before it finished. Send again to upload it again.",
      "upload_not_received": "The photo didn't reach the server. Send again.",
      "unavailable": "kof22.com is temporarily unavailable. Try again later.",
      "internal_error": "The server ran into a problem. Try again later.",
      "bad_request": "The server couldn't understand the request.",
   ]

   /// A clear, user-facing message for an API error: validation failures list each field
   /// problem, a bad request keeps its specific message, rate limiting says how long to
   /// wait when the server said, known codes use fixed wording and anything else shows the
   /// server's message.
   public static func userMessage(for error: APIError) -> String {
      if error.code == "validation_failed" {
         guard !error.details.isEmpty else { return "The post wasn't accepted: \(error.message)" }
         return "Please fix: " + error.details.map { "\($0.field) \($0.issue)" }.joined(separator: "; ")
      }
      if error.code == "bad_request", !error.message.isEmpty {
         //////////////////////////////////////////////////////////////
         // a 400's own message names what was wrong with the       //
         // request (local checks raise it too), so it is kept.      //
         //////////////////////////////////////////////////////////////
         return error.summary
      }
      if error.code == "upload_put_failed" {
         //////////////////////////////////////////////////////////////
         // storage answers a presigned PUT with 403 once the link  //
         // has expired; that is not an account permission problem. //
         //////////////////////////////////////////////////////////////
         return error.status == storageExpiredStatus
            ? "The photo upload link expired. Send again to start a new upload."
            : "The photo upload to storage failed. It will be retried."
      }
      if error.code == "rate_limited", let seconds = error.retryAfter {
         return "Too many requests right now. Try again in \(Int(seconds.rounded(.up))) seconds."
      }
      return codeMessages[error.code] ?? error.summary
   }
}
