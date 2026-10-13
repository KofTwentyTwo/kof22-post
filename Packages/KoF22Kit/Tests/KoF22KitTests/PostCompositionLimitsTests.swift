/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// Per-photo location, compatibility with payloads saved by earlier versions, and the
/// client-side limits.
@Suite struct PostCompositionLimitsTests {
   /// A composition encoded the way the previous version stored it: a post-level
   /// `keepLocation` and photos without the per-photo keys.
   static func legacyPayload(keepLocation: Bool?) throws -> Data {
      let current = PostComposition(body: "old", photos: [ComposedPhoto(fileName: "a.jpg"), ComposedPhoto(fileName: "b.jpg")])
      var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
      let photos = try #require(object["photos"] as? [[String: Any]])
      object["photos"] = photos.map { photo in
         photo.filter { $0.key != "keepLocation" && $0.key != "uploadGeneration" }
      }
      if let keepLocation { object["keepLocation"] = keepLocation }
      return try JSONSerialization.data(withJSONObject: object)
   }

   @Test func photosDropLocationUnlessTheyOptIn() {
      #expect(!ComposedPhoto().keepLocation)
      #expect(ComposedPhoto(keepLocation: true).keepLocation)
   }

   @Test func aLegacyPostLevelOptInAppliesToEveryPhoto() throws {
      let decoded = try JSONDecoder().decode(PostComposition.self, from: Self.legacyPayload(keepLocation: true))
      #expect(decoded.photos.count == 2)
      #expect(decoded.photos.allSatisfy { $0.keepLocation })
      #expect(decoded.photos.allSatisfy { $0.uploadGeneration == 0 })
   }

   @Test func legacyPayloadsWithoutAnOptInKeepLocationOff() throws {
      for flag in [false, nil] as [Bool?] {
         let decoded = try JSONDecoder().decode(PostComposition.self, from: Self.legacyPayload(keepLocation: flag))
         #expect(decoded.photos.allSatisfy { !$0.keepLocation })
      }
   }

   @Test func currentPayloadsRoundTripWithoutThePostLevelKey() throws {
      var photo = ComposedPhoto(fileName: "a.jpg", keepLocation: true)
      photo.uploadGeneration = 2
      let composition = PostComposition(body: "new", status: .scheduled, publishAt: .distantFuture, photos: [photo, ComposedPhoto()])
      let data = try JSONEncoder().encode(composition)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["keepLocation"] == nil)
      #expect(try JSONDecoder().decode(PostComposition.self, from: data) == composition)
   }

   @Test func storedItemsReadLegacyPayloads() throws {
      let item = OutboxItem(operation: .create, state: .queued, composition: PostComposition())
      item.payload = try Self.legacyPayload(keepLocation: true)
      #expect(item.composition.photos.allSatisfy { $0.keepLocation })
   }

   @Test func validationCoversEveryServerLimit() {
      let now = Date(timeIntervalSince1970: 10_000)
      let limits = PhotoLimits.fallback
      let long = { (count: Int) in String(repeating: "x", count: count) }
      let cases: [(PostComposition, String?)] = [
         (PostComposition(body: "x", tags: [long(PostFieldLimits.tag + 1)]), "Tags are limited to 40 characters."),
         (PostComposition(body: "x", tags: [long(PostFieldLimits.tag)]), nil),
         (PostComposition(title: long(PostFieldLimits.title + 1), body: "x"), "Titles are limited to 100 characters."),
         (PostComposition(name: long(PostFieldLimits.name + 1), body: "x"), "Names are limited to 40 characters."),
         (PostComposition(shortName: long(PostFieldLimits.shortName + 1), body: "x"), "Short names are limited to 20 characters."),
         (PostComposition(slug: long(PostFieldLimits.slug + 1), body: "x"), "Slugs are limited to 100 characters."),
         (PostComposition(description: long(PostFieldLimits.description + 1), body: "x"), "Descriptions are limited to 255 characters."),
         (PostComposition(metaTitle: long(PostFieldLimits.metaTitle + 1), body: "x"), "SEO titles are limited to 255 characters."),
         (PostComposition(metaDescription: long(PostFieldLimits.metaDescription + 1), body: "x"), "SEO descriptions are limited to 500 characters."),
         (PostComposition(metaKeywords: long(PostFieldLimits.metaKeywords + 1), body: "x"), "SEO keywords are limited to 255 characters."),
         (PostComposition(body: "x", locationLabel: long(PostFieldLimits.locationLabel + 1)), "Places are limited to 200 characters."),
         (PostComposition(body: "x", photos: [ComposedPhoto(altText: long(PostFieldLimits.altText + 1))]), "Alt text is limited to 1000 characters."),
         (PostComposition(body: "x", photos: [ComposedPhoto(caption: long(PostFieldLimits.caption + 1))]), "Captions are limited to 2000 characters."),
         (PostComposition(body: "x", photos: [ComposedPhoto(altText: "a", caption: "c")]), nil),
         (PostComposition(body: "x", linkURL: "https://a.example/" + long(PostFieldLimits.link)), "Links are limited to 2000 characters."),
         (PostComposition(body: "x", linkURL: "httpx://a.example"), "Links must start with http:// or https://"),
         (PostComposition(body: "x", linkURL: "https://"), "Links must start with http:// or https://"),
         (PostComposition(body: "x", linkURL: "not a link"), "Links must start with http:// or https://"),
         (PostComposition(body: "x", linkURL: " HTTP://a.example "), nil),
         (PostComposition(body: "x", linkURL: "  "), nil),
         (PostComposition(body: "x", status: .scheduled), "Pick a time to schedule."),
         (PostComposition(body: "x", status: .scheduled, publishAt: now.addingTimeInterval(30)), "Schedule at least a minute ahead."),
         (
            PostComposition(body: "x", status: .scheduled, publishAt: now.addingTimeInterval(PostComposition.maximumScheduleHorizon + 1)),
            "Schedule at most a year ahead."
         ),
         (PostComposition(body: "x", status: .scheduled, publishAt: now.addingTimeInterval(PostComposition.maximumScheduleHorizon)), nil),
         (PostComposition(), "Write something, add a photo or a link."),
      ]
      for (composition, message) in cases {
         #expect(composition.validationMessage(limits: limits, now: now) == message)
      }
   }

   @Test func photoRulesFromTheServerApplyToPhotosNotYetUploaded() {
      let strict = PhotoLimits(maxPhotoBytes: 1, photoContentTypes: [], photoAltTextRequired: true, photoCaptionRequired: true)
      #expect(PostComposition(body: "x", photos: [ComposedPhoto(fileName: "a")]).validationMessage(limits: strict) == "Every photo needs alt text.")
      #expect(
         PostComposition(body: "x", photos: [ComposedPhoto(fileName: "a", altText: "alt")]).validationMessage(limits: strict)
            == "Every photo needs a caption.")
      #expect(PostComposition(body: "x", photos: [ComposedPhoto(mediaId: 1)]).validationMessage(limits: strict) == nil)
   }

   @Test func storedPayloadsWithoutTheNewFieldsDecodeWithDefaults() throws {
      var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PostComposition(body: "b"))) as? [String: Any])
      for key in ["authorId", "name", "shortName", "slug", "description", "metaTitle", "metaDescription", "metaKeywords", "isFeatured", "featuredPhotoID"] {
         object.removeValue(forKey: key)
      }
      let decoded = try JSONDecoder().decode(PostComposition.self, from: JSONSerialization.data(withJSONObject: object))
      #expect(decoded == PostComposition(body: "b"))
   }
}
