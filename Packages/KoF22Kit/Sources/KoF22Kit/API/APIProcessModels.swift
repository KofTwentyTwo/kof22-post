/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

// The payloads of the Site API v2 processes, whose shapes the spec leaves untyped
// (`ProcessClient`): uploads, link previews and the version list.

/// The presigned URL and headers for one photo upload (`POST /media/createUpload`).
public struct UploadTicket: Codable, Sendable, Hashable {
   /// Identifies the upload for `completeUpload`.
   public var uploadId: String
   /// Presigned URL; PUT the raw bytes here.
   public var uploadUrl: String
   /// Always `PUT`.
   public var method: String?
   /// Headers to send with the PUT.
   public var headers: [String: String]
   /// When the presigned URL stops working.
   public var expiresAt: Date
   /// Largest accepted file.
   public var maxBytes: Int64?

   /// Creates a ticket; used by the fake backend and tests.
   public init(uploadId: String, uploadUrl: String, method: String? = "PUT", headers: [String: String], expiresAt: Date, maxBytes: Int64?) {
      self.uploadId = uploadId
      self.uploadUrl = uploadUrl
      self.method = method
      self.headers = headers
      self.expiresAt = expiresAt
      self.maxBytes = maxBytes
   }
}

/// The request for a presigned photo upload.
public struct UploadRequest: Codable, Sendable, Hashable {
   /// File name, used for the media record's name.
   public var fileName: String
   /// MIME type of the bytes.
   public var contentType: String
   /// Size of the bytes.
   public var byteSize: Int64

   /// Creates a request.
   public init(fileName: String, contentType: String, byteSize: Int64) {
      self.fileName = fileName
      self.contentType = contentType
      self.byteSize = byteSize
   }
}

/// Confirms an upload once the bytes are stored (`POST /media/completeUpload/{id}`).
public struct UploadCompletion: Codable, Sendable, Hashable {
   /// Text for screen readers.
   public var altText: String?
   /// Visible caption.
   public var caption: String?
   /// Keep EXIF including GPS (published publicly).
   public var keepLocation: Bool

   /// Creates a completion.
   public init(altText: String?, caption: String?, keepLocation: Bool) {
      self.altText = altText
      self.caption = caption
      self.keepLocation = keepLocation
   }
}

/// An uploaded photo that can be attached to a post.
public struct MediaItem: Codable, Sendable, Hashable {
   /// The new `media` record.
   public var mediaId: Int64
   /// Full-size public URL.
   public var url: String
   /// Thumbnail URL.
   public var thumbnailUrl: String?
   /// Width in pixels.
   public var width: Int?
   /// Height in pixels.
   public var height: Int?
   /// Stored MIME type.
   public var mimeType: String?
   /// Alt text as stored.
   public var altText: String?
   /// Caption as stored.
   public var caption: String?
   /// True when the server removed location metadata.
   public var locationRemoved: Bool?

   /// Creates a media item; used by the fake backend and tests.
   public init(
      mediaId: Int64, url: String, thumbnailUrl: String? = nil, width: Int? = nil, height: Int? = nil, mimeType: String? = nil,
      altText: String? = nil, caption: String? = nil, locationRemoved: Bool? = nil
   ) {
      self.mediaId = mediaId
      self.url = url
      self.thumbnailUrl = thumbnailUrl
      self.width = width
      self.height = height
      self.mimeType = mimeType
      self.altText = altText
      self.caption = caption
      self.locationRemoved = locationRemoved
   }
}

/// The title, description and image the server found for a link.
public struct LinkPreview: Codable, Sendable, Hashable {
   /// The final URL.
   public var url: String
   /// Page title.
   public var title: String?
   /// Page description.
   public var description: String?
   /// Page image.
   public var imageUrl: String?

   /// Creates a preview.
   public init(url: String, title: String? = nil, description: String? = nil, imageUrl: String? = nil) {
      self.url = url
      self.title = title
      self.description = description
      self.imageUrl = imageUrl
   }
}

/// The API versions the server supports (`/versions.json`).
public struct APIVersions: Codable, Sendable, Hashable {
   /// Semantic version per major version, such as `["v2": "2.1.0"]`.
   public var semanticVersions: [String: String]
   /// The major versions served.
   public var supportedVersions: [String]
   /// The newest major version.
   public var currentVersion: String

   /// The major version this app is built for.
   public static let appMajor = "v2"

   /// The semantic version of the app's major version, when the server serves it.
   public var appVersion: String? { semanticVersions[Self.appMajor] }
}
