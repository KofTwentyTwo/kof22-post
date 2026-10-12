/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Files shared between the app and its extensions (SwiftData store, queued photos,
/// mock backend state). Falls back to Application Support when the App Group is not
/// available (unsigned simulator builds, `swift test`).
public enum SharedContainer {
   /// The App Group container, or the Application Support fallback.
   public static var rootURL: URL {
      resolveRoot(
         groupContainer: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.appGroup),
         applicationSupport: .applicationSupportDirectory
      )
   }

   /// Picks the App Group container when there is one, otherwise a folder in
   /// Application Support, so the app still works without the entitlement.
   static func resolveRoot(groupContainer: URL?, applicationSupport: URL) -> URL {
      groupContainer ?? applicationSupport.appending(path: "KoF22Post", directoryHint: .isDirectory)
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
