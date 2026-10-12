/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// What the composer produces and how it maps onto the API's create and update bodies.
@Suite struct PostCompositionTests {
   /// A server post with a link, a location and one photo.
   static let serverPost = Post(
      id: 4, blogId: 2, blog: "deep-thoughts", status: .scheduled, title: "Title", body: "Body", slug: "title",
      publishAt: Date(timeIntervalSince1970: 5_000), tags: ["Swift"], locationLabel: "Lisbon",
      link: PostLink(url: "https://example.com", title: nil, description: nil, imageUrl: nil),
      media: [
         PostPhoto(mediaId: 8, url: "https://cdn/8.jpg", thumbnailUrl: nil, altText: "Alt", caption: nil),
         PostPhoto(mediaId: 9, url: "https://cdn/9.jpg", thumbnailUrl: "https://cdn/9-thumb.jpg", altText: nil, caption: "Cap"),
      ],
      version: "v")

   @Test func editingStartsFromTheServerCopy() {
      let composition = PostComposition(post: Self.serverPost)
      #expect(composition.blog == "deep-thoughts")
      #expect(composition.linkURL == "https://example.com")
      #expect(composition.locationLabel == "Lisbon")
      #expect(composition.originalHadLink)
      #expect(composition.photos.first?.remoteURL == "https://cdn/8.jpg")
      #expect(composition.photos.first?.altText == "Alt")
      #expect(composition.photos.first?.isUploaded == true)
      #expect(composition.photos.last?.remoteURL == "https://cdn/9-thumb.jpg")
      #expect(composition.photos.last?.altText == "")
      #expect(composition.photos.last?.caption == "Cap")
   }

   @Test func summaryPrefersTheTitleThenTheBody() {
      #expect(PostComposition(title: " Trip ", body: "Day one").summary == "Trip")
      #expect(PostComposition(body: "Day one\nmore").summary == "Day one")
      #expect(PostComposition().summary == "Field note")
      #expect(PostComposition(photos: [ComposedPhoto(), ComposedPhoto()]).summary == "2 photo post")
   }

   @Test func theServerAlwaysGetsABody() {
      #expect(PostComposition(body: "text").bodyForServer == "text")
      #expect(PostComposition(linkURL: "https://a.example").bodyForServer == "https://a.example")
      #expect(PostComposition(body: " ").bodyForServer == " ")
      #expect(PostComposition(linkURL: "https://a.example").isEmpty == false)
   }

   @Test func validationNamesTheFirstProblem() {
      let now = Date(timeIntervalSince1970: 10_000)
      let limits = AuthoringLimits.fallback
      let tooMany = (0...limits.maxTags).map { "t\($0)" }
      let photos = (0...limits.maxPhotosPerPost).map { _ in ComposedPhoto() }
      let cases: [(PostComposition, String?)] = [
         (PostComposition(body: String(repeating: "b", count: limits.maxBodyLength + 1)), "Posts are limited to 10000 characters."),
         (PostComposition(title: String(repeating: "t", count: limits.maxTitleLength + 1), body: "x"), "Titles are limited to 100 characters."),
         (PostComposition(body: "x", tags: tooMany), "At most 10 tags."),
         (PostComposition(photos: photos), "At most 20 photos per post."),
         (PostComposition(body: "x", status: .scheduled, publishAt: now.addingTimeInterval(30)), "Schedule at least a minute ahead."),
         (PostComposition(body: "x", status: .scheduled, publishAt: now.addingTimeInterval(120)), nil),
         (PostComposition(body: "x", linkURL: "https://ok.example"), nil),
      ]
      for (composition, message) in cases {
         #expect(composition.validationMessage(limits: limits, now: now) == message)
      }
   }

   @Test func createBodyOmitsBlanksAndUnscheduledTimes() {
      let photos = [ComposedPhoto(mediaId: 3, altText: " ", caption: "Cap"), ComposedPhoto(fileName: "local.jpg")]
      let published = PostComposition(
         title: " ", body: "b", locationLabel: "", publishAt: .distantFuture, photos: photos
      ).createBody()
      #expect(published.title == nil)
      #expect(published.locationLabel == nil)
      #expect(published.publishAt == nil)
      #expect(published.media == [MediaAttachment(mediaId: 3, altText: nil, caption: "Cap")])
      let scheduled = PostComposition(body: "b", status: .scheduled, publishAt: .distantFuture).createBody()
      #expect(scheduled.publishAt == .distantFuture)
   }

   @Test func updateBodySendsTheFullTrimmedState() {
      let (update, clearLink) = PostComposition(
         title: " T ", body: "b", linkURL: "https://x.example", locationLabel: " Porto ", status: .scheduled,
         publishAt: .distantFuture
      ).updateBody()
      #expect(update.title == "T")
      #expect(update.locationLabel == "Porto")
      #expect(update.linkUrl == "https://x.example")
      #expect(update.publishAt == .distantFuture)
      #expect(!clearLink)
   }

   @Test func attachingMediaPrefersTheThumbnail() {
      var photo = ComposedPhoto(fileName: "a.jpg")
      photo.attach(MediaItem(mediaId: 5, url: "https://cdn/5.jpg", mimeType: "image/jpeg", locationRemoved: true))
      #expect(photo.mediaId == 5)
      #expect(photo.remoteURL == "https://cdn/5.jpg")
      photo.attach(MediaItem(mediaId: 6, url: "https://cdn/6.jpg", thumbnailUrl: "https://cdn/6-t.jpg", mimeType: "image/jpeg", locationRemoved: true))
      #expect(photo.remoteURL == "https://cdn/6-t.jpg")
   }

   @Test func photosKnowWhereTheirFileIs() {
      let directory = URL(filePath: "/tmp/photos")
      #expect(ComposedPhoto(fileName: "a.jpg").localURL(in: directory)?.lastPathComponent == "a.jpg")
      #expect(ComposedPhoto(mediaId: 1).localURL(in: directory) == nil)
      #expect(" x ".nilIfBlank == "x")
      #expect("  ".nilIfBlank == nil)
   }
}
