/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Security

/// Stores one Codable value per account in the Keychain. When an access group is
/// given it is tried first and the default group is used if the entitlement is
/// missing (e.g. unsigned simulator builds).
public protocol SecureStore: Sendable {
   /// The data stored for `account`, or nil when there is none.
   func load(_ account: String) throws -> Data?
   /// Stores `data` for `account`, replacing any previous value.
   func save(_ data: Data, for account: String) throws
   /// Removes the value for `account`; removing a missing value is not an error.
   func delete(_ account: String) throws
}

/// A Keychain call that failed with an unexpected status.
public struct KeychainError: Error, Equatable {
   /// The `OSStatus` the Security framework returned.
   public let status: OSStatus
}

/// The Security framework calls `KeychainStore` makes. They are injected so tests can
/// drive every status (found, not found, missing entitlement, other failures) without
/// touching the real Keychain (K22-CODE-17). The signatures match the C functions, so
/// `.system` passes them through unchanged.
struct KeychainOperations: Sendable {
   /// `SecItemCopyMatching`.
   var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
   /// `SecItemUpdate`.
   var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
   /// `SecItemAdd`.
   var add: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
   /// `SecItemDelete`.
   var delete: @Sendable (CFDictionary) -> OSStatus

   /// The real Keychain.
   static let system = Self(copyMatching: SecItemCopyMatching, update: SecItemUpdate, add: SecItemAdd, delete: SecItemDelete)
}

/// `SecureStore` backed by the data-protection Keychain, shared between the app and its
/// extensions through an access group.
public struct KeychainStore: SecureStore {
   /// The Keychain service all tokens are stored under.
   let service: String
   /// The shared access group, tried before the app's default group.
   let accessGroup: String?
   /// The Security framework calls, replaced in tests.
   let operations: KeychainOperations

   /// Creates a store on the real Keychain.
   public init(service: String = SharedIDs.keychainService, accessGroup: String? = Self.sharedAccessGroup) {
      self.init(service: service, accessGroup: accessGroup, operations: .system)
   }

   /// Creates a store on injected Keychain operations.
   init(service: String, accessGroup: String?, operations: KeychainOperations) {
      self.service = service
      self.accessGroup = accessGroup
      self.operations = operations
   }

   /// `$(AppIdentifierPrefix)com.kof22.post.shared`, read from the app's Info.plist
   /// (`KoF22KeychainGroup`) because the team prefix is only known at build time.
   public static var sharedAccessGroup: String? {
      Bundle.main.object(forInfoDictionaryKey: "KoF22KeychainGroup") as? String
   }

   /// The attributes that identify one item, in one access group or the default group.
   private func query(_ account: String, group: String?) -> [String: Any] {
      var query: [String: Any] = [
         kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
      ]
      if let group { query[kSecAttrAccessGroup as String] = group }
      return query
   }

   /// The groups to try in order: the shared group first, then the default group.
   private var groups: [String?] {
      accessGroup.map { [$0, nil] } ?? [nil]
   }

   /// Returns the first value found. A missing item or a missing entitlement moves on to
   /// the next group; any other status is an error.
   public func load(_ account: String) throws -> Data? {
      for group in groups {
         var search = query(account, group: group)
         search[kSecReturnData as String] = true
         search[kSecMatchLimit as String] = kSecMatchLimitOne
         var item: CFTypeRef?
         let status = operations.copyMatching(search as CFDictionary, &item)
         switch status {
         case errSecSuccess: return item as? Data
         case errSecItemNotFound, errSecMissingEntitlement: continue
         default: throw KeychainError(status: status)
         }
      }
      return nil
   }

   /// Updates the item in place or adds it when it does not exist yet. Falls back to the
   /// default group only when the shared group's entitlement is missing.
   public func save(_ data: Data, for account: String) throws {
      var lastStatus: OSStatus = errSecSuccess
      for group in groups {
         let match = query(account, group: group)
         let update: [String: Any] = [kSecValueData as String: data]
         var status = operations.update(match as CFDictionary, update as CFDictionary)
         if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = operations.add(add as CFDictionary, nil)
         }
         if status == errSecSuccess { return }
         lastStatus = status
         if status != errSecMissingEntitlement { break }
      }
      throw KeychainError(status: lastStatus)
   }

   /// Deletes the item from every group so no stale copy survives a sign-out.
   public func delete(_ account: String) throws {
      for group in groups {
         let status = operations.delete(query(account, group: group) as CFDictionary)
         guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
            throw KeychainError(status: status)
         }
      }
   }
}

/// In-memory store for tests and previews.
public final class MemorySecureStore: SecureStore, @unchecked Sendable {
   /// Guards `items`; the class is shared across tasks.
   private let lock = NSLock()
   /// The stored values by account.
   private var items: [String: Data] = [:]

   /// Creates an empty store.
   public init() {}

   /// The value for `account`, or nil.
   public func load(_ account: String) throws -> Data? { lock.withLock { items[account] } }
   /// Stores `data` for `account`.
   public func save(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
   /// Removes the value for `account`.
   public func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
}
