/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// An in-process stand-in for the Site API v1 authoring endpoints, following the
/// behaviour documented in Website-Backend (`AuthoringService`, `MediaUploadService`,
/// `IdempotencyStore`): validation limits, idempotent replays, ETag/If-Match,
/// scheduled publishing, presigned uploads and the error envelope.
///
/// It works on the generated schema types, so a spec change that the mock does not
/// follow fails to compile. State is persisted as JSON when a directory is given.
/// The endpoint handlers live in extensions grouped by area (posts, uploads, tags and
/// links, responses, text helpers) so each file stays small enough to review.
public actor MockBackend {
   /// A reply ready to hand back to the generated client through `MockTransport`.
   public struct Response: Sendable {
      /// The HTTP status code.
      public var status: Int
      /// The encoded JSON body, or nil for responses without content such as 204.
      public var body: Data?
      /// Response headers keyed by their wire name.
      public var headers: [String: String] = [:]
   }

   /// A presigned upload ticket and what has happened to it so far.
   struct StoredUpload: Codable {
      /// The file name the client announced.
      var fileName: String
      /// The MIME type the client announced; decides the stored file extension.
      var contentType: String
      /// The size the client announced.
      var byteSize: Int64
      /// After this instant the presigned PUT is refused.
      var expiresAt: Date
      /// The file received through the presigned PUT, if any.
      var receivedFile: String?
      /// Set once the upload has been completed, so a repeat complete replays it.
      var mediaId: Int64?
   }

   /// A completed photo in the media library.
   struct StoredMedia: Codable {
      /// The file name inside the media directory.
      var file: String
      /// The MIME type of the stored file.
      var mimeType: String
      /// Pixel width read from the image, when available.
      var width: Int?
      /// Pixel height read from the image, when available.
      var height: Int?
      /// Alt text given when the upload was completed.
      var altText: String?
   }

   /// A recorded response for an idempotency key, replayed for the same body.
   struct Replay: Codable {
      /// SHA-256 of the request body the key was first used with.
      var bodyHash: String
      /// The status of the original response.
      var status: Int
      /// The body of the original response.
      var body: Data?
      /// The headers of the original response.
      var headers: [String: String]
   }

   /// Everything the mock knows, persisted as one JSON document.
   struct State: Codable {
      /// The id the next created post receives.
      var nextPostId: Int64 = 1
      /// The id the next completed upload receives.
      var nextMediaId: Int64 = 1
      /// The id the next new tag receives; seeded tags start here.
      var nextTagId: Int64 = 100
      /// All posts, in creation order.
      var posts: [Post] = []
      /// All tags of all blogs.
      var tags: [AuthoringTag] = []
      /// Upload tickets by upload id.
      var uploads: [String: StoredUpload] = [:]
      /// Completed media by media id.
      var media: [Int64: StoredMedia] = [:]
      /// Idempotent replays keyed by `operation:key`.
      var replays: [String: Replay] = [:]
   }

   /// HTTP status codes the mock answers with.
   enum Status {
      /// 200 OK.
      static let okay = 200
      /// 201 Created.
      static let created = 201
      /// 204 No Content.
      static let noContent = 204
      /// 400 Bad Request.
      static let badRequest = 400
      /// 403 Forbidden, as S3 answers an unknown or expired presigned URL.
      static let forbidden = 403
      /// 404 Not Found.
      static let notFound = 404
      /// 409 Conflict.
      static let conflict = 409
      /// 412 Precondition Failed.
      static let preconditionFailed = 412
      /// 413 Payload Too Large.
      static let payloadTooLarge = 413
      /// 415 Unsupported Media Type.
      static let unsupportedMediaType = 415
      /// 422 Unprocessable Content.
      static let unprocessable = 422
      /// 428 Precondition Required.
      static let preconditionRequired = 428
      /// Statuses that count as success and are recorded for idempotent replay.
      static let success = 200..<300
   }

   /// Id of the second seeded blog.
   static let deepThoughtsID: Int64 = 2

   /// The blogs the signed-in author can post to.
   public static let blogs: [BlogRef] = [
      BlogRef(id: 1, slug: "quick-bits", name: "Quick Bits", isDefault: true),
      BlogRef(id: deepThoughtsID, slug: "deep-thoughts", name: "Deep Thoughts", isDefault: false),
   ]

   /// The blog used when a request names none.
   static let defaultBlog = "quick-bits"

   /// Scheme of the media URLs stored in posts; resolved to files when served.
   static let mediaScheme = "mock-media"

   /// Name of the persisted state document inside the mock directory.
   static let stateFileName = "state.json"

   /// The current state; read fresh from disk before every request.
   var state = State()
   /// Where state and media are kept, or nil for an in-memory mock.
   let directory: URL?
   /// The clock, injected so tests can control expiry and scheduling.
   let now: @Sendable () -> Date
   /// Artificial delay before each request, so the UI can show progress.
   private let latency: Duration
   /// When true every request fails like a device with no connection.
   public var simulateOffline = false

   /// Opens the mock, restoring saved state from `directory` when there is any and
   /// seeding sample posts and tags otherwise.
   public init(directory: URL?, latency: Duration = .zero, now: @escaping @Sendable () -> Date = { .now }) {
      self.directory = directory
      self.latency = latency
      self.now = now
      state = Self.loadState(from: directory) ?? Self.seed(now: now())
   }

   /// Turns the simulated loss of connectivity on or off.
   public func setSimulateOffline(_ value: Bool) { simulateOffline = value }

   /// Forgets every post, upload and replay and starts again from the seed data.
   public func reset() {
      state = Self.seed(now: now())
      if let directory {
         ////////////////////////////////////////////////////////////
         // The media folder may not exist yet; nothing to delete. //
         ////////////////////////////////////////////////////////////
         try? FileManager.default.removeItem(at: directory.appending(path: "media"))
      }
      save()
   }

   /// Handles one request routed by its OpenAPI operation id. Path parameters
   /// (post id, upload id) are read from the path segments.
   public func handle(
      operation: String, path: String, query: [String: String], headers: [String: String], body: Data?
   ) async throws -> Response {
      if latency > .zero { try await Task.sleep(for: latency) }
      if simulateOffline { throw URLError(.notConnectedToInternet) }
      reload()
      promoteScheduled()
      defer { save() }
      let segments = path.split(separator: "/").map(String.init)
      switch operation {
      case "getApiVersions": return try json(Status.okay, versions())
      case "getMe": return try json(Status.okay, me())
      case "listMyTags": return try listTags(query)
      case "getLinkPreview": return try linkPreview(body)
      case "createUpload":
         return try idempotent("createUpload", headers: headers, body: body) { try createUpload(body) }
      case "completeUpload": return try completeUpload(segments.dropLast().last ?? "", body: body)
      default: return try handlePostOperation(operation, segments: segments, query: query, headers: headers, body: body)
      }
   }

   /// Routes the post endpoints, which share the post-id path parameter.
   private func handlePostOperation(
      _ operation: String, segments: [String], query: [String: String], headers: [String: String], body: Data?
   ) throws -> Response {
      switch operation {
      case "listMyPosts": return try listPosts(query)
      case "createPost":
         return try idempotent("createPost", headers: headers, body: body) { try createPost(body) }
      case "getMyPost": return try withPost(segments) { try json(Status.okay, $0, etag: $0.version) }
      case "updatePost": return try updatePost(postID(segments), headers: headers, body: body)
      case "deletePost": return try deletePost(postID(segments), headers: headers)
      default: return try problem(Status.notFound, "not_found", "No such endpoint")
      }
   }

   /// Resolves the `mock-media:` URLs stored in posts to files on disk.
   public nonisolated func fileURL(forMockMedia url: String, directory base: URL) -> URL? {
      guard url.hasPrefix(Self.mediaScheme + ":") else { return nil }
      return base.appending(path: "media").appending(path: String(url.dropFirst(Self.mediaScheme.count + 1)))
   }

   // MARK: - Persistence

   /// Reads the saved state document. A missing file is the normal first run; a file
   /// that cannot be read or decoded is logged and the caller falls back to a fresh
   /// state rather than failing every request.
   static func loadState(from directory: URL?) -> State? {
      guard let directory else { return nil }
      let file = directory.appending(path: stateFileName)
      guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
      do {
         return try decoder.decode(State.self, from: Data(contentsOf: file))
      }
      catch {
         Log.api.warning("Mock backend state could not be read: \(error.localizedDescription, privacy: .public)")
         return nil
      }
   }

   /// The app and the Share Extension share the state file; read it fresh so one
   /// process never overwrites the other's posts with a stale copy.
   func reload() {
      if let saved = Self.loadState(from: directory) { state = saved }
   }

   /// Writes the state document atomically. A failure is logged and the in-memory
   /// state stays authoritative for this process.
   func save() {
      guard let directory else { return }
      do {
         try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
         try Self.encoder.encode(state).write(to: directory.appending(path: Self.stateFileName), options: .atomic)
      }
      catch {
         Log.api.warning("Mock backend state could not be saved: \(error.localizedDescription, privacy: .public)")
      }
   }
}
