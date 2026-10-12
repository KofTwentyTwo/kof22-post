/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// Decodes recorded live responses and spec examples through the generated client, the
/// same path the app uses, without touching the network.
@Suite struct ContractFixtureTests {
   let serverURL = URL(literal: "https://api.kof22.com")

   func reads(_ replies: [String: FixtureTransport.Reply]) -> PublicReadService {
      PublicReadService(serverURL: serverURL, transport: FixtureTransport(replies))
   }

   func authoring(_ replies: [String: FixtureTransport.Reply]) -> SiteService {
      SiteService(
         serverURL: serverURL, transport: FixtureTransport(replies), auth: StubAuthSession(signedIn: true),
         uploader: URLSessionUploadPerformer())
   }

   @Test func recordedVersionsDecode() async throws {
      let versions = try await authoring(["getApiVersions": try .okay("versions")]).versions()
      #expect(versions.currentVersion == "v1")
      #expect(versions.versions.first?.semver == "1.1.0")
   }

   @Test func recordedBlogQueryDecodesWithMicrosecondDates() async throws {
      let blogs = try await reads(["queryBlog": try .okay("blog-query")]).blogs()
      #expect(blogs.map(\.slug) == ["ideas-into-systems", "quick-bits"])
      #expect(blogs.allSatisfy { $0.modifyDate != nil })
   }

   @Test func recordedPostQueryDecodesRecordsAndPaging() async throws {
      let page = try await reads(["queryPost": try .okay("post-query")]).posts(blogId: 2, pageSize: 3)
      #expect(page.records.count == 3)
      #expect(page.count == 3)
      #expect(page.pageNo == 1)
      #expect(page.pageSize == 3)
      #expect(!page.hasMore)
      let first = try #require(page.records.first)
      #expect(first.title?.isEmpty == false)
      #expect(first.publishDate != nil)
      #expect(first.tags?.isEmpty == false)
   }

   @Test func recordedPostDecodes() async throws {
      let post = try await reads(["getPost": try .okay("post-1")]).post(id: 1)
      #expect(post.id == 1)
      #expect(post.content?.isEmpty == false)
      #expect(post.media != nil)
   }

   @Test func recordedTagQueryDecodes() async throws {
      let tags = try await reads(["queryTag": try .okay("tag-query")]).tags(blogId: 2)
      #expect(tags.count == 5)
      #expect(tags.allSatisfy { $0.blogId == 2 && $0.slug != nil })
   }

   @Test func recordedNotFoundIsATypedError() async throws {
      let service = reads(["getPost": .init(status: 404, body: try Fixture.data("error-not-found"))])
      let error = await #expect(throws: APIError.self) { try await service.post(id: 999_999) }
      #expect(error?.code == "not_found")
      #expect(error.map(ErrorClassifier.userMessage(for:)) == "Not found. It may have been deleted.")
   }

   @Test func unknownFieldsInRecordsAreIgnored() async throws {
      let body = try Fixture.injecting("futureField", into: "blog-query", records: true)
      let blogs = try await reads(["queryBlog": .init(status: 200, body: body)]).blogs()
      #expect(blogs.count == 2)
   }

   @Test func unknownTopLevelFieldsAreIgnored() async throws {
      let body = try Fixture.injecting("futureField", into: "post-query")
      let page = try await reads(["queryPost": .init(status: 200, body: body)]).posts(blogId: 2)
      #expect(page.records.count == 3)
   }

   @Test func meExampleWithAnUnknownFieldDecodes() async throws {
      let account = try await authoring(["getMe": try .okay("me")]).me()
      #expect(account.canPost)
      #expect(account.blogs.count == 2)
      #expect(account.limits.maxTitleLength == 100)
   }

   @Test func authoringPostAndPageExamplesDecode() async throws {
      let service = authoring(["getMyPost": try .okay("authoring-post"), "listMyPosts": try .okay("post-page")])
      let post = try await service.post(id: 42)
      #expect(post.status == .published)
      #expect(post.link?.title == "Sensor notes")
      #expect(post.media.first?.mediaId == 7)
      let page = try await service.myPosts()
      #expect(page.items.map(\.status) == [.published, .scheduled])
      #expect(page.nextCursor == "MjA=")
   }

   @Test func uploadExamplesDecode() async throws {
      let service = authoring(["createUpload": .init(status: 201, body: try Fixture.data("upload-ticket")), "completeUpload": try .okay("media-item")])
      let ticket = try await service.createUpload(
         UploadCreate(fileName: "a.jpg", contentType: .imageJpeg, byteSize: 10), idempotencyKey: "fixture-upload-one")
      #expect(ticket.headers.additionalProperties["Content-Type"] == "image/jpeg")
      let media = try await service.completeUpload(id: ticket.uploadId, UploadComplete())
      #expect(media.locationRemoved)
      #expect(media.mimeType == "image/jpeg")
   }

   @Test func validationEnvelopeBecomesAFieldMessage() async throws {
      let service = authoring(["getMe": .init(status: 422, body: try Fixture.data("error-validation"))])
      let error = await #expect(throws: APIError.self) { try await service.me() }
      #expect(error?.details == [APIError.Detail(field: "title", issue: "max 100 characters")])
      #expect(error.map(ErrorClassifier.userMessage(for:)) == "Please fix: title max 100 characters")
   }

   @Test func recordedFixturesCarryNoEmailAddresses() throws {
      for name in ["versions", "blog-query", "post-query", "tag-query", "post-1", "error-not-found"] {
         let text = try #require(String(bytes: try Fixture.data(name), encoding: .utf8))
         #expect(text.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) == nil, "\(name)")
      }
   }
}

@Suite struct SiteDateTranscoderTests {
   let transcoder = SiteDateTranscoder()

   @Test func readsWholeAndFractionalSeconds() throws {
      let whole = try transcoder.decode("2026-10-11T12:16:04Z")
      let micro = try transcoder.decode("2026-10-11T12:16:04.144433Z")
      #expect(micro.timeIntervalSince(whole) > 0.14)
      #expect(micro.timeIntervalSince(whole) < 0.15)
   }

   @Test func writesWholeSeconds() throws {
      #expect(try transcoder.encode(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
   }

   @Test func rejectsTextThatIsNotADate() {
      #expect(throws: (any Error).self) { try transcoder.decode("yesterday") }
   }
}
