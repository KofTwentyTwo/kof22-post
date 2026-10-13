/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
@_exported import KoF22API

// Site API v2 is the CMS model itself (`blogPost`, `blogTag`, `media`, ...), with every
// field optional on the wire. The app works with these app-owned types instead, mapped
// in `APIMapping.swift`, so screens and the outbox see one stable shape with the
// derived values (status, tag names, blog slug) filled in.

/// Draft, scheduled or published. Site API v2 stores this as `isPublished` plus
/// `scheduledPublishAt`; `APIMapping` converts between the two.
public enum PostStatus: String, Codable, Sendable, Hashable, CaseIterable {
   /// Saved on the server, not public.
   case draft
   /// Goes live at `Post.publishAt`.
   case scheduled
   /// Public now.
   case published

   /// The status as shown in the post list and composer.
   public var label: String {
      switch self {
      case .draft: "Draft"
      case .scheduled: "Scheduled"
      case .published: "Published"
      }
   }
}

/// The link card attached to a post (`linkUrl`, `linkTitle`, `linkDescription`,
/// `linkImageUrl` on `blogPost`).
public struct PostLink: Codable, Sendable, Hashable {
   /// The linked page.
   public var url: String
   /// The page title the server found.
   public var title: String?
   /// The page description the server found.
   public var description: String?
   /// The page image the server found.
   public var imageUrl: String?

   /// Creates a link card.
   public init(url: String, title: String? = nil, description: String? = nil, imageUrl: String? = nil) {
      self.url = url
      self.title = title
      self.description = description
      self.imageUrl = imageUrl
   }
}

/// A photo attached to a post (`blogPostMedia`), in display order.
public struct PostPhoto: Codable, Sendable, Hashable, Identifiable {
   /// The `media` record.
   public var mediaId: Int64
   /// The full-size public URL.
   public var url: String
   /// The thumbnail URL, when the server made one.
   public var thumbnailUrl: String?
   /// Width in pixels.
   public var width: Int?
   /// Height in pixels.
   public var height: Int?
   /// Text for screen readers.
   public var altText: String?
   /// Visible caption.
   public var caption: String?

   /// Identified by its media record.
   public var id: Int64 { mediaId }

   /// Creates a photo reference.
   public init(
      mediaId: Int64, url: String, thumbnailUrl: String? = nil, width: Int? = nil, height: Int? = nil,
      altText: String? = nil, caption: String? = nil
   ) {
      self.mediaId = mediaId
      self.url = url
      self.thumbnailUrl = thumbnailUrl
      self.width = width
      self.height = height
      self.altText = altText
      self.caption = caption
   }
}

/// A blog post with every field the CMS keeps, as the app shows and edits it.
public struct Post: Codable, Sendable, Hashable, Identifiable {
   /// The `blogPost` id.
   public var id: Int64
   /// The blog's id.
   public var blogId: Int64
   /// The blog's slug, resolved from `blogId` (empty when the blog is unknown).
   public var blog: String
   /// The author's id.
   public var authorId: Int64?
   /// Draft, scheduled or published.
   public var status: PostStatus
   /// Headline (100).
   public var title: String
   /// Display name in lists and the admin (40).
   public var name: String
   /// Short label (20).
   public var shortName: String
   /// URL slug, unique within the blog (100).
   public var slug: String
   /// Markdown body (`content`).
   public var body: String
   /// One-sentence summary (255).
   public var description: String?
   /// Plain-text teaser.
   public var excerpt: String?
   /// SEO title (255).
   public var metaTitle: String?
   /// SEO description (500).
   public var metaDescription: String?
   /// SEO keywords, comma-separated (255).
   public var metaKeywords: String?
   /// Minutes to read.
   public var readTime: Int?
   /// Shown as a featured post on the site.
   public var isFeatured: Bool
   /// The media record used as the post's image.
   public var featuredMediaId: Int64?
   /// The featured image URL the server resolved.
   public var featuredImage: String?
   /// The public page, once the post is public.
   public var url: String?
   /// When a scheduled post goes live.
   public var publishAt: Date?
   /// When the post went live.
   public var publishedAt: Date?
   /// When the post was created.
   public var createdAt: Date?
   /// When the post last changed.
   public var updatedAt: Date?
   /// Tag names, in the order the server returned their links.
   public var tags: [String]
   /// Place name.
   public var locationLabel: String?
   /// The link card, when the post has a link.
   public var link: PostLink?
   /// Photos in display order.
   public var media: [PostPhoto]
   /// Change marker for edit-conflict checks: the server's `modifyDate`. Site API v2 has
   /// no ETags, so an edit compares this before writing.
   public var version: String

   /// Creates a post; used by the mapping and by tests.
   public init(
      id: Int64, blogId: Int64, blog: String, authorId: Int64? = nil, status: PostStatus, title: String, name: String = "",
      shortName: String = "", slug: String, body: String, description: String? = nil, excerpt: String? = nil,
      metaTitle: String? = nil, metaDescription: String? = nil, metaKeywords: String? = nil, readTime: Int? = nil,
      isFeatured: Bool = false, featuredMediaId: Int64? = nil, featuredImage: String? = nil, url: String? = nil,
      publishAt: Date? = nil, publishedAt: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil,
      tags: [String] = [], locationLabel: String? = nil, link: PostLink? = nil, media: [PostPhoto] = [], version: String
   ) {
      self.id = id
      self.blogId = blogId
      self.blog = blog
      self.authorId = authorId
      self.status = status
      self.title = title
      self.name = name
      self.shortName = shortName
      self.slug = slug
      self.body = body
      self.description = description
      self.excerpt = excerpt
      self.metaTitle = metaTitle
      self.metaDescription = metaDescription
      self.metaKeywords = metaKeywords
      self.readTime = readTime
      self.isFeatured = isFeatured
      self.featuredMediaId = featuredMediaId
      self.featuredImage = featuredImage
      self.url = url
      self.publishAt = publishAt
      self.publishedAt = publishedAt
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.tags = tags
      self.locationLabel = locationLabel
      self.link = link
      self.media = media
      self.version = version
   }
}

/// One page of the author's posts.
public struct PostPage: Sendable, Hashable {
   /// The posts on this page.
   public var items: [Post]
   /// The page to ask for next, or nil on the last page.
   public var nextPage: Int?

   /// Creates a page.
   public init(items: [Post], nextPage: Int?) {
      self.items = items
      self.nextPage = nextPage
   }
}

/// An author the app can post as.
public struct AuthorRef: Codable, Sendable, Hashable, Identifiable {
   /// The `author` id.
   public var id: Int64
   /// Display name.
   public var name: String
   /// URL slug.
   public var slug: String?

   /// Creates an author reference.
   public init(id: Int64, name: String, slug: String? = nil) {
      self.id = id
      self.name = name
      self.slug = slug
   }
}

/// A blog the author can post to.
public struct BlogRef: Codable, Sendable, Hashable, Identifiable {
   /// The `blog` id.
   public var id: Int64
   /// URL slug, such as `quick-bits`.
   public var slug: String
   /// Display name.
   public var name: String
   /// True for the default authoring blog.
   public var isDefault: Bool

   /// Creates a blog reference.
   public init(id: Int64, slug: String, name: String, isDefault: Bool = false) {
      self.id = id
      self.slug = slug
      self.name = name
      self.isDefault = isDefault
   }
}

/// The server's photo rules (`me.limits`).
public struct PhotoLimits: Codable, Sendable, Hashable {
   /// Largest photo accepted, in bytes.
   public var maxPhotoBytes: Int64
   /// Accepted content types.
   public var photoContentTypes: [String]
   /// The server refuses a photo without alt text.
   public var photoAltTextRequired: Bool
   /// The server refuses a photo without a caption.
   public var photoCaptionRequired: Bool

   /// Largest photo the backend's upload path accepts: 25 MiB.
   static let fallbackMaxPhotoBytes: Int64 = 26_214_400

   /// Used before `/me` has loaded (the backend's defaults).
   public static let fallback = Self(
      maxPhotoBytes: fallbackMaxPhotoBytes, photoContentTypes: ["image/jpeg", "image/png"],
      photoAltTextRequired: false, photoCaptionRequired: false
   )

   /// Creates limits.
   public init(maxPhotoBytes: Int64, photoContentTypes: [String], photoAltTextRequired: Bool = false, photoCaptionRequired: Bool = false) {
      self.maxPhotoBytes = maxPhotoBytes
      self.photoContentTypes = photoContentTypes
      self.photoAltTextRequired = photoAltTextRequired
      self.photoCaptionRequired = photoCaptionRequired
   }

   /// Reads the server's keys; ones it leaves out keep the fallback values.
   public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      maxPhotoBytes = try container.decodeIfPresent(Int64.self, forKey: .maxPhotoBytes) ?? Self.fallback.maxPhotoBytes
      photoContentTypes = try container.decodeIfPresent([String].self, forKey: .photoContentTypes) ?? Self.fallback.photoContentTypes
      photoAltTextRequired = try container.decodeIfPresent(Bool.self, forKey: .photoAltTextRequired) ?? false
      photoCaptionRequired = try container.decodeIfPresent(Bool.self, forKey: .photoCaptionRequired) ?? false
   }
}

/// The signed-in user (`GET /me`): who they are, their author profile, the blogs and the
/// photo rules.
public struct Me: Codable, Sendable, Hashable {  // swiftlint:disable:this type_name
   /// Account email.
   public var email: String?
   /// Account name.
   public var name: String?
   /// Admin permissions, such as `blog_post.insert`.
   public var permissions: [String]
   /// The author profile linked to the account's email, when there is one.
   public var author: AuthorRef?
   /// The account may create posts.
   public var canPost: Bool
   /// Every blog.
   public var blogs: [BlogRef]
   /// The default blog's slug.
   public var defaultBlog: String
   /// Photo rules.
   public var limits: PhotoLimits

   /// Creates the caller description; used by the fake backend and tests.
   public init(
      email: String?, name: String?, permissions: [String] = [], author: AuthorRef?, canPost: Bool, blogs: [BlogRef],
      defaultBlog: String = Post.defaultBlogSlug, limits: PhotoLimits = .fallback
   ) {
      self.email = email
      self.name = name
      self.permissions = permissions
      self.author = author
      self.canPost = canPost
      self.blogs = blogs
      self.defaultBlog = defaultBlog
      self.limits = limits
   }

   /// Reads `/me`, tolerating keys the server leaves out.
   public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      email = try container.decodeIfPresent(String.self, forKey: .email)
      name = try container.decodeIfPresent(String.self, forKey: .name)
      permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
      author = try container.decodeIfPresent(AuthorRef.self, forKey: .author)
      canPost = try container.decodeIfPresent(Bool.self, forKey: .canPost) ?? false
      blogs = try container.decodeIfPresent([BlogRef].self, forKey: .blogs) ?? []
      defaultBlog = try container.decodeIfPresent(String.self, forKey: .defaultBlog) ?? Post.defaultBlogSlug
      limits = try container.decodeIfPresent(PhotoLimits.self, forKey: .limits) ?? .fallback
   }
}

/// A tag of a blog (`blogTag`).
public struct BlogTagRef: Codable, Sendable, Hashable, Identifiable {
   /// The `blogTag` id.
   public var id: Int64
   /// Display name (40).
   public var name: String
   /// URL slug.
   public var slug: String?

   /// Creates a tag reference.
   public init(id: Int64, name: String, slug: String? = nil) {
      self.id = id
      self.name = name
      self.slug = slug
   }
}

extension Post {
   /// The default authoring blog (Field Notes).
   public static let defaultBlogSlug = "quick-bits"
}

/// Field lengths of `blogPost`, `blogTag` and `blogPostMedia` in the Site API v2 schema.
public enum PostFieldLimits {
   /// `title` maxLength.
   public static let title = 100
   /// `name` maxLength.
   public static let name = 40
   /// `shortName` maxLength.
   public static let shortName = 20
   /// `slug` maxLength.
   public static let slug = 100
   /// `description` maxLength.
   public static let description = 255
   /// `metaTitle` maxLength.
   public static let metaTitle = 255
   /// `metaDescription` maxLength.
   public static let metaDescription = 500
   /// `metaKeywords` maxLength.
   public static let metaKeywords = 255
   /// `blogTag.name` maxLength.
   public static let tag = 40
   /// `locationLabel` maxLength.
   public static let locationLabel = 200
   /// `linkUrl` maxLength.
   public static let link = 2_000
   /// `blogPostMedia.altText` maxLength.
   public static let altText = 1_000
   /// `blogPostMedia.caption` maxLength.
   public static let caption = 2_000

   /// Search engines show about this many characters of a title.
   public static let seoTitleTarget = 60
   /// Search engines show about this many characters of a description.
   public static let seoDescriptionTarget = 160
}
