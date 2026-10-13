/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// An in-process fake of the Site API v2 operations the app uses, for demo mode (App
/// Review signs in with it) and tests, which must never reach production. It follows
/// the backend's documented behaviour: `/me`, the `blogPost`, `blogTag`, `blog`,
/// `author`, `media` and `site` tables with the query filter syntax, the authoring
/// rules of `BlogAuthoringCustomizer` (blank title, name, short name and slug derived,
/// slug unique per blog), media links copied from the media record, scheduled
/// publishing, presigned uploads and both error envelopes.
///
/// State is kept in the generated record types and persisted as JSON when a directory
/// is given, so the app and the Share Extension see the same posts.
public actor MockBackend {
   /// A reply ready to hand back through `MockTransport`.
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
      /// After this instant the presigned PUT is refused.
      var expiresAt: Date
      /// The file received through the presigned PUT, if any.
      var receivedFile: String?
      /// Set once the upload has been completed.
      var mediaId: Int?
   }

   /// Everything the fake knows, persisted as one JSON document.
   struct State: Codable {
      /// The id the next created record receives (posts, tags, media, links).
      var nextId = 1_000
      /// All posts, with their tag and media links nested.
      var posts: [Components.Schemas.BlogPost] = []
      /// All tags of all blogs.
      var tags: [Components.Schemas.BlogTag] = []
      /// Media records.
      var media: [Components.Schemas.Media] = []
      /// Upload tickets by upload id.
      var uploads: [String: StoredUpload] = [:]

      /// Returns a fresh id.
      mutating func takeId() -> Int {
         defer { nextId += 1 }
         return nextId
      }
   }

   /// HTTP status codes the fake answers with.
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
      /// 415 Unsupported Media Type.
      static let unsupportedMediaType = 415
      /// 422 Unprocessable Content.
      static let unprocessable = 422
   }

   /// Scheme of the media URLs; resolved to files when served.
   static let mediaScheme = "mock-media"
   /// Name of the persisted state document inside the fake's directory.
   static let stateFileName = "state.json"
   /// The site posts and media belong to.
   static let siteId = 1
   /// The public website the fake's `siteUrl` values point at.
   static let websiteBase = "https://www.kof22.com"

   /// The current state; read fresh from disk before every request.
   var state = State()
   /// Where state and media are kept, or nil for an in-memory fake.
   let directory: URL?
   /// The clock, injected so tests can control expiry and scheduling.
   public nonisolated let now: @Sendable () -> Date
   /// Artificial delay before each request, so the UI can show progress.
   private let latency: Duration
   /// When true every request fails like a device with no connection.
   public var simulateOffline = false

   /// Opens the fake, restoring saved state from `directory` when there is any and
   /// seeding sample posts and tags otherwise.
   public init(directory: URL?, latency: Duration = .zero, now: @escaping @Sendable () -> Date = { .now }) {
      self.directory = directory
      self.latency = latency
      self.now = now
      state = Self.loadState(from: directory) ?? Self.seed(now: now())
   }

   /// Turns the simulated loss of connectivity on or off.
   public func setSimulateOffline(_ value: Bool) { simulateOffline = value }

   /// Forgets every post and upload and starts again from the seed data.
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

   /// Handles one request routed by its operation id; record ids and the upload id are
   /// read from the path.
   public func handle(operation: String, path: String, query: [String: String], body: Data?) async throws -> Response {
      if latency > .zero { try await Task.sleep(for: latency) }
      if simulateOffline { throw URLError(.notConnectedToInternet) }
      reload()
      promoteScheduled()
      defer { save() }
      let last = String(path.split(separator: "/").last ?? "")
      switch operation {
      case "me", "versions", "createUpload", "completeUpload", "linkPreview": return try handleProcess(operation, last: last, body: body)
      case "queryBlogPost": return try page(filter(state.posts.map(listed), query), query)
      case "createBlogPost": return try createPost(body)
      case "updateBlogPost": return try updatePost(Int(last), body: body)
      case "deleteBlogPost": return try deletePost(Int(last))
      case "createBlogTag": return try createTag(body)
      default: return try handleTable(operation, id: Int(last), query: query)
      }
   }

   /// The process endpoints; `last` is the final path segment (the upload id).
   private func handleProcess(_ operation: String, last: String, body: Data?) throws -> Response {
      switch operation {
      case "me": try json(Status.okay, Self.demoCaller)
      case "versions": try json(Status.okay, Self.versions)
      case "createUpload": try createUpload(body)
      case "completeUpload": try completeUpload(last, body: body)
      default: try linkPreview(body)
      }
   }

   /// The read-only table operations: queries and reads by id.
   private func handleTable(_ operation: String, id: Int?, query: [String: String]) throws -> Response {
      switch operation {
      case "getBlogPost": try record(state.posts.first { $0.id == id })
      case "queryBlogTag": try page(filter(state.tags, query), query)
      case "queryBlog": try page(filter(Self.blogs, query), query)
      case "getBlog": try record(Self.blogs.first { $0.id == id })
      case "queryAuthor": try page(filter(Self.authors, query), query)
      case "getAuthor": try record(Self.authors.first { $0.id == id })
      case "getMedia": try record(state.media.first { $0.id == id })
      case "querySite": try page(filter(Self.sites, query), query)
      case "getSite": try record(Self.sites.first { $0.id == id })
      default: try tableError(Status.notFound, "No such endpoint: \(operation)")
      }
   }

   /// A post as a query returns it: without its nested tag and media lists.
   func listed(_ post: Components.Schemas.BlogPost) -> Components.Schemas.BlogPost {
      var copy = post
      copy.tags = nil
      copy.media = nil
      return copy
   }

   /// Resolves the `mock-media:` URLs stored in posts to files on disk.
   public nonisolated func fileURL(forMockMedia url: String, directory base: URL) -> URL? {
      guard url.hasPrefix(Self.mediaScheme + ":") else { return nil }
      return base.appending(path: "media").appending(path: String(url.dropFirst(Self.mediaScheme.count + 1)))
   }

   ///////////////
   // Responses //
   ///////////////

   /// Encodes like the backend: ISO 8601 dates with milliseconds, sorted keys.
   static let encoder: JSONEncoder = {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .custom { date, encoder in
         var container = encoder.singleValueContainer()
         try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
      }
      encoder.outputFormatting = [.sortedKeys]
      return encoder
   }()

   /// Decodes request bodies and the saved state.
   static let decoder = SiteService.decoder

   /// Decodes a request body, or nil when it is missing or malformed (answered with 400).
   static func decodeBody<Body: Decodable>(_ type: Body.Type, from body: Data?) -> Body? {
      /////////////////////////////////////////////////////
      // The caller turns nil into a 400 for the client. //
      /////////////////////////////////////////////////////
      return body.flatMap { try? decoder.decode(type, from: $0) }
   }

   /// A JSON response.
   func json(_ status: Int, _ value: some Encodable) throws -> Response {
      Response(status: status, body: try Self.encoder.encode(value), headers: ["Content-Type": "application/json"])
   }

   /// One record, or the table 404.
   func record(_ value: (some Encodable)?) throws -> Response {
      guard let value else { return try tableError(Status.notFound, "The requested record was not found.") }
      return try json(Status.okay, value)
   }

   /// A table operation's error: `{"error":"message"}`.
   func tableError(_ status: Int, _ message: String) throws -> Response {
      try json(status, ["error": message])
   }

   /// A process error: `{"error":{"code","message","status","details"}}`.
   func problem(_ status: Int, _ code: String, _ message: String) throws -> Response {
      let envelope: [String: [String: String]] = ["error": ["code": code, "message": message, "status": String(status)]]
      return try json(status, envelope)
   }

   /// A query page `{"pageNo","pageSize","count","records"}`.
   func page<Record: Codable>(_ records: [Record], _ query: [String: String]) throws -> Response {
      let pageNo = max(Int(query["pageNo"] ?? "") ?? 1, 1)
      let pageSize = min(max(Int(query["pageSize"] ?? "") ?? Self.defaultPageSize, 1), Self.maximumPageSize)
      let slice = Array(records.dropFirst((pageNo - 1) * pageSize).prefix(pageSize))
      return try json(Status.okay, QueryEnvelope(records: slice, count: records.count, pageNo: pageNo, pageSize: pageSize))
   }

   /// Records per page when a query names none.
   static let defaultPageSize = 50
   /// Largest page.
   static let maximumPageSize = 1_000

   /////////////////
   // Persistence //
   /////////////////

   /// Reads the saved state document. A missing file is the normal first run; a file
   /// that cannot be read is logged and the caller seeds a fresh state.
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
