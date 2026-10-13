/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// A photo attached to a composition. Local photos have a `fileName` in
/// `SharedContainer.photosDirectory` until they are uploaded and get a `mediaId`.
public struct ComposedPhoto: Codable, Sendable, Identifiable, Equatable, Hashable {
   /// Stable identity; part of the photo's upload idempotency key.
   public var id: UUID
   /// The local file in the photos directory, until the photo is uploaded.
   public var fileName: String?
   /// The server's media id once the photo is uploaded.
   public var mediaId: Int64?
   /// A URL to show the uploaded photo (thumbnail when the server has one).
   public var remoteURL: String?
   /// Alt text for screen readers; blank sends none.
   public var altText: String
   /// Caption shown with the photo; blank sends none.
   public var caption: String
   /// Whether this photo keeps its GPS metadata (published publicly). Off by default:
   /// location is removed on device before upload.
   public var keepLocation: Bool
   /// Counts upload restarts after an expired presigned URL; part of the upload's
   /// idempotency key so a restart gets a fresh ticket while plain retries reuse it.
   var uploadGeneration: Int

   /// Creates a photo reference; a new photo has only a `fileName`.
   public init(
      id: UUID = UUID(), fileName: String? = nil, mediaId: Int64? = nil, remoteURL: String? = nil,
      altText: String = "", caption: String = "", keepLocation: Bool = false
   ) {
      self.id = id
      self.fileName = fileName
      self.mediaId = mediaId
      self.remoteURL = remoteURL
      self.altText = altText
      self.caption = caption
      self.keepLocation = keepLocation
      self.uploadGeneration = 0
   }

   /// Decodes a stored photo. Payloads saved before location became a per-photo choice
   /// have no `keepLocation` (or `uploadGeneration`); both default to off and zero, and
   /// `PostComposition` applies a stored post-level opt-in on top.
   public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(UUID.self, forKey: .id)
      fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
      mediaId = try container.decodeIfPresent(Int64.self, forKey: .mediaId)
      remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
      altText = try container.decode(String.self, forKey: .altText)
      caption = try container.decode(String.self, forKey: .caption)
      keepLocation = try container.decodeIfPresent(Bool.self, forKey: .keepLocation) ?? false
      uploadGeneration = try container.decodeIfPresent(Int.self, forKey: .uploadGeneration) ?? 0
   }

   /// Whether the photo already has a server media id and needs no upload.
   public var isUploaded: Bool { mediaId != nil }

   /// The local file's URL in `directory`, or nil for a photo that only exists on the
   /// server.
   public func localURL(in directory: URL = SharedContainer.photosDirectory) -> URL? {
      fileName.map { directory.appending(path: $0) }
   }
}

extension ComposedPhoto {
   /// Records the server's media for this photo once it is uploaded; lists show the
   /// thumbnail when the server made one and the full image otherwise.
   mutating func attach(_ media: MediaItem) {
      mediaId = media.mediaId
      remoteURL = media.thumbnailUrl ?? media.url
   }
}

/// What the user wrote, independent of whether it has been sent yet. Blank metadata
/// fields are filled by `PostText` rules when the post is sent (`draft()`), so every
/// post reaches the server with a title, names, slug, description and SEO fields.
public struct PostComposition: Codable, Sendable, Equatable {
   /// A composition may be scheduled no sooner than this, leaving time to send it.
   public static let minimumScheduleLead: TimeInterval = 60
   /// Scheduling further ahead than a year is refused locally.
   public static let maximumScheduleHorizon: TimeInterval = 31_622_400

   /// The blog slug to post to.
   public var blog: String
   /// The author to post as; nil posts as the signed-in user's author.
   public var authorId: Int64?
   /// Headline; blank derives it from the first line of the body.
   public var title: String
   /// Display name (40); blank derives it from the title.
   public var name: String
   /// Short label (20); blank derives it from the title.
   public var shortName: String
   /// URL slug; blank derives it from the title. Normalised with `PostText.slugify`.
   public var slug: String
   /// One-sentence summary (255); blank uses the start of the body.
   public var description: String
   /// SEO title; blank uses the title.
   public var metaTitle: String
   /// SEO description; blank uses the description.
   public var metaDescription: String
   /// SEO keywords, comma-separated; blank uses the tags.
   public var metaKeywords: String
   /// The markdown body.
   public var body: String
   /// Tag names as typed.
   public var tags: [String]
   /// Optional link to preview with the post; blank for none.
   public var linkURL: String
   /// Optional place name; blank for none.
   public var locationLabel: String
   /// Draft, published now, or scheduled.
   public var status: PostStatus
   /// When a scheduled post goes live.
   public var publishAt: Date?
   /// Shown as a featured post on the site.
   public var isFeatured: Bool
   /// The photo used as the post's image; nil uses the first photo.
   public var featuredPhotoID: UUID?
   /// Attached photos, local or already uploaded.
   public var photos: [ComposedPhoto]
   /// For edits: whether the server copy had a link, so removing it clears it.
   public var originalHadLink: Bool

   /// Creates a composition; the defaults are an empty post to the default blog,
   /// published on send.
   public init(
      blog: String = Post.defaultBlogSlug, authorId: Int64? = nil, title: String = "", name: String = "", shortName: String = "",
      slug: String = "", description: String = "", metaTitle: String = "", metaDescription: String = "", metaKeywords: String = "",
      body: String = "", tags: [String] = [], linkURL: String = "", locationLabel: String = "",
      status: PostStatus = .published, publishAt: Date? = nil, isFeatured: Bool = false, featuredPhotoID: UUID? = nil,
      photos: [ComposedPhoto] = [], originalHadLink: Bool = false
   ) {
      self.blog = blog
      self.authorId = authorId
      self.title = title
      self.name = name
      self.shortName = shortName
      self.slug = slug
      self.description = description
      self.metaTitle = metaTitle
      self.metaDescription = metaDescription
      self.metaKeywords = metaKeywords
      self.body = body
      self.tags = tags
      self.linkURL = linkURL
      self.locationLabel = locationLabel
      self.status = status
      self.publishAt = publishAt
      self.isFeatured = isFeatured
      self.featuredPhotoID = featuredPhotoID
      self.photos = photos
      self.originalHadLink = originalHadLink
   }

   /// The post-level location switch of payloads saved before location became a
   /// per-photo choice; read when decoding, never written.
   private enum LegacyKeys: String, CodingKey {
      /// Whether every photo of the post kept its GPS metadata.
      case keepLocation
   }

   /// Decodes a stored composition. Fields added after a payload was saved take their
   /// defaults; an older payload's post-level `keepLocation: true` opts every one of its
   /// photos in.
   public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      blog = try container.decode(String.self, forKey: .blog)
      authorId = try container.decodeIfPresent(Int64.self, forKey: .authorId)
      title = try container.decode(String.self, forKey: .title)
      name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
      shortName = try container.decodeIfPresent(String.self, forKey: .shortName) ?? ""
      slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
      description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
      metaTitle = try container.decodeIfPresent(String.self, forKey: .metaTitle) ?? ""
      metaDescription = try container.decodeIfPresent(String.self, forKey: .metaDescription) ?? ""
      metaKeywords = try container.decodeIfPresent(String.self, forKey: .metaKeywords) ?? ""
      body = try container.decode(String.self, forKey: .body)
      tags = try container.decode([String].self, forKey: .tags)
      linkURL = try container.decode(String.self, forKey: .linkURL)
      locationLabel = try container.decode(String.self, forKey: .locationLabel)
      status = try container.decode(PostStatus.self, forKey: .status)
      publishAt = try container.decodeIfPresent(Date.self, forKey: .publishAt)
      isFeatured = try container.decodeIfPresent(Bool.self, forKey: .isFeatured) ?? false
      featuredPhotoID = try container.decodeIfPresent(UUID.self, forKey: .featuredPhotoID)
      photos = try container.decode([ComposedPhoto].self, forKey: .photos)
      originalHadLink = try container.decode(Bool.self, forKey: .originalHadLink)
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      if try legacy.decodeIfPresent(Bool.self, forKey: .keepLocation) == true {
         for index in photos.indices { photos[index].keepLocation = true }
      }
   }

   /// Starts an edit from a server post. The featured photo is matched by media id.
   public init(post: Post) {
      let photos = post.media.map {
         ComposedPhoto(mediaId: $0.mediaId, remoteURL: $0.thumbnailUrl ?? $0.url, altText: $0.altText ?? "", caption: $0.caption ?? "")
      }
      self.init(
         blog: post.blog, authorId: post.authorId, title: post.title, name: post.name, shortName: post.shortName, slug: post.slug,
         description: post.description ?? "", metaTitle: post.metaTitle ?? "", metaDescription: post.metaDescription ?? "",
         metaKeywords: post.metaKeywords ?? "", body: post.body, tags: post.tags,
         linkURL: post.link?.url ?? "", locationLabel: post.locationLabel ?? "",
         status: post.status, publishAt: post.publishAt, isFeatured: post.isFeatured,
         featuredPhotoID: photos.first { $0.mediaId != nil && $0.mediaId == post.featuredMediaId }?.id,
         photos: photos, originalHadLink: post.link != nil
      )
   }

   /// Whether there is nothing to post: no text, photo or link.
   public var isEmpty: Bool {
      body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty && linkURL.isEmpty
   }

   /// Short label for lists and notifications.
   public var summary: String {
      if let title = title.nilIfBlank { return title }
      let derived = PostText.deriveTitle(body)
      return derived == PostText.fallbackTitle && !photos.isEmpty ? "\(photos.count) photo post" : derived
   }

   /// The server requires a body; a photo or link-only post gets a minimal one.
   var bodyForServer: String {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return body }
      if !linkURL.isEmpty { return linkURL }
      return photos.isEmpty ? body : "📷"
   }

   /// The photo shown as the post's image: the chosen one, else the first.
   public var featuredPhoto: ComposedPhoto? {
      photos.first { $0.id == featuredPhotoID } ?? photos.first
   }

   /// Every value the post is sent with, blanks filled by the `PostText` rules. The
   /// slug here is the base; the service makes it unique within the blog.
   public func draft() -> PostDraft {
      let body = bodyForServer
      let title = title.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.title) } ?? PostText.deriveTitle(body)
      let description =
         description.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.description) }
         ?? PostText.clip(PostText.plain(body), to: PostFieldLimits.description)
      let slugSource = slug.nilIfBlank ?? title
      var slug = PostText.slugify(slugSource, maxLength: slug.nilIfBlank == nil ? PostText.slugLength : PostFieldLimits.slug)
      if slug.isEmpty { slug = PostText.slugify(PostText.fallbackTitle) }
      return PostDraft(
         blog: blog, authorId: authorId, title: title,
         name: name.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.name, ellipsis: false) } ?? PostText.name(fromTitle: title),
         shortName: shortName.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.shortName, ellipsis: false) }
            ?? PostText.shortName(fromTitle: title),
         slug: slug, body: body, description: description,
         excerpt: PostText.excerpt(body), readTime: PostText.readTime(body),
         metaTitle: metaTitle.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.metaTitle) }
            ?? PostText.clip(title, to: PostFieldLimits.seoTitleTarget),
         metaDescription: metaDescription.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.metaDescription) }
            ?? PostText.clip(description, to: PostFieldLimits.seoDescriptionTarget),
         metaKeywords: metaKeywords.nilIfBlank.map { PostText.keywords($0.split(separator: ",").map(String.init)) }
            ?? PostText.keywords(tags),
         tags: tags, locationLabel: locationLabel.nilIfBlank.map { PostText.clip($0, to: PostFieldLimits.locationLabel, ellipsis: false) },
         linkURL: linkURL.nilIfBlank, status: status, publishAt: status == .scheduled ? publishAt : nil, isFeatured: isFeatured,
         featuredMediaId: featuredPhoto?.mediaId,
         media: photos.compactMap { photo in
            photo.mediaId.map { PostDraft.Attachment(mediaId: $0, altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank) }
         }
      )
   }
}

/// A post ready to send: every field resolved. `SiteService` turns it into a
/// `blogPost` record, resolving the blog slug, tag names and the link preview.
public struct PostDraft: Sendable, Equatable {
   /// A photo to attach, in order.
   public struct Attachment: Sendable, Equatable {
      /// The uploaded media record.
      public var mediaId: Int64
      /// Text for screen readers.
      public var altText: String?
      /// Visible caption.
      public var caption: String?
   }

   /// Blog slug.
   public var blog: String
   /// Author to post as; nil means the signed-in user's author.
   public var authorId: Int64?
   /// Headline.
   public var title: String
   /// Display name.
   public var name: String
   /// Short label.
   public var shortName: String
   /// Base slug (made unique when created).
   public var slug: String
   /// Markdown body.
   public var body: String
   /// Summary.
   public var description: String
   /// Plain teaser.
   public var excerpt: String
   /// Minutes to read.
   public var readTime: Int
   /// SEO title.
   public var metaTitle: String
   /// SEO description.
   public var metaDescription: String
   /// SEO keywords.
   public var metaKeywords: String
   /// Tag names.
   public var tags: [String]
   /// Place name.
   public var locationLabel: String?
   /// Link to preview.
   public var linkURL: String?
   /// Draft, published now or scheduled.
   public var status: PostStatus
   /// When a scheduled post goes live.
   public var publishAt: Date?
   /// Featured on the site.
   public var isFeatured: Bool
   /// The post's image.
   public var featuredMediaId: Int64?
   /// Photos in order.
   public var media: [Attachment]
}

extension String {
   /// The trimmed string, or nil when nothing is left.
   var nilIfBlank: String? {
      let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
   }
}
