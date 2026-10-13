/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Tags, photo uploads and link previews.
extension SiteService {
   //////////
   // Tags //
   //////////

   /// Tag suggestions for autocomplete in a blog (the default blog when nil): names
   /// starting with `query`, or every tag for an empty query.
   public func tags(matching query: String, blog slug: String?, limit: Int = Self.defaultPageSize) async throws -> [BlogTagRef] {
      let blog = try await blog(slug)
      let trimmed = query.trimmingCharacters(in: .whitespaces)
      let records: [Components.Schemas.BlogTag] = try await self.query {
         _ = try await client.queryBlogTag(
            query: .init(
               pageSize: limit, orderBy: "name", blogId: [String(blog.id)], name: trimmed.isEmpty ? nil : ["LIKE \(trimmed)%"])
         ).ok
      }
      return records.compactMap(Self.tag)
   }

   /// A tag reference from a record, or nil when it has no id or name.
   static func tag(_ record: Components.Schemas.BlogTag) -> BlogTagRef? {
      guard let id = record.id, let name = record.name else { return nil }
      return BlogTagRef(id: Int64(id), name: name, slug: record.slug)
   }

   /// The ids of `names` in a blog, creating the tags that do not exist yet. Names
   /// match case-insensitively; order and duplicates follow `names`.
   func tagIds(_ names: [String], blogId: Int64) async throws -> [Int64] {
      var ids: [Int64] = []
      for name in names {
         let clean = PostText.clip(name, to: PostFieldLimits.tag, ellipsis: false)
         guard !clean.isEmpty else { continue }
         let found: [Components.Schemas.BlogTag] = try await query {
            _ = try await client.queryBlogTag(query: .init(pageSize: Self.maximumPageSize, blogId: [String(blogId)], name: [clean])).ok
         }
         var id = found.first { $0.name?.caseInsensitiveCompare(clean) == .orderedSame }?.id.map(Int64.init)
         if id == nil {
            let created = try await call {
               try await client.createBlogTag(body: .json(.init(blogId: Int(blogId), name: clean))).created.body.json
            }
            id = created.id.map(Int64.init)
         }
         if let id, !ids.contains(id) {
            ids.append(id)
            await directory.keepTag(id: id, name: clean)
         }
      }
      return ids
   }

   /// Names of tag ids, from the shared copy or one query for the missing ones.
   func tagNames(_ ids: Set<Int64>) async throws -> [Int64: String] {
      var names = await directory.tagNames
      let missing = ids.subtracting(names.keys)
      if !missing.isEmpty {
         let list = missing.sorted().map(String.init).joined(separator: ",")
         let records: [Components.Schemas.BlogTag] = try await query {
            _ = try await client.queryBlogTag(query: .init(pageSize: Self.maximumPageSize, id: ["IN \(list)"])).ok
         }
         for tag in records.compactMap(Self.tag) {
            names[tag.id] = tag.name
            await directory.keepTag(id: tag.id, name: tag.name)
         }
      }
      return names
   }

   ////////////
   // Photos //
   ////////////

   /// Asks for a presigned upload URL for one photo.
   public func createUpload(_ upload: UploadRequest) async throws -> UploadTicket {
      try await processes.send(.post, "/v2/media/createUpload", operation: ProcessClient.Operation.createUpload, body: upload)
   }

   /// Sends the photo bytes to the ticket's presigned URL.
   public func putUpload(fileURL: URL, ticket: UploadTicket) async throws {
      guard let url = URL(string: ticket.uploadUrl) else { throw URLError(.badURL) }
      try await uploader.put(fileURL: fileURL, to: url, headers: ticket.headers)
   }

   /// Confirms an upload: the server strips location (unless kept), makes the
   /// renditions and creates the media record.
   public func completeUpload(id: String, _ completion: UploadCompletion) async throws -> MediaItem {
      guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw URLError(.badURL) }
      let path = "/v2/media/completeUpload/" + encoded
      return try await processes.send(.post, path, operation: ProcessClient.Operation.completeUpload, body: completion)
   }

   ///////////
   // Links //
   ///////////

   /// The title and image the server finds for a link.
   public func linkPreview(for url: String) async throws -> LinkPreview {
      try await processes.send(.post, "/v2/blogPost/linkPreview", operation: ProcessClient.Operation.linkPreview, body: ["url": url])
   }

   /// The preview of a post's link, or just the URL when the server cannot fetch it:
   /// the post is still sent.
   func preview(_ url: String?) async -> LinkPreview? {
      guard let url else { return nil }
      do {
         return try await linkPreview(for: url)
      }
      catch {
         Log.api.notice("Link preview failed, sending the URL alone: \(error.localizedDescription, privacy: .public)")
         return LinkPreview(url: url)
      }
   }
}
