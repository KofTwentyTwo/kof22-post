/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Files shared between the app and its extensions (SwiftData store, queued photos,
/// mock backend state). Falls back to Application Support when the App Group is not
/// available (unsigned simulator builds, `swift test`).
public enum SharedContainer {
   /// Environment variable that redirects all shared data to another folder. Tests set
   /// it so they never write to the real container (K22-TEST-24).
   public static let dataDirectoryVariable = "KOF22_DATA_DIR"

   /// The data-directory override, then the App Group container, then the Application
   /// Support fallback.
   public static var rootURL: URL {
      resolveRoot(
         override: ProcessInfo.processInfo.environment[dataDirectoryVariable],
         groupContainer: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.appGroup),
         applicationSupport: .applicationSupportDirectory
      )
   }

   /// Uses a non-empty override first; otherwise picks the App Group container when there
   /// is one, or a folder in Application Support so the app still works without the
   /// entitlement.
   static func resolveRoot(override: String? = nil, groupContainer: URL?, applicationSupport: URL) -> URL {
      if let override, !override.isEmpty {
         return URL(filePath: override, directoryHint: .isDirectory)
      }
      return groupContainer ?? applicationSupport.appending(path: "KoF22Post", directoryHint: .isDirectory)
   }

   /// A named folder under `root`, created on first use. A folder that cannot be created
   /// is logged; the write that follows reports the failure to its caller.
   public static func directory(_ name: String, root: URL = rootURL) -> URL {
      let url = root.appending(path: name, directoryHint: .isDirectory)
      do {
         try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      catch {
         Log.storage.error("Creating the \(name, privacy: .public) folder failed: \(error.localizedDescription, privacy: .public)")
      }
      return url
   }

   /// Photos waiting in the outbox, referenced by file name from queued posts.
   public static var photosDirectory: URL { directory("Outbox Photos") }
   /// The mock backend's saved state.
   public static var mockDirectory: URL { directory("Mock Backend") }
   /// The SwiftData store file.
   public static var storeURL: URL { directory("Store").appending(path: "KoF22Post.store") }
}
