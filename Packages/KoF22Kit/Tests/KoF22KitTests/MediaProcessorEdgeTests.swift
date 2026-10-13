/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KoF22Kit

@Suite struct MediaProcessorEdgeTests {
   let accepted = ["image/jpeg", "image/png"]
   let generousLimit: Int64 = 10_000_000

   @Test func pngPassesThroughAsPNGWithoutLocation() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.png")
      try TestImages.write(to: source, type: .png, gps: true)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: false, acceptedTypes: accepted, maxBytes: generousLimit, workDirectory: directory.appending(path: "work"))
      #expect(prepared.contentType == "image/png")
      #expect(prepared.fileURL.pathExtension == "png")
      #expect(!MediaProcessor.hasGPS(prepared.fileURL))
   }

   @Test func pngKeptWithLocationIsCopiedByteForByte() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.png")
      try TestImages.write(to: source, type: .png, gps: false)
      let prepared = try MediaProcessor.prepare(
         source: source, keepLocation: true, acceptedTypes: accepted, maxBytes: generousLimit, workDirectory: directory.appending(path: "work"))
      #expect(try Data(contentsOf: prepared.fileURL) == Data(contentsOf: source))
      #expect(prepared.byteSize == Int64(try Data(contentsOf: source).count))
   }

   @Test func fileThatIsNotAnImageIsUnreadable() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "notes.txt")
      try Data("not an image".utf8).write(to: source)
      #expect(throws: MediaError.unreadable) {
         try MediaProcessor.prepare(source: source, keepLocation: false, acceptedTypes: accepted, maxBytes: generousLimit, workDirectory: directory)
      }
      #expect(!MediaProcessor.hasGPS(source))
   }

   @Test func photoThatCannotShrinkEnoughIsRefused() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.jpg")
      try TestImages.write(to: source, gps: false)
      #expect(throws: MediaError.tooLarge) {
         try MediaProcessor.prepare(source: source, keepLocation: false, acceptedTypes: accepted, maxBytes: 1, workDirectory: directory)
      }
   }

   @Test func formatWithoutLosslessCopyIsReencodedWithoutLocation() throws {
      let directory = TestImages.temporaryDirectory()
      let source = directory.appending(path: "in.gif")
      try TestImages.write(to: source, type: .gif, gps: false)
      let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
      let output = directory.appending(path: "out.gif")
      try MediaProcessor.copyWithoutGPS(image, type: .gif, to: output)
      #expect(FileManager.default.fileExists(atPath: output.path()))
      #expect(!MediaProcessor.hasGPS(output))
   }

   @Test func sourceWithoutImagesCannotBeCopied() {
      let output = TestImages.temporaryDirectory().appending(path: "out.gif")
      #expect(throws: MediaError.encodeFailed) { try MediaProcessor.copyWithoutGPS(CGImageSourceCreateIncremental(nil), type: .gif, to: output) }
   }

   @Test func sourceWithoutImagesCannotBeEncoded() {
      let output = TestImages.temporaryDirectory().appending(path: "out.jpg")
      let empty = CGImageSourceCreateIncremental(nil)
      #expect(throws: MediaError.encodeFailed) {
         try MediaProcessor.encodeJPEG(empty, keepLocation: false, maxPixelSize: 100, quality: MediaProcessor.shrinkQuality, to: output)
      }
      #expect(throws: MediaError.encodeFailed) {
         try MediaProcessor.encodeJPEG(empty, keepLocation: false, maxPixelSize: nil, quality: MediaProcessor.jpegQuality, to: output)
      }
   }

   @Test func typeImageIOCannotWriteIsAnEncodeFailure() {
      let output = TestImages.temporaryDirectory().appending(path: "out.txt")
      #expect(throws: MediaError.encodeFailed) { try MediaProcessor.makeDestination(output, type: .plainText) }
   }

   @Test func removingAMissingLeftoverIsHarmless() {
      let missing = TestImages.temporaryDirectory().appending(path: "gone.jpg")
      MediaProcessor.removeLeftover(missing)
      #expect(!FileManager.default.fileExists(atPath: missing.path()))
   }

   @Test func sizeOfSomethingWithoutAFileSizeIsZero() throws {
      #expect(try MediaProcessor.fileSize(TestImages.temporaryDirectory()) == 0)
   }

   @Test func errorsReadAsSentences() {
      #expect(MediaError.unreadable.errorDescription == "The photo could not be read.")
      #expect(MediaError.encodeFailed.errorDescription == "The photo could not be converted.")
      #expect(MediaError.tooLarge.errorDescription == "The photo is too large to upload.")
   }
}
