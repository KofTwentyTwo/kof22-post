/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// A field value with its longest allowed length, for the length checks.
struct LengthRule {
   /// The value, or nil when the field is not set.
   let value: String?
   /// Longest allowed length in characters.
   let limit: Int
   /// How the field is named in messages and errors.
   let label: String

   /// True when the trimmed value is longer than the limit.
   var isTooLong: Bool { (value?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) > limit }
}

/// Client-side checks that mirror the Site API v2 field limits and photo rules, so the
/// composer can say what is wrong before anything is queued. The server stays
/// authoritative.
extension PostComposition {
   /// The first problem that would make the server refuse this post, worded for the
   /// user, or nil when it can be sent. `now` is injectable for tests.
   public func validationMessage(limits: PhotoLimits, now: Date = .now) -> String? {
      if isEmpty { return "Write something, add a photo or a link." }
      return textProblem() ?? photoProblem(limits: limits) ?? scheduleProblem(now: now) ?? linkProblem()
   }

   /// Field lengths the composer lets the user type freely.
   func textProblem() -> String? {
      let rules = [
         LengthRule(value: title, limit: PostFieldLimits.title, label: "Titles"), LengthRule(value: name, limit: PostFieldLimits.name, label: "Names"),
         LengthRule(value: shortName, limit: PostFieldLimits.shortName, label: "Short names"),
         LengthRule(value: slug, limit: PostFieldLimits.slug, label: "Slugs"),
         LengthRule(value: description, limit: PostFieldLimits.description, label: "Descriptions"),
         LengthRule(value: metaTitle, limit: PostFieldLimits.metaTitle, label: "SEO titles"),
         LengthRule(value: metaDescription, limit: PostFieldLimits.metaDescription, label: "SEO descriptions"),
         LengthRule(value: metaKeywords, limit: PostFieldLimits.metaKeywords, label: "SEO keywords"),
         LengthRule(value: locationLabel, limit: PostFieldLimits.locationLabel, label: "Places"),
      ]
      if let rule = rules.first(where: \.isTooLong) { return "\(rule.label) are limited to \(rule.limit) characters." }
      if tags.contains(where: { $0.count > PostFieldLimits.tag }) { return "Tags are limited to \(PostFieldLimits.tag) characters." }
      return nil
   }

   /// Alt text and caption lengths, and the server's alt-text and caption requirements.
   func photoProblem(limits: PhotoLimits) -> String? {
      if photos.contains(where: { $0.altText.count > PostFieldLimits.altText }) {
         return "Alt text is limited to \(PostFieldLimits.altText) characters."
      }
      if photos.contains(where: { $0.caption.count > PostFieldLimits.caption }) {
         return "Captions are limited to \(PostFieldLimits.caption) characters."
      }
      if limits.photoAltTextRequired, photos.contains(where: { !$0.isUploaded && $0.altText.nilIfBlank == nil }) {
         return "Every photo needs alt text."
      }
      if limits.photoCaptionRequired, photos.contains(where: { !$0.isUploaded && $0.caption.nilIfBlank == nil }) {
         return "Every photo needs a caption."
      }
      return nil
   }

   /// A scheduled post needs a time at least a minute ahead and at most a year ahead.
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
      if link.count > PostFieldLimits.link { return "Links are limited to \(PostFieldLimits.link) characters." }
      let url = URL(string: link)
      let scheme = url?.scheme?.lowercased()
      guard scheme == "http" || scheme == "https", url?.host()?.isEmpty == false else {
         return "Links must start with http:// or https://"
      }
      return nil
   }
}
