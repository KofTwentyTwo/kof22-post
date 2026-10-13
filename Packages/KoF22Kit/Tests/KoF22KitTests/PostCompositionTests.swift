/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// What the composer produces and how it resolves into the values a post is sent with.
@Suite struct PostCompositionTests {
   /// A server post with a link, a location and one photo.
   static let serverPost = Post(
      id: 4, blogId: 2, blog: "deep-thoughts", authorId: 3, status: .scheduled, title: "Title", name: "Name", shortName: "Short",
      slug: "title", body: "Body", description: "Desc", metaTitle: "MT", metaDescription: "MD", metaKeywords: "a, b", isFeatured: true,
      featuredMediaId: 9, publishAt: Date(timeIntervalSince1970: 5_000), tags: ["Swift"], locationLabel: "Lisbon",
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
      #expect(composition.authorId == 3)
      #expect(composition.name == "Name")
      #expect(composition.shortName == "Short")
      #expect(composition.description == "Desc")
      #expect(composition.metaKeywords == "a, b")
      #expect(composition.isFeatured)
      #expect(composition.featuredPhotoID == composition.photos.last?.id)
      #expect(composition.featuredPhoto?.mediaId == 9)
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

   @Test func aBareDraftFillsEveryDetailByRule() {
      let body = "# Morning at the lake\nThe *water* was still and the [herons](https://x.example) were out early."
      let draft = PostComposition(body: body, tags: ["Birds", "birds", "Lake"]).draft()
      #expect(draft.title == "Morning at the lake")
      #expect(draft.name == "Morning at the lake")
      #expect(draft.shortName == "Morning at the lake")
      #expect(draft.slug == "morning-at-the-lake")
      #expect(draft.description.hasPrefix("Morning at the lake The water was still and the herons"))
      #expect(draft.metaTitle == "Morning at the lake")
      #expect(draft.metaDescription == draft.description)
      #expect(draft.metaKeywords == "Birds, Lake")
      #expect(draft.readTime == 1)
      #expect(draft.excerpt == draft.description)
      #expect(draft.status == .published)
      #expect(draft.publishAt == nil)
      #expect(draft.linkURL == nil)
      #expect(draft.locationLabel == nil)
      #expect(draft.featuredMediaId == nil)
   }

   @Test func typedDetailsWinAndAreClipped() {
      let long = String(repeating: "word ", count: 120)
      let draft = PostComposition(
         authorId: 2, title: " Title ", name: long, shortName: long, slug: "Hello Wörld!", description: long, metaTitle: "SEO",
         metaDescription: "Meta", metaKeywords: "x, y , x", body: "b", linkURL: " https://a.example ", locationLabel: " Here ",
         status: .scheduled, publishAt: .distantFuture, isFeatured: true
      ).draft()
      #expect(draft.authorId == 2)
      #expect(draft.title == "Title")
      #expect(draft.name.count <= PostFieldLimits.name)
      #expect(draft.shortName.count <= PostFieldLimits.shortName)
      #expect(draft.slug == "hello-world")
      #expect(draft.description.count <= PostFieldLimits.description)
      #expect(draft.metaTitle == "SEO")
      #expect(draft.metaDescription == "Meta")
      #expect(draft.metaKeywords == "x, y")
      #expect(draft.linkURL == "https://a.example")
      #expect(draft.locationLabel == "Here")
      #expect(draft.publishAt == .distantFuture)
      #expect(draft.isFeatured)
   }

   @Test func aTitleWithoutLettersStillGetsASlug() {
      #expect(PostComposition(title: "!!!", body: "b").draft().slug == "field-note")
   }

   @Test func uploadedPhotosAttachInOrderAndTheFeaturedOneIsChosen() {
      let first = ComposedPhoto(mediaId: 3, altText: " ", caption: "Cap")
      let local = ComposedPhoto(fileName: "local.jpg")
      let second = ComposedPhoto(mediaId: 4, altText: "Alt")
      var composition = PostComposition(photos: [first, local, second])
      #expect(composition.bodyForServer == "📷")
      var draft = composition.draft()
      #expect(draft.media == [.init(mediaId: 3, altText: nil, caption: "Cap"), .init(mediaId: 4, altText: "Alt", caption: nil)])
      #expect(draft.featuredMediaId == 3)
      composition.featuredPhotoID = second.id
      draft = composition.draft()
      #expect(draft.featuredMediaId == 4)
      composition.featuredPhotoID = local.id
      #expect(composition.draft().featuredMediaId == nil)
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
