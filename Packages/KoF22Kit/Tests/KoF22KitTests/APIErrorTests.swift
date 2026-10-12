/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

@Suite struct APIErrorDecodingTests {
   @Test func envelopeFieldsAndHeadersAreKept() {
      let body = #"{"error":{"code":"validation_failed","message":"Invalid post","status":422,"details":[{"field":"title","issue":"is too long"}]}}"#
      let error = APIError.decode(status: 422, data: Data(body.utf8), retryAfter: "12", etag: "\"v2\"")
      #expect(error.code == "validation_failed")
      #expect(error.message == "Invalid post")
      #expect(error.details == [APIError.Detail(field: "title", issue: "is too long")])
      #expect(error.retryAfter == 12)
      #expect(error.currentETag == "\"v2\"")
      #expect(error.errorDescription == "Invalid post: title is too long")
   }

   @Test func bodyThatIsNotAnEnvelopeFallsBackToTheStatus() {
      let error = APIError.decode(status: 503, data: Data("<html>busy</html>".utf8), retryAfter: "soon", etag: nil)
      #expect(error.code == "http_503")
      #expect(error.message == HTTPURLResponse.localizedString(forStatusCode: 503).capitalized)
      #expect(error.details.isEmpty)
      #expect(error.retryAfter == nil)
      #expect(error.errorDescription == error.message)
   }

   @Test(arguments: [408, 429, 500, 503])
   func timeoutsRateLimitsAndServerFaultsAreTransient(status: Int) {
      #expect(APIError(status: status, code: "x", message: "m").isTransient)
   }

   @Test func idempotencyInProgressIsTransient() {
      #expect(APIError(status: 409, code: "idempotency_in_progress", message: "busy").isTransient)
      #expect(!APIError(status: 409, code: "conflict", message: "no").isTransient)
   }
}

@Suite struct ErrorClassifierTests {
   @Test func apiErrorsMapToTheirReaction() {
      #expect(ErrorClassifier.disposition(for: APIError(status: 401, code: "unauthorized", message: "")) == .needsSignIn)
      #expect(ErrorClassifier.disposition(for: APIError(status: 412, code: "precondition_failed", message: "")) == .conflict)
      #expect(ErrorClassifier.disposition(for: APIError(status: 429, code: "rate_limited", message: "", retryAfter: 30)) == .retryLater(after: 30))
      #expect(ErrorClassifier.disposition(for: APIError(status: 404, code: "not_found", message: "")) == .permanent)
   }

   @Test func authErrorsMapToTheirReaction() {
      #expect(ErrorClassifier.disposition(for: AuthError.sessionExpired) == .needsSignIn)
      #expect(ErrorClassifier.disposition(for: AuthError.signedOut) == .needsSignIn)
      #expect(ErrorClassifier.disposition(for: AuthError.server(status: 502, message: "bad gateway")) == .retryLater(after: nil))
      #expect(ErrorClassifier.disposition(for: AuthError.server(status: 400, message: "bad request")) == .permanent)
      #expect(ErrorClassifier.disposition(for: AuthError.stateMismatch) == .permanent)
   }

   @Test func networkFailuresAndCancellationAreRetried() {
      #expect(ErrorClassifier.disposition(for: URLError(.timedOut)) == .retryLater(after: nil))
      #expect(ErrorClassifier.disposition(for: CancellationError()) == .retryLater(after: nil))
   }

   @Test func unknownErrorsArePermanent() {
      #expect(ErrorClassifier.disposition(for: MediaError.tooLarge) == .permanent)
   }

   @Test func messagesAreShortAndSpecific() {
      let validation = APIError(status: 422, code: "v", message: "Invalid", details: [.init(field: "body", issue: "is empty")])
      #expect(ErrorClassifier.message(for: validation) == "Invalid: body is empty")
      #expect(ErrorClassifier.message(for: AuthError.signedOut) == "Signed out. Sign in again to send.")
      #expect(ErrorClassifier.message(for: AuthError.sessionExpired) == "Signed out. Sign in again to send.")
      #expect(ErrorClassifier.message(for: URLError(.notConnectedToInternet)) == "Offline")
      #expect(ErrorClassifier.message(for: URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
      #expect(ErrorClassifier.message(for: MediaError.unreadable) == "The photo could not be read.")
   }
}

@Suite struct APIModelTests {
   @Test func statusLabelsAreHumanReadable() {
      #expect(PostStatus.draft.label == "Draft")
      #expect(PostStatus.scheduled.label == "Scheduled")
      #expect(PostStatus.published.label == "Published")
   }

   @Test func fallbackLimitsMatchTheBackend() {
      let limits = AuthoringLimits.fallback
      #expect(limits.maxBodyLength == 10_000)
      #expect(limits.maxTitleLength == 100)
      #expect(limits.maxTags == 10)
      #expect(limits.maxPhotosPerPost == 20)
      #expect(limits.maxPhotoBytes == 25 * 1_024 * 1_024)
      #expect(limits.photoContentTypes == ["image/jpeg", "image/png"])
   }
}

/// Storage errors on the presigned PUT get their own wording.
@Suite struct StorageErrorMessageTests {
   /// An expired upload link is explained as such, not as a permission problem.
   @Test func expiredUploadLinkIsNotReportedAsForbidden() {
      let expired = APIError(status: 403, code: "upload_put_failed", message: "Request has expired")
      #expect(ErrorClassifier.userMessage(for: expired).contains("expired"))
      #expect(!ErrorClassifier.isForbidden(expired))
   }

   /// Other storage failures say the upload will be retried.
   @Test func otherStorageFailuresAreRetried() {
      let failed = APIError(status: 500, code: "upload_put_failed", message: "Internal")
      #expect(ErrorClassifier.userMessage(for: failed).contains("retried"))
   }
}
