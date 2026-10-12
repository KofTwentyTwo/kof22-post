/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// A small in-memory cache for anonymous reads. The API's rate limit is shared by every
/// client of the host and published content changes rarely, so screens reuse a recent
/// answer instead of refetching each time they appear. Entries expire after a fixed time
/// to live; nothing is fetched in the background (no polling).
public actor ReadCache {
   /// How long an answer is reused when the caller does not say: five minutes, the same
   /// time the server caches its feeds.
   public static let defaultTimeToLive: TimeInterval = 300

   /// One cached answer and when it was stored.
   private struct Entry {
      /// The cached value.
      let value: any Sendable
      /// When the value was stored.
      let storedAt: Date
   }

   /// How long an entry is served.
   public nonisolated let timeToLive: TimeInterval
   /// The clock, injected so tests control expiry.
   private let now: @Sendable () -> Date
   /// The entries by request key.
   private var entries: [String: Entry] = [:]

   /// Creates an empty cache whose entries live for `timeToLive` seconds on `now`'s clock.
   public init(timeToLive: TimeInterval = defaultTimeToLive, now: @escaping @Sendable () -> Date = { .now }) {
      self.timeToLive = timeToLive
      self.now = now
   }

   /// The value stored under `key` when it is still fresh and of type `type`; an expired
   /// entry is dropped.
   public func value<Value: Sendable>(for key: String, as type: Value.Type) -> Value? {
      guard let entry = entries[key] else { return nil }
      guard now().timeIntervalSince(entry.storedAt) < timeToLive else {
         entries[key] = nil
         return nil
      }
      return entry.value as? Value
   }

   /// Stores `value` under `key`, replacing any earlier entry.
   public func store(_ value: some Sendable, for key: String) {
      entries[key] = Entry(value: value, storedAt: now())
   }

   /// Forgets every entry, for pull to refresh or after posting.
   public func removeAll() { entries.removeAll() }
}
