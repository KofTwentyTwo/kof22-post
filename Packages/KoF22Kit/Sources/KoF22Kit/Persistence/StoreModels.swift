import Foundation
import SwiftData

public enum OutboxState: String, Codable, Sendable, CaseIterable {
   /// Being written; autosaved locally, never sent.
   case localDraft
   /// Waiting to be sent (possibly after a backoff).
   case queued
   /// Uploading photos or calling the API right now.
   case sending
   /// Needs attention: validation error, conflict, signed out, or too many retries.
   case failed
   /// Accepted by the server.
   case sent
}

public enum OutboxOperation: String, Codable, Sendable {
   case create
   case update
   case delete
}

/// One post (or edit/delete) on its way to the server. Shared with the Share
/// Extension through the App Group store.
@Model
public final class OutboxItem {
   @Attribute(.unique) public var id: UUID
   public var createdAt: Date
   public var updatedAt: Date
   public var stateRaw: String
   public var operationRaw: String
   public var payload: Data
   public var serverPostID: Int64?
   public var ifMatch: String?
   public var idempotencyKey: String
   public var attempts: Int
   public var nextAttemptAt: Date?
   public var lastError: String?
   public var isConflict: Bool
   public var phase: String?
   public var progress: Double
   public var resultURL: String?
   public var summary: String

   public init(
      id: UUID = UUID(), operation: OutboxOperation, state: OutboxState, composition: PostComposition,
      serverPostID: Int64? = nil, ifMatch: String? = nil, now: Date = .now
   ) {
      self.id = id
      self.createdAt = now
      self.updatedAt = now
      self.stateRaw = state.rawValue
      self.operationRaw = operation.rawValue
      self.payload = (try? JSONEncoder().encode(composition)) ?? Data()
      self.serverPostID = serverPostID
      self.ifMatch = ifMatch
      self.idempotencyKey = "kof22post-\(id.uuidString.lowercased())"
      self.attempts = 0
      self.isConflict = false
      self.progress = 0
      self.summary = composition.summary
   }

   public var state: OutboxState {
      get { OutboxState(rawValue: stateRaw) ?? .failed }
      set { stateRaw = newValue.rawValue }
   }

   public var operation: OutboxOperation { OutboxOperation(rawValue: operationRaw) ?? .create }

   public var composition: PostComposition {
      get { (try? JSONDecoder().decode(PostComposition.self, from: payload)) ?? PostComposition() }
      set {
         payload = (try? JSONEncoder().encode(newValue)) ?? payload
         summary = newValue.summary
      }
   }
}

/// Last known copy of one of my posts, for offline viewing.
@Model
public final class CachedPost {
   @Attribute(.unique) public var postID: Int64
   public var data: Data
   public var updatedAt: Date
   public var statusRaw: String

   public init(post: Post) {
      self.postID = post.id
      self.data = (try? CachedPost.encoder.encode(post)) ?? Data()
      self.updatedAt = post.updatedAt ?? .now
      self.statusRaw = post.status.rawValue
   }

   public var post: Post? { try? CachedPost.decoder.decode(Post.self, from: data) }

   public func update(from post: Post) {
      data = (try? CachedPost.encoder.encode(post)) ?? data
      updatedAt = post.updatedAt ?? .now
      statusRaw = post.status.rawValue
   }

   static let encoder: JSONEncoder = {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return encoder
   }()

   static let decoder: JSONDecoder = {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return decoder
   }()
}

public enum PersistenceStack {
   public static let schema = Schema([OutboxItem.self, CachedPost.self])

   public static func makeContainer(inMemory: Bool = false, url: URL = SharedContainer.storeURL) throws -> ModelContainer {
      let configuration =
         inMemory
         ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
         : ModelConfiguration(schema: schema, url: url)
      return try ModelContainer(for: schema, configurations: [configuration])
   }
}
