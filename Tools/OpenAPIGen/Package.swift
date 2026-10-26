// swift-tools-version: 6.0
/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import PackageDescription

/// Pins the swift-openapi-generator CLI used by `make generate`. Not shipped in the app.
let package = Package(
   name: "OpenAPIGen",
   platforms: [.macOS(.v15)],
   dependencies: [
      .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.1")
   ]
)
