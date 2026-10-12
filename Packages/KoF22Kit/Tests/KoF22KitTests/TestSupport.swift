/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KoF22Kit

/// Errors raised by the test helpers themselves, so a broken fixture fails the test
/// with a clear reason instead of crashing the runner.
enum TestSupportError: Error {
   /// Core Graphics could not create the bitmap context or image.
   case imageCreationFailed
   /// ImageIO could not open a destination for the requested type.
   case destinationUnavailable
   /// The request had no URL or the response could not be built.
   case invalidStubResponse
}

/// Writes small synthetic images for the media and outbox tests.
enum TestImages {
   /// Default width of a generated test image, in pixels.
   static let defaultWidth = 64
   /// Default height of a generated test image, in pixels.
   static let defaultHeight = 48
   /// Bits per colour component of the RGB bitmap.
   private static let bitsPerComponent = 8
   /// sRGB fill colour of the generated image.
   private static let fillRGB = (red: 0.2, green: 0.8, blue: 0.6)
   /// Latitude written into GPS metadata (northern hemisphere).
   private static let latitude = 39.96
   /// Longitude written into GPS metadata (western hemisphere).
   private static let longitude = 75.6

   /// Creates a fresh, uniquely named directory under the system temporary directory.
   static func temporaryDirectory() -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "kof22-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      do {
         try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      catch {
         Issue.record(error, "Could not create the temporary test directory")
      }
      return url
   }

   /// Writes a small image of `type` with optional GPS metadata.
   static func write(
      to url: URL, type: UTType = .jpeg, width: Int = defaultWidth, height: Int = defaultHeight, gps: Bool,
      orientation: Int? = nil
   ) throws {
      guard
         let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: Self.bitsPerComponent, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw TestSupportError.imageCreationFailed }
      context.setFillColor(CGColor(red: Self.fillRGB.red, green: Self.fillRGB.green, blue: Self.fillRGB.blue, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      guard let image = context.makeImage() else { throw TestSupportError.imageCreationFailed }
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
         throw TestSupportError.destinationUnavailable
      }
      var properties: [CFString: Any] = [:]
      if let orientation { properties[kCGImagePropertyOrientation] = orientation }
      if gps {
         properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: Self.latitude, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: Self.longitude, kCGImagePropertyGPSLongitudeRef: "W",
         ]
      }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw MediaError.encodeFailed }
   }
}

/// Builds a mock-backed service with signed-in mock auth.
func makeMockService(backend: MockBackend = MockBackend(directory: nil)) async throws -> (SiteService, MockBackend, AuthSession) {  // swiftlint:disable:this large_tuple
   ////////////////////////////////////////////////////////////////////
   // A tuple (not a struct) lets every test destructure only the    //
   // parts it needs: `let (service, _, _) = try await ...`.         //
   ////////////////////////////////////////////////////////////////////
   let auth = AuthSession(mode: .mock, store: MemorySecureStore())
   try await auth.signIn(using: NoWebAuthenticator())
   return (SiteService.mock(backend: backend, auth: auth), backend, auth)
}

/// A web authenticator for mock sign-in, where no browser is needed; any call is a
/// cancelled sign-in.
struct NoWebAuthenticator: WebAuthenticator {
   /// Always throws `AuthError.cancelled`.
   func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AuthError.cancelled }
}

/// Records HTTP requests and replies from a queue.
final class StubLoader: @unchecked Sendable {
   /// Status returned once the queue of canned responses is empty.
   private static let exhaustedStatus = 500
   /// Simulated network latency in milliseconds, long enough for concurrent callers to overlap.
   private static let latencyMilliseconds = 20
   /// Number of parts in a `key=value` form field.
   private static let formFieldParts = 2

   /// Guards `responses` and `requests`, which the loader touches from many tasks.
   private let lock = NSLock()
   /// Remaining canned `(status, body)` replies, served in order.
   private var responses: [(Int, String)]
   /// Every request received, in arrival order.
   private(set) var requests: [URLRequest] = []

   /// Creates a loader that answers with `responses` in order, then with 500 `{}`.
   init(_ responses: [(Int, String)]) { self.responses = responses }

   /// The `HTTPLoader` closure to inject into the code under test.
   var loader: HTTPLoader {
      { request in
         let (status, body) = self.lock.withLock {
            self.requests.append(request)
            return self.responses.isEmpty ? (Self.exhaustedStatus, "{}") : self.responses.removeFirst()
         }
         try await Task.sleep(for: .milliseconds(Self.latencyMilliseconds))
         guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
         else { throw TestSupportError.invalidStubResponse }
         return (Data(body.utf8), response)
      }
   }

   /// Number of requests received so far.
   var requestCount: Int { lock.withLock { requests.count } }

   /// Decodes the form-encoded body of request `index` into a dictionary.
   func form(_ index: Int) -> [String: String] {
      let body = lock.withLock { requests[index].httpBody } ?? Data()
      var fields: [String: String] = [:]
      for pair in String(bytes: body, encoding: .utf8)?.split(separator: "&") ?? [] {
         let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
         if parts.count == Self.formFieldParts { fields[parts[0]] = parts[1] }
      }
      return fields
   }
}
