/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Client-side checks that mirror the Site API's limits, so the composer can say what is
/// wrong before anything is queued. The server's 422 stays authoritative.
extension PostComposition {
   /// The first problem that would make the server refuse this post, worded for the
   /// user, or nil when it can be sent. `now` is injectable for tests.
   public func validationMessage(limits: AuthoringLimits, now: Date = .now) -> String? {
      if isEmpty { return "Write something, add a photo or a link." }
      return textProblem(limits: limits) ?? photoProblem(limits: limits) ?? scheduleProblem(now: now) ?? linkProblem()
   }

   /// Body, title, tag and location lengths.
   func textProblem(limits: AuthoringLimits) -> String? {
      if body.count > limits.maxBodyLength { return "Posts are limited to \(limits.maxBodyLength) characters." }
      if title.count > limits.maxTitleLength { return "Titles are limited to \(limits.maxTitleLength) characters." }
      if tags.count > limits.maxTags { return "At most \(limits.maxTags) tags." }
      if tags.contains(where: { $0.count > Self.maxTagLength }) { return "Tags are limited to \(Self.maxTagLength) characters." }
      if locationLabel.count > Self.maxLocationLabelLength { return "Places are limited to \(Self.maxLocationLabelLength) characters." }
      return nil
   }

   /// Photo count, alt text and caption lengths.
   func photoProblem(limits: AuthoringLimits) -> String? {
      if photos.count > limits.maxPhotosPerPost { return "At most \(limits.maxPhotosPerPost) photos per post." }
      if photos.contains(where: { $0.altText.count > Self.maxAltTextLength }) {
         return "Alt text is limited to \(Self.maxAltTextLength) characters."
      }
      if photos.contains(where: { $0.caption.count > Self.maxCaptionLength }) {
         return "Captions are limited to \(Self.maxCaptionLength) characters."
      }
      return nil
   }

   /// A scheduled post needs a time at least a minute ahead (the server's minimum is 30
   /// seconds; the extra margin leaves time to send) and at most 366 days ahead.
   func scheduleProblem(now: Date) -> String? {
      guard status == .scheduled else { return nil }
      guard let publishAt else { return "Pick a time to schedule." }
      let lead = publishAt.timeIntervalSince(now)
      if lead < Self.minimumScheduleLead { return "Schedule at least a minute ahead." }
      if lead > Self.maximumScheduleHorizon { return "Schedule at most a year ahead." }
      return nil
   }

   /// A link must be an http(s) URL with a host, within the server's length limit.
   func linkProblem() -> String? {
      guard let link = linkURL.nilIfBlank else { return nil }
      if link.count > Self.maxLinkLength { return "Links are limited to \(Self.maxLinkLength) characters." }
      let url = URL(string: link)
      let scheme = url?.scheme?.lowercased()
      guard scheme == "http" || scheme == "https", url?.host()?.isEmpty == false else {
         return "Links must start with http:// or https://"
      }
      return nil
   }
}
