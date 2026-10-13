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
      _ operation: String, path: String = "/", query: [String: String] = [:], json: (any Encodable & Sendable)? = nil
   ) async throws
      -> MockBackend.Response
   {
      let body = try json.map { try MockBackend.encoder.encode($0) }
      return try await backend.handle(operation: operation, path: path, query: query, body: body)
   }

   /// Sends one request with a raw body.
   func call(_ operation: String, path: String = "/", raw: Data?) async throws -> MockBackend.Response {
      try await backend.handle(operation: operation, path: path, query: [:], body: raw)
   }

   /// Decodes a reply body.
   func decode<Value: Decodable>(_ type: Value.Type, _ response: MockBackend.Response) throws -> Value {
      try MockBackend.decoder.decode(type, from: response.body ?? Data())
   }

   /// The reply as the client's error.
   func error(_ response: MockBackend.Response) -> APIError {
      APIError.decode(status: response.status, data: response.body ?? Data(), retryAfter: nil, etag: nil)
   }

   /// Inserts a post record and reads it back.
   func create(_ record: Components.Schemas.BlogPost) async throws -> Components.Schemas.BlogPost {
      let response = try await call("createBlogPost", path: "/v2/blogPost/", json: record)
      guard response.status == MockBackend.Status.created else { throw error(response) }
      let id = try decode([String: Int].self, response)["id"] ?? 0
      return try decode(Components.Schemas.BlogPost.self, try await call("getBlogPost", path: "/v2/blogPost/\(id)"))
   }

   /// A minimal valid post record for the default blog.
   static func record(_ body: String, title: String? = nil, published: Bool = true) -> Components.Schemas.BlogPost {
      Components.Schemas.BlogPost(
         authorId: MockBackend.ownerAuthorID, blogId: MockBackend.quickBitsID, content: body, isFeatured: false, isPublished: published,
         readTime: 1, title: title, viewCount: 0)
   }

   /// Creates an upload ticket, PUTs `file` and completes it, returning the media item.
   func upload(file: URL, contentType: String = "image/jpeg", altText: String? = nil) async throws -> MediaItem {
      let ticketResponse = try await call(
         "createUpload", path: "/v2/media/createUpload", json: UploadRequest(fileName: file.lastPathComponent, contentType: contentType, byteSize: 1))
      let ticket = try decode(UploadTicket.self, ticketResponse)
      try await backend.receiveUpload(id: ticket.uploadId, from: file)
      let completed = try await call(
         "completeUpload", path: "/v2/media/completeUpload/\(ticket.uploadId)",
         json: UploadCompletion(altText: altText, caption: nil, keepLocation: false))
      return try decode(MediaItem.self, completed)
   }
}

/// A session with fixed tokens: `token` until a 401, then `fresh`. Counts refreshes.
final class StaticAuth: SessionAuthenticating, @unchecked Sendable {
   /// Guards `refreshCount`.
   private let lock = NSLock()
   /// The first token.
   let token: String
   /// The token after a refresh.
   let fresh: String
   /// Refreshes so far.
   private var refreshed = 0

   /// Creates a session handing out `token`, then `fresh` after a refresh.
   init(token: String = "token-1", fresh: String = "token-2") {
      self.token = token
      self.fresh = fresh
   }

   /// How many times a refresh was forced.
   var refreshCount: Int { lock.withLock { refreshed } }

   /// Always signed in.
   var isSignedIn: Bool { true }

   /// The current token.
   func accessToken() async throws -> String { lock.withLock { refreshed == 0 ? token : fresh } }

   /// Switches to `fresh`.
   func forceRefresh(rejected token: String) async throws -> String {
      lock.withLock {
         refreshed += 1
         return fresh
      }
   }

   /// Nothing to do.
   func signIn(using authenticator: any WebAuthenticator) async throws {}

   /// Nothing to do.
   func signOut() async {}
}

/// A service over `transport` with a fixed-token session and an uploader that refuses.
func fixtureService(_ transport: any ClientTransport, auth: StaticAuth = StaticAuth(), cache: ReadCache = ReadCache()) -> SiteService {
   SiteService(serverURL: URL(literal: "https://api.kof22.com"), transport: transport, auth: auth, uploader: RefusingUploader(), cache: cache)
}

/// An uploader that must never be reached.
struct RefusingUploader: UploadPerformer {
   /// Always fails.
   func put(fileURL: URL, to url: URL, headers: [String: String]) async throws { throw RigError.deliberate }
}
