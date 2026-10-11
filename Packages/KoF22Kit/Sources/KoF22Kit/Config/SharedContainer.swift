import Foundation

/// Files shared between the app and its extensions (SwiftData store, queued photos,
/// mock backend state). Falls back to Application Support when the App Group is not
/// available (unsigned simulator builds, `swift test`).
public enum SharedContainer {
   public static var rootURL: URL {
      if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedIDs.appGroup) {
         return url
      }
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      return base.appending(path: "KoF22Post", directoryHint: .isDirectory)
   }

   public static func directory(_ name: String, root: URL = rootURL) -> URL {
      let url = root.appending(path: name, directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
   }

   /// Photos waiting in the outbox, referenced by file name from queued posts.
   public static var photosDirectory: URL { directory("Outbox Photos") }
   public static var mockDirectory: URL { directory("Mock Backend") }
   public static var storeURL: URL { directory("Store").appending(path: "KoF22Post.store") }
}
