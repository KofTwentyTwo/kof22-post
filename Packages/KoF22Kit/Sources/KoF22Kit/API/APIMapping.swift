/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The v2 `blogPost` record (every field optional on the wire).
typealias BlogPostRecord = Components.Schemas.BlogPost
/// One photo link of a `blogPost` (`blogPostMedia`).
typealias BlogPostMediaRecord = Components.Schemas.BlogPostMedia
/// One tag link of a `blogPost` (`blogPostTagInt`).
typealias BlogPostTagRecord = Components.Schemas.BlogPostTagInt

/// Converts between Site API v2 records and the app's models.
enum APIMapping {
   /// The version used for a record the server sent without a `modifyDate`.
   static let unknownVersion = "0"

   /// The change marker of a record: its `modifyDate` to the millisecond.
   static func version(of date: Date?) -> String {
      guard let date else { return unknownVersion }
      return Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
   }

   /// Draft, scheduled or published from `isPublished` and `scheduledPublishAt`.
   static func status(isPublished: Bool?, scheduledPublishAt: Date?) -> PostStatus {
      if isPublished == true { return .published }
      return scheduledPublishAt == nil ? .draft : .scheduled
   }

   /// The app's post from a record. `blogSlugs` maps blog ids to slugs and `tagNames`
   /// tag ids to names; unknown ids are left out.
   static func post(_ record: BlogPostRecord, blogSlugs: [Int64: String], tagNames: [Int64: String]) -> Post {
      let blogId = Int64(record.blogId ?? 0)
      let status = status(isPublished: record.isPublished, scheduledPublishAt: record.scheduledPublishAt)
      let photos = (record.media ?? [])
         .sorted { ($0.sortOrder ?? 0, $0.id ?? 0) < ($1.sortOrder ?? 0, $1.id ?? 0) }
         .compactMap(photo)
      return Post(
         id: Int64(record.id ?? 0), blogId: blogId, blog: blogSlugs[blogId] ?? "", authorId: record.authorId.map(Int64.init),
         status: status, title: record.title ?? "", name: record.name ?? "", shortName: record.shortName ?? "",
         slug: record.slug ?? "", body: record.content ?? "", description: record.description, excerpt: record.excerpt,
         metaTitle: record.metaTitle, metaDescription: record.metaDescription, metaKeywords: record.metaKeywords,
         readTime: record.readTime, isFeatured: record.isFeatured ?? false, featuredMediaId: record.featuredMediaId.map(Int64.init),
         featuredImage: record.featuredImage, url: status == .published ? record.siteUrl : nil,
         publishAt: status == .scheduled ? record.scheduledPublishAt : nil,
         publishedAt: status == .published ? record.publishDate : nil,
         createdAt: record.createDate, updatedAt: record.modifyDate,
         tags: (record.tags ?? []).compactMap { $0.blogTagId.flatMap { tagNames[Int64($0)] } },
         locationLabel: record.locationLabel,
         link: record.linkUrl.map { PostLink(url: $0, title: record.linkTitle, description: record.linkDescription, imageUrl: record.linkImageUrl) },
         media: photos, version: version(of: record.modifyDate)
      )
   }

   /// A photo link, or nil when it has no media or URL.
   static func photo(_ record: BlogPostMediaRecord) -> PostPhoto? {
      guard let mediaId = record.mediaId, let url = record.url else { return nil }
      return PostPhoto(
         mediaId: Int64(mediaId), url: url, thumbnailUrl: record.thumbnailUrl, width: record.width, height: record.height,
         altText: record.altText, caption: record.caption)
   }

   /// What the service resolved for a draft before it is written.
   struct Resolved {
      /// The blog's id.
      var blogId: Int64
      /// The author's id.
      var authorId: Int64
      /// The final slug, unique within the blog.
      var slug: String
      /// The tags' ids.
      var tagIds: [Int64]
      /// The server's preview of the draft's link.
      var link: LinkPreview?
      /// The publish time of a post that is or goes live with this request.
      var publishDate: Date?
   }

   /// The fields of a draft as a record, with the ids, slug and link the service
   /// resolved.
   static func record(_ draft: PostDraft, _ resolved: Resolved) -> BlogPostRecord {
      let slug = resolved.slug
      let link = resolved.link
      var record = BlogPostRecord()
      record.blogId = Int(resolved.blogId)
      record.authorId = Int(resolved.authorId)
      record.title = draft.title
      record.name = draft.name
      record.shortName = draft.shortName
      record.slug = slug
      record.content = draft.body
      record.description = draft.description
      record.excerpt = draft.excerpt
      record.readTime = draft.readTime
      record.metaTitle = draft.metaTitle
      record.metaDescription = draft.metaDescription
      record.metaKeywords = draft.metaKeywords
      record.isFeatured = draft.isFeatured
      record.featuredMediaId = draft.featuredMediaId.map(Int.init)
      record.locationLabel = draft.locationLabel
      record.linkUrl = link?.url ?? draft.linkURL
      record.linkTitle = link?.title.map { PostText.clip($0, to: linkTitleLength) }
      record.linkDescription = link?.description.map { PostText.clip($0, to: linkDescriptionLength) }
      record.linkImageUrl = link?.imageUrl.flatMap { $0.count <= PostFieldLimits.link ? $0 : nil }
      record.isPublished = draft.status == .published
      record.publishDate = draft.status == .published ? resolved.publishDate : nil
      record.scheduledPublishAt = draft.status == .scheduled ? draft.publishAt : nil
      record.tags = resolved.tagIds.map { BlogPostTagRecord(blogTagId: Int($0)) }
      record.media = draft.media.enumerated().map { index, item in
         BlogPostMediaRecord(altText: item.altText, caption: item.caption, mediaId: Int(item.mediaId), sortOrder: index)
      }
      return record
   }

   /// `blogPost.linkTitle` maxLength.
   static let linkTitleLength = 300
   /// `blogPost.linkDescription` maxLength.
   static let linkDescriptionLength = 1_000

   /// Optional record fields that a full-state update clears with an explicit `null`
   /// when the draft leaves them empty.
   static func clearedFields(_ record: BlogPostRecord) -> Set<String> {
      var fields = Set<String>()
      if record.locationLabel == nil { fields.insert("locationLabel") }
      if record.linkUrl == nil { fields.formUnion(["linkUrl", "linkTitle", "linkDescription", "linkImageUrl"]) }
      if record.featuredMediaId == nil { fields.insert("featuredMediaId") }
      if record.scheduledPublishAt == nil { fields.insert("scheduledPublishAt") }
      return fields
   }
}
