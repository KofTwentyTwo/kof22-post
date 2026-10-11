// swift-tools-version: 6.0
// Pins the swift-openapi-generator CLI used by `make generate`. Not shipped in the app.
import PackageDescription

let package = Package(
    name: "OpenAPIGen",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.0"),
    ]
)
