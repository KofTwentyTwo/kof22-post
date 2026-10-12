/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO
import Testing

@testable import KoF22Kit

/// The pixel dimensions of an image file, or zero by zero when it cannot be read.
func pixelSize(of url: URL) -> (width: Int, height: Int) {
   guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
   else { return (0, 0) }
   return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

/// Server pixel limits and the upload size preference.
@Suite struct UploadSizingTests {
   /// A byte limit no test image comes close to.
   static let generousBytes: Int64 = 1 << 26
   /// Small limits standing in for the server's, so tests avoid 80-megapixel images.
   static let smallLimits = PixelLimits(maxSide: 100, maxPixels: 2_000)

   @Test func photosWithinTheLimitsKeepTheirSize() {
      #expect(PixelLimits.server.requiredLongEdge(width: 16_000, height: 5_000) == nil)
      #expect(PixelLimits.server.requiredLongEdge(width: 0, height: 0) == nil)
   }

   @Test func aSideOverTheLimitIsScaledToIt() {
      #expect(PixelLimits.server.requiredLongEdge(width: 2, height: 16_001) == 16_000)
   }

   @Test func anAreaOverTheLimitIsScaledUnderItEvenAfterRounding() throws {
      let limits = PixelLimits.server
      let edge = try #require(limits.requiredLongEdge(width: 12_000, height: 8_000))
      let short = Int((Double(8_000) * Double(edge) / Double(12_000)).rounded(.up))
      #expect(edge * short <= limits.maxPixels)
      #expect(edge > 10_000)
      let small = try #require(Self.smallLimits.requiredLongEdge(width: 60, height: 50))
      #expect(small * Int((Double(50) * Double(small) / Double(60)).rounded(.up)) <= Self.smallLimits.maxPixels)
   }

   @Test func aSourceWithoutDimensionsIsLeftAlone() {
      let empty = CGImageSourceCreateIncremental(nil)
      #expect(MediaProcessor.scaledLongEdge(empty, size: .large, pixelLimits: .server) == nil)
   }

   @Test func thePreferenceDescribesItself() {
      #expect(UploadSizePreference.original.maxLongEdge == nil)
      #expect(UploadSizePreference.large.maxLongEdge == 4_096)
      #expect(UploadSizePreference.allCases.map(\.displayName) == ["Original", "Large (4096 px)"])
   }

   @Test func aPhotoOverThePixelLimitsIsDownscaledWithoutLocation() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "wide.png")
      try TestImages.write(to: source, type: .png, width: 300, height: 10, gps: true)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/jpeg", "image/png"], maxBytes: Self.generousBytes,
         pixelLimits: Self.smallLimits, workDirectory: directory.appending(path: "out"))
      #expect(prepared.contentType == .imageJpeg)
      #expect(pixelSize(of: prepared.fileURL).width == 100)
      #expect(!MediaProcessor.hasGPS(prepared.fileURL))
   }

   @Test func aPhotoOnePixelOverTheServerSideLimitIsDownscaled() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "strip.jpg")
      try TestImages.write(to: source, width: 16_001, height: 2, gps: false)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: true, acceptedTypes: ["image/jpeg"], maxBytes: Self.generousBytes, workDirectory: directory)
      #expect(pixelSize(of: prepared.fileURL).width == 16_000)
   }

   @Test func theLargePreferenceCapsTheLongEdge() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "tall.jpg")
      try TestImages.write(to: source, width: 20, height: 4_200, gps: true)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: true, acceptedTypes: ["image/jpeg"], maxBytes: Self.generousBytes, size: .large,
         workDirectory: directory)
      #expect(pixelSize(of: prepared.fileURL).height == 4_096)
      #expect(MediaProcessor.hasGPS(prepared.fileURL))
   }

   @Test func theLargePreferenceKeepsSmallerPhotosAsTheyAre() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "small.png")
      try TestImages.write(to: source, type: .png, gps: false)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: ["image/png"], maxBytes: Self.generousBytes, size: .large,
         workDirectory: directory)
      #expect(prepared.contentType == .imagePng)
      #expect(pixelSize(of: prepared.fileURL).width == TestImages.defaultWidth)
   }

   @Test func aDownscaledPhotoOverTheByteLimitShrinksFurther() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "huge.png")
      try TestImages.write(to: source, type: .png, width: 2_000, height: 1_500, gps: false)
      let limits = PixelLimits(maxSide: 1_800, maxPixels: 10_000_000)
      #expect(throws: MediaError.tooLarge) {
         try MediaProcessor.prepare(
            source: source, keepLocation: false, acceptedTypes: ["image/png"], maxBytes: 1, pixelLimits: limits, workDirectory: directory)
      }
   }

   @Test func theSizePreferenceIsSharedAndDefaultsToOriginal() throws {
      let name = "kof22-upload-size-tests-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      let settings = SharedSettings(defaults: defaults)
      #expect(settings.uploadSize == .original)
      settings.uploadSize = .large
      #expect(SharedSettings(defaults: defaults).uploadSize == .large)
      defaults.set("tiny", forKey: "uploadSize")
      #expect(settings.uploadSize == .original)
   }

   @Test func outboxStatesHaveLabelsAndKeepTheirStoredNames() {
      #expect(OutboxState.allCases.map(\.displayName) == ["Draft", "Queued", "Uploading", "Failed", "Done"])
      #expect(OutboxState.allCases.map(\.rawValue) == ["localDraft", "queued", "sending", "failed", "sent"])
   }
}
