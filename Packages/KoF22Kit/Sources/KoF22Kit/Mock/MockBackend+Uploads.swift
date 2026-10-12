/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO

/// The photo upload flow: create a ticket, PUT the bytes to the presigned URL,
/// then complete the upload to get a media id.
extension MockBackend {
   /// How long a presigned upload URL stays valid (15 minutes).
   static let uploadLifetime: TimeInterval = 900
   /// Base of the presigned upload URLs; the upload id is the last path segment.
   static let uploadBaseURL = "https://mock.s3.kof22.invalid/kof22-website-incoming"

   /// `POST /me/uploads`: refuses HEIC (no converter on this server) and files over
   /// the size limit, then issues a ticket with a presigned PUT URL.
   func createUpload(_ body: Data?) throws -> Response {
      guard let input = Self.decodeBody(UploadCreate.self, from: body) else { return try badBody() }
      if input.contentType == .imageHeic || input.contentType == .imageHeif {
         return try problem(Status.unsupportedMediaType, "heic_conversion_unavailable", "HEIC is not accepted by this server; send JPEG")
      }
      if input.byteSize > Self.limits.maxPhotoBytes {
         return try problem(Status.payloadTooLarge, "payload_too_large", "Photos are limited to \(Self.limits.maxPhotoBytes) bytes")
      }
      if input.byteSize <= 0 { return try validation([.init(field: "byteSize", issue: "must be positive")]) }
      let id = UUID().uuidString.lowercased()
      let expires = now().addingTimeInterval(Self.uploadLifetime)
      state.uploads[id] = StoredUpload(
         fileName: input.fileName, contentType: input.contentType.rawValue,
         byteSize: input.byteSize, expiresAt: expires)
      let ticket = UploadTicket(
         uploadId: id,
         uploadUrl: "\(Self.uploadBaseURL)/\(id)",
         method: .put,
         headers: .init(additionalProperties: ["Content-Type": input.contentType.rawValue]),
         expiresAt: expires,
         maxBytes: Self.limits.maxPhotoBytes,
         completeUrl: "https://api.kof22.com/v1/me/uploads/\(id)/complete"
      )
      return try json(Status.created, ticket)
   }

   /// Receives the bytes PUT to a presigned upload URL. Unknown and expired URLs are
   /// refused with 403, as S3 does.
   public func receiveUpload(id: String, from fileURL: URL) throws {
      reload()
      guard var upload = state.uploads[id] else { throw APIError(status: Status.forbidden, code: "upload_put_failed", message: "Unknown upload URL") }
      guard upload.expiresAt > now() else { throw APIError(status: Status.forbidden, code: "upload_put_failed", message: "Upload URL expired") }
      let name = "upload-\(id)"
      let target = try mediaDirectory().appending(path: name)
      ////////////////////////////////////////////////////////////////
      // A repeated PUT replaces the earlier bytes; usually absent. //
      ////////////////////////////////////////////////////////////////
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.copyItem(at: fileURL, to: target)
      upload.receivedFile = name
      state.uploads[id] = upload
      save()
   }

   /// `POST /me/uploads/{id}/complete`: turns the received file into a media item.
   /// Completing twice replays the same media item.
   func completeUpload(_ id: String, body: Data?) throws -> Response {
      guard var upload = state.uploads[id] else { return try problem(Status.notFound, "not_found", "Upload not found") }
      //////////////////////////////////////////////////////////////////
      // Every field of the completion body is optional, so a missing //
      // or unreadable body means the defaults, as on the server.     //
      //////////////////////////////////////////////////////////////////
      let input = Self.decodeBody(UploadComplete.self, from: body) ?? UploadComplete()
      let locationRemoved = !(input.keepLocation ?? false)
      if let mediaId = upload.mediaId, let media = state.media[mediaId] {
         return try json(Status.okay, mediaItem(mediaId, media, locationRemoved: locationRemoved))
      }
      guard let received = upload.receivedFile else {
         if upload.expiresAt < now() { return try problem(Status.conflict, "upload_expired", "The upload URL expired") }
         return try problem(Status.conflict, "upload_not_received", "No file has been uploaded yet")
      }
      let fileURL = try mediaDirectory().appending(path: received)
      guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
         let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      else {
         return try problem(Status.unsupportedMediaType, "unsupported_media_type", "The uploaded file is not an image")
      }
      let mediaId = state.nextMediaId
      let file = "media-\(mediaId).\(upload.contentType == "image/png" ? "png" : "jpg")"
      let destination = try mediaDirectory().appending(path: file)
      ////////////////////////////////////////////////////////////////////
      // An in-memory mock's temporary folder can hold a file left by a //
      // previous instance; the new media replaces it.                  //
      ////////////////////////////////////////////////////////////////////
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: fileURL, to: destination)
      state.nextMediaId += 1
      let media = StoredMedia(
         file: file, mimeType: upload.contentType,
         width: properties[kCGImagePropertyPixelWidth] as? Int,
         height: properties[kCGImagePropertyPixelHeight] as? Int,
         altText: Self.blankToNil(input.altText))
      state.media[mediaId] = media
      upload.mediaId = mediaId
      state.uploads[id] = upload
      return try json(Status.okay, mediaItem(mediaId, media, locationRemoved: locationRemoved))
   }

   /// Builds the API's media item, with a file URL when the mock keeps files on disk.
   func mediaItem(_ id: Int64, _ media: StoredMedia, locationRemoved: Bool) -> MediaItem {
      let stored = "\(Self.mediaScheme):\(media.file)"
      let url = directory.flatMap { fileURL(forMockMedia: stored, directory: $0)?.absoluteString } ?? stored
      return MediaItem(
         mediaId: id, url: url, thumbnailUrl: url, width: media.width, height: media.height,
         mimeType: media.mimeType, altText: media.altText, caption: nil, locationRemoved: locationRemoved)
   }

   /// The folder for received and completed files, created on demand. An in-memory
   /// mock uses a per-instance temporary folder.
   func mediaDirectory() throws -> URL {
      let base = directory ?? FileManager.default.temporaryDirectory.appending(path: "kof22-mock-\(ObjectIdentifier(self).hashValue)")
      let url = base.appending(path: "media", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
   }
}
