/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

@Suite struct ErrorMessageTests {
   /// Every code the Site API and its storage are known to use.
   static let knownCodes = [
      "unauthorized", "forbidden", "insufficient_scope", "not_found", "conflict", "slug_conflict", "idempotency_in_progress",
      "idempotency_key_reused", "delete_blocked", "precondition_failed", "precondition_required", "payload_too_large",
      "image_too_large", "unsupported_media_type", "heic_conversion_unavailable", "heic_conversion_failed", "rate_limited",
      "link_not_allowed", "upload_expired", "upload_not_received", "unavailable", "internal_error",
   ]

   @Test(arguments: knownCodes)
   func knownCodesHaveTheirOwnWording(code: String) {
      let error = APIError(status: 400, code: code, message: "server text \(code)")
      let message = ErrorClassifier.userMessage(for: error)
      #expect(message == ErrorClassifier.codeMessages[code])
      #expect(!message.contains("server text"))
      #expect(ErrorClassifier.message(for: error) == message)
   }

   @Test func unknownCodesFallBackToTheServerMessage() {
      let error = APIError(status: 418, code: "teapot", message: "I'm a teapot", details: [.init(field: "pot", issue: "is full")])
      #expect(ErrorClassifier.userMessage(for: error) == "I'm a teapot: pot is full")
   }

   @Test func validationFailuresListEachField() {
      let error = APIError(
         status: 422, code: "validation_failed", message: "Invalid",
         details: [.init(field: "title", issue: "max 100 characters"), .init(field: "tags", issue: "at most 10 tags")])
      #expect(ErrorClassifier.userMessage(for: error) == "Please fix: title max 100 characters; tags at most 10 tags")
   }

   @Test func validationFailureWithoutDetailsUsesTheMessage() {
      let error = APIError(status: 422, code: "validation_failed", message: "body is required")
      #expect(ErrorClassifier.userMessage(for: error) == "The post wasn't accepted: body is required")
   }

   @Test func badRequestKeepsItsSpecificMessage() {
      #expect(ErrorClassifier.userMessage(for: APIError(status: 400, code: "bad_request", message: "Invalid cursor")) == "Invalid cursor")
      #expect(ErrorClassifier.userMessage(for: APIError(status: 400, code: "bad_request", message: "")) == ErrorClassifier.codeMessages["bad_request"])
   }

   @Test func rateLimitWithoutRetryAfterUsesTheFixedWording() {
      let error = APIError(status: 429, code: "rate_limited", message: "Slow down")
      #expect(ErrorClassifier.userMessage(for: error) == ErrorClassifier.codeMessages["rate_limited"])
   }

   @Test func rateLimitSaysHowLongToWait() {
      let error = APIError(status: 429, code: "rate_limited", message: "Slow down", retryAfter: 2.5)
      #expect(ErrorClassifier.userMessage(for: error) == "Too many requests right now. Try again in 3 seconds.")
   }

   @Test func forbiddenIsDistinguishable() {
      #expect(ErrorClassifier.isForbidden(APIError(status: 403, code: "forbidden", message: "")))
      #expect(ErrorClassifier.isForbidden(APIError(status: 403, code: "insufficient_scope", message: "")))
      #expect(ErrorClassifier.isForbidden(APIError(status: 403, code: "http_403", message: "Forbidden")))
      #expect(!ErrorClassifier.isForbidden(APIError(status: 403, code: "upload_put_failed", message: "Signature expired")))
      #expect(!ErrorClassifier.isForbidden(APIError(status: 401, code: "unauthorized", message: "")))
      #expect(!ErrorClassifier.isForbidden(AuthError.signedOut))
      #expect(ErrorClassifier.disposition(for: APIError(status: 403, code: "forbidden", message: "")) == .permanent)
   }
}
