/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// `SiteService` on Site API v2, against the in-process fake.
@Suite struct SiteServiceTests {
   /// Status of a stale edit.
   static let preconditionFailed = 412

   /// A signed-in service over a fresh fake with a controllable clock.
   static func make() async throws -> (SiteService, MockBackend, TestClock) {  // swiftlint:disable:this large_tuple
      ////////////////////////////////////////////////////////////////
      // whole seconds, because the client sends dates without     //
      // fractions.                                                 //
      ////////////////////////////////////////////////////////////////
      let clock = TestClock(Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down)))
      let backend = MockBackend(directory: nil, now: clock.provider)
      let (service, _) = try await makeSignedInService(backend)
      return (service, backend, clock)
   }

   @Test func meListsBlogsAuthorAndLimitsAndTheVersionIsKnown() async throws {
      let (service, _, _) = try await Self.make()
      let caller = try await service.me()
      #expect(caller.canPost)
      #expect(caller.author?.id == Int64(MockBackend.ownerAuthorID))
      #expect(caller.blogs.map(\.slug) == [Post.defaultBlogSlug, "deep-thoughts"])
      #expect(try await service.versions().appVersion == "2.1.0")
      #expect(try await service.authors().map(\.name) == ["Guest Writer", "Mock Author"])
   }

   @Test func createFillsEveryFieldAndPublishes() async throws {
      let (service, _, clock) = try await Self.make()
      let draft = PostComposition(body: "Morning at the lake\n\nHerons everywhere.", tags: ["Birds", "Swift"], linkURL: "https://example.com/herons")
         .draft()
      let post = try await service.createPost(draft)
      #expect(post.status == .published)
      #expect(post.slug == "morning-at-the-lake")
      #expect(post.name == "Morning at the lake")
      #expect(post.metaKeywords == "Birds, Swift")
      #expect(post.tags == ["Birds", "Swift"])
      #expect(post.link?.title == "herons")
      #expect(post.url == "https://www.kof22.com/blogs/quick-bits/morning-at-the-lake")
      #expect(post.publishedAt == clock.now)
      #expect(post.blog == Post.defaultBlogSlug)
      #expect(post.version != APIMapping.unknownVersion)
   }

   @Test func aSecondPostWithTheSameTitleGetsTheNextSlug() async throws {
      let (service, _, _) = try await Self.make()
      let first = try await service.createPost(PostComposition(title: "Trip", body: "one").draft())
      let second = try await service.createPost(PostComposition(title: "Trip", body: "two").draft())
      #expect(first.slug == "trip")
      #expect(second.slug == "trip-2")
   }

   @Test func aRetriedCreateFindsThePostTheFirstAttemptMade() async throws {
      let (service, _, _) = try await Self.make()
      let draft = PostComposition(title: "Once", body: "only once").draft()
      let first = try await service.createPost(draft)
      let again = try await service.createPost(draft)
      #expect(again.id == first.id)
   }

   @Test func aLinkThePreviewCannotReadIsStillSent() async throws {
      let (service, _, _) = try await Self.make()
      let post = try await service.createPost(PostComposition(body: "x", linkURL: "ftp://files.example/a").draft())
      #expect(post.link == PostLink(url: "ftp://files.example/a"))
      #expect(try await service.linkPreview(for: "https://example.com").title == "example.com")
   }

   @Test func scheduledPostsGoLiveWhenTheirTimeComes() async throws {
      let (service, _, clock) = try await Self.make()
      let goLive = clock.now.addingTimeInterval(3_600)
      let post = try await service.createPost(PostComposition(body: "later", status: .scheduled, publishAt: goLive).draft())
      #expect(post.status == .scheduled)
      #expect(post.publishAt == goLive)
      #expect(post.url == nil)
      clock.advance(by: 7_200)
      let live = try await service.post(id: post.id)
      #expect(live.status == .published)
      #expect(live.publishedAt == goLive)
   }

   @Test func updatesReplaceTheStateAndClearEmptiedFields() async throws {
      let (service, _, _) = try await Self.make()
      let post = try await service.createPost(
         PostComposition(title: "Edit me", body: "b", tags: ["Swift"], linkURL: "https://example.com/a", locationLabel: "Here").draft())
      var edit = PostComposition(post: post)
      edit.locationLabel = ""
      edit.slug = "renamed"
      edit.tags = []
      let updated = try await service.updatePost(id: post.id, edit.draft(), ifMatch: post.version)
      #expect(updated.locationLabel == nil)
      #expect(updated.slug == "renamed")
      #expect(updated.tags.isEmpty)
      #expect(updated.link?.title == post.link?.title)
      #expect(updated.publishedAt == post.publishedAt)
      edit.linkURL = ""
      let unlinked = try await service.updatePost(id: post.id, edit.draft(), ifMatch: SiteService.anyVersion)
      #expect(unlinked.link == nil)
   }

   @Test func aStaleEditOrDeleteIsAConflict() async throws {
      let (service, _, clock) = try await Self.make()
      let post = try await service.createPost(PostComposition(body: "v1").draft())
      clock.advance(by: 1)
      var web = PostComposition(post: post)
      web.body = "changed elsewhere"
      _ = try await service.updatePost(id: post.id, web.draft(), ifMatch: post.version)
      let stale = await #expect(throws: APIError.self) { try await service.updatePost(id: post.id, web.draft(), ifMatch: post.version) }
      #expect(stale?.status == Self.preconditionFailed)
      #expect(stale?.code == "precondition_failed")
      let staleDelete = await #expect(throws: APIError.self) { try await service.deletePost(id: post.id, ifMatch: post.version) }
      #expect(staleDelete?.status == Self.preconditionFailed)
      try await service.deletePost(id: post.id, ifMatch: SiteService.anyVersion)
      await #expect(throws: APIError.self) { try await service.post(id: post.id) }
   }

   @Test func deletingWithTheCurrentVersionOrNoneWorks() async throws {
      let (service, _, _) = try await Self.make()
      let first = try await service.createPost(PostComposition(body: "one").draft())
      try await service.deletePost(id: first.id, ifMatch: first.version)
      let second = try await service.createPost(PostComposition(body: "two").draft())
      try await service.deletePost(id: second.id, ifMatch: nil)
      #expect(try await service.myPosts().items.allSatisfy { $0.id != first.id && $0.id != second.id })
   }

   @Test func movingAPostToAnotherBlogKeepsItsSlugUnique() async throws {
      let (service, _, _) = try await Self.make()
      _ = try await service.createPost(PostComposition(blog: "deep-thoughts", title: "Same", body: "a").draft())
      let post = try await service.createPost(PostComposition(title: "Same", body: "b").draft())
      var edit = PostComposition(post: post)
      edit.blog = "deep-thoughts"
      let moved = try await service.updatePost(id: post.id, edit.draft(), ifMatch: post.version)
      #expect(moved.blog == "deep-thoughts")
      #expect(moved.slug == "same-2")
   }

   @Test func anUnknownBlogIsRefusedBeforeSending() async throws {
      let (service, _, _) = try await Self.make()
      let error = await #expect(throws: APIError.self) { try await service.createPost(PostComposition(blog: "nope", body: "x").draft()) }
      #expect(error?.details.first?.field == "blog")
   }

   @Test func tagsAreSuggestedResolvedAndCreated() async throws {
      let (service, _, _) = try await Self.make()
      #expect(try await service.tags(matching: "sw", blog: nil).map(\.name) == ["Swift"])
      #expect(try await service.tags(matching: " ", blog: "deep-thoughts").map(\.name) == ["Apple", "Unix"])
      let ids = try await service.tagIds(["swift", "Brand new", "", "SWIFT"], blogId: 1)
      #expect(ids.count == 2)
      #expect(try await service.tags(matching: "brand", blog: nil).map(\.name) == ["Brand new"])
   }

   @Test func tagNamesAreLookedUpForPostsFromElsewhere() async throws {
      let backend = MockBackend(directory: nil)
      let (service, _) = try await makeSignedInService(backend)
      let page = try await service.myPosts()
      #expect(page.items.allSatisfy { $0.tags.count == 0 })
      let seeded = try #require(page.items.first { $0.status == .published })
      #expect(try await service.post(id: seeded.id).tags == ["Swift"])
      #expect(try await service.tagNames([]).isEmpty == false)
   }

   @Test func anAccountWithoutAnAuthorCannotList() async throws {
      let transport = FixtureTransport(["me": .init(status: 200, body: Data(#"{"canPost":false,"blogs":[]}"#.utf8))])
      let error = await #expect(throws: APIError.self) { try await fixtureService(transport).myPosts() }
      #expect(error?.code == "forbidden")
   }

   @Test func aCreateAnswerWithoutAnIdIsReported() async throws {
      let caller = #"{"canPost":true,"author":{"id":1,"name":"A"},"blogs":[{"id":1,"slug":"quick-bits","name":"Q","isDefault":true}]}"#
      let transport = FixtureTransport([
         "me": .init(status: 200, body: Data(caller.utf8)),
         "queryBlogPost": .init(status: 200, body: Data(#"{"records":[]}"#.utf8)),
         "createBlogPost": .init(status: 201, body: Data("{}".utf8)),
      ])
      let error = await #expect(throws: APIError.self) { try await fixtureService(transport).createPost(PostComposition(body: "x").draft()) }
      #expect(error?.code == "bad_response")
   }

   @Test func uploadsGoThroughTicketPutAndComplete() async throws {
      let (service, _, _) = try await Self.make()
      let file = try KitFiles.makeDirectory().appending(path: "a.jpg")
      try KitFiles.writeImage(to: file)
      let ticket = try await service.createUpload(UploadRequest(fileName: "a.jpg", contentType: "image/jpeg", byteSize: 10))
      try await service.putUpload(fileURL: file, ticket: ticket)
      let media = try await service.completeUpload(id: ticket.uploadId, UploadCompletion(altText: "Alt", caption: nil, keepLocation: true))
      #expect(media.altText == "Alt")
      #expect(media.locationRemoved == false)
      let post = try await service.createPost(
         PostComposition(body: "photo", photos: [ComposedPhoto(mediaId: media.mediaId, caption: "Cap")]).draft())
      #expect(post.media.first?.caption == "Cap")
      #expect(post.media.first?.altText == "Alt")
      #expect(post.featuredMediaId == media.mediaId)
      #expect(post.featuredImage == media.url)
   }
}

/// Converting between records and the app's post.
@Suite struct APIMappingTests {
   @Test func statusFollowsPublishedAndSchedule() {
      #expect(APIMapping.status(isPublished: true, scheduledPublishAt: .now) == .published)
      #expect(APIMapping.status(isPublished: false, scheduledPublishAt: .now) == .scheduled)
      #expect(APIMapping.status(isPublished: nil, scheduledPublishAt: nil) == .draft)
      #expect(APIMapping.version(of: nil) == APIMapping.unknownVersion)
   }

   @Test func incompleteRecordsMapToSafeDefaults() {
      let post = APIMapping.post(BlogPostRecord(), blogSlugs: [:], tagNames: [:])
      #expect(post.id == 0)
      #expect(post.blog.isEmpty)
      #expect(post.status == .draft)
      #expect(post.link == nil)
      #expect(APIMapping.photo(BlogPostMediaRecord(mediaId: 1)) == nil)
      #expect(post.media.first?.id == nil)
   }

   @Test func photosAreSortedAndIdentifiedByMedia() {
      var record = BlogPostRecord()
      record.media = [
         BlogPostMediaRecord(id: 2, mediaId: 20, sortOrder: 1, url: "b"), BlogPostMediaRecord(id: 1, mediaId: 10, sortOrder: 0, url: "a"),
      ]
      let post = APIMapping.post(record, blogSlugs: [:], tagNames: [:])
      #expect(post.media.map(\.id) == [10, 20])
   }

   @Test func longLinkDetailsAreClippedAndOversizedImagesDropped() {
      let draft = PostComposition(body: "b", linkURL: "https://x.example").draft()
      let link = LinkPreview(
         url: "https://x.example", title: String(repeating: "t", count: 400), description: String(repeating: "d", count: 1_200),
         imageUrl: String(repeating: "i", count: PostFieldLimits.link + 1))
      let record = APIMapping.record(draft, .init(blogId: 1, authorId: 1, slug: "s", tagIds: [], link: link, publishDate: nil))
      #expect((record.linkTitle?.count ?? 0) <= APIMapping.linkTitleLength)
      #expect((record.linkDescription?.count ?? 0) <= APIMapping.linkDescriptionLength)
      #expect(record.linkImageUrl == nil)
      #expect(APIMapping.clearedFields(record) == ["locationLabel", "featuredMediaId", "scheduledPublishAt"])
   }
}
