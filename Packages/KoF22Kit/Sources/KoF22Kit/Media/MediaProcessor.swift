/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo file ready to upload, with the content type and size the upload ticket needs.
public struct PreparedPhoto: Sendable, Equatable {
   /// The prepared file in the work directory.
   public var fileURL: URL
   /// The content type declared to the server.
   public var contentType: UploadCreate.ContentTypePayload
   /// The file's size in bytes.
   public var byteSize: Int64
}

/// Why a photo could not be prepared.
public enum MediaError: Error, LocalizedError, Equatable {
   /// The file is not an image ImageIO can read.
   case unreadable
   /// Writing the converted or stripped image failed.
   case encodeFailed
   /// The photo stays over the byte limit even at the smallest allowed size.
   case tooLarge

   /// A sentence for the outbox row.
   public var errorDescription: String? {
      switch self {
      case .unreadable: "The photo could not be read."
      case .encodeFailed: "The photo could not be converted."
      case .tooLarge: "The photo is too large to upload."
      }
   }
}

/// Prepares a photo for upload. Originals are kept at full resolution (owner's
/// choice); the only changes are:
///   - GPS metadata is removed unless the post opts in (lossless for JPEG/PNG);
///   - formats the server does not accept (HEIC today) are converted to JPEG;
///   - a photo over the server's byte limit is re-encoded smaller until it fits.
public enum MediaProcessor {
   /// JPEG quality for format conversion; visually lossless for photos.
   static let jpegQuality = 0.92

   /// JPEG quality once a photo has to shrink to fit the byte limit.
   static let shrinkQuality = 0.85

   /// The longest edge, in pixels, of the first shrink attempt.
   static let firstShrinkPixelSize = 6_000

   /// The smallest longest edge worth uploading; below this the photo is refused.
   static let minimumShrinkPixelSize = 1_000

   /// Each shrink attempt keeps three quarters of the previous longest edge.
   static let shrinkNumerator = 3
   /// See `shrinkNumerator`.
   static let shrinkDenominator = 4

   /// Copies or converts `source` into `workDirectory`. JPEG and PNG files the server
   /// accepts pass through with only GPS removed; anything else becomes JPEG. A result
   /// over `maxBytes` is re-encoded at smaller sizes until it fits.
   public static func prepare(
      source: URL,
      keepLocation: Bool,
      acceptedTypes: [String],
      maxBytes: Int64,
      workDirectory: URL
   ) throws -> PreparedPhoto {
      guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
         let typeID = CGImageSourceGetType(image) as String?,
         let type = UTType(typeID)
      else { throw MediaError.unreadable }

      let accepted = Set(acceptedTypes)
      let serverAccepts = type.preferredMIMEType.map { accepted.contains($0) } == true
      let passThrough = serverAccepts && (type.conforms(to: .jpeg) || type.conforms(to: .png))
      try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

      var output: URL
      var contentType: UploadCreate.ContentTypePayload
      if passThrough {
         contentType = type.conforms(to: .png) ? .imagePng : .imageJpeg
         output = workDirectory.appending(path: UUID().uuidString + (contentType == .imagePng ? ".png" : ".jpg"))
         if keepLocation {
            try FileManager.default.copyItem(at: source, to: output)
         }
         else {
            try copyWithoutGPS(image, type: type, to: output)
         }
      }
      else {
         contentType = .imageJpeg
         output = workDirectory.appending(path: UUID().uuidString + ".jpg")
         try encodeJPEG(image, keepLocation: keepLocation, maxPixelSize: nil, quality: jpegQuality, to: output)
      }

      var size = try fileSize(output)
      var maxPixel = firstShrinkPixelSize
      while size > maxBytes {
         guard maxPixel >= minimumShrinkPixelSize else { throw MediaError.tooLarge }
         removeLeftover(output)
         contentType = .imageJpeg
         output = workDirectory.appending(path: UUID().uuidString + ".jpg")
         try encodeJPEG(image, keepLocation: keepLocation, maxPixelSize: maxPixel, quality: shrinkQuality, to: output)
         size = try fileSize(output)
         maxPixel = maxPixel * shrinkNumerator / shrinkDenominator
      }
      return PreparedPhoto(fileURL: output, contentType: contentType, byteSize: size)
   }

   /// Deletes an earlier attempt that was too large. Failure only leaves a stray file in
   /// the work directory, so it is logged rather than thrown.
   static func removeLeftover(_ url: URL) {
      do {
         try FileManager.default.removeItem(at: url)
      }
      catch {
         Log.media.warning("Removing an oversized attempt failed: \(error.localizedDescription, privacy: .public)")
      }
   }

   /// An image destination for one image of `type` at `url`.
   static func makeDestination(_ url: URL, type: UTType) throws -> CGImageDestination {
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
         throw MediaError.encodeFailed
      }
      return destination
   }

   /// Rewrites metadata without recompressing the image data where ImageIO can, and
   /// re-encodes when the lossless copy fails or leaves GPS data behind.
   static func copyWithoutGPS(_ image: CGImageSource, type: UTType, to url: URL) throws {
      let destination = try makeDestination(url, type: type)
      ////////////////////////////////////////////////////////////
      // merge an empty set into the existing metadata so all   //
      // else (orientation, EXIF) survives; without the merge   //
      // flag ImageIO drops orientation.                        //
      ////////////////////////////////////////////////////////////
      let options: [CFString: Any] = [
         kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
         kCGImageDestinationMergeMetadata: true,
         kCGImageMetadataShouldExcludeGPS: true,
      ]
      var error: Unmanaged<CFError>?
      let copied = CGImageDestinationCopyImageSource(destination, image, options as CFDictionary, &error)
      if copied && !hasGPS(url) { return }
      ////////////////////////////////////////////////////////////
      // lossless copy is not supported for every format, and   //
      // for PNG it leaves GPS fields in the XMP packet, so     //
      // re-encode. The partial file may not exist; a failed    //
      // removal is expected and the re-encode overwrites it.   //
      ////////////////////////////////////////////////////////////
      try? FileManager.default.removeItem(at: url)
      let fallback = try makeDestination(url, type: type)
      CGImageDestinationAddImageFromSource(fallback, image, 0, [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary)
      guard CGImageDestinationFinalize(fallback) else { throw MediaError.encodeFailed }
   }

   /// Encodes the first image of `image` as JPEG, optionally scaled so its longest edge is
   /// at most `maxPixelSize`. Scaling bakes the orientation into the pixels.
   static func encodeJPEG(_ image: CGImageSource, keepLocation: Bool, maxPixelSize: Int?, quality: Double, to url: URL) throws {
      let destination = try makeDestination(url, type: .jpeg)
      var properties = (CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]) ?? [:]
      properties[kCGImageDestinationLossyCompressionQuality] = quality
      if !keepLocation { properties[kCGImagePropertyGPSDictionary] = kCFNull }
      if let maxPixelSize {
         let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
         ]
         guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
            throw MediaError.encodeFailed
         }
         //////////////////////////////////////////////////////
         // the transform is baked in, so orientation resets //
         // to up.                                           //
         //////////////////////////////////////////////////////
         properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
         properties[kCGImagePropertyPixelWidth] = nil
         properties[kCGImagePropertyPixelHeight] = nil
         CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
      }
      else {
         CGImageDestinationAddImageFromSource(destination, image, 0, properties as CFDictionary)
      }
      guard CGImageDestinationFinalize(destination) else { throw MediaError.encodeFailed }
   }

   /// The size of the file at `url` in bytes.
   static func fileSize(_ url: URL) throws -> Int64 {
      Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
   }

   /// True when the file carries a GPS dictionary (used by tests and the UI).
   public static func hasGPS(_ url: URL) -> Bool {
      guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
         let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
      else { return false }
      return properties[kCGImagePropertyGPSDictionary] != nil
   }
}
