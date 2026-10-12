/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation
import HTTPTypes
import ImageIO
import OpenAPIRuntime
import SwiftData
import UniformTypeIdentifiers

@testable import KoF22Kit

/// Temporary folders and small images owned by these fixtures.
enum KitFiles {
   /// A new empty folder under the system temporary directory.
   static func makeDirectory() throws -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "kof22-kit-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
   }

   /// Writes a small solid image of `type`.
   static func writeImage(to url: URL, type: UTType = .jpeg) throws {
      let side = 16
      let bitsPerComponent = 8
      guard
         let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
         let image = context.makeImage(),
         let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
      else { throw RigError.deliberate }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { throw RigError.deliberate }
   }
}

/// Refuses the browser step; mock sign-in never shows it.
struct RefusingAuthenticator: WebAuthenticator {
   /// Always cancels.
   func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AuthError.cancelled }
}

/// A signed-in mock-mode service over `backend`.
func makeSignedInService(_ backend: MockBackend) async throws -> (SiteService, AuthSession) {
   let auth = AuthSession(mode: .mock, store: MemorySecureStore())
   try await auth.signIn(using: RefusingAuthenticator())
   return (SiteService.mock(backend: backend, auth: auth), auth)
}

/// A clock tests can move forward, shared with the code under test.
final class TestClock: @unchecked Sendable {
   /// Guards `current`.
   private let lock = NSLock()
   /// The instant the clock reports.
   private var current: Date

   /// A fixed whole-second instant, so dates survive ISO 8601 round trips exactly.
   static let defaultStartSeconds: TimeInterval = 1_800_000_000
   /// The default start as a date.
   static let defaultStart = Date(timeIntervalSince1970: defaultStartSeconds)

   /// Starts the clock at `start`.
   init(_ start: Date = defaultStart) { current = start }

   /// The current instant.
   var now: Date { lock.withLock { current } }

   /// The clock as the `now:` closure the production types take.
   var provider: @Sendable () -> Date { { self.now } }

   /// Moves the clock forward.
   func advance(by interval: TimeInterval) { lock.withLock { current = current.addingTimeInterval(interval) } }
}

/// Records notifier calls as `posted:<summary>` and `failed:<summary>`.
final class EventRecorder: OutboxNotifier, @unchecked Sendable {
   /// Guards `events`.
   private let lock = NSLock()
   /// The calls received, in order.
   private var recorded: [String] = []

   /// The calls received, in order.
   var events: [String] { lock.withLock { recorded } }

   /// Records a success.
   func posted(summary: String, status: PostStatus, url: String?) async { lock.withLock { recorded.append("posted:\(summary)") } }

   /// Records a stop.
   func failed(summary: String, message: String) async { lock.withLock { recorded.append("failed:\(summary)") } }
}

/// Answers every request with one fixed status and headers, for failures the mock
/// backend never produces (server errors, Retry-After).
struct FixedStatusTransport: ClientTransport {
   /// The status to answer with.
   let status: Int
   /// Extra response headers.
   let headers: [String: String]

   /// Replies with the fixed status and an error envelope.
   func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
      var fields = HTTPFields()
      fields[.contentType] = "application/json"
      for (name, value) in headers {
         if let name = HTTPField.Name(name) { fields[name] = value }
      }
      let envelope = #"{"error":{"code":"unavailable","message":"Try later","status":\#(status)}}"#
      return (HTTPResponse(status: .init(code: status), headerFields: fields), HTTPBody(envelope))
   }
}

/// An in-memory outbox wired to a mock backend in a temporary directory.
struct OutboxRig {
   /// The temporary root for this rig.
   let root: URL
   /// The outbox store.
   let store: OutboxStore
   /// The mock backend.
   let backend: MockBackend
   /// A signed-in service against the backend.
   let service: SiteService
   /// The auth session behind `service`.
   let auth: AuthSession
   /// The processor under test.
   let processor: OutboxProcessor
   /// Where queued photos live.
   let photos: URL
   /// Notifier calls.
   let recorder: EventRecorder
   /// The injected clock.
   let clock: TestClock

   /// Builds a rig; `provider` overrides the service the processor gets.
   static func make(provider: OutboxProcessor.ServiceProvider? = nil) async throws -> Self {
      let root = try KitFiles.makeDirectory()
      let clock = TestClock(.now)
      let store = OutboxStore(modelContainer: try PersistenceStack.makeContainer(inMemory: true))
      let backend = MockBackend(directory: root.appending(path: "mock"), now: clock.provider)
      let (service, auth) = try await makeSignedInService(backend)
      let photos = root.appending(path: "Outbox Photos")
      try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
      let recorder = EventRecorder()
      let processor = OutboxProcessor(
         store: store, service: provider ?? { service }, notifier: recorder, photosDirectory: photos, now: clock.provider)
      return Self(
         root: root, store: store, backend: backend, service: service, auth: auth, processor: processor,
         photos: photos, recorder: recorder, clock: clock)
   }

   /// The current snapshot of an item that must exist.
   func item(_ id: UUID) async throws -> OutboxSnapshot {
      guard let snapshot = try await store.snapshot(id) else { throw RigError.missingItem }
      return snapshot
   }
}

/// Failures raised by the test fixtures themselves.
enum RigError: Error {
   /// An item the test expected was not in the store.
   case missingItem
   /// A deliberate failure for error-path tests.
   case deliberate
}

/// Calls `MockBackend.handle` the way the transport does and decodes replies.
struct MockCaller {
   /// The backend under test.
   let backend: MockBackend

   /// Sends one request with an optional JSON-encodable body.
   func call(
      _ operation: String, path: String = "/", query: [String: String] = [:], headers: [String: String] = [:],
      json: (any Encodable & Sendable)? = nil
   ) async throws -> MockBackend.Response {
      let body = try json.map { try MockBackend.encoder.encode($0) }
      return try await backend.handle(operation: operation, path: path, query: query, headers: headers, body: body)
   }

   /// Sends one request with a raw body.
   func call(_ operation: String, path: String = "/", headers: [String: String] = [:], raw: Data?) async throws -> MockBackend.Response {
      try await backend.handle(operation: operation, path: path, query: [:], headers: headers, body: raw)
   }

   /// Decodes a reply body.
   func decode<Value: Decodable>(_ type: Value.Type, _ response: MockBackend.Response) throws -> Value {
      try MockBackend.decoder.decode(type, from: response.body ?? Data())
   }

   /// The error envelope code of a reply.
   func errorCode(_ response: MockBackend.Response) throws -> String {
      try decode(Components.Schemas._Error.self, response).error.code
   }

   /// The first validation detail field of a reply.
   func firstIssueField(_ response: MockBackend.Response) throws -> String? {
      try decode(Components.Schemas._Error.self, response).error.details?.first?.field
   }

   /// Creates a post and returns it, failing when the backend refuses it.
   func create(_ input: PostCreate, key: String = "key-\(UUID().uuidString)") async throws -> Post {
      let response = try await call("createPost", path: "/v1/me/posts", headers: ["idempotency-key": key], json: input)
      return try decode(Post.self, response)
   }

   /// Creates an upload ticket, PUTs `file` and completes it, returning the media item.
   func upload(file: URL, contentType: UploadCreate.ContentTypePayload = .imageJpeg) async throws -> MediaItem {
      let ticketResponse = try await call(
         "createUpload", path: "/v1/me/uploads",
         json: UploadCreate(fileName: file.lastPathComponent, contentType: contentType, byteSize: 1))
      let ticket = try decode(UploadTicket.self, ticketResponse)
      try await backend.receiveUpload(id: ticket.uploadId, from: file)
      let completed = try await call("completeUpload", path: "/v1/me/uploads/\(ticket.uploadId)/complete", json: UploadComplete())
      return try decode(MediaItem.self, completed)
   }
}
