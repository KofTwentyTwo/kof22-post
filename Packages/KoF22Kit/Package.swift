// swift-tools-version: 6.2
//
// Shared code for the app, Share Extension and widgets.
//   KoF22API  - client generated from openapi/openapi.yaml (`make generate`)
//   KoF22Kit  - auth, API service, mock backend, outbox, media, persistence
//   KoF22UI   - SwiftUI screens and theme shared by the app and extensions
//
// macOS is listed only so `swift test` can run the core tests without a simulator.
import PackageDescription

/// Warnings are errors for hand-written code (K22-CODE-02, K22-CODE-SW-04). The
/// generated client (KoF22API) is excluded by target (K22-CODE-25): the generator
/// emits unused-import warnings that cannot be fixed without editing its output.
let strictSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
   name: "KoF22Kit",
   platforms: [.iOS("27.0"), .macOS("26.0")],
   products: [
      .library(name: "KoF22API", targets: ["KoF22API"]),
      .library(name: "KoF22Kit", targets: ["KoF22Kit"]),
      .library(name: "KoF22UI", targets: ["KoF22UI"]),
   ],
   dependencies: [
      .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
      .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.2"),
      .package(url: "https://github.com/apple/swift-http-types", from: "1.3.0"),
      .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
   ],
   targets: [
      .target(
         name: "KoF22API",
         dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")]
      ),
      .target(
         name: "KoF22Kit",
         dependencies: [
            "KoF22API",
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
         ],
         swiftSettings: strictSettings
      ),
      .target(
         name: "KoF22UI",
         dependencies: [
            "KoF22Kit",
            .product(name: "Textual", package: "textual", condition: .when(platforms: [.iOS])),
         ],
         swiftSettings: strictSettings
      ),
      .testTarget(
         name: "KoF22KitTests",
         dependencies: [
            "KoF22Kit",
            "KoF22API",
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
         ],
         swiftSettings: strictSettings
      ),
   ]
)
