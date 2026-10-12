/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Synchronization

/// An upload task as far as the performer needs it. `URLSessionUploadTask` is one; tests
/// use a fake.
protocol UploadTaskHandle: Sendable {
   /// Starts the upload.
   func resume()
}

/// Creates upload tasks tagged with a token the delegate reports back. A background
/// `URLSession` in the app; a fake in tests, so no real background session runs there.
protocol UploadTaskFactory: Sendable {
   /// An upload of `fileURL` with `request`, not yet started, carrying `token` as its
   /// task description.
   func makeUploadTask(with request: URLRequest, fromFile fileURL: URL, token: String) -> any UploadTaskHandle
}

extension URLSessionUploadTask: UploadTaskHandle {}

extension URLSession: UploadTaskFactory {
   /// A delegate-based upload task (background sessions do not take completion handlers),
   /// tagged with `token` so the delegate can find the caller waiting for it.
   func makeUploadTask(with request: URLRequest, fromFile fileURL: URL, token: String) -> any UploadTaskHandle {
      let task = uploadTask(with: request, fromFile: fileURL)
      task.taskDescription = token
      return task
   }
}

/// The completion handlers iOS hands the app when it relaunches it for background
/// session events, kept until the session reports that all events were delivered.
final class BackgroundEventHandlers: Sendable {
   /// The handlers the app delegate received, shared by every performer.
   static let shared = BackgroundEventHandlers()

   /// The waiting handlers by session identifier.
   private let handlers = Mutex<[String: @Sendable () -> Void]>([:])

   /// Keeps `handler` until the session `identifier` finishes its events.
   func store(_ handler: @escaping @Sendable () -> Void, for identifier: String) {
      handlers.withLock { $0[identifier] = handler }
   }

   /// Removes and returns the handler for `identifier`, if one is waiting.
   func take(_ identifier: String) -> (@Sendable () -> Void)? {
      handlers.withLock { $0.removeValue(forKey: identifier) }
   }
}

/// The session delegate: maps finished tasks (by their token) to the callers waiting for
/// them, collects the start of each response body for error messages, and calls the
/// app's events handler once the system has delivered everything.
final class UploadBridge: NSObject, URLSessionDataDelegate, Sendable {
   /// What the bridge tracks for the uploads of this process.
   private struct State {
      /// Callers waiting for an upload, by token.
      var waiting: [String: CheckedContinuation<Void, any Error>] = [:]
      /// The start of each upload's response body, by token.
      var bodies: [String: Data] = [:]
   }

   /// Status codes that mean the storage service kept the bytes.
   static let successStatusCodes = 200..<300
   /// How much of a failed upload's response body ends up in the error message.
   static let errorBodyPrefixBytes = 300

   /// The waiting callers and collected bodies.
   private let state = Mutex(State())
   /// Where the app delegate's completion handlers wait.
   let handlers: BackgroundEventHandlers

   /// Creates a bridge that calls the handlers kept in `handlers`.
   init(handlers: BackgroundEventHandlers = .shared) {
      self.handlers = handlers
   }

   /// Remembers the caller waiting for the upload tagged `token`. Called before the task
   /// starts, so even an instant completion finds it.
   func register(_ token: String, _ continuation: CheckedContinuation<Void, any Error>) {
      state.withLock { $0.waiting[token] = continuation }
   }

   /// Keeps the start of a response body for an upload someone is waiting for.
   func received(_ data: Data, token: String?) {
      guard let token else { return }
      state.withLock { state in
         guard state.waiting[token] != nil else { return }
         let body = state.bodies[token, default: Data()] + data
         state.bodies[token] = body.prefix(Self.errorBodyPrefixBytes)
      }
   }

   /// Resumes the caller waiting for `token` with the upload's outcome. After a relaunch
   /// nobody is waiting for uploads the previous process started; their results are
   /// dropped, and the outbox PUTs those photos again (a repeated PUT is safe).
   func complete(token: String?, response: URLResponse?, error: (any Error)?) {
      let (continuation, body) = state.withLock { state in
         (token.flatMap { state.waiting.removeValue(forKey: $0) }, token.flatMap { state.bodies.removeValue(forKey: $0) } ?? Data())
      }
      guard let continuation else {
         Log.outbox.info("A background upload finished with nobody waiting; the outbox will upload it again")
         return
      }
      continuation.resume(with: Self.outcome(response: response, body: body, error: error))
   }

   /// A transport error as is, a missing HTTP response as `badServerResponse`, and a
   /// non-2xx status as `APIError` `upload_put_failed` carrying the start of the body.
   static func outcome(response: URLResponse?, body: Data, error: (any Error)?) -> Result<Void, any Error> {
      if let error { return .failure(error) }
      guard let http = response as? HTTPURLResponse else { return .failure(URLError(.badServerResponse)) }
      guard successStatusCodes.contains(http.statusCode) else {
         let message = String(data: body, encoding: .utf8) ?? "Upload failed"
         return .failure(APIError(status: http.statusCode, code: "upload_put_failed", message: message))
      }
      return .success(())
   }

   /// Calls the app delegate's completion handler for `identifier` on the main queue, as
   /// UIKit requires, once the session has delivered all its events.
   func finishEvents(identifier: String?) {
      guard let identifier, let handler = handlers.take(identifier) else { return }
      DispatchQueue.main.async { handler() }
   }

   /// Collects response bytes (S3 sends an XML error body on failure).
   func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      received(data, token: dataTask.taskDescription)
   }

   /// Reports a finished upload to its caller.
   func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      complete(token: task.taskDescription, response: task.response, error: error)
   }

   /// All events for a relaunched app were delivered.
   func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
      finishEvents(identifier: session.configuration.identifier)
   }
}

/// Uploads photos with a background `URLSession`, so a PUT keeps going while the app is
/// suspended. The file is uploaded from disk with exactly the ticket's headers and no
/// `Authorization` (the presigned URL is the credential).
public final class BackgroundUploadPerformer: UploadPerformer {
   /// The app's background upload session.
   public static let sessionIdentifier = SharedIDs.backgroundUploadSession
   /// The idle timeout of one upload request (full-resolution photos on slow networks).
   static let requestTimeout: TimeInterval = 300
   /// The presigned URL lives 15 minutes; waiting longer cannot succeed, and the outbox
   /// restarts the upload with a new ticket instead.
   static let resourceTimeout: TimeInterval = 900

   /// One performer per session identifier: a background session must exist only once
   /// per process.
   private static let performers = Mutex<[String: BackgroundUploadPerformer]>([:])

   /// Creates the upload tasks.
   let factory: any UploadTaskFactory
   /// Connects task completions to the waiting callers.
   let bridge: UploadBridge

   /// Creates a performer on any task factory; tests pass a fake.
   init(factory: any UploadTaskFactory, bridge: UploadBridge) {
      self.factory = factory
      self.bridge = bridge
   }

   /// The app's performer, on the `com.kof22.post.uploads` session.
   public static var shared: BackgroundUploadPerformer { performer(for: sessionIdentifier) }

   /// The performer for the background session `identifier`, created on first use. An
   /// app extension passes its own identifier; the session shares the App Group.
   public static func performer(for identifier: String, appGroup: String = SharedIDs.appGroup) -> BackgroundUploadPerformer {
      performers.withLock { performers in
         if let existing = performers[identifier] { return existing }
         let bridge = UploadBridge()
         let session = URLSession(configuration: configuration(identifier: identifier, appGroup: appGroup), delegate: bridge, delegateQueue: nil)
         let performer = BackgroundUploadPerformer(factory: session, bridge: bridge)
         performers[identifier] = performer
         return performer
      }
   }

   /// A background configuration that shares the App Group container, relaunches the app
   /// for its events and starts at once (not discretionary).
   static func configuration(identifier: String, appGroup: String) -> URLSessionConfiguration {
      let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
      configuration.sharedContainerIdentifier = appGroup
      configuration.isDiscretionary = false
      configuration.timeoutIntervalForRequest = requestTimeout
      configuration.timeoutIntervalForResource = resourceTimeout
      #if os(iOS)
         configuration.sessionSendsLaunchEvents = true
      #endif
      return configuration
   }

   /// PUTs the file and returns when the background task finishes; throws the transport
   /// error, or `APIError` `upload_put_failed` for a non-2xx response.
   public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      let token = UUID().uuidString
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
         bridge.register(token, continuation)
         factory.makeUploadTask(with: request, fromFile: fileURL, token: token).resume()
      }
   }

   /// For `application(_:handleEventsForBackgroundURLSession:completionHandler:)`: keeps
   /// the handler, recreates the session so its delegate receives the pending events, and
   /// calls the handler once they are delivered.
   public static func handleEvents(forBackgroundURLSession identifier: String, completionHandler: @escaping @Sendable () -> Void) {
      BackgroundEventHandlers.shared.store(completionHandler, for: identifier)
      _ = performer(for: identifier)
   }
}
