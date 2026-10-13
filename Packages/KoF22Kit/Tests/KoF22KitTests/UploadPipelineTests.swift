/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import KoF22Kit

/// Records the operation of every request before handing it to the fake backend.
final class OperationRecordingTransport: ClientTransport, @unchecked Sendable {
   /// The transport that answers.
   let inner: MockTransport
   /// Guards `recorded`.
   private let lock = NSLock()
   /// The operation id of each request, in order.
   private var recorded: [String] = []

   /// Wraps a mock transport for `backend`.
   init(backend: MockBackend) { inner = MockTransport(backend: backend) }

   /// How many requests were sent for `operation`.
   func count(of operation: String) -> Int { lock.withLock { recorded.filter { $0 == operation }.count } }

   /// Records the request and forwards it.
   func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
      lock.withLock { recorded.append(operationID) }
      return try await inner.send(request, body: body, baseURL: baseURL, operationID: operationID)
   }
}

/// What a scripted PUT does.
enum PutScript: Sendable {
   /// Hand the bytes to the mock backend.
   case deliver
   /// Let the presigned URL expire first, then deliver (storage answers 403).
   case expireThenDeliver
   /// Let the URL expire and send nothing (completion answers `upload_expired`).
   case expireAndDrop
   /// Send nothing, the URL still valid (completion answers `upload_not_received`).
   case drop
   /// Fail like a phone without a connection.
   case offline
}

/// A PUT performer that follows a script, one step per call (the last step repeats), and
/// records the headers it was given.
final class ScriptedUploadPerformer: UploadPerformer, @unchecked Sendable {
   /// How far past a presigned URL's 15-minute lifetime the clock jumps.
   static let expiryJump: TimeInterval = 901
   /// The backend receiving the bytes.
   let backend: MockBackend
   /// The clock shared with the backend.
   let clock: TestClock
   /// Guards the mutable state.
   private let lock = NSLock()
   /// The remaining steps.
   private var script: [PutScript]
   /// The headers of each PUT, in order.
   private var recordedHeaders: [[String: String]] = []

   /// Creates a performer following `script`.
   init(backend: MockBackend, clock: TestClock, script: [PutScript]) {
      self.backend = backend
      self.clock = clock
      self.script = script
   }

   /// The headers of each PUT so far.
   var headers: [[String: String]] { lock.withLock { recordedHeaders } }

   /// Runs the next step of the script.
   func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      let step = lock.withLock {
         recordedHeaders.append(headers)
         return script.count > 1 ? script.removeFirst() : script.first ?? .deliver
      }
      switch step {
      case .deliver:
         try await backend.receiveUpload(id: url.lastPathComponent, from: fileURL)
      case .expireThenDeliver:
         clock.advance(by: Self.expiryJump)
         try await backend.receiveUpload(id: url.lastPathComponent, from: fileURL)
      case .expireAndDrop:
         clock.advance(by: Self.expiryJump)
      case .drop:
         break
      case .offline:
         throw URLError(.notConnectedToInternet)
      }
   }
}

/// A processor wired to the mock backend with every dependency injected.
struct PipelineRig {
   /// The outbox store.
   let store: OutboxStore
   /// The mock backend.
   let backend: MockBackend
   /// The service the processor uses.
   let service: SiteService
   /// The processor under test.
   let processor: OutboxProcessor
   /// Where queued photos live.
   let photos: URL
   /// Where prepared photos live.
   let work: URL
   /// The scripted PUT performer.
   let uploader: ScriptedUploadPerformer
   /// The recording transport.
   let transport: OperationRecordingTransport
   /// The shared clock.
   let clock: TestClock

   /// The jitter source of most tests: the middle of the range, so delays equal the base.
   static let middleRandom = 0.5

   /// Builds a rig; `script` drives the PUTs, `size` is the injected preference and
   /// `random` the jitter source.
   static func make(
      script: [PutScript] = [.deliver], size: UploadSizePreference = .original,
      random: @escaping @Sendable () -> Double = { middleRandom }
   ) async throws -> Self {
      let root = try KitFiles.makeDirectory()
      let clock = TestClock(.now)
      let store = OutboxStore(modelContainer: try PersistenceStack.makeContainer(inMemory: true))
      let backend = MockBackend(directory: root.appending(path: "mock"), now: clock.provider)
      let auth = AuthSession(mode: .mock, store: MemorySecureStore())
      try await auth.signIn(using: RefusingAuthenticator())
      let uploader = ScriptedUploadPerformer(backend: backend, clock: clock, script: script)
      let transport = OperationRecordingTransport(backend: backend)
      let service = SiteService(serverURL: AppConfig.mockAPIBaseURL, transport: transport, auth: auth, uploader: uploader)
      let photos = root.appending(path: "Outbox Photos")
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let work = root.appending(path: "Upload Work")
      let processor = OutboxProcessor(
         store: store, service: { service }, photosDirectory: photos, workDirectory: work, uploadSize: { size }, random: random,
         now: clock.provider)
      return Self(
         store: store, backend: backend, service: service, processor: processor, photos: photos, work: work, uploader: uploader,
         transport: transport, clock: clock)
   }

   /// Queues a post with one JPEG photo carrying GPS and returns the item id.
   func enqueuePhotoPost(_ photo: ComposedPhoto = ComposedPhoto(fileName: "p.jpg")) async throws -> UUID {
      try TestImages.write(to: photos.appending(path: photo.fileName ?? "p.jpg"), gps: true)
      return try await store.enqueue(PostComposition(body: "photo", photos: [photo]), operation: .create)
   }

   /// The current snapshot of an item that must exist.
   func item(_ id: UUID) async throws -> OutboxSnapshot {
      guard let snapshot = try await store.snapshot(id) else { throw RigError.missingItem }
      return snapshot
   }

   /// The files left in the work directory.
   func workFiles() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: work.path(percentEncoded: false))) ?? []).sorted()
   }

   /// The local file behind a mock media URL of the sent post.
   func mediaFiles(of id: UUID) async throws -> [URL] {
      let post = try await service.post(id: try #require(try await item(id).serverPostID))
      return try post.media.map { try #require(URL(string: $0.url)) }
   }
}

/// The retry-safe upload state machine: per-photo location, expired-URL restarts, key
/// reuse, prepared-file lifetime, size preference and backoff jitter.
@Suite(.serialized) struct UploadPipelineTests {
   @Test func eachPhotoKeepsOrDropsItsOwnLocation() async throws {
      let rig = try await PipelineRig.make()
      try TestImages.write(to: rig.photos.appending(path: "keep.jpg"), gps: true)
      try TestImages.write(to: rig.photos.appending(path: "drop.jpg"), gps: true)
      let composition = PostComposition(
         body: "two places",
         photos: [ComposedPhoto(fileName: "keep.jpg", keepLocation: true), ComposedPhoto(fileName: "drop.jpg")])
      let id = try await rig.store.enqueue(composition, operation: .create)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
      let files = try await rig.mediaFiles(of: id)
      #expect(files.map(MediaProcessor.hasGPS) == [true, false])
      #expect(rig.uploader.headers == [["Content-Type": "image/jpeg"], ["Content-Type": "image/jpeg"]])
      #expect(rig.workFiles().isEmpty)
   }

   @Test func anExpiredPutRestartsWithANewTicket() async throws {
      let rig = try await PipelineRig.make(script: [.expireThenDeliver, .deliver])
      let id = try await rig.enqueuePhotoPost()
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .sent)
      #expect(item.composition.photos.first?.uploadGeneration == 1)
      #expect(rig.transport.count(of: "createUpload") == 2)
   }

   @Test func anUploadThatExpiredBeforeItArrivedRestarts() async throws {
      let rig = try await PipelineRig.make(script: [.expireAndDrop, .deliver])
      let id = try await rig.enqueuePhotoPost()
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
      #expect(rig.transport.count(of: "createUpload") == 2)
   }

   @Test func anUploadRestartsOnlyOncePerPass() async throws {
      let rig = try await PipelineRig.make(script: [.expireThenDeliver])
      let id = try await rig.enqueuePhotoPost()
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .failed)
      #expect(item.lastError?.localizedCaseInsensitiveContains("expired") == true)
      #expect(item.composition.photos.first?.uploadGeneration == 1)
      #expect(rig.transport.count(of: "createUpload") == 2)
      ////////////////////////////////////////////////////////////////
      // The prepared file stays for the next attempt.              //
      ////////////////////////////////////////////////////////////////
      #expect(rig.workFiles().count == 1)
   }

   @Test func bytesMissingBeforeExpiryAreNotRestarted() async throws {
      let rig = try await PipelineRig.make(script: [.drop])
      let id = try await rig.enqueuePhotoPost()
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .failed)
      #expect(rig.transport.count(of: "createUpload") == 1)
   }

   @Test func retriesReuseTheKeyAndThePreparedFile() async throws {
      let rig = try await PipelineRig.make(script: [.offline, .deliver])
      let id = try await rig.enqueuePhotoPost()
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .queued)
      let prepared = rig.workFiles()
      #expect(prepared.count == 1)
      ////////////////////////////////////////////////////////////////
      // The original goes away; the prepared copy is enough.       //
      ////////////////////////////////////////////////////////////////
      try FileManager.default.removeItem(at: rig.photos.appending(path: "p.jpg"))
      try await rig.store.retry(id)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
      #expect(rig.transport.count(of: "createUpload") == 2)
      #expect(rig.workFiles().isEmpty)
   }

   @Test func aPreparedPNGIsReusedAsPNG() async throws {
      let rig = try await PipelineRig.make(script: [.offline, .deliver])
      try TestImages.write(to: rig.photos.appending(path: "p.png"), type: .png, gps: false)
      let id = try await rig.store.enqueue(PostComposition(body: "png", photos: [ComposedPhoto(fileName: "p.png")]), operation: .create)
      await rig.processor.drain()
      #expect(rig.workFiles().allSatisfy { $0.hasSuffix(".png") })
      try await rig.store.retry(id)
      await rig.processor.drain()
      #expect(try await rig.item(id).state == .sent)
   }

   @Test func theInjectedSizePreferenceIsUsed() async throws {
      let rig = try await PipelineRig.make(size: .large)
      try TestImages.write(to: rig.photos.appending(path: "tall.jpg"), width: 20, height: 4_200, gps: false)
      let id = try await rig.store.enqueue(PostComposition(body: "tall", photos: [ComposedPhoto(fileName: "tall.jpg")]), operation: .create)
      await rig.processor.drain()
      let files = try await rig.mediaFiles(of: id)
      #expect(files.map { pixelSize(of: $0).height } == [UploadSizePreference.largeLongEdge])
   }

   @Test func expiryIsRecognisedOnlyWhereARestartCanHelp() {
      let expires = Date(timeIntervalSince1970: 1_000)
      let before = Date(timeIntervalSince1970: 999)
      let after = Date(timeIntervalSince1970: 1_001)
      let forbidden = APIError(status: 403, code: "forbidden", message: "expired")
      let notReceived = APIError(status: 409, code: "upload_not_received", message: "missing")
      let expired = APIError(status: 409, code: "upload_expired", message: "expired")
      let busy = APIError(status: 409, code: "idempotency_in_progress", message: "busy")
      let unavailable = APIError(status: 503, code: "unavailable", message: "later")
      #expect(OutboxProcessor.isExpiredUpload(forbidden, stage: .put, expiresAt: expires, now: before))
      #expect(!OutboxProcessor.isExpiredUpload(forbidden, stage: .complete, expiresAt: expires, now: after))
      #expect(!OutboxProcessor.isExpiredUpload(URLError(.timedOut), stage: .put, expiresAt: expires, now: after))
      #expect(OutboxProcessor.isExpiredUpload(expired, stage: .complete, expiresAt: expires, now: before))
      #expect(OutboxProcessor.isExpiredUpload(notReceived, stage: .complete, expiresAt: expires, now: after))
      #expect(!OutboxProcessor.isExpiredUpload(notReceived, stage: .complete, expiresAt: expires, now: before))
      #expect(!OutboxProcessor.isExpiredUpload(busy, stage: .complete, expiresAt: expires, now: after))
      #expect(!OutboxProcessor.isExpiredUpload(unavailable, stage: .put, expiresAt: expires, now: after))
   }
}

/// Backoff jitter and the cleanup of prepared files.
@Suite(.serialized) struct UploadPipelineHousekeepingTests {
   @Test func jitterStaysWithinAQuarterOfTheBaseAndUnderTheCap() {
      for attempt in 1...12 {
         let base = OutboxProcessor.backoff(attempt: attempt)
         for random in stride(from: -1.0, through: 2.0, by: 0.25) {
            let delay = OutboxProcessor.backoff(attempt: attempt, random: random)
            #expect(delay >= base * 0.75)
            #expect(delay <= min(base * 1.25, OutboxProcessor.maximumBackoff))
         }
      }
      #expect(OutboxProcessor.backoff(attempt: 1, random: 0) == 3.75)
      #expect(OutboxProcessor.backoff(attempt: 1, random: 1) == 6.25)
      #expect(OutboxProcessor.backoff(attempt: 2, random: 0.5) == 10)
      #expect(OutboxProcessor.backoff(attempt: 20, random: 1) == 900)
   }

   @Test func networkFailuresWaitAJitteredBackoff() async throws {
      let rig = try await PipelineRig.make(random: { 0 })
      await rig.backend.setSimulateOffline(true)
      let id = try await rig.store.enqueue(PostComposition(body: "later"), operation: .create)
      await rig.processor.drain()
      let item = try await rig.item(id)
      #expect(item.state == .queued)
      #expect(item.nextAttemptAt == rig.clock.now.addingTimeInterval(3.75))
   }

   @Test func oldPreparedFilesAreSweptAndNewOnesKept() async throws {
      let rig = try await PipelineRig.make()
      try FileManager.default.createDirectory(at: rig.work, withIntermediateDirectories: true)
      let old = rig.work.appending(path: "old.jpg")
      let fresh = rig.work.appending(path: "fresh.jpg")
      try Data([1]).write(to: old)
      try Data([2]).write(to: fresh)
      let stale = rig.clock.now.addingTimeInterval(-OutboxProcessor.workFileRetention - 60)
      try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: old.path(percentEncoded: false))
      await rig.processor.drain()
      #expect(rig.workFiles() == ["fresh.jpg"])
   }

   @Test func sweepingAndRemovingCopeWithMissingFiles() async throws {
      let rig = try await PipelineRig.make()
      await rig.processor.drain()
      await rig.processor.removeWorkFile(rig.work.appending(path: "missing.jpg"))
      #expect(OutboxProcessor.modificationDate(of: rig.work.appending(path: "missing.jpg")) == .distantFuture)
      #expect(rig.workFiles().isEmpty)
   }
}
