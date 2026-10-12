/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import OpenAPIRuntime

/// Anonymous reads of published content (`/v1/blog`, `/v1/post`, `/v1/tag`) through the
/// generated client. Requests never carry credentials: this client has no auth
/// middleware at all. Answers are kept in a `ReadCache` so screens do not refetch on every
/// appearance; pass `forceRefresh` for pull to refresh.
public struct PublicReadService: Sendable {
   /// Posts per page when the caller does not ask for a size.
   public static let defaultPageSize = 20
   /// The largest page the spec allows (`pageSize` 1 to 1000), used to list a blog's
   /// blogs and tags in one request.
   public static let maximumPageSize = 1_000
   /// The first page number; the spec counts pages from 1.
   public static let firstPage = 1
   /// Newest published first, ties broken by id so paging is stable.
   static let newestFirst = "publishDate DESC, id DESC"
   /// Blogs in creation order, so the original (default) blog comes first.
   static let blogOrder = "id ASC"
   /// Tags alphabetically.
   static let tagOrder = "name ASC"

   /// The generated client: error mapping and body capture only, never auth.
   let client: Client
   /// Recent answers, shared by every copy of this service.
   public let cache: ReadCache

   /// Builds the service on any transport.
   public init(serverURL: URL, transport: any ClientTransport, cache: ReadCache = ReadCache()) {
      self.client = Client(
         serverURL: serverURL,
         configuration: SiteService.configuration,
         transport: transport,
         middlewares: [ErrorEnvelopeMiddleware(), ResponseCaptureMiddleware()]
      )
      self.cache = cache
   }

   /// The service for the real Site API over `URLSession`.
   public static func live(config: AppConfig = .production, cache: ReadCache = ReadCache()) -> Self {
      Self(serverURL: config.apiBaseURL, transport: SiteService.liveTransport(), cache: cache)
   }

   /// The service answered by the in-process mock backend.
   public static func mock(backend: MockBackend, cache: ReadCache = ReadCache()) -> Self {
      Self(serverURL: AppConfig.mockAPIBaseURL, transport: MockTransport(backend: backend), cache: cache)
   }

   /// All blogs, oldest first.
   public func blogs(forceRefresh: Bool = false) async throws -> [SiteBlog] {
      try await cached("blogs", forceRefresh: forceRefresh) {
         try await query(SiteBlog.self) {
            try await client.queryBlog(
               query: .init(pageNo: Self.firstPage, pageSize: Self.maximumPageSize, orderBy: Self.blogOrder)
            ).ok.body.json.value1
         }.records
      }
   }

   /// One page of a blog's published posts, newest first. Each post on the page is also
   /// cached for `post(id:)`.
   public func posts(
      blogId: Int, pageNo: Int = firstPage, pageSize: Int = defaultPageSize, forceRefresh: Bool = false
   ) async throws -> ReadPage<SitePost> {
      let page = try await cached("posts:\(blogId):\(pageNo):\(pageSize)", forceRefresh: forceRefresh) {
         try await query(SitePost.self) {
            try await client.queryPost(
               query: .init(pageNo: pageNo, pageSize: pageSize, orderBy: Self.newestFirst, blogId: [String(blogId)])
            ).ok.body.json.value1
         }
      }
      for post in page.records {
         if let id = post.id { await cache.store(post, for: Self.postKey(id)) }
      }
      return page
   }

   /// One published post by id.
   public func post(id: Int, forceRefresh: Bool = false) async throws -> SitePost {
      try await cached(Self.postKey(id), forceRefresh: forceRefresh) {
         try await unwrappingClientErrors { try await client.getPost(path: .init(id: id)).ok.body.json }
      }
   }

   /// All tags of a blog, alphabetically.
   public func tags(blogId: Int, forceRefresh: Bool = false) async throws -> [SiteTag] {
      try await cached("tags:\(blogId)", forceRefresh: forceRefresh) {
         try await query(SiteTag.self) {
            try await client.queryTag(
               query: .init(pageNo: Self.firstPage, pageSize: Self.maximumPageSize, orderBy: Self.tagOrder, blogId: [String(blogId)])
            ).ok.body.json.value1
         }.records
      }
   }

   /// The cache key of one post.
   static func postKey(_ id: Int) -> String { "post:\(id)" }

   /// Serves a fresh cached value for `key`, or loads and caches a new one.
   private func cached<Value: Sendable>(_ key: String, forceRefresh: Bool, load: () async throws -> Value) async throws -> Value {
      if !forceRefresh, let hit = await cache.value(for: key, as: Value.self) { return hit }
      let value = try await load()
      await cache.store(value, for: key)
      return value
   }

   /// Runs one generated query call, which checks the status and decodes the paging
   /// fields, and decodes the records from the captured body with the generated record
   /// type (the generated result type has no `records`, see `QueryEnvelope`).
   private func query<Record: Codable & Hashable & Sendable>(
      _ type: Record.Type, _ call: () async throws -> Components.Schemas.BaseSearchResultFields
   ) async throws -> ReadPage<Record> {
      let capture = ResponseCapture()
      let paging = try await ResponseCapture.$current.withValue(capture) {
         try await unwrappingClientErrors(call)
      }
      let envelope = try SiteDateTranscoder.jsonDecoder().decode(QueryEnvelope<Record>.self, from: capture.data)
      let records = envelope.records ?? []
      return ReadPage(
         records: records, count: paging.count, pageNo: paging.pageNo ?? Self.firstPage, pageSize: paging.pageSize ?? records.count)
   }
}
