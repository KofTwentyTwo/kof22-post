/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import KoF22Kit

/// Tests for photo preparation: location stripping, HEIC conversion, resizing and orientation.
@Suite struct MediaProcessorTests {
   /// GPS is removed when location is off and kept when it is on.
   @Test func removesGPSFromJPEGWithoutLosingIt() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.jpg")
      try TestImages.write(to: source, gps: true)
      #expect(MediaProcessor.hasGPS(source))

      let stripped = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg", "image/png"],
         maxBytes: 1 << 24, workDirectory: directory.appending(path: "out"))
      #expect(stripped.contentType == "image/jpeg")
      #expect(!MediaProcessor.hasGPS(stripped.fileURL))

      let kept = try MediaProcessor.prepare(
         source: source, keepLocation: true, acceptedTypes: ["image/jpeg"],
         maxBytes: 1 << 24, workDirectory: directory.appending(path: "out"))
      #expect(MediaProcessor.hasGPS(kept.fileURL))
   }

   /// HEIC is converted to JPEG (without GPS) when the server does not accept HEIC.
   @Test func convertsHEICToJPEGWhenServerRefusesHEIC() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.heic")
      try TestImages.write(to: source, type: .heic, gps: true)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg", "image/png"],
         maxBytes: 1 << 24, workDirectory: directory)
      #expect(prepared.contentType == "image/jpeg")
      #expect(prepared.fileURL.pathExtension == "jpg")
      #expect(!MediaProcessor.hasGPS(prepared.fileURL))
   }

   /// A photo larger than the byte limit is shrunk to fit it.
   @Test func shrinksPhotosOverTheByteLimit() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "big.png")
      try TestImages.write(to: source, type: .png, width: 3000, height: 2000, gps: false)
      let original = try MediaProcessor.fileSize(source)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/png", "image/jpeg"],
         maxBytes: max(original / 4, 20_000), workDirectory: directory)
      #expect(prepared.byteSize <= max(original / 4, 20_000))
   }
}

/// Tests for the composer's post model: bodies, link clearing, validation and titles.
@Suite struct CompositionTests {
   /// A photo-only post gets a minimal body and a photo summary.
   @Test func photoOnlyPostGetsAMinimalBody() {
      let composition = PostComposition(photos: [ComposedPhoto(fileName: "a.jpg")])
      #expect(composition.bodyForServer == "📷")
      #expect(composition.summary == "1 photo post")
   }

   /// Removing a link leaves the draft without one, which the update then clears.
   @Test func removingAnExistingLinkClearsItOnUpdate() {
      var composition = PostComposition(body: "x", linkURL: "https://a.example", originalHadLink: true)
      #expect(composition.draft().linkURL == "https://a.example")
      composition.linkURL = ""
      #expect(composition.draft().linkURL == nil)
   }

   /// Empty posts, scheduling without a time and non-web links are rejected; a plain body passes.
   @Test func validation() {
      #expect(PostComposition().validationMessage(limits: .fallback) != nil)
      #expect(PostComposition(body: "ok").validationMessage(limits: .fallback) == nil)
      #expect(PostComposition(body: "ok", status: .scheduled).validationMessage(limits: .fallback) == "Pick a time to schedule.")
      #expect(PostComposition(body: "ok", linkURL: "ftp://x").validationMessage(limits: .fallback) != nil)
   }

   /// Title derivation and slugs follow the backend's rules.
   @Test func titleDerivationMatchesBackendRules() {
      #expect(PostText.deriveTitle("\n\n# A [link](https://x) and `code`\nrest") == "A link and code")
      #expect(PostText.deriveTitle("   ") == "Field note")
      #expect(PostText.slugify("Héllo, Wörld!") == "hello-world")
   }
}

/// End-to-end outbox tests against the mock backend and an in-memory store.
@Suite(.serialized) struct OutboxTests {
   /// Everything one outbox test needs, wired together.
   struct Fixture {
      /// In-memory SwiftData container.
      let container: ModelContainer
      /// The outbox store under test.
      let store: OutboxStore
      /// The mock backend the service talks to.
      let backend: MockBackend
      /// Service bound to `backend` with a signed-in mock session.
      let service: SiteService
      /// The processor that sends queued items.
      let processor: OutboxProcessor
      /// Directory holding the queued photos.
      let photos: URL
      /// Records the notifications the processor posts.
      let notifier: RecordingNotifier
   }

   /// Notifier that records each event as `posted:<summary>` or `failed:<summary>`.
   final class RecordingNotifier: OutboxNotifier, @unchecked Sendable {
      /// Guards `events`.
      let lock = NSLock()
      /// The recorded events, in order.
      var events: [String] = []

      /// Records a successful post.
      func posted(summary: String, status: PostStatus, url: String?) async { lock.withLock { events.append("posted:\(summary)") } }

      /// Records a failed post.
      func failed(summary: String, message: String) async { lock.withLock { events.append("failed:\(summary)") } }
   }

   /// Builds a fresh store, mock backend, service and processor in a temporary directory.
   func makeFixture() async throws -> Fixture {
      let container = try PersistenceStack.makeContainer(inMemory: true)
      let store = OutboxStore(modelContainer: container)
      let directory = TestImages.temporaryDirectory()
      let backend = MockBackend(directory: directory.appending(path: "mock"))
      let (service, _, _) = try await makeMockService(backend: backend)
      let notifier = RecordingNotifier()
      let photos = directory.appending(path: "Outbox Photos")
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let processor = OutboxProcessor(store: store, service: { service }, notifier: notifier, photosDirectory: photos)
      return Fixture(
         container: container, store: store, backend: backend, service: service, processor: processor,
         photos: photos, notifier: notifier)
   }

   /// A post with photos is sent with alt text, without GPS, and its local copies are removed.
   @Test func sendsAPostWithPhotosAndStripsLocation() async throws {
      let fixture = try await makeFixture()
      try TestImages.write(to: fixture.photos.appending(path: "p1.heic"), type: .heic, gps: true)
      try TestImages.write(to: fixture.photos.appending(path: "p2.jpg"), gps: true)
      let composition = PostComposition(
         body: "Sunset", tags: ["Photo"],
         photos: [ComposedPhoto(fileName: "p1.heic", altText: "Orange sky"), ComposedPhoto(fileName: "p2.jpg")]
      )
      let id = try await fixture.store.enqueue(composition, operation: .create)
      await fixture.processor.drain()

      let item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .sent)
      let post = try await fixture.service.post(id: try #require(item.serverPostID))
      #expect(post.media.count == 2)
      #expect(post.media.first?.altText == "Orange sky")
      let first = try #require(URL(string: post.media[0].url))
      #expect(!MediaProcessor.hasGPS(first))
      ///////////////////////////////////////////////////////////
      // Local copies are removed once the post is accepted.   //
      ///////////////////////////////////////////////////////////
      #expect(!FileManager.default.fileExists(atPath: fixture.photos.appending(path: "p1.heic").path(percentEncoded: false)))
      #expect(fixture.notifier.events == ["posted:Sunset"])
      #expect(try await fixture.store.cachedPosts().map(\.id) == [post.id])
   }

   /// Offline sends stay queued with a backoff, and succeed after a retry once back online.
   @Test func offlineQueuesWithBackoffThenSucceeds() async throws {
      let fixture = try await makeFixture()
      await fixture.backend.setSimulateOffline(true)
      let id = try await fixture.store.enqueue(PostComposition(body: "later"), operation: .create)
      await fixture.processor.drain()
      var item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .queued)
      #expect(item.attempts == 1)
      #expect(item.nextAttemptAt != nil)
      #expect(try await fixture.store.due().isEmpty)

      await fixture.backend.setSimulateOffline(false)
      try await fixture.store.retry(id)
      await fixture.processor.drain()
      item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .sent)
   }

   /// Retrying after the server accepted a create (but the app lost the reply) does not post twice.
   @Test func retryAfterLostResponseDoesNotDoublePost() async throws {
      let fixture = try await makeFixture()
      let id = try await fixture.store.enqueue(PostComposition(body: "exactly once"), operation: .create)
      ////////////////////////////////////////////////////////////////////
      // Simulate: the server accepted the create but the app died      //
      // before recording it.                                           //
      ////////////////////////////////////////////////////////////////////
      _ = try await fixture.service.createPost(PostComposition(body: "exactly once").draft())
      await fixture.processor.drain()
      #expect(try await fixture.store.snapshot(id)?.state == .sent)
      let page = try await fixture.service.myPosts(limit: 50)
      #expect(page.items.filter { $0.body == "exactly once" }.count == 1)
   }

   /// A validation error marks the item failed, keeps the message and notifies once.
   @Test func validationFailureStopsAndNotifies() async throws {
      let fixture = try await makeFixture()
      let id = try await fixture.store.enqueue(PostComposition(blog: "nope", body: "x"), operation: .create)
      await fixture.processor.drain()
      let item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .failed)
      #expect(item.lastError?.contains("blog") == true)
      #expect(fixture.notifier.events.count == 1)
   }

   /// An edit based on a stale version becomes a conflict, and overwrite sends it anyway.
   @Test func staleEditBecomesConflictAndOverwriteResolvesIt() async throws {
      let fixture = try await makeFixture()
      let original = try await fixture.service.createPost(PostComposition(body: "v1").draft())
      var web = PostComposition(post: original)
      web.body = "changed on web"
      _ = try await fixture.service.updatePost(id: original.id, web.draft(), ifMatch: original.version)

      var edit = PostComposition(post: original)
      edit.body = "v2 from phone"
      let id = try await fixture.store.enqueue(edit, operation: .update, serverPostID: original.id, ifMatch: original.version)
      await fixture.processor.drain()
      var item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .failed)
      #expect(item.isConflict)

      await fixture.processor.overwrite(id)
      item = try #require(try await fixture.store.snapshot(id))
      #expect(item.state == .sent)
      #expect(try await fixture.service.post(id: original.id).body == "v2 from phone")
   }

   /// The retry backoff grows with each attempt and caps at 15 minutes.
   @Test func backoffGrowsAndCaps() {
      #expect(OutboxProcessor.backoff(attempt: 1) == 5)
      #expect(OutboxProcessor.backoff(attempt: 3) == 20)
      #expect(OutboxProcessor.backoff(attempt: 20) == 900)
   }
}

extension OutboxTests {
   /// "Send now" retries everything immediately, ignoring the backoff.
   @Test func sendNowIgnoresBackoff() async throws {
      let fixture = try await makeFixture()
      await fixture.backend.setSimulateOffline(true)
      let id = try await fixture.store.enqueue(PostComposition(body: "now"), operation: .create)
      await fixture.processor.drain()
      await fixture.backend.setSimulateOffline(false)
      #expect(try await fixture.store.due().isEmpty)
      try await fixture.store.retryAll()
      await fixture.processor.drain()
      #expect(try await fixture.store.snapshot(id)?.state == .sent)
   }
}

extension OutboxTests {
   /// A second drain started during a run waits for it instead of returning early.
   @Test func concurrentDrainWaitsForTheRunInProgress() async throws {
      let fixture = try await makeFixture()
      let id = try await fixture.store.enqueue(PostComposition(body: "wait for me"), operation: .create)
      async let first: Void = fixture.processor.drain()
      async let second: Void = fixture.processor.drain()
      _ = await (first, second)
      #expect(try await fixture.store.snapshot(id)?.state == .sent)
   }

   /// An item deleted after it was listed as due is not sent.
   @Test func deletedItemIsNotSent() async throws {
      let fixture = try await makeFixture()
      let id = try await fixture.store.enqueue(PostComposition(body: "never mind"), operation: .create)
      let listed = try await fixture.store.due()
      try await fixture.store.delete(id)
      await fixture.processor.process(listed[0], service: fixture.service)
      #expect(try await fixture.service.myPosts(limit: 50).items.allSatisfy { $0.body != "never mind" })
   }

   /// Draft autosave and discard never change an item that has already been queued.
   @Test func draftHelpersNeverTouchQueuedItems() async throws {
      let fixture = try await makeFixture()
      let draft = try await fixture.store.saveLocalDraft(PostComposition(body: "draft"), id: nil)
      try await fixture.store.enqueue(PostComposition(body: "final"), operation: .create, replacing: draft)
      ////////////////////////////////////////////////////////////////////
      // Stale composer autosave and discard after the draft was        //
      // posted elsewhere.                                              //
      ////////////////////////////////////////////////////////////////////
      let other = try await fixture.store.saveLocalDraft(PostComposition(body: "stale edit"), id: draft)
      #expect(other != draft)
      try await fixture.store.deleteDraft(draft)
      let item = try #require(try await fixture.store.snapshot(draft))
      #expect(item.composition.body == "final")
      #expect(item.state == .queued)
   }

   /// A second queued edit of the same post uses the version produced by the first.
   @Test func secondQueuedEditUsesTheVersionFromTheFirst() async throws {
      let fixture = try await makeFixture()
      let post = try await fixture.service.createPost(PostComposition(body: "v1").draft())
      var firstEdit = PostComposition(post: post)
      firstEdit.body = "v2"
      var secondEdit = PostComposition(post: post)
      secondEdit.body = "v3"
      try await fixture.store.enqueue(firstEdit, operation: .update, serverPostID: post.id, ifMatch: post.version)
      let second = try await fixture.store.enqueue(secondEdit, operation: .update, serverPostID: post.id, ifMatch: post.version)
      await fixture.processor.drain()
      #expect(try await fixture.store.snapshot(second)?.state == .sent)
      #expect(try await fixture.service.post(id: post.id).body == "v3")
   }
}

extension MediaProcessorTests {
   /// Stripping GPS keeps the EXIF orientation of the photo.
   @Test func strippingGPSKeepsOrientation() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "rotated.jpg")
      try TestImages.write(to: source, gps: true, orientation: 6)
      let output = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg"],
         maxBytes: 1 << 24, workDirectory: directory.appending(path: "out"))
      let image = try #require(CGImageSourceCreateWithURL(output.fileURL as CFURL, nil))
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
      #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
      #expect(!MediaProcessor.hasGPS(output.fileURL))
   }
}
