import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import KoF22Kit

@Suite struct MediaProcessorTests {
   @Test func removesGPSFromJPEGWithoutLosingIt() throws {
      let dir = TestImages.temporaryDirectory()
      let source = dir.appending(path: "in.jpg")
      try TestImages.write(to: source, gps: true)
      #expect(MediaProcessor.hasGPS(source))

      let stripped = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg", "image/png"],
         maxBytes: 1 << 24, workDirectory: dir.appending(path: "out"))
      #expect(stripped.contentType == .imageJpeg)
      #expect(!MediaProcessor.hasGPS(stripped.fileURL))

      let kept = try MediaProcessor.prepare(
         source: source, keepLocation: true, acceptedTypes: ["image/jpeg"],
         maxBytes: 1 << 24, workDirectory: dir.appending(path: "out"))
      #expect(MediaProcessor.hasGPS(kept.fileURL))
   }

   @Test func convertsHEICToJPEGWhenServerRefusesHEIC() throws {
      let dir = TestImages.temporaryDirectory()
      let source = dir.appending(path: "in.heic")
      try TestImages.write(to: source, type: .heic, gps: true)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg", "image/png"],
         maxBytes: 1 << 24, workDirectory: dir)
      #expect(prepared.contentType == .imageJpeg)
      #expect(prepared.fileURL.pathExtension == "jpg")
      #expect(!MediaProcessor.hasGPS(prepared.fileURL))
   }

   @Test func shrinksPhotosOverTheByteLimit() throws {
      let dir = TestImages.temporaryDirectory()
      let source = dir.appending(path: "big.png")
      try TestImages.write(to: source, type: .png, width: 3000, height: 2000, gps: false)
      let original = try MediaProcessor.fileSize(source)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/png", "image/jpeg"],
         maxBytes: max(original / 4, 20_000), workDirectory: dir)
      #expect(prepared.byteSize <= max(original / 4, 20_000))
   }
}

@Suite struct CompositionTests {
   @Test func photoOnlyPostGetsAMinimalBody() {
      let composition = PostComposition(photos: [ComposedPhoto(fileName: "a.jpg")])
      #expect(composition.bodyForServer == "📷")
      #expect(composition.summary == "1 photo post")
   }

   @Test func removingAnExistingLinkClearsItOnUpdate() {
      var composition = PostComposition(body: "x", linkURL: "https://a.example", originalHadLink: true)
      #expect(composition.updateBody().clearLink == false)
      composition.linkURL = ""
      #expect(composition.updateBody().clearLink == true)
   }

   @Test func validation() {
      #expect(PostComposition().validationMessage(limits: .fallback) != nil)
      #expect(PostComposition(body: "ok").validationMessage(limits: .fallback) == nil)
      #expect(PostComposition(body: "ok", status: .scheduled).validationMessage(limits: .fallback) == "Pick a time to schedule.")
      #expect(PostComposition(body: "ok", linkURL: "ftp://x").validationMessage(limits: .fallback) != nil)
   }

   @Test func titleDerivationMatchesBackendRules() {
      #expect(MockBackend.deriveTitle("\n\n# A [link](https://x) and `code`\nrest") == "A link and code")
      #expect(MockBackend.deriveTitle("   ") == "Field note")
      #expect(MockBackend.slugify("Héllo, Wörld!") == "hello-world")
   }
}

@Suite(.serialized) struct OutboxTests {
   struct Fixture {
      let container: ModelContainer
      let store: OutboxStore
      let backend: MockBackend
      let service: SiteService
      let processor: OutboxProcessor
      let photos: URL
      let notifier: RecordingNotifier
   }

   final class RecordingNotifier: OutboxNotifier, @unchecked Sendable {
      let lock = NSLock()
      var events: [String] = []
      func posted(summary: String, status: PostStatus, url: String?) async { lock.withLock { events.append("posted:\(summary)") } }
      func failed(summary: String, message: String) async { lock.withLock { events.append("failed:\(summary)") } }
   }

   func makeFixture() async throws -> Fixture {
      let container = try PersistenceStack.makeContainer(inMemory: true)
      let store = OutboxStore(modelContainer: container)
      let dir = TestImages.temporaryDirectory()
      let backend = MockBackend(directory: dir.appending(path: "mock"))
      let (service, _, _) = try await makeMockService(backend: backend)
      let notifier = RecordingNotifier()
      let photos = dir.appending(path: "Outbox Photos")
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let processor = OutboxProcessor(store: store, service: { service }, notifier: notifier, photosDirectory: photos)
      return Fixture(
         container: container, store: store, backend: backend, service: service, processor: processor,
         photos: photos, notifier: notifier)
   }

   @Test func sendsAPostWithPhotosAndStripsLocation() async throws {
      let f = try await makeFixture()
      try TestImages.write(to: f.photos.appending(path: "p1.heic"), type: .heic, gps: true)
      try TestImages.write(to: f.photos.appending(path: "p2.jpg"), gps: true)
      let composition = PostComposition(
         body: "Sunset", tags: ["Photo"],
         photos: [ComposedPhoto(fileName: "p1.heic", altText: "Orange sky"), ComposedPhoto(fileName: "p2.jpg")]
      )
      let id = try await f.store.enqueue(composition, operation: .create)
      await f.processor.drain()

      let item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .sent)
      let post = try await f.service.post(id: try #require(item.serverPostID))
      #expect(post.media.count == 2)
      #expect(post.media.first?.altText == "Orange sky")
      let first = try #require(URL(string: post.media[0].url))
      #expect(!MediaProcessor.hasGPS(first))
      // Local copies are removed once the post is accepted.
      #expect(!FileManager.default.fileExists(atPath: f.photos.appending(path: "p1.heic").path(percentEncoded: false)))
      #expect(f.notifier.events == ["posted:Sunset"])
      #expect(try await f.store.cachedPosts().map(\.id) == [post.id])
   }

   @Test func offlineQueuesWithBackoffThenSucceeds() async throws {
      let f = try await makeFixture()
      await f.backend.setSimulateOffline(true)
      let id = try await f.store.enqueue(PostComposition(body: "later"), operation: .create)
      await f.processor.drain()
      var item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .queued)
      #expect(item.attempts == 1)
      #expect(item.nextAttemptAt != nil)
      #expect(try await f.store.due().isEmpty)

      await f.backend.setSimulateOffline(false)
      try await f.store.retry(id)
      await f.processor.drain()
      item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .sent)
   }

   @Test func retryAfterLostResponseDoesNotDoublePost() async throws {
      let f = try await makeFixture()
      let id = try await f.store.enqueue(PostComposition(body: "exactly once"), operation: .create)
      let key = try #require(try await f.store.snapshot(id)).idempotencyKey
      // Simulate: the server accepted the create but the app died before recording it.
      _ = try await f.service.createPost(PostComposition(body: "exactly once").createBody(), idempotencyKey: key)
      await f.processor.drain()
      let page = try await f.service.myPosts(limit: 50)
      #expect(page.items.filter { $0.body == "exactly once" }.count == 1)
   }

   @Test func validationFailureStopsAndNotifies() async throws {
      let f = try await makeFixture()
      let id = try await f.store.enqueue(PostComposition(blog: "nope", body: "x"), operation: .create)
      await f.processor.drain()
      let item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .failed)
      #expect(item.lastError?.contains("blog") == true)
      #expect(f.notifier.events.count == 1)
   }

   @Test func staleEditBecomesConflictAndOverwriteResolvesIt() async throws {
      let f = try await makeFixture()
      let original = try await f.service.createPost(PostCreate(body: "v1"), idempotencyKey: "k-conflict-1")
      _ = try await f.service.updatePost(id: original.id, PostUpdate(body: "changed on web"), ifMatch: original.version)

      var edit = PostComposition(post: original)
      edit.body = "v2 from phone"
      let id = try await f.store.enqueue(edit, operation: .update, serverPostID: original.id, ifMatch: original.version)
      await f.processor.drain()
      var item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .failed)
      #expect(item.isConflict)

      await f.processor.overwrite(id)
      item = try #require(try await f.store.snapshot(id))
      #expect(item.state == .sent)
      #expect(try await f.service.post(id: original.id).body == "v2 from phone")
   }

   @Test func backoffGrowsAndCaps() {
      #expect(OutboxProcessor.backoff(attempt: 1) == 5)
      #expect(OutboxProcessor.backoff(attempt: 3) == 20)
      #expect(OutboxProcessor.backoff(attempt: 20) == 900)
   }
}

extension OutboxTests {
   @Test func sendNowIgnoresBackoff() async throws {
      let f = try await makeFixture()
      await f.backend.setSimulateOffline(true)
      let id = try await f.store.enqueue(PostComposition(body: "now"), operation: .create)
      await f.processor.drain()
      await f.backend.setSimulateOffline(false)
      #expect(try await f.store.due().isEmpty)
      try await f.store.retryAll()
      await f.processor.drain()
      #expect(try await f.store.snapshot(id)?.state == .sent)
   }
}

extension OutboxTests {
   @Test func concurrentDrainWaitsForTheRunInProgress() async throws {
      let f = try await makeFixture()
      let id = try await f.store.enqueue(PostComposition(body: "wait for me"), operation: .create)
      async let first: Void = f.processor.drain()
      async let second: Void = f.processor.drain()
      _ = await (first, second)
      #expect(try await f.store.snapshot(id)?.state == .sent)
   }

   @Test func deletedItemIsNotSent() async throws {
      let f = try await makeFixture()
      let id = try await f.store.enqueue(PostComposition(body: "never mind"), operation: .create)
      let listed = try await f.store.due()
      try await f.store.delete(id)
      await f.processor.process(listed[0], service: f.service)
      #expect(try await f.service.myPosts(limit: 50).items.allSatisfy { $0.body != "never mind" })
   }

   @Test func draftHelpersNeverTouchQueuedItems() async throws {
      let f = try await makeFixture()
      let draft = try await f.store.saveLocalDraft(PostComposition(body: "draft"), id: nil)
      try await f.store.enqueue(PostComposition(body: "final"), operation: .create, replacing: draft)
      // Stale composer autosave and discard after the draft was posted elsewhere:
      let other = try await f.store.saveLocalDraft(PostComposition(body: "stale edit"), id: draft)
      #expect(other != draft)
      try await f.store.deleteDraft(draft)
      let item = try #require(try await f.store.snapshot(draft))
      #expect(item.composition.body == "final")
      #expect(item.state == .queued)
   }

   @Test func secondQueuedEditUsesTheVersionFromTheFirst() async throws {
      let f = try await makeFixture()
      let post = try await f.service.createPost(PostCreate(body: "v1"), idempotencyKey: "k-carry-1")
      var one = PostComposition(post: post); one.body = "v2"
      var two = PostComposition(post: post); two.body = "v3"
      try await f.store.enqueue(one, operation: .update, serverPostID: post.id, ifMatch: post.version)
      let second = try await f.store.enqueue(two, operation: .update, serverPostID: post.id, ifMatch: post.version)
      await f.processor.drain()
      #expect(try await f.store.snapshot(second)?.state == .sent)
      #expect(try await f.service.post(id: post.id).body == "v3")
   }
}

extension MediaProcessorTests {
   @Test func strippingGPSKeepsOrientation() throws {
      let dir = TestImages.temporaryDirectory()
      let source = dir.appending(path: "rotated.jpg")
      try TestImages.write(to: source, gps: true, orientation: 6)
      let out = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg"],
         maxBytes: 1 << 24, workDirectory: dir.appending(path: "out"))
      let image = CGImageSourceCreateWithURL(out.fileURL as CFURL, nil)!
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as! [CFString: Any]
      #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
      #expect(!MediaProcessor.hasGPS(out.fileURL))
   }
}
