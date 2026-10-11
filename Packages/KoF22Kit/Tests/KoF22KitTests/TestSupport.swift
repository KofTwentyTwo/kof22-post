import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import KoF22Kit

enum TestImages {
   static func temporaryDirectory() -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "kof22-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
   }

   /// Writes a small image of `type` with optional GPS metadata.
   static func write(to url: URL, type: UTType = .jpeg, width: Int = 64, height: Int = 48, gps: Bool, orientation: Int? = nil) throws {
      let context = CGContext(
         data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let image = context.makeImage()!
      let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
      var properties: [CFString: Any] = [:]
      if let orientation { properties[kCGImagePropertyOrientation] = orientation }
      if gps {
         properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 39.96, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 75.6, kCGImagePropertyGPSLongitudeRef: "W",
         ]
      }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw MediaError.encodeFailed }
   }
}

/// Builds a mock-backed service with signed-in mock auth.
func makeMockService(backend: MockBackend = MockBackend(directory: nil)) async throws -> (SiteService, MockBackend, AuthSession) {
   let auth = AuthSession(mode: .mock, store: MemorySecureStore())
   try await auth.signIn(using: NoWebAuthenticator())
   return (SiteService.mock(backend: backend, auth: auth), backend, auth)
}

struct NoWebAuthenticator: WebAuthenticator {
   func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AuthError.cancelled }
}

/// Records HTTP requests and replies from a queue.
final class StubLoader: @unchecked Sendable {
   private let lock = NSLock()
   private var responses: [(Int, String)]
   private(set) var requests: [URLRequest] = []

   init(_ responses: [(Int, String)]) { self.responses = responses }

   var loader: HTTPLoader {
      { request in
         let (status, body) = self.lock.withLock {
            self.requests.append(request)
            return self.responses.isEmpty ? (500, "{}") : self.responses.removeFirst()
         }
         try await Task.sleep(for: .milliseconds(20))
         let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
         return (Data(body.utf8), response)
      }
   }

   var requestCount: Int { lock.withLock { requests.count } }

   func form(_ index: Int) -> [String: String] {
      let body = lock.withLock { requests[index].httpBody } ?? Data()
      var out: [String: String] = [:]
      for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
         let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
         if parts.count == 2 { out[parts[0]] = parts[1] }
      }
      return out
   }
}
