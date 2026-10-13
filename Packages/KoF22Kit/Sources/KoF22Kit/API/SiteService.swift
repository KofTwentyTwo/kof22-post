/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// PUTs photo bytes to a presigned upload URL.
public protocol UploadPerformer: Sendable {
   /// Uploads the file at `fileURL` to `url` with the headers the upload ticket requires.
   func put(fileURL: URL, to url: URL, headers: [String: String]) async throws
}

/// Uploads photos straight to object storage with `URLSession`. The presigned URL is not
/// part of the Site API, so this bypasses the generated client and its middlewares.
public struct URLSessionUploadPerformer: UploadPerformer {
   /// Full-resolution photos on a slow connection need far longer than an API call.
   static let uploadTimeout: TimeInterval = 300

   /// How much of a failed upload's response body ends up in the error message.
   static let errorBodyPrefixBytes = 300

   /// Status codes that mean the storage service kept the bytes.
   static let successStatusCodes = 200..<300

   /// The session that performs the upload.
   let session: URLSession

   /// Creates a performer on `session`; tests pass a session with a stub protocol.
   public init(session: URLSession = .shared) { self.session = session }

   /// Uploads the file and throws `APIError` with code `upload_put_failed` for a non-2xx
   /// response, carrying the start of the storage service's response as the message.
   public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.timeoutInterval = Self.uploadTimeout
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      let (data, response) = try await session.upload(for: request, fromFile: fileURL)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      guard Self.successStatusCodes.contains(http.statusCode) else {
         throw APIError(
            status: http.statusCode, code: "upload_put_failed",
            message: String(data: data.prefix(Self.errorBodyPrefixBytes), encoding: .utf8) ?? "Upload failed")
      }
   }
}

/// The hand-written layer over Site API v2: auth, error mapping, id resolution and the
/// safety rules v2 leaves to the client. Everything the app sends goes through here.
///
/// Site API v2 has no idempotency keys or ETags, so:
///   - a create first looks for a post this client already created with the same blog,
///     author, slug family and body (a retry after a lost response) and returns it;
///     otherwise it picks a slug no other post of the blog uses (the database keeps
///     `(slug, blogId)` unique);
///   - an update or delete first reads the post and stops with 412
///     `precondition_failed` when its `modifyDate` differs from the version the edit
///     started from.
public struct SiteService: Sendable {
   /// Fail fast instead of waiting for connectivity: the outbox owns retries.
   static let requestTimeout: TimeInterval = 30

   /// Page size used when the caller does not ask for one.
   public static let defaultPageSize = 20

   /// Largest page the API serves.
   static let maximumPageSize = 1_000

   /// Status of a stale edit.
   static let preconditionFailedStatus = 412
   /// Status of a request the client can tell is invalid (an unknown blog).
   static let unprocessableStatus = 422
   /// Status of an account without an author profile.
   static let forbiddenStatus = 403
   /// Status of a server answer that lacks what the API promises.
   static let badGatewayStatus = 502

   /// The edit version that skips the conflict check.
   public static let anyVersion = "*"

   /// The generated client with the middlewares installed.
   let client: Client
   /// The process endpoints the spec leaves untyped, over the same transport and
   /// middlewares.
   let processes: ProcessClient
   /// Sends photo bytes to presigned URLs.
   let uploader: any UploadPerformer
   /// Lookups that rarely change (the caller, blogs, tag names), shared by copies.
   let directory: Directory
   /// Published content for the site browser, cached briefly.
   public let reads: PublicReadService
   /// The clock, for publish dates; injectable for tests.
   let now: @Sendable () -> Date

   /// Builds the service on any transport. The middleware order matters: errors are
   /// mapped outermost so the auth middleware still sees the raw 401, and the capture
   /// only keeps successful bodies.
   public init(
      serverURL: URL, transport: any ClientTransport, auth: any SessionAuthenticating, uploader: any UploadPerformer,
      cache: ReadCache = ReadCache(), now: @escaping @Sendable () -> Date = { .now }
   ) {
      let middlewares: [any ClientMiddleware] = [
         ErrorEnvelopeMiddleware(), ResponseCaptureMiddleware(), ExplicitNullMiddleware(), AuthMiddleware(auth: auth),
      ]
      let client = Client(serverURL: serverURL, configuration: Self.configuration, transport: transport, middlewares: middlewares)
      self.client = client
      self.processes = ProcessClient(serverURL: serverURL, transport: transport, middlewares: middlewares)
      self.uploader = uploader
      self.directory = Directory()
      self.reads = PublicReadService(client: client, cache: cache)
      self.now = now
   }

   /// Client settings shared by every generated client in the app: dates with or
   /// without fractional seconds.
   static let configuration = Configuration(dateTranscoder: SiteDateTranscoder())

   /// A `URLSession` transport that fails fast instead of waiting for connectivity.
   static func liveTransport() -> URLSessionTransport {
      let configuration = URLSessionConfiguration.default
      configuration.waitsForConnectivity = false
      configuration.timeoutIntervalForRequest = Self.requestTimeout
      return URLSessionTransport(configuration: .init(session: URLSession(configuration: configuration)))
   }

   /// The service for the real Site API over `URLSession`. `uploader` sends photo bytes;
   /// the app passes a background-session uploader so uploads survive suspension.
   public static func live(
      config: AppConfig = .production, auth: any SessionAuthenticating, uploader: any UploadPerformer = URLSessionUploadPerformer()
   ) -> Self {
      Self(serverURL: config.apiBaseURL, transport: liveTransport(), auth: auth, uploader: uploader)
   }

   /// The service backed by the in-process fake of Site API v2 (demo mode and tests).
   public static func mock(backend: MockBackend, auth: any SessionAuthenticating) -> Self {
      Self(
         serverURL: AppConfig.mockAPIBaseURL, transport: MockTransport(backend: backend), auth: auth,
         uploader: MockUploadPerformer(backend: backend), now: { backend.now() }
      )
   }

   /// Unwraps errors thrown by middlewares out of the generator's `ClientError`.
   func call<T>(_ body: () async throws -> T) async throws -> T {
      try await unwrappingClientErrors(body)
   }

   //////////////////////
   // Caller and blogs //
   //////////////////////

   /// The signed-in user, their author profile, the blogs and the photo rules. Each
   /// call asks the server and refreshes the shared copy.
   public func me() async throws -> Me {
      let caller: Me = try await processes.send(.get, "/v2/me", operation: ProcessClient.Operation.caller)
      await directory.keep(caller)
      return caller
   }

   /// The API versions the server supports.
   public func versions() async throws -> APIVersions {
      try await processes.send(.get, "/versions.json", operation: ProcessClient.Operation.versions)
   }

   /// The caller from the shared copy, asking the server only the first time.
   func cachedMe() async throws -> Me {
      if let caller = await directory.caller { return caller }
      return try await me()
   }

   /// The blog for `slug` (the default blog when nil), from the caller's blogs.
   func blog(_ slug: String?) async throws -> BlogRef {
      let caller = try await cachedMe()
      let wanted = slug ?? caller.defaultBlog
      guard let blog = caller.blogs.first(where: { $0.slug == wanted }) else {
         throw APIError(status: Self.unprocessableStatus, code: "validation_failed", message: "Unknown blog", details: [.init(field: "blog", issue: "unknown blog \(wanted)")])
      }
      return blog
   }

   /// Active authors, by name; the composer's author picker lists them.
   public func authors() async throws -> [AuthorRef] {
      let records: [Components.Schemas.Author] = try await query {
         _ = try await client.queryAuthor(query: .init(pageSize: Self.maximumPageSize, orderBy: "name", isActive: ["true"])).ok
      }
      return records.compactMap { record in
         guard let id = record.id, let name = record.name else { return nil }
         return AuthorRef(id: Int64(id), name: name, slug: record.slug)
      }
   }

   /// The author a post is written as: `authorId` when given, else the caller's own.
   func authorId(_ authorId: Int64?) async throws -> Int64 {
      if let authorId { return authorId }
      guard let author = try await cachedMe().author else {
         throw APIError(status: Self.forbiddenStatus, code: "forbidden", message: "No active author profile is linked to this account")
      }
      return author.id
   }

   ///////////
   // Posts //
   ///////////

   /// One page of an author's posts (the caller's when nil), newest change first,
   /// optionally only one status. Pages start at 1.
   public func myPosts(
      authorId: Int64? = nil, status: PostStatus? = nil, page: Int = 1, limit: Int = Self.defaultPageSize
   ) async throws -> PostPage {
      let author = try await self.authorId(authorId)
      let published: [String]? = status.map { [$0 == .published ? "true" : "false"] }
      let records: [BlogPostRecord] = try await query {
         _ = try await client.queryBlogPost(
            query: .init(
               pageNo: page, pageSize: limit, orderBy: "modifyDate DESC, id DESC", authorId: [String(author)], isPublished: published)
         ).ok
      }
      var posts = try await posts(records)
      if let status { posts = posts.filter { $0.status == status } }
      return PostPage(items: posts, nextPage: records.count == limit ? page + 1 : nil)
   }

   /// One post by id, with its tags and photos.
   public func post(id: Int64) async throws -> Post {
      let record = try await record(id: id)
      return try await posts([record])[0]
   }

   /// The raw record of one post.
   func record(id: Int64) async throws -> BlogPostRecord {
      try await call { try await client.getBlogPost(path: .init(id: Int(id))).ok.body.json }
   }

   /// Records as posts: blog slugs from the caller's blogs, tag names looked up once.
   func posts(_ records: [BlogPostRecord]) async throws -> [Post] {
      let caller = try await cachedMe()
      let slugs = Dictionary(caller.blogs.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
      let tagIds = Set(records.flatMap { $0.tags ?? [] }.compactMap { $0.blogTagId.map(Int64.init) })
      let names = try await tagNames(tagIds)
      return records.map { APIMapping.post($0, blogSlugs: slugs, tagNames: names) }
   }

   /// Creates a post and returns it as stored. A retry after a lost response finds the
   /// post the first attempt created instead of making a second one.
   public func createPost(_ draft: PostDraft) async throws -> Post {
      let blog = try await blog(draft.blog)
      let author = try await authorId(draft.authorId)
      let family = try await slugFamily(blogId: blog.id, base: draft.slug)
      if let existing = family.first(where: { $0.authorId.map(Int64.init) == author && $0.content == draft.body }), let id = existing.id {
         Log.api.info("Create matched post \(id, privacy: .public) from an earlier attempt")
         return try await post(id: Int64(id))
      }
      let slug = PostText.uniqueSlug(draft.slug, taken: Set(family.compactMap(\.slug)))
      let resolved = APIMapping.Resolved(
         blogId: blog.id, authorId: author, slug: slug, tagIds: try await tagIds(draft.tags, blogId: blog.id),
         link: await preview(draft.linkURL), publishDate: now())
      var record = APIMapping.record(draft, resolved)
      record.viewCount = 0
      let created = try await call { try await client.createBlogPost(body: .json(record)).created.body.json }
      guard let id = created.id else { throw APIError(status: Self.badGatewayStatus, code: "bad_response", message: "The server did not return the new post's id") }
      return try await post(id: Int64(id))
   }

   /// Replaces a post with `draft` (full state: emptied optional fields are cleared).
   /// `ifMatch` is the post's `version` when the edit started, or `anyVersion`.
   public func updatePost(id: Int64, _ draft: PostDraft, ifMatch: String) async throws -> Post {
      let current = try await record(id: id)
      try Self.requireVersion(ifMatch, current: current)
      let blog = try await blog(draft.blog)
      var slug = draft.slug
      if slug != current.slug || current.blogId.map(Int64.init) != blog.id {
         let taken = try await slugFamily(blogId: blog.id, base: draft.slug).filter { $0.id.map(Int64.init) != id }.compactMap(\.slug)
         slug = PostText.uniqueSlug(draft.slug, taken: Set(taken))
      }
      let link =
         draft.linkURL == current.linkUrl
         ? draft.linkURL.map { LinkPreview(url: $0, title: current.linkTitle, description: current.linkDescription, imageUrl: current.linkImageUrl) }
         : await preview(draft.linkURL)
      let alreadyLive = current.isPublished == true ? current.publishDate : nil
      let resolved = APIMapping.Resolved(
         blogId: blog.id, authorId: try await authorId(draft.authorId ?? current.authorId.map(Int64.init)), slug: slug,
         tagIds: try await tagIds(draft.tags, blogId: blog.id), link: link, publishDate: alreadyLive ?? now())
      let record = APIMapping.record(draft, resolved)
      try await ExplicitNullMiddleware.$fields.withValue(APIMapping.clearedFields(record)) {
         _ = try await call { try await client.updateBlogPost(path: .init(id: Int(id)), body: .json(record)).noContent }
      }
      return try await post(id: id)
   }

   /// Deletes a post; with `ifMatch`, only when it has not changed since then.
   public func deletePost(id: Int64, ifMatch: String?) async throws {
      if let ifMatch, ifMatch != Self.anyVersion {
         try Self.requireVersion(ifMatch, current: try await record(id: id))
      }
      _ = try await call { try await client.deleteBlogPost(path: .init(id: Int(id))).noContent }
   }

   /// Throws 412 `precondition_failed` when `current` changed after `ifMatch`.
   static func requireVersion(_ ifMatch: String, current: BlogPostRecord) throws {
      guard ifMatch != anyVersion, ifMatch != APIMapping.version(of: current.modifyDate) else { return }
      throw APIError(status: preconditionFailedStatus, code: "precondition_failed", message: "The post changed on the server since it was loaded.")
   }

   /// The posts of a blog whose slug is `base` or starts with it.
   func slugFamily(blogId: Int64, base: String) async throws -> [BlogPostRecord] {
      try await query {
         _ = try await client.queryBlogPost(
            query: .init(pageSize: Self.maximumPageSize, blogId: [String(blogId)], slug: ["LIKE \(base)%"])
         ).ok
      }
   }

   ///////////////
   // Internals //
   ///////////////

   /// Runs a query call and decodes its records from the raw body: the generated
   /// `*SearchResult` types drop `records` (the spec puts it beside an `allOf`).
   func query<Record: Codable & Sendable>(_ call: () async throws -> Void) async throws -> [Record] {
      let capture = ResponseCapture()
      try await ResponseCapture.$current.withValue(capture) {
         try await self.call(call)
      }
      return try Self.decoder.decode(QueryEnvelope<Record>.self, from: capture.data).records ?? []
   }

   /// Decodes API JSON with the same date rules as the generated client.
   static let decoder: JSONDecoder = {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .custom { decoder in
         let container = try decoder.singleValueContainer()
         return try SiteDateTranscoder().decode(try container.decode(String.self))
      }
      return decoder
   }()
}

/// Lookups shared by every copy of one `SiteService`: the caller and tag names.
actor Directory {
   /// The caller, after the first `/me`.
   private(set) var caller: Me?
   /// Tag names by id.
   private(set) var tagNames: [Int64: String] = [:]

   /// Keeps the caller.
   func keep(_ caller: Me) { self.caller = caller }

   /// Keeps a tag name.
   func keepTag(id: Int64, name: String) { tagNames[id] = name }
}
