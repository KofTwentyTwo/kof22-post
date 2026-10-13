/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The photo upload state machine of the outbox: prepare the file once, create a ticket,
/// PUT the bytes, complete the upload, and record the media id.
extension OutboxProcessor {
   /// Which request of an upload was running when it failed.
   enum UploadStage: Sendable {
      /// The PUT of the bytes to the presigned URL.
      case put
      /// The `completeUpload` call.
      case complete
   }

   /// Storage answers 403 to a PUT on an expired (or otherwise invalid) presigned URL.
   static let forbiddenStatus = 403
   /// `completeUpload` answers 409 when the bytes never arrived.
   static let conflictStatus = 409
   /// The prepared file types the outbox keeps, by extension.
   static let preparedTypes: [(fileExtension: String, contentType: String)] = [
      ("jpg", "image/jpeg"), ("png", "image/png"),
   ]

   /// Uploads the photos that have no media id yet, saving each media id as soon as it is
   /// known so a retry continues where this attempt stopped.
   func uploadPhotos(_ item: OutboxSnapshot, service: SiteService) async throws -> PostComposition {
      var composition = item.composition
      let pending = composition.photos.indices.filter { !composition.photos[$0].isUploaded }
      guard !pending.isEmpty else { return composition }
      let limits = try await currentLimits(service)
      for (done, index) in pending.enumerated() {
         try await store.update(item.id) {
            $0.phase = "Uploading photo \(done + 1) of \(pending.count)"
            $0.progress = Double(done) / Double(pending.count + 1)
         }
         let prepared = try preparedFile(for: composition.photos[index], limits: limits)
         let current = composition
         let uploaded = try await upload(current.photos[index], prepared: prepared, item: item, service: service) { photo in
            ////////////////////////////////////////////////////////////////
            // A restart is saved at once so later retries see it.        //
            ////////////////////////////////////////////////////////////////
            var restarted = current
            restarted.photos[index] = photo
            let saved = restarted
            try await self.store.update(item.id) { $0.composition = saved }
         }
         composition.photos[index] = uploaded
         let saved = composition
         try await store.update(item.id) { $0.composition = saved }
         removeWorkFile(prepared.fileURL)
      }
      return composition
   }

   /// Runs ticket, PUT and complete for one photo and returns it with its media attached.
   /// An expired presigned URL restarts the upload once (`canRestart`) with a new
   /// ticket, after `saveRestart` persists the new generation; any other failure is
   /// thrown.
   func upload(
      _ photo: ComposedPhoto, prepared: PreparedPhoto, item: OutboxSnapshot, service: SiteService, canRestart: Bool = true,
      saveRestart: (ComposedPhoto) async throws -> Void
   ) async throws -> ComposedPhoto {
      let ticket = try await service.createUpload(
         UploadRequest(fileName: prepared.fileURL.lastPathComponent, contentType: prepared.contentType, byteSize: prepared.byteSize)
      )
      var stage = UploadStage.put
      do {
         try await service.putUpload(fileURL: prepared.fileURL, ticket: ticket)
         stage = .complete
         let media = try await service.completeUpload(
            id: ticket.uploadId,
            UploadCompletion(altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank, keepLocation: photo.keepLocation)
         )
         var uploaded = photo
         uploaded.attach(media)
         return uploaded
      }
      catch  where canRestart && Self.isExpiredUpload(error, stage: stage, expiresAt: ticket.expiresAt, now: now()) {
         Log.outbox.info("Upload URL for a photo of \(item.id, privacy: .public) expired; starting a new upload")
         var restarted = photo
         restarted.uploadGeneration += 1
         try await saveRestart(restarted)
         return try await upload(restarted, prepared: prepared, item: item, service: service, canRestart: false, saveRestart: saveRestart)
      }
   }

   /// Whether a failure means the presigned URL expired, so a fresh ticket can succeed:
   /// storage refused the PUT with 403, or completion found no bytes because the URL ran
   /// out (`upload_expired`, or `upload_not_received` once the ticket has expired).
   static func isExpiredUpload(_ error: any Error, stage: UploadStage, expiresAt: Date, now: Date) -> Bool {
      guard let error = error as? APIError else { return false }
      switch stage {
      case .put:
         return error.status == forbiddenStatus
      case .complete:
         guard error.status == conflictStatus else { return false }
         return error.code == "upload_expired" || (error.code == "upload_not_received" && now >= expiresAt)
      }
   }

   /// The photo prepared for upload. A file prepared by an earlier attempt is reused, so
   /// the bytes, size and idempotency key stay the same across retries and a background
   /// upload still in flight keeps its file; otherwise the original is prepared with the
   /// photo's location choice and the current size preference.
   func preparedFile(for photo: ComposedPhoto, limits: PhotoLimits) throws -> PreparedPhoto {
      for type in Self.preparedTypes {
         let url = workDirectory.appending(path: "\(photo.id.uuidString).\(type.fileExtension)")
         if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return PreparedPhoto(fileURL: url, contentType: type.contentType, byteSize: try MediaProcessor.fileSize(url))
         }
      }
      guard let source = photo.localURL(in: photosDirectory), FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
         throw APIError(status: Self.goneStatus, code: "photo_missing", message: "A photo for this post is no longer on the device")
      }
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: photo.keepLocation, acceptedTypes: limits.photoContentTypes,
         maxBytes: limits.maxPhotoBytes, size: uploadSize(), workDirectory: workDirectory
      )
      /////////////////////////////////////////////////////////////////
      // A stable name lets the next attempt find the file; the move //
      // is atomic, so a crash never leaves a half-written file.     //
      /////////////////////////////////////////////////////////////////
      let fileExtension = prepared.contentType == "image/png" ? "png" : "jpg"
      let target = workDirectory.appending(path: "\(photo.id.uuidString).\(fileExtension)")
      try FileManager.default.moveItem(at: prepared.fileURL, to: target)
      return PreparedPhoto(fileURL: target, contentType: prepared.contentType, byteSize: prepared.byteSize)
   }

   /// Deletes a prepared file that is no longer needed. A failure only leaves a stray
   /// file that `sweepWorkDirectory` removes later, so it is logged rather than thrown.
   func removeWorkFile(_ url: URL) {
      do {
         try FileManager.default.removeItem(at: url)
      }
      catch {
         Log.outbox.warning("Removing a prepared photo failed: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// Removes prepared files older than `workFileRetention`: leftovers of items that were
   /// deleted or abandoned before their photos were uploaded.
   func sweepWorkDirectory() {
      let cutoff = now().addingTimeInterval(-Self.workFileRetention)
      let files: [URL]
      do {
         files = try FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
      }
      catch {
         Log.outbox.info("No prepared photos to sweep: \(error.localizedDescription, privacy: .public)")
         return
      }
      for file in files where Self.modificationDate(of: file) < cutoff {
         removeWorkFile(file)
      }
   }

   /// When `file` last changed; a file whose date cannot be read counts as new, so it is
   /// kept rather than deleted while it may still be in use.
   static func modificationDate(of file: URL) -> Date {
      let date: Date?
      do {
         date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      }
      catch {
         Log.outbox.warning("Reading the date of a prepared photo failed: \(error.localizedDescription, privacy: .public)")
         date = nil
      }
      return date ?? .distantFuture
   }
}
