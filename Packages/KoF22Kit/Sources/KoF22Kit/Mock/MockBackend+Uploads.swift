/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO

/// The upload processes (`createUpload`, the presigned PUT, `completeUpload`) and
/// `linkPreview`.
extension MockBackend {
   /// How long a presigned upload URL stays valid (15 minutes, as on the server).
   static let uploadLifetime: TimeInterval = 900
   /// Host of the fake presigned URLs; never resolved.
   static let uploadHost = "https://uploads.mock.kof22.invalid/"

   /// `POST /media/createUpload`: a ticket for one photo.
   func createUpload(_ body: Data?) throws -> Response {
      guard let input = Self.decodeBody(UploadRequest.self, from: body) else {
         return try problem(Status.badRequest, "bad_request", "fileName, contentType and byteSize are required")
      }
      guard Self.demoCaller.limits.photoContentTypes.contains(input.contentType) || input.contentType == "image/heic" else {
         return try problem(Status.unsupportedMediaType, "unsupported_media_type", "Use JPEG or PNG")
      }
      guard input.byteSize <= Self.demoCaller.limits.maxPhotoBytes else {
         return try problem(Status.unprocessable, "image_too_large", "The photo is too large")
      }
      let id = UUID().uuidString.lowercased()
      let expires = now().addingTimeInterval(Self.uploadLifetime)
      state.uploads[id] = StoredUpload(fileName: input.fileName, contentType: input.contentType, expiresAt: expires)
      let ticket = UploadTicket(
         uploadId: id, uploadUrl: Self.uploadHost + id, headers: ["Content-Type": input.contentType], expiresAt: expires,
         maxBytes: Self.demoCaller.limits.maxPhotoBytes)
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

   /// `POST /media/completeUpload/{id}`: turns the received file into a media record of
   /// the site. Completing twice answers the same record.
   func completeUpload(_ id: String, body: Data?) throws -> Response {
      guard var upload = state.uploads[id] else { return try problem(Status.notFound, "not_found", "Upload not found") }
      //////////////////////////////////////////////////////////////////
      // Every field of the completion body is optional, so a missing //
      // or unreadable body means the defaults, as on the server.     //
      //////////////////////////////////////////////////////////////////
      let input = Self.decodeBody(UploadCompletion.self, from: body) ?? UploadCompletion(altText: nil, caption: nil, keepLocation: false)
      if let mediaId = upload.mediaId, let media = state.media.first(where: { $0.id == mediaId }), let url = media.publicUrl {
         return try json(Status.okay, mediaItem(id: mediaId, url: url, media, locationRemoved: !input.keepLocation))
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
      let mediaId = state.takeId()
      let file = "media-\(mediaId).\(upload.contentType == "image/png" ? "png" : "jpg")"
      let destination = try mediaDirectory().appending(path: file)
      ////////////////////////////////////////////////////////////////////
      // An in-memory fake's temporary folder can hold a file left by a //
      // previous instance; the new media replaces it.                  //
      ////////////////////////////////////////////////////////////////////
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: fileURL, to: destination)
      let url = publicURL(file)
      let media = Components.Schemas.Media(
         altText: input.altText?.nilIfBlank, caption: input.caption?.nilIfBlank, createDate: now(), fileName: upload.fileName,
         height: properties[kCGImagePropertyPixelHeight] as? Int, id: mediaId, isActive: true, mimeType: upload.contentType,
         modifyDate: now(), name: upload.fileName, publicUrl: url, siteId: Self.siteId, thumbnailUrl: url,
         width: properties[kCGImagePropertyPixelWidth] as? Int)
      state.media.append(media)
      upload.mediaId = mediaId
      state.uploads[id] = upload
      return try json(Status.okay, mediaItem(id: mediaId, url: url, media, locationRemoved: !input.keepLocation))
   }

   /// The process answer for the media record `id` at `url`.
   func mediaItem(id: Int, url: String, _ media: Components.Schemas.Media, locationRemoved: Bool) -> MediaItem {
      MediaItem(
         mediaId: Int64(id), url: url, thumbnailUrl: media.thumbnailUrl, width: media.width,
         height: media.height, mimeType: media.mimeType, altText: media.altText, caption: media.caption, locationRemoved: locationRemoved)
   }

   /// A file URL when the fake keeps files on disk, else the `mock-media:` form.
   func publicURL(_ file: String) -> String {
      let stored = "\(Self.mediaScheme):\(file)"
      return directory.flatMap { fileURL(forMockMedia: stored, directory: $0)?.absoluteString } ?? stored
   }

   /// The folder for received and completed files, created on demand. An in-memory
   /// fake uses a per-instance temporary folder.
   func mediaDirectory() throws -> URL {
      let base = directory ?? FileManager.default.temporaryDirectory.appending(path: "kof22-mock-\(ObjectIdentifier(self).hashValue)")
      let url = base.appending(path: "media", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
   }

   /// `POST /blogPost/linkPreview`: a preview made from the URL itself (the fake never
   /// goes online). Only public http(s) addresses are accepted.
   func linkPreview(_ body: Data?) throws -> Response {
      guard let input = Self.decodeBody([String: String].self, from: body), let raw = input["url"], let url = URL(string: raw),
         let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
      else {
         return try problem(Status.unprocessable, "link_not_allowed", "Only public http or https links can be used")
      }
      let title = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? host : url.lastPathComponent
      return try json(Status.okay, LinkPreview(url: raw, title: title, description: "A page on \(host)", imageUrl: nil))
   }
}
