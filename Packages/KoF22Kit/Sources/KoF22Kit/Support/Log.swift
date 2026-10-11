import OSLog

/// Structured logging for the app and its extensions (K22-CODE-19). Every message goes
/// through `os.Logger` so it lands in the unified log with a category, and values are
/// interpolated with an explicit privacy level. Nothing is written to standard output.
///
/// Levels follow the Kingsrook rule: `warning` when one item failed and an engineer
/// may need to look (a post that could not be sent), `error` only for systemic failure
/// (the local store cannot be opened).
public enum Log {
   /// Subsystem shared by the app, the Share Extension and the widgets.
   public static let subsystem = "com.kof22.post"

   /// Sign-in, token refresh and Keychain access.
   public static let auth = Logger(subsystem: subsystem, category: "auth")

   /// Requests to the Site API and the mock backend.
   public static let api = Logger(subsystem: subsystem, category: "api")

   /// Queueing, sending and retrying posts.
   public static let outbox = Logger(subsystem: subsystem, category: "outbox")

   /// Photo preparation and local photo files.
   public static let media = Logger(subsystem: subsystem, category: "media")

   /// SwiftData and other local storage.
   public static let storage = Logger(subsystem: subsystem, category: "storage")

   /// Screens, permissions and other user-interface work.
   public static let ui = Logger(subsystem: subsystem, category: "ui")
}
