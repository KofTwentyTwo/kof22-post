/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The post endpoints: list, create, read, update and delete, with the backend's
/// validation rules, ETag preconditions and scheduled publishing.
extension MockBackend {
   /// Contract limits the backend enforces (`AuthoringService`), shared with `/me`.
   static let limits = AuthoringLimits.fallback
   /// Longest location label the backend accepts.
   static let maxLocationLength = 200
   /// Longest single tag the backend accepts.
   static let maxTagLength = 50
   /// Page size when the client sends none.
   static let defaultPageSize = 20
   /// Largest page the backend returns.
   static let maxPageSize = 50
   /// A scheduled post must be at least this far in the future.
   static let minimumScheduleLead: TimeInterval = 30
   /// A scheduled post must be at most this far in the future (366 days).
   static let maximumScheduleHorizon: TimeInterval = 31_622_400
   /// Base of the public post URLs.
   static let publicBlogsURL = "https://www.kof22.com/blogs"

   /// `GET /me/posts`: newest first, optionally filtered by status, paged with an
   /// opaque cursor that encodes the offset.
   func listPosts(_ query: [String: String]) throws -> Response {
      var posts = state.posts
      if let status = query["status"] {
         guard let wanted = PostStatus(rawValue: status) else { return try problem(Status.badRequest, "bad_request", "Unknown status") }
         posts = posts.filter { $0.status == wanted }
      }
      posts.sort { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
      let limit = Self.pageSize(query["limit"])
      var offset = 0
      if let cursor = query["cursor"] {
         guard let data = Data(base64Encoded: cursor), let text = String(bytes: data, encoding: .utf8), let value = Int(text), value >= 0 else {
            return try problem(Status.badRequest, "bad_request", "Invalid cursor")
         }
         offset = value
      }
      let page = Array(posts.dropFirst(offset).prefix(limit)).map(resolved)
      let end = offset + page.count
      let next = end < posts.count ? Data(String(end).utf8).base64EncodedString() : nil
      return try json(Status.okay, PostPage(items: page, nextCursor: next))
   }

   /// Clamps a requested page size to what the backend allows.
   static func pageSize(_ requested: String?) -> Int {
      min(max(Int(requested ?? "") ?? defaultPageSize, 1), maxPageSize)
   }

   /// `POST /me/posts`: validates, derives the title and slug, and publishes
   /// immediately when the status says so.
   func createPost(_ body: Data?) throws -> Response {
      guard let input = Self.decodeBody(PostCreate.self, from: body) else { return try badBody() }
      var issues = Self.contentIssues(body: input.body, title: input.title, locationLabel: input.locationLabel)
      let blog = blog(input.blog, issues: &issues)
      let tags = normalizedTags(input.tags ?? [], issues: &issues)
      let status = input.status ?? .draft
      let publishAt = schedule(status: status, publishAt: input.publishAt, issues: &issues)
      let media = attachments(input.media ?? [], issues: &issues)
      let link = input.linkUrl.flatMap { $0.isEmpty ? nil : preview(for: $0, field: "linkUrl", issues: &issues) }
      guard issues.isEmpty else { return try validation(issues) }

      let id = state.nextPostId
      state.nextPostId += 1
      let explicitTitle = Self.blankToNil(input.title)
      let title = explicitTitle ?? Self.deriveTitle(input.body)
      let instant = now()
      var post = Post(
         id: id, blogId: blog.id, blog: blog.slug, status: status, title: title, body: input.body,
         slug: uniqueSlug(explicitTitle.map(Self.slugify) ?? Self.timestampSlug(instant), blogID: blog.id),
         publishAt: publishAt, tags: tags, locationLabel: Self.blankToNil(input.locationLabel),
         link: link, media: media, createdAt: instant, updatedAt: instant, version: Self.newVersion()
      )
      if status == .published { publish(&post) }
      registerTags(tags, blogID: blog.id)
      state.posts.append(post)
      return try json(
         Status.created, resolved(post), etag: post.version,
         extra: ["Location": "https://api.kof22.com/v1/me/posts/\(id)"])
   }

   /// The length rules for a new post's text fields.
   static func contentIssues(body: String, title: String?, locationLabel: String?) -> [APIError.Detail] {
      var issues: [APIError.Detail] = []
      if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(field: "body", issue: "required")) }
      if body.count > limits.maxBodyLength { issues.append(.init(field: "body", issue: "at most \(limits.maxBodyLength) characters")) }
      if let title, title.count > limits.maxTitleLength {
         issues.append(.init(field: "title", issue: "at most \(limits.maxTitleLength) characters"))
      }
      if (locationLabel?.count ?? 0) > maxLocationLength {
         issues.append(.init(field: "locationLabel", issue: "at most \(maxLocationLength) characters"))
      }
      return issues
   }

   /// `PATCH /me/posts/{id}`: requires a current `If-Match`, applies only the fields
   /// present in the body (an explicit `null` link clears it) and bumps the version.
   func updatePost(_ id: Int64?, headers: [String: String], body: Data?) throws -> Response {
      guard let id, let index = state.posts.firstIndex(where: { $0.id == id }) else {
         return try problem(Status.notFound, "not_found", "Post not found")
      }
      guard let ifMatch = headers["if-match"], !ifMatch.isEmpty else {
         return try problem(Status.preconditionRequired, "precondition_required", "If-Match is required")
      }
      var post = state.posts[index]
      guard Self.matches(ifMatch, version: post.version) else {
         return try problem(Status.preconditionFailed, "precondition_failed", "The post changed since it was read", etag: post.version)
      }
      guard let raw = Self.jsonObject(body), let input = Self.decodeBody(PostUpdate.self, from: body) else { return try badBody() }
      var issues: [APIError.Detail] = []
      applyText(raw, input, to: &post, issues: &issues)
      applyLists(raw, input, to: &post, issues: &issues)
      applyStatus(input, to: &post, issues: &issues)
      guard issues.isEmpty else { return try validation(issues) }
      registerTags(post.tags, blogID: post.blogId)
      post.updatedAt = now()
      post.version = Self.newVersion()
      state.posts[index] = post
      return try json(Status.okay, resolved(post), etag: post.version)
   }

   /// Applies body, blog and title from a PATCH, in the backend's order: a blank
   /// title is derived from the (possibly new) body.
   private func applyText(_ raw: [String: Any], _ input: PostUpdate, to post: inout Post, issues: inout [APIError.Detail]) {
      if raw["body"] != nil {
         let text = input.body ?? ""
         if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > Self.limits.maxBodyLength {
            issues.append(.init(field: "body", issue: "required, at most \(Self.limits.maxBodyLength) characters"))
         }
         else {
            post.body = text
         }
      }
      if raw["blog"] != nil {
         let blog = blog(input.blog, issues: &issues)
         post.blog = blog.slug
         post.blogId = blog.id
      }
      if raw["title"] != nil {
         let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
         if title.count > Self.limits.maxTitleLength {
            issues.append(.init(field: "title", issue: "at most \(Self.limits.maxTitleLength) characters"))
         }
         post.title = title.isEmpty ? Self.deriveTitle(post.body) : title
      }
   }

   /// Applies location, tags, media and link from a PATCH; lists replace whole lists.
   private func applyLists(_ raw: [String: Any], _ input: PostUpdate, to post: inout Post, issues: inout [APIError.Detail]) {
      if raw["locationLabel"] != nil { post.locationLabel = Self.blankToNil(input.locationLabel) }
      if raw["tags"] != nil { post.tags = normalizedTags(input.tags ?? [], issues: &issues) }
      if raw["media"] != nil { post.media = attachments(input.media ?? [], issues: &issues) }
      //////////////////////////////////////////////////////////
      // An explicit null decodes as nil and clears the link. //
      //////////////////////////////////////////////////////////
      if raw["linkUrl"] != nil { post.link = input.linkUrl.flatMap { preview(for: $0, field: "linkUrl", issues: &issues) } }
   }

   /// Applies a status change. Publishing stamps the publish date once; going back
   /// to draft removes the public URL.
   private func applyStatus(_ input: PostUpdate, to post: inout Post, issues: inout [APIError.Detail]) {
      guard let status = input.status else { return }
      let publishAt = schedule(status: status, publishAt: input.publishAt, issues: &issues)
      guard issues.isEmpty else { return }
      post.status = status
      post.publishAt = publishAt
      if status == .published, post.publishedAt == nil { publish(&post) }
      if status == .draft {
         post.publishedAt = nil
         post.url = nil
      }
   }

   /// `DELETE /me/posts/{id}`: `If-Match` is optional, but a stale one is refused.
   func deletePost(_ id: Int64?, headers: [String: String]) throws -> Response {
      guard let id, let index = state.posts.firstIndex(where: { $0.id == id }) else {
         return try problem(Status.notFound, "not_found", "Post not found")
      }
      let version = state.posts[index].version
      if let ifMatch = headers["if-match"], !ifMatch.isEmpty, !Self.matches(ifMatch, version: version) {
         return try problem(Status.preconditionFailed, "precondition_failed", "The post changed since it was read", etag: version)
      }
      state.posts.remove(at: index)
      return Response(status: Status.noContent, body: nil)
   }

   /// Looks up the post named by the last path segment and builds a response from it.
   func withPost(_ segments: [String], _ body: (Post) throws -> Response) throws -> Response {
      guard let id = postID(segments), let post = state.posts.first(where: { $0.id == id }) else {
         return try problem(Status.notFound, "not_found", "Post not found")
      }
      return try body(resolved(post))
   }

   /// The post id in the last path segment, or nil when it is not a number.
   func postID(_ segments: [String]) -> Int64? { segments.last.flatMap { Int64($0) } }

   /// Publishes scheduled posts whose time has come, as the backend's scheduler does.
   func promoteScheduled() {
      let instant = now()
      for index in state.posts.indices where state.posts[index].status == .scheduled {
         if let publishAt = state.posts[index].publishAt, publishAt <= instant {
            publish(&state.posts[index], at: publishAt)
         }
      }
   }

   /// Marks a post published and gives it its public URL.
   func publish(_ post: inout Post, at date: Date? = nil) {
      post.status = .published
      post.publishedAt = date ?? now()
      post.url = "\(Self.publicBlogsURL)/\(post.blog)/\(post.slug)"
   }

   /// Resolves a blog slug, recording an issue (and returning the default blog so
   /// validation can continue) when it is unknown.
   func blog(_ slug: String?, issues: inout [APIError.Detail]) -> BlogRef {
      let slug = slug ?? Self.defaultBlog
      if let blog = Self.blogs.first(where: { $0.slug == slug }) { return blog }
      issues.append(.init(field: "blog", issue: "unknown blog \(slug)"))
      return Self.blogs[0]
   }

   /// Validates `publishAt` for a scheduled status; other statuses drop it.
   func schedule(status: PostStatus, publishAt: Date?, issues: inout [APIError.Detail]) -> Date? {
      guard status == .scheduled else { return nil }
      guard let publishAt else {
         issues.append(.init(field: "publishAt", issue: "required when status is scheduled"))
         return nil
      }
      let delta = publishAt.timeIntervalSince(now())
      if delta < Self.minimumScheduleLead {
         issues.append(.init(field: "publishAt", issue: "must be at least \(Int(Self.minimumScheduleLead)) seconds in the future"))
      }
      if delta > Self.maximumScheduleHorizon { issues.append(.init(field: "publishAt", issue: "must be within 366 days")) }
      return publishAt
   }

   /// Trims tags, drops a leading `#` and duplicates (by slug), and records an issue
   /// for each tag that is empty, too long or has no letters or digits.
   func normalizedTags(_ tags: [String], issues: inout [APIError.Detail]) -> [String] {
      if tags.count > Self.limits.maxTags { issues.append(.init(field: "tags", issue: "at most \(Self.limits.maxTags) tags")) }
      var seen = Set<String>()
      var normalized: [String] = []
      for tag in tags {
         var name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
         if name.hasPrefix("#") { name.removeFirst() }
         if name.isEmpty || name.count > Self.maxTagLength || Self.slugify(name).isEmpty {
            issues.append(.init(field: "tags", issue: "invalid tag '\(tag)'"))
            continue
         }
         if seen.insert(Self.slugify(name)).inserted { normalized.append(name) }
      }
      return normalized
   }

   /// Adds tags the blog has not seen before, so autocomplete offers them next time.
   func registerTags(_ names: [String], blogID: Int64) {
      for name in names where !state.tags.contains(where: { $0.blogId == blogID && $0.slug == Self.slugify(name) }) {
         state.tags.append(AuthoringTag(id: state.nextTagId, name: name, slug: Self.slugify(name), blogId: blogID))
         state.nextTagId += 1
      }
   }

   /// Turns media references into post photos, recording an issue for unknown ids.
   func attachments(_ items: [MediaAttachment], issues: inout [APIError.Detail]) -> [PostPhoto] {
      if items.count > Self.limits.maxPhotosPerPost {
         issues.append(.init(field: "media", issue: "at most \(Self.limits.maxPhotosPerPost) photos"))
      }
      return items.compactMap { item in
         guard let media = state.media[item.mediaId] else {
            issues.append(.init(field: "media", issue: "unknown mediaId \(item.mediaId)"))
            return nil
         }
         let url = "\(Self.mediaScheme):\(media.file)"
         return PostPhoto(
            mediaId: item.mediaId, url: url, thumbnailUrl: url, width: media.width, height: media.height,
            altText: item.altText ?? media.altText, caption: item.caption)
      }
   }

   /// Makes a slug unique within the blog by appending `-2`, `-3`, and so on.
   func uniqueSlug(_ base: String, blogID: Int64) -> String {
      var slug = base.isEmpty ? Self.timestampSlug(now()) : base
      var suffix = 2
      while state.posts.contains(where: { $0.blogId == blogID && $0.slug == slug }) {
         slug = "\(base)-\(suffix)"
         suffix += 1
      }
      return slug
   }

   /// Mock media URLs are rewritten to file URLs so the app can display them.
   func resolved(_ post: Post) -> Post {
      guard let directory else { return post }
      var copy = post
      copy.media = post.media.map { photo in
         var photo = photo
         if let file = fileURL(forMockMedia: photo.url, directory: directory) { photo.url = file.absoluteString }
         if let thumb = photo.thumbnailUrl, let file = fileURL(forMockMedia: thumb, directory: directory) {
            photo.thumbnailUrl = file.absoluteString
         }
         return photo
      }
      return copy
   }
}
