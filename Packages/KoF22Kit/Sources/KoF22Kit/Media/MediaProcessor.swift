import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PreparedPhoto: Sendable, Equatable {
    public var fileURL: URL
    public var contentType: UploadCreate.ContentTypePayload
    public var byteSize: Int64
}

public enum MediaError: Error, LocalizedError, Equatable {
    case unreadable
    case encodeFailed
    case tooLarge

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
    static let jpegQuality = 0.92

    public static func prepare(
        source: URL,
        keepLocation: Bool,
        acceptedTypes: [String],
        maxBytes: Int64,
        workDirectory: URL
    ) throws -> PreparedPhoto {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let typeID = CGImageSourceGetType(image) as String?,
              let type = UTType(typeID) else { throw MediaError.unreadable }

        let accepted = Set(acceptedTypes)
        let mime = type.preferredMIMEType ?? ""
        let passThrough = accepted.contains(mime) && (type.conforms(to: .jpeg) || type.conforms(to: .png))
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var output: URL
        var contentType: UploadCreate.ContentTypePayload
        if passThrough {
            contentType = type.conforms(to: .png) ? .imagePng : .imageJpeg
            output = workDirectory.appending(path: UUID().uuidString + (contentType == .imagePng ? ".png" : ".jpg"))
            if keepLocation {
                try FileManager.default.copyItem(at: source, to: output)
            } else {
                try copyWithoutGPS(image, type: type, to: output)
            }
        } else {
            contentType = .imageJpeg
            output = workDirectory.appending(path: UUID().uuidString + ".jpg")
            try encodeJPEG(image, keepLocation: keepLocation, maxPixelSize: nil, quality: jpegQuality, to: output)
        }

        var size = try fileSize(output)
        var maxPixel = 6000
        while size > maxBytes {
            guard maxPixel >= 1000 else { throw MediaError.tooLarge }
            try? FileManager.default.removeItem(at: output)
            contentType = .imageJpeg
            output = workDirectory.appending(path: UUID().uuidString + ".jpg")
            try encodeJPEG(image, keepLocation: keepLocation, maxPixelSize: maxPixel, quality: 0.85, to: output)
            size = try fileSize(output)
            maxPixel = maxPixel * 3 / 4
        }
        return PreparedPhoto(fileURL: output, contentType: contentType, byteSize: size)
    }

    /// Rewrites metadata without recompressing the image data.
    static func copyWithoutGPS(_ image: CGImageSource, type: UTType, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw MediaError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                                        kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(destination, image, options as CFDictionary, &error) {
            // Lossless copy is not supported for every format; fall back to re-encoding.
            try? FileManager.default.removeItem(at: url)
            guard let fallback = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw MediaError.encodeFailed
            }
            CGImageDestinationAddImageFromSource(fallback, image, 0, [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary)
            guard CGImageDestinationFinalize(fallback) else { throw MediaError.encodeFailed }
        }
    }

    static func encodeJPEG(_ image: CGImageSource, keepLocation: Bool, maxPixelSize: Int?, quality: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError.encodeFailed
        }
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
            // The transform is baked in, so orientation resets to up.
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = nil
            properties[kCGImagePropertyPixelHeight] = nil
            CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, image, 0, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw MediaError.encodeFailed }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// True when the file carries a GPS dictionary (used by tests and the UI).
    public static func hasGPS(_ url: URL) -> Bool {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }
}
