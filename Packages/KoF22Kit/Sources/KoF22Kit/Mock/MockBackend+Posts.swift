/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// `blogPost` and `blogTag` writes, with the backend's authoring rules.
extension MockBackend {
   /// Fields the admin requires on insert, after blanks are derived.
   static let requiredPostFields = ["authorId", "blogId", "content", "isFeatured", "isPublished", "readTime", "viewCount"]

   /// `POST /blogPost/`: derives blank identity fields, checks required fields, the
   /// unique slug and the featured media, links tags and photos.
   func createPost(_ body: Data?) throws -> Response {
      guard var post = Self.decodeBody(Components.Schemas.BlogPost.self, from: body) else {
         return try tableError(Status.badRequest, "Request body was not a blogPost record")
      }
      derive(&post, insert: true)
      if let problem = check(post, excluding: nil) { return try tableError(Status.badRequest, problem) }
      let instant = now()
      post.id = state.takeId()
      post.createDate = instant
      post.modifyDate = instant
      link(&post)
      state.posts.append(post)
      return try json(Status.created, ["id": post.id])
   }

   /// `PATCH /blogPost/{id}`: merges the fields sent (an explicit `null` clears one; a
   /// nested `tags` or `media` list replaces that list) and re-applies the rules.
   func updatePost(_ id: Int?, body: Data?) throws -> Response {
      guard let index = state.posts.firstIndex(where: { $0.id == id }) else {
         return try tableError(Status.notFound, "The requested record was not found.")
      }
      guard let changes = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
         return try tableError(Status.badRequest, "Request body was not a JSON object")
      }
      ///////////////////////////////////////////////////////
      // a stored record always encodes to a JSON object.  //
      ///////////////////////////////////////////////////////
      let stored = try JSONSerialization.jsonObject(with: Self.encoder.encode(state.posts[index]))
      var merged: [String: Any] = [:]
      if let object = stored as? [String: Any] { merged = object }
      for (key, value) in changes {
         if value is NSNull {
            merged.removeValue(forKey: key)
         }
         else {
            merged[key] = value
         }
      }
      var post = try Self.decoder.decode(Components.Schemas.BlogPost.self, from: JSONSerialization.data(withJSONObject: merged))
      derive(&post, insert: false)
      if let problem = check(post, excluding: id) { return try tableError(Status.badRequest, problem) }
      post.modifyDate = now()
      link(&post)
      state.posts[index] = post
      return Response(status: Status.noContent)
   }

   /// `DELETE /blogPost/{id}`.
   func deletePost(_ id: Int?) throws -> Response {
      guard let index = state.posts.firstIndex(where: { $0.id == id }) else {
         return try tableError(Status.notFound, "The requested record was not found.")
      }
      state.posts.remove(at: index)
      return Response(status: Status.noContent)
   }

   /// `POST /blogTag/`: the slug is derived from the name.
   func createTag(_ body: Data?) throws -> Response {
      guard var tag = Self.decodeBody(Components.Schemas.BlogTag.self, from: body), let name = tag.name?.nilIfBlank, tag.blogId != nil else {
         return try tableError(Status.badRequest, "Missing value in required field: name")
      }
      tag.id = state.takeId()
      tag.slug = tag.slug?.nilIfBlank ?? PostText.slugify(name)
      tag.createDate = now()
      tag.modifyDate = tag.createDate
      state.tags.append(tag)
      return try json(Status.created, ["id": tag.id])
   }

   /// `BlogAuthoringCustomizer`: a blank title comes from the body; blank name and short
   /// name from the title and slug; a blank slug from a typed title, else a timestamp,
   /// made unique within the blog. Inserts only fill the slug.
   func derive(_ post: inout Components.Schemas.BlogPost, insert: Bool) {
      let typed = post.title?.nilIfBlank
      let title = typed ?? PostText.deriveTitle(post.content ?? "")
      post.title = title
      if insert, post.slug?.nilIfBlank == nil {
         let base = typed.map { PostText.slugify($0) }.flatMap(\.nilIfBlank) ?? Self.timestampSlug(now())
         let taken = Set(state.posts.filter { $0.blogId == post.blogId }.compactMap(\.slug))
         post.slug = PostText.uniqueSlug(base, taken: taken)
      }
      if post.name?.nilIfBlank == nil { post.name = String(title.prefix(PostFieldLimits.name)) }
      if post.shortName?.nilIfBlank == nil { post.shortName = String((post.slug ?? "").prefix(PostFieldLimits.shortName)) }
   }

   /// The first rule a post breaks, worded like the admin, or nil.
   func check(_ post: Components.Schemas.BlogPost, excluding id: Int?) -> String? {
      let fields = Self.fields(of: post)
      if let missing = Self.requiredPostFields.first(where: { fields[$0] == nil }) {
         return "Missing value in required field: \(missing)"
      }
      if Self.blogs.contains(where: { $0.id == post.blogId }) == false { return "Unknown blog" }
      let rules = [
         LengthRule(value: post.title, limit: PostFieldLimits.title, label: "title"),
         LengthRule(value: post.name, limit: PostFieldLimits.name, label: "name"),
         LengthRule(value: post.shortName, limit: PostFieldLimits.shortName, label: "shortName"),
         LengthRule(value: post.slug, limit: PostFieldLimits.slug, label: "slug"),
         LengthRule(value: post.description, limit: PostFieldLimits.description, label: "description"),
         LengthRule(value: post.metaTitle, limit: PostFieldLimits.metaTitle, label: "metaTitle"),
         LengthRule(value: post.metaDescription, limit: PostFieldLimits.metaDescription, label: "metaDescription"),
         LengthRule(value: post.metaKeywords, limit: PostFieldLimits.metaKeywords, label: "metaKeywords"),
      ]
      if let rule = rules.first(where: \.isTooLong) { return "The value for \(rule.label) is too long" }
      if state.posts.contains(where: { $0.id != id && $0.blogId == post.blogId && $0.slug == post.slug }) {
         return "Another record already exists with this Slug and Blog"
      }
      if let featured = post.featuredMediaId, !state.media.contains(where: { $0.id == featured && $0.siteId == Self.siteId }) {
         return "The featured image must be an active image of this site"
      }
      return nil
   }

   /// Copies media details into the photo links, fills the featured image and the
   /// public URL, and gives new links ids.
   func link(_ post: inout Components.Schemas.BlogPost) {
      post.tags = post.tags?.map { tag in
         var tag = tag
         tag.blogPostId = post.id
         if tag.id == nil { tag.id = state.takeId() }
         return tag
      }
      post.media = post.media?.map { item in
         var item = item
         item.blogPostId = post.id
         if item.id == nil { item.id = state.takeId() }
         if let media = state.media.first(where: { $0.id == item.mediaId }) {
            item.url = item.url ?? media.publicUrl
            item.thumbnailUrl = item.thumbnailUrl ?? media.thumbnailUrl
            item.width = item.width ?? media.width
            item.height = item.height ?? media.height
            item.altText = item.altText ?? media.altText
         }
         return item
      }
      post.featuredImage = post.featuredMediaId.flatMap { id in state.media.first { $0.id == id }?.publicUrl }
      post.sitePath = nil
      if post.isPublished == true, let blogSlug = Self.blogs.first(where: { $0.id == post.blogId })?.slug, let slug = post.slug {
         post.sitePath = "/blogs/\(blogSlug)/\(slug)"
      }
      post.siteUrl = post.sitePath.map { Self.websiteBase + $0 }
   }

   /// Publishes scheduled posts whose time has come, as the backend's scheduler does.
   func promoteScheduled() {
      let instant = now()
      for index in state.posts.indices {
         guard state.posts[index].isPublished != true, let due = state.posts[index].scheduledPublishAt, due <= instant else { continue }
         state.posts[index].isPublished = true
         state.posts[index].publishDate = due
         state.posts[index].scheduledPublishAt = nil
         state.posts[index].modifyDate = instant
         link(&state.posts[index])
      }
   }

   /// The slug for a post without a title: its creation time in UTC.
   static func timestampSlug(_ date: Date) -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      return formatter.string(from: date)
   }
}
