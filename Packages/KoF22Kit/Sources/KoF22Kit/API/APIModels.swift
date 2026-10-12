/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
@_exported import KoF22API

// The generated schema types are the domain model. When the spec changes, code that
// depends on a changed field stops compiling, which is exactly what we want.

/// A post as its author sees it, including drafts and scheduled posts.
public typealias Post = Components.Schemas.AuthoringPost
/// Draft, scheduled or published.
public typealias PostStatus = Components.Schemas.PostStatus
/// The body of `POST /v1/me/posts`.
public typealias PostCreate = Components.Schemas.PostCreate
/// The body of `PATCH /v1/me/posts/{id}`.
public typealias PostUpdate = Components.Schemas.PostUpdate
/// One page of the author's posts with the cursor for the next page.
public typealias PostPage = Components.Schemas.PostPage
/// A photo attached to a post.
public typealias PostPhoto = Components.Schemas.PostPhoto
/// The link card attached to a post.
public typealias PostLink = Components.Schemas.PostLink
/// A reference to an uploaded photo when creating or updating a post.
public typealias MediaAttachment = Components.Schemas.MediaAttachment
/// The signed-in author, their blogs and the server's authoring limits.
public typealias Me = Components.Schemas.Me  // swiftlint:disable:this type_name
/// A blog the author can post to.
public typealias BlogRef = Components.Schemas.BlogRef
/// The server's limits on title, body, tags and photos.
public typealias AuthoringLimits = Components.Schemas.AuthoringLimits
/// A tag suggestion from autocomplete.
public typealias AuthoringTag = Components.Schemas.AuthoringTag
/// The title and image the server found for a link.
public typealias LinkPreview = Components.Schemas.LinkPreview
/// The request for a presigned photo upload.
public typealias UploadCreate = Components.Schemas.UploadCreate
/// The presigned URL and headers for one photo upload.
public typealias UploadTicket = Components.Schemas.UploadTicket
/// Confirms an upload once the bytes are stored.
public typealias UploadComplete = Components.Schemas.UploadComplete
/// An uploaded photo that can be attached to a post.
public typealias MediaItem = Components.Schemas.MediaItem
/// The API versions the server supports.
public typealias APIVersions = Components.Schemas.Versions

extension Components.Schemas.AuthoringPost: Identifiable {}
extension Components.Schemas.BlogRef: Identifiable {}
extension Components.Schemas.AuthoringTag: Identifiable {}

extension Components.Schemas.PostStatus {
   /// The status as shown in the post list and composer.
   public var label: String {
      switch self {
      case .draft: "Draft"
      case .scheduled: "Scheduled"
      case .published: "Published"
      }
   }
}

extension Components.Schemas.AuthoringLimits {
   /// Longest body the backend's `AuthoringService` accepts, in characters.
   private static let fallbackMaxBodyLength = 10_000
   /// Longest title the backend accepts, in characters.
   private static let fallbackMaxTitleLength = 100
   /// Most tags the backend accepts on one post.
   private static let fallbackMaxTags = 10
   /// Most photos the backend accepts on one post.
   private static let fallbackMaxPhotosPerPost = 20
   /// Largest photo the backend accepts: 25 MiB.
   private static let fallbackMaxPhotoBytes: Int64 = 26_214_400

   /// Used before `/me` has loaded (values from the backend's `AuthoringService`).
   public static let fallback = AuthoringLimits(
      maxBodyLength: fallbackMaxBodyLength,
      maxTitleLength: fallbackMaxTitleLength,
      maxTags: fallbackMaxTags,
      maxPhotosPerPost: fallbackMaxPhotosPerPost,
      maxPhotoBytes: fallbackMaxPhotoBytes,
      photoContentTypes: ["image/jpeg", "image/png"]
   )
}
