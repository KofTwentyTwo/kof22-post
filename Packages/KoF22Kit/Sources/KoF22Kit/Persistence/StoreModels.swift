/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import SwiftData

/// Where an outbox item is in its life.
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

/// What an outbox item asks the server to do.
public enum OutboxOperation: String, Codable, Sendable {
   /// Create a new post.
   case create
   /// Replace an existing post's content, guarded by `If-Match`.
   case update
   /// Delete an existing post.
   case delete
}

/// JSON coding for values stored as blobs in SwiftData. A failure is logged with the
/// value's type (never its content, which may be a post body) and returns nil, so a
/// single unreadable row degrades to a default instead of breaking the whole list.
enum StoreCoding {
   /// Encodes post copies with ISO 8601 dates, matching the API.
   static let isoEncoder: JSONEncoder = {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return encoder
   }()

   /// Decodes post copies with ISO 8601 dates, matching the API.
   static let isoDecoder: JSONDecoder = {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return decoder
   }()

   /// Encodes `value`, or logs and returns `fallback` (typically the bytes already
   /// stored, so a failed write keeps the previous value).
   static func encode<Value: Encodable>(_ value: Value, using encoder: JSONEncoder = JSONEncoder(), otherwise fallback: Data) -> Data {
      do {
         return try encoder.encode(value)
      }
      catch {
         Log.storage.warning("Could not encode \(String(describing: Value.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
         return fallback
      }
   }

   /// Decodes a `Value` from `data`, or logs and returns nil.
   static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, using decoder: JSONDecoder = JSONDecoder()) -> Value? {
      do {
         return try decoder.decode(type, from: data)
      }
      catch {
         Log.storage.warning("Could not decode \(String(describing: Value.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
         return nil
      }
   }
}

/// One post (or edit/delete) on its way to the server. Shared with the Share
/// Extension through the App Group store.
@Model
public final class OutboxItem {
   /// Stable identity; also the base of the item's idempotency keys.
   @Attribute(.unique) public var id: UUID
   /// When the item was first saved; the send order.
   public var createdAt: Date
   /// When the item last changed; sent items are pruned by it.
   public var updatedAt: Date
   /// Storage for `state`.
   public var stateRaw: String
   /// Storage for `operation`.
   public var operationRaw: String
   /// The encoded `PostComposition`.
   public var payload: Data
   /// The server's id of the post, for updates, deletes and after a create.
   public var serverPostID: Int64?
   /// The post version an update or delete is based on.
   public var ifMatch: String?
   /// Sent with the create so a retry after a lost response cannot post twice.
   public var idempotencyKey: String
   /// Failed send attempts since the last manual retry.
   public var attempts: Int
   /// Not sent before this instant (backoff); nil means as soon as possible.
   public var nextAttemptAt: Date?
   /// The last failure, worded for the user.
   public var lastError: String?
   /// The server copy changed since the edit started (412); needs the user.
   public var isConflict: Bool
   /// What is happening right now, for the Outbox screen.
   public var phase: String?
   /// Send progress from 0 to 1.
   public var progress: Double
   /// The public URL once the post is live.
   public var resultURL: String?
   /// A short label (title or derived) kept in sync with the payload for lists.
   public var summary: String

   /// Creates an item. The idempotency key is derived from `id`, so it survives app
   /// restarts and is the same for every retry.
   public init(
      id: UUID = UUID(), operation: OutboxOperation, state: OutboxState, composition: PostComposition,
      serverPostID: Int64? = nil, ifMatch: String? = nil, now: Date = .now
   ) {
      self.id = id
      self.createdAt = now
      self.updatedAt = now
      self.stateRaw = state.rawValue
      self.operationRaw = operation.rawValue
      self.payload = StoreCoding.encode(composition, otherwise: Data())
      self.serverPostID = serverPostID
      self.ifMatch = ifMatch
      self.idempotencyKey = "kof22post-\(id.uuidString.lowercased())"
      self.attempts = 0
      self.isConflict = false
      self.progress = 0
      self.summary = composition.summary
   }

   /// The item's state; an unknown stored value reads as `failed` so it surfaces.
   public var state: OutboxState {
      get { OutboxState(rawValue: stateRaw) ?? .failed }
      set { stateRaw = newValue.rawValue }
   }

   /// The requested operation; an unknown stored value reads as `create`.
   public var operation: OutboxOperation { OutboxOperation(rawValue: operationRaw) ?? .create }

   /// The decoded payload. An unreadable payload reads as an empty composition, and
   /// a value that cannot be encoded leaves the stored payload unchanged.
   public var composition: PostComposition {
      get { StoreCoding.decode(PostComposition.self, from: payload) ?? PostComposition() }
      set {
         payload = StoreCoding.encode(newValue, otherwise: payload)
         summary = newValue.summary
      }
   }
}

/// Last known copy of one of my posts, for offline viewing.
@Model
public final class CachedPost {
   /// The server's post id.
   @Attribute(.unique) public var postID: Int64
   /// The encoded `Post`.
   public var data: Data
   /// The post's last change, for newest-first lists.
   public var updatedAt: Date
   /// The post's status, for filtering without decoding.
   public var statusRaw: String

   /// Caches a server post.
   public init(post: Post) {
      self.postID = post.id
      self.data = StoreCoding.encode(post, using: StoreCoding.isoEncoder, otherwise: Data())
      self.updatedAt = post.updatedAt ?? .now
      self.statusRaw = post.status.rawValue
   }

   /// The cached post, or nil when the stored copy cannot be read.
   public var post: Post? { StoreCoding.decode(Post.self, from: data, using: StoreCoding.isoDecoder) }

   /// Replaces the cached copy with a newer one from the server.
   public func update(from post: Post) {
      data = StoreCoding.encode(post, using: StoreCoding.isoEncoder, otherwise: data)
      updatedAt = post.updatedAt ?? .now
      statusRaw = post.status.rawValue
   }
}

/// Builds the SwiftData container shared by the app and its extensions.
public enum PersistenceStack {
   /// Every model the store holds.
   public static let schema = Schema([OutboxItem.self, CachedPost.self])

   /// Opens the store at `url`, or an in-memory store for tests and previews.
   public static func makeContainer(inMemory: Bool = false, url: URL = SharedContainer.storeURL) throws -> ModelContainer {
      let configuration =
         inMemory
         ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
         : ModelConfiguration(schema: schema, url: url)
      return try ModelContainer(for: schema, configurations: [configuration])
   }
}
