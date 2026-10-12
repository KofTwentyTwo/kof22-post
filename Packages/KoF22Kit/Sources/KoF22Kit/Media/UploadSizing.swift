/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// How large uploaded photos are. Stored in `SharedSettings.uploadSize`.
public enum UploadSizePreference: String, Codable, Sendable, CaseIterable {
   /// Full resolution (the owner's default, ADR-0005); only server limits shrink a photo.
   case original
   /// At most `largeLongEdge` pixels on the long edge, re-encoded as JPEG.
   case large

   /// The long edge, in pixels, of a `.large` photo.
   public static let largeLongEdge = 4_096

   /// JPEG quality used when a `.large` photo is re-encoded.
   public static let largeJPEGQuality = 0.85

   /// The longest edge allowed by this preference, or nil for no limit.
   public var maxLongEdge: Int? {
      switch self {
      case .original: nil
      case .large: Self.largeLongEdge
      }
   }

   /// A short label for Settings.
   public var displayName: String {
      switch self {
      case .original: "Original"
      case .large: "Large (4096 px)"
      }
   }
}

/// The pixel dimensions the server accepts. A photo over either limit is scaled down
/// before upload; anything within them keeps its resolution.
public struct PixelLimits: Sendable, Equatable {
   /// The longest side the server accepts, in pixels.
   public var maxSide: Int
   /// The most pixels (width times height) the server accepts.
   public var maxPixels: Int

   /// Creates limits; tests use small values to avoid huge images.
   public init(maxSide: Int, maxPixels: Int) {
      self.maxSide = maxSide
      self.maxPixels = maxPixels
   }

   /// The longest side the Site API accepts, in pixels.
   static let serverMaxSide = 16_000
   /// The most pixels the Site API accepts (80 megapixels).
   static let serverMaxPixels = 80_000_000

   /// The Site API's limits: 16,000 px per side and 80 megapixels.
   public static let server = Self(maxSide: serverMaxSide, maxPixels: serverMaxPixels)

   /// The long edge a `width` by `height` photo must be scaled to, or nil when it is
   /// within both limits. The result keeps the area within `maxPixels` even after the
   /// short side is rounded up by one pixel: reserving `maxSide` pixels covers that
   /// rounding, since the new long edge is never longer than `maxSide`.
   public func requiredLongEdge(width: Int, height: Int) -> Int? {
      let long = max(width, height)
      let short = max(min(width, height), 1)
      guard long > maxSide || long * short > maxPixels else { return nil }
      let areaFit = Int((Double(maxPixels - maxSide) * Double(long) / Double(short)).squareRoot())
      return min(maxSide, areaFit)
   }
}
