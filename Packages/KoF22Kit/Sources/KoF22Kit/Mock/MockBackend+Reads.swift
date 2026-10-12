/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The anonymous content reads (`/v1/blog/query`, `/v1/post/query`, `/v1/post/{id}`,
/// `/v1/tag/query`) answered from the mock's own state, so mock mode shows the posts
/// written in it. Only published posts are visible, as on the real API. Query replies use
/// the spec's `{"records","count","pageNo","pageSize"}` shape.
extension MockBackend {
   /// Page size when the client sends none (the spec's default).
   static let readDefaultPageSize = 50
   /// The page sizes the spec allows.
   static let readPageSizes = 1...1_000
   /// Author id of the mock author, matching `me().author`.
   static let mockAuthorID = 1

   /// Routes one read operation.
   func handleRead(_ operation: String, segments: [String], query: [String: String]) throws -> Response {
      guard let pageNo = Int(query["pageNo"] ?? "1"), pageNo >= 1,
         let pageSize = Int(query["pageSize"] ?? String(Self.readDefaultPageSize)), Self.readPageSizes.contains(pageSize)
      else {
         return try problem(Status.badRequest, "bad_request", "pageNo must be 1 or more and pageSize between 1 and 1000")
      }
      let page = (number: pageNo, size: pageSize)
      switch operation {
      case "queryBlog": return try queryReply(Self.blogs.sorted { $0.id < $1.id }.map(Self.siteBlog), page: page)
      case "queryTag": return try queryReply(siteTags(blogID: query["blogId"]), page: page)
      case "queryPost": return try queryReply(publishedPosts(blogID: query["blogId"]).map(sitePost), page: page)
      default: return try getPublishedPost(segments.last ?? "")
      }
   }

   /// `GET /v1/post/{id}`: one published post, or the API's 404 envelope.
   private func getPublishedPost(_ rawID: String) throws -> Response {
      guard let id = Int64(rawID), let post = publishedPosts(blogID: nil).first(where: { $0.id == id }) else {
         return try problem(Status.notFound, "not_found", "Could not find Blog Post with Id of \(rawID)")
      }
      return try json(Status.okay, sitePost(post))
   }

   /// One page of `records` in the query envelope, with the total count.
   private func queryReply<Record: Codable>(_ records: [Record], page: (number: Int, size: Int)) throws -> Response {
      let slice = Array(records.dropFirst((page.number - 1) * page.size).prefix(page.size))
      return try json(Status.okay, QueryEnvelope(records: slice, count: records.count, pageNo: page.number, pageSize: page.size))
   }

   /// Published posts, newest first (ties by id), optionally of one blog.
   private func publishedPosts(blogID: String?) -> [Post] {
      state.posts
         .filter { $0.status == .published && (blogID == nil || String($0.blogId) == blogID) }
         .compactMap { post in post.publishedAt.map { (date: $0, post: post) } }
         .sorted { ($0.date, $0.post.id) > ($1.date, $1.post.id) }
         .map(\.post)
   }

   /// A blog's tags (all blogs' without a filter), alphabetically.
   private func siteTags(blogID: String?) -> [SiteTag] {
      state.tags
         .filter { blogID == nil || String($0.blogId) == blogID }
         .sorted { $0.name < $1.name }
         .map { SiteTag(blogId: Int($0.blogId), id: Int($0.id), name: $0.name, slug: $0.slug) }
   }

   /// The public shape of a seeded blog.
   static func siteBlog(_ blog: BlogRef) -> SiteBlog {
      SiteBlog(id: Int(blog.id), name: blog.name, shortName: blog.name, slug: blog.slug)
   }

   /// The public shape of an authored post: body as `content`, tag names resolved to the
   /// blog's tag ids, photos in order, the link card flattened into `link*` fields.
   private func sitePost(_ post: Post) -> SitePost {
      let resolvedPost = resolved(post)
      let tagIDs = post.tags.compactMap { name in
         state.tags.first { $0.blogId == post.blogId && $0.slug == Self.slugify(name) }.map { SitePostTagLink(tagId: Int($0.id)) }
      }
      let media = resolvedPost.media.enumerated().map { index, photo in
         SitePostMedia(
            altText: photo.altText, caption: photo.caption, height: photo.height, mediaId: Int(photo.mediaId), sortOrder: index,
            thumbnailUrl: photo.thumbnailUrl, url: photo.url, width: photo.width)
      }
      return SitePost(
         authorId: Self.mockAuthorID, blogId: Int(post.blogId), content: post.body, id: Int(post.id),
         linkDescription: post.link?.description, linkImageUrl: post.link?.imageUrl, linkTitle: post.link?.title,
         linkUrl: post.link?.url, locationLabel: post.locationLabel, modifyDate: post.updatedAt, name: post.slug,
         publishDate: post.publishedAt, slug: post.slug, title: post.title, tags: tagIDs, media: media)
   }
}
