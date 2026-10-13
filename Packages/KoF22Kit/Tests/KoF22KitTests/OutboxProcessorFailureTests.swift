/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// How the processor reacts to each kind of failure, and the delete and overwrite
/// paths.
@Suite(.serialized) struct OutboxProcessorFailureTests {
   @Test func nothingIsSentWithoutAService() async throws {
      let rig = try await OutboxRig.make(provider: { nil })
      let id = try await rig.store.enqueue(PostComposition(body: "waiting"), operation: .create)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .queued)
      await rig.processor.overwrite(id)
      #expect(try await rig.item(id).state == .queued)
   }

   @Test func signedOutStopsAndAsksTheUser() async throws {
      let rig = try await OutboxRig.make()
      await rig.auth.signOut()
      let id = try await rig.store.enqueue(PostComposition(body: "needs sign-in"), operation: .create)
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .failed)
      #expect(item.lastError == "Signed out. Sign in again to send.")
      #expect(rig.recorder.events == ["failed:needs sign-in"])
   }

   @Test func retryAfterFromTheServerSetsTheNextAttempt() async throws {
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: RefusingAuthenticator())
      let failing = SiteService(
         serverURL: AppConfig.mockAPIBaseURL, transport: FixedStatusTransport(status: 503, headers: ["Retry-After": "120"]),
         auth: auth, uploader: MockUploadPerformer(backend: MockBackend(directory: nil)))
      let rig = try await OutboxRig.make(provider: { failing })
      let id = try await rig.store.enqueue(PostComposition(body: "busy"), operation: .create)
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .queued)
      #expect(item.attempts == 1)
      #expect(item.nextAttemptAt == rig.clock.now.addingTimeInterval(120))
      #expect(rig.recorder.events.isEmpty)
   }

   @Test func retryingStopsAfterTheMaximumAttempts() async throws {
      let rig = try await OutboxRig.make()
      await rig.backend.setSimulateOffline(true)
      let id = try await rig.store.enqueue(PostComposition(body: "give up"), operation: .create)
      try await rig.store.update(id) { $0.attempts = OutboxProcessor.maxAutomaticAttempts - 1 }
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .failed)
      #expect(item.attempts == OutboxProcessor.maxAutomaticAttempts)
      #expect(rig.recorder.events == ["failed:give up"])
   }

   @Test func aMissingPhotoStopsThePost() async throws {
      let rig = try await OutboxRig.make()
      let composition = PostComposition(body: "photo gone", photos: [ComposedPhoto(fileName: "missing.jpg")])
      let id = try await rig.store.enqueue(composition, operation: .create)
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .failed)
      #expect(item.lastError == "A photo for this post is no longer on the device")
   }

   @Test func photosAreUploadedOnceAndLimitsFetchedOnce() async throws {
      let rig = try await OutboxRig.make()
      try KitFiles.writeImage(to: rig.photos.appending(path: "a.jpg"))
      try KitFiles.writeImage(to: rig.photos.appending(path: "b.png"), type: .png)
      let first = try await rig.store.enqueue(
         PostComposition(body: "first", photos: [ComposedPhoto(fileName: "a.jpg", caption: "A")]), operation: .create)
      let second = try await rig.store.enqueue(
         PostComposition(body: "second", photos: [ComposedPhoto(fileName: "b.png"), ComposedPhoto(mediaId: 1)]), operation: .create)
      await rig.processor.drain()
      #expect(try await rig.item(first).state == .sent)
      let sent = try await rig.item(second)
      #expect(sent.state == .sent)
      #expect(sent.composition.photos.allSatisfy { $0.isUploaded })
      #expect(!FileManager.default.fileExists(atPath: rig.photos.appending(path: "b.png").path(percentEncoded: false)))
      #expect(rig.recorder.events == ["posted:first", "posted:second"])
   }

   @Test func deletingRemovesThePostAndItsCachedCopy() async throws {
      let rig = try await OutboxRig.make()
      let post = try await rig.service.createPost(PostComposition(body: "to delete").draft())
      try await rig.store.cache([post])
      let id = try await rig.store.enqueue(PostComposition(post: post), operation: .delete, serverPostID: post.id, ifMatch: post.version)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
      #expect(try await rig.store.cachedPosts().isEmpty)
      await #expect(throws: APIError.self) { try await rig.service.post(id: post.id) }
   }

   @Test func deletingAPostThatIsAlreadyGoneSucceeds() async throws {
      let rig = try await OutboxRig.make()
      let id = try await rig.store.enqueue(PostComposition(body: "gone"), operation: .delete, serverPostID: 9_999)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
   }

   @Test func itemsMissingTheirServerIdentityFail() async throws {
      let rig = try await OutboxRig.make()
      let delete = try await rig.store.enqueue(PostComposition(body: "no id"), operation: .delete)
      let update = try await rig.store.enqueue(PostComposition(body: "no version"), operation: .update, serverPostID: 1)
      await rig.processor.drain()
      #expect(try await rig.item(delete).lastError == "Missing post id")
      #expect(try await rig.item(update).lastError == "Missing post id or version")
   }

   @Test func overwriteIgnoresUnknownItemsAndCreates() async throws {
      let rig = try await OutboxRig.make()
      await rig.processor.overwrite(UUID())
      let create = try await rig.store.enqueue(PostComposition(body: "create"), operation: .create)
      try await rig.store.update(create) { $0.state = .failed }
      await rig.processor.overwrite(create)
      #expect(try await rig.item(create).state == .failed)
   }

   @Test func overwriteOfADeletedPostRecordsTheFailure() async throws {
      let rig = try await OutboxRig.make()
      let id = try await rig.store.enqueue(PostComposition(body: "edit"), operation: .update, serverPostID: 9_999, ifMatch: "v")
      try await rig.store.update(id) { stored in
         stored.state = .failed
         stored.isConflict = true
      }
      await rig.processor.overwrite(id)
      let item = try await rig.item(id)
      #expect(item.state == .failed)
      #expect(item.attempts == 1)
      #expect(rig.recorder.events == ["failed:edit"])
   }

   @Test func bestEffortReturnsNilAndKeepsGoingOnFailure() async throws {
      let rig = try await OutboxRig.make()
      let systemic = await rig.processor.bestEffort("fail systemically", systemic: true, otherwise: [Int]()) { throw RigError.deliberate }
      let single = await rig.processor.bestEffort("fail once", otherwise: -1) { throw RigError.deliberate }
      let fine = await rig.processor.bestEffort("succeed", otherwise: -1) { 42 }
      await rig.processor.bestEffort("fail without a result") { throw RigError.deliberate }
      #expect(systemic.isEmpty)
      #expect(single == -1)
      #expect(fine == 42)
   }

   @Test func theSilentNotifierIsTheDefault() async throws {
      let container = try PersistenceStack.makeContainer(inMemory: true)
      let store = OutboxStore(modelContainer: container)
      let backend = MockBackend(directory: nil)
      let (service, _) = try await makeSignedInService(backend)
      let processor = OutboxProcessor(store: store, service: { service }, photosDirectory: try KitFiles.makeDirectory())
      let id = try await store.enqueue(PostComposition(body: "quiet"), operation: .create)
      await processor.drain()
      #expect(try await store.snapshot(id)?.state == .sent)
      let failed = try await store.enqueue(PostComposition(blog: "nope", body: "quiet failure"), operation: .create)
      await processor.drain()
      #expect(try await store.snapshot(failed)?.state == .failed)
   }
}
