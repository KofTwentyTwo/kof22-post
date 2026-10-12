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

/// What the user wrote, independent of whether it has been sent yet.
public struct PostComposition: Codable, Sendable, Equatable {
   /// A composition may be scheduled no sooner than this, leaving time to send it
   /// before the server's own 30-second minimum applies.
   public static let minimumScheduleLead: TimeInterval = 60
   /// The server refuses a schedule more than 366 days ahead.
   public static let maximumScheduleHorizon: TimeInterval = 31_622_400
   /// Longest tag name the server accepts (`PostCreate.tags.items.maxLength`).
   public static let maxTagLength = 50
   /// Longest place name the server accepts (`PostCreate.locationLabel.maxLength`).
   public static let maxLocationLabelLength = 200
   /// Longest link the server accepts (`PostCreate.linkUrl.maxLength`).
   public static let maxLinkLength = 2_000
   /// Longest photo alt text the server accepts (`MediaAttachment.altText.maxLength`).
   public static let maxAltTextLength = 1_000
   /// Longest photo caption the server accepts (`MediaAttachment.caption.maxLength`).
   public static let maxCaptionLength = 2_000

   /// The blog slug to post to.
   public var blog: String
   /// Optional title; blank lets the server derive one from the body.
   public var title: String
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
   /// Attached photos, local or already uploaded.
   public var photos: [ComposedPhoto]
   /// For edits: whether the server copy had a link, so removing it sends `null`.
   public var originalHadLink: Bool

   /// Creates a composition; the defaults are an empty post to the default blog,
   /// published on send.
   public init(
      blog: String = "quick-bits", title: String = "", body: String = "", tags: [String] = [],
      linkURL: String = "", locationLabel: String = "",
      status: PostStatus = .published, publishAt: Date? = nil, photos: [ComposedPhoto] = [],
      originalHadLink: Bool = false
   ) {
      self.blog = blog
      self.title = title
      self.body = body
      self.tags = tags
      self.linkURL = linkURL
      self.locationLabel = locationLabel
      self.status = status
      self.publishAt = publishAt
      self.photos = photos
      self.originalHadLink = originalHadLink
   }

   /// The post-level location switch of payloads saved before location became a
   /// per-photo choice; read when decoding, never written.
   private enum LegacyKeys: String, CodingKey {
      /// Whether every photo of the post kept its GPS metadata.
      case keepLocation
   }

   /// Decodes a stored composition. An older payload's post-level `keepLocation: true`
   /// opts every one of its photos in, so a queued post keeps the choice it was made with.
   public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      blog = try container.decode(String.self, forKey: .blog)
      title = try container.decode(String.self, forKey: .title)
      body = try container.decode(String.self, forKey: .body)
      tags = try container.decode([String].self, forKey: .tags)
      linkURL = try container.decode(String.self, forKey: .linkURL)
      locationLabel = try container.decode(String.self, forKey: .locationLabel)
      status = try container.decode(PostStatus.self, forKey: .status)
      publishAt = try container.decodeIfPresent(Date.self, forKey: .publishAt)
      photos = try container.decode([ComposedPhoto].self, forKey: .photos)
      originalHadLink = try container.decode(Bool.self, forKey: .originalHadLink)
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      if try legacy.decodeIfPresent(Bool.self, forKey: .keepLocation) == true {
         for index in photos.indices { photos[index].keepLocation = true }
      }
   }

   /// Starts an edit from a server post.
   public init(post: Post) {
      self.init(
         blog: post.blog, title: post.title, body: post.body, tags: post.tags,
         linkURL: post.link?.url ?? "", locationLabel: post.locationLabel ?? "",
         status: post.status, publishAt: post.publishAt,
         photos: post.media.map {
            ComposedPhoto(
               mediaId: $0.mediaId, remoteURL: $0.thumbnailUrl ?? $0.url,
               altText: $0.altText ?? "", caption: $0.caption ?? "")
         },
         originalHadLink: post.link != nil
      )
   }

   /// Whether there is nothing to post: no text, photo or link.
   public var isEmpty: Bool {
      body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty && linkURL.isEmpty
   }

   /// Short label for lists and notifications.
   public var summary: String {
      let title = title.trimmingCharacters(in: .whitespaces)
      if !title.isEmpty { return title }
      let derived = MockBackend.deriveTitle(body)
      return derived == MockBackend.fallbackTitle && !photos.isEmpty ? "\(photos.count) photo post" : derived
   }

   /// The server requires a body; a photo or link-only post gets a minimal one.
   var bodyForServer: String {
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return body }
      if !linkURL.isEmpty { return linkURL }
      return photos.isEmpty ? body : "📷"
   }

   /// The uploaded photos as API attachments; photos not yet uploaded are left out.
   var mediaAttachments: [MediaAttachment] {
      photos.compactMap { photo in
         photo.mediaId.map {
            MediaAttachment(mediaId: $0, altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank)
         }
      }
   }

   /// The create request: blank optional fields are omitted.
   func createBody() -> PostCreate {
      PostCreate(
         blog: blog,
         title: title.nilIfBlank,
         body: bodyForServer,
         status: status,
         publishAt: status == .scheduled ? publishAt : nil,
         tags: tags,
         locationLabel: locationLabel.nilIfBlank,
         linkUrl: linkURL.nilIfBlank,
         media: mediaAttachments
      )
   }

   /// Full-state update: the server treats blank title as "derive" and blank
   /// location as "clear"; a removed link needs an explicit null (`clearLink`).
   func updateBody() -> (PostUpdate, clearLink: Bool) {
      let update = PostUpdate(
         blog: blog,
         title: title.trimmingCharacters(in: .whitespaces),
         body: bodyForServer,
         status: status,
         publishAt: status == .scheduled ? publishAt : nil,
         tags: tags,
         locationLabel: locationLabel.trimmingCharacters(in: .whitespaces),
         linkUrl: linkURL.nilIfBlank,
         media: mediaAttachments
      )
      return (update, linkURL.nilIfBlank == nil && originalHadLink)
   }
}

extension String {
   /// The trimmed string, or nil when nothing is left.
   var nilIfBlank: String? {
      let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
   }
}
