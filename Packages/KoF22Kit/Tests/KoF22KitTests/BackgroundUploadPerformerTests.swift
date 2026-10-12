/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// What the fake session reports when a task is resumed.
enum FakeOutcome: Sendable {
   /// An HTTP response with a status and body.
   case http(Int, String)
   /// A transport failure.
   case failure(URLError.Code)
   /// A response that is not HTTP.
   case nonHTTP
}

/// A task that reports a scripted outcome to the bridge when resumed, like the session
/// delegate would.
struct FakeUploadTask: UploadTaskHandle {
   /// Runs when the task is resumed.
   let onResume: @Sendable () -> Void

   /// Starts the fake upload.
   func resume() { onResume() }
}

/// Creates fake tasks and records the requests, files and tokens it was given.
final class FakeUploadFactory: UploadTaskFactory, @unchecked Sendable {
   /// The bridge the fake reports to.
   let bridge: UploadBridge
   /// What every task reports.
   let outcome: FakeOutcome
   /// Guards `made`.
   private let lock = NSLock()
   /// One task the performer asked for.
   struct Made {
      /// The PUT request.
      let request: URLRequest
      /// The file to upload.
      let file: URL
   }

   /// The tasks made so far.
   private var made: [Made] = []

   /// Creates a factory reporting `outcome` to `bridge`.
   init(bridge: UploadBridge, outcome: FakeOutcome) {
      self.bridge = bridge
      self.outcome = outcome
   }

   /// The tasks made so far.
   var tasks: [Made] { lock.withLock { made } }

   /// A task that completes (synchronously, the hardest case) with the outcome.
   func makeUploadTask(with request: URLRequest, fromFile fileURL: URL, token: String) -> any UploadTaskHandle {
      lock.withLock { made.append(Made(request: request, file: fileURL)) }
      return FakeUploadTask { [bridge, outcome] in
         let url = request.url ?? URL(filePath: "/")
         switch outcome {
         case .http(let status, let body):
            bridge.received(Data(body.utf8), token: token)
            bridge.complete(token: token, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil), error: nil)
         case .failure(let code):
            bridge.complete(token: token, response: nil, error: URLError(code))
         case .nonHTTP:
            bridge.complete(token: token, response: URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), error: nil)
         }
      }
   }
}

/// The background upload performer's bridging, error mapping, relaunch handling and the
/// app delegate's events handler, all without a real background session.
@Suite struct BackgroundUploadPerformerTests {
   /// A presigned URL like the server's.
   static let presigned = URL(literal: "https://storage.kof22.invalid/incoming/abc?X-Amz-Signature=1")
   /// The file being uploaded (never read by the fake).
   static let file = URL(filePath: "/tmp/photo.jpg")

   /// A performer over a fake factory reporting `outcome`.
   func makePerformer(_ outcome: FakeOutcome) -> (BackgroundUploadPerformer, FakeUploadFactory) {
      let bridge = UploadBridge(handlers: BackgroundEventHandlers())
      let factory = FakeUploadFactory(bridge: bridge, outcome: outcome)
      return (BackgroundUploadPerformer(factory: factory, bridge: bridge), factory)
   }

   @Test func aSuccessfulPutSendsExactlyTheTicketHeadersFromTheFile() async throws {
      let (performer, factory) = makePerformer(.http(200, ""))
      try await performer.put(fileURL: Self.file, to: Self.presigned, headers: ["Content-Type": "image/jpeg"])
      let task = try #require(factory.tasks.first)
      #expect(task.request.httpMethod == "PUT")
      #expect(task.request.url == Self.presigned)
      #expect(task.request.allHTTPHeaderFields == ["Content-Type": "image/jpeg"])
      #expect(task.request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(task.file == Self.file)
   }

   @Test func aRefusedPutThrowsTheStatusAndTheStartOfTheBody() async throws {
      let body = "<Error><Code>AccessDenied</Code>" + String(repeating: "x", count: 400)
      let (performer, _) = makePerformer(.http(403, body))
      do {
         try await performer.put(fileURL: Self.file, to: Self.presigned, headers: [:])
         Issue.record("The PUT should fail")
      }
      catch let error as APIError {
         #expect(error.status == 403)
         #expect(error.code == "upload_put_failed")
         #expect(error.message.hasPrefix("<Error><Code>AccessDenied"))
         #expect(error.message.utf8.count == UploadBridge.errorBodyPrefixBytes)
         #expect(ErrorClassifier.disposition(for: error) == .permanent)
      }
   }

   @Test func transportFailuresAndOddResponsesAreRetryable() async throws {
      let (offline, _) = makePerformer(.failure(.networkConnectionLost))
      await #expect(throws: URLError(.networkConnectionLost)) { try await offline.put(fileURL: Self.file, to: Self.presigned, headers: [:]) }
      let (odd, _) = makePerformer(.nonHTTP)
      await #expect(throws: URLError(.badServerResponse)) { try await odd.put(fileURL: Self.file, to: Self.presigned, headers: [:]) }
   }

   @Test func anUnreadableErrorBodyStillGivesAMessage() {
      let response = HTTPURLResponse(url: Self.presigned, statusCode: 500, httpVersion: nil, headerFields: nil)
      let outcome = UploadBridge.outcome(response: response, body: Data([0xFF, 0xFE]), error: nil)
      #expect(throws: APIError(status: 500, code: "upload_put_failed", message: "Upload failed")) { try outcome.get() }
   }

   @Test func resultsNobodyWaitsForAreDroppedAfterARelaunch() {
      let bridge = UploadBridge(handlers: BackgroundEventHandlers())
      bridge.received(Data("late".utf8), token: "from-previous-process")
      bridge.received(Data("late".utf8), token: nil)
      bridge.complete(token: "from-previous-process", response: nil, error: nil)
      bridge.complete(token: nil, response: nil, error: URLError(.cancelled))
   }

   @Test func theEventsHandlerRunsOnceTheSessionHasDeliveredEverything() async {
      let handlers = BackgroundEventHandlers()
      let bridge = UploadBridge(handlers: handlers)
      bridge.finishEvents(identifier: nil)
      bridge.finishEvents(identifier: "nobody-waiting")
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
         handlers.store({ continuation.resume() }, for: "session")
         bridge.finishEvents(identifier: "session")
      }
      #expect(handlers.take("session") == nil)
   }

   @Test func delegateCallbacksReachTheBridge() async throws {
      let bridge = UploadBridge(handlers: BackgroundEventHandlers())
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let file = TestImages.temporaryDirectory().appending(path: "bytes.bin")
      try Data([1, 2, 3]).write(to: file)
      let task = try #require(session.makeUploadTask(with: URLRequest(url: Self.presigned), fromFile: file, token: "t-1") as? URLSessionUploadTask)
      #expect(task.taskDescription == "t-1")
      await #expect(throws: URLError(.badServerResponse)) {
         try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            bridge.register("t-1", continuation)
            bridge.urlSession(session, dataTask: task, didReceive: Data("body".utf8))
            bridge.urlSession(session, task: task, didCompleteWithError: nil)
         }
      }
      bridge.urlSessionDidFinishEvents(forBackgroundURLSession: session)
      task.cancel()
   }

   @Test func theBackgroundConfigurationSharesTheAppGroupAndStartsAtOnce() {
      let configuration = BackgroundUploadPerformer.configuration(identifier: "com.kof22.post.uploads.test", appGroup: SharedIDs.appGroup)
      #expect(configuration.identifier == "com.kof22.post.uploads.test")
      #expect(configuration.sharedContainerIdentifier == "group.com.kof22.post")
      #expect(!configuration.isDiscretionary)
      #expect(configuration.timeoutIntervalForResource == BackgroundUploadPerformer.resourceTimeout)
      #expect(BackgroundUploadPerformer.sessionIdentifier == "com.kof22.post.uploads")
   }

   @Test func theAppDelegateHandlerRecreatesTheSessionOnce() async {
      let identifier = "com.kof22.post.uploads.tests-\(UUID().uuidString)"
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
         BackgroundUploadPerformer.handleEvents(forBackgroundURLSession: identifier) { continuation.resume() }
         let performer = BackgroundUploadPerformer.performer(for: identifier)
         #expect(performer === BackgroundUploadPerformer.performer(for: identifier))
         performer.bridge.finishEvents(identifier: identifier)
      }
      #expect(BackgroundUploadPerformer.shared === BackgroundUploadPerformer.performer(for: BackgroundUploadPerformer.sessionIdentifier))
   }
}
