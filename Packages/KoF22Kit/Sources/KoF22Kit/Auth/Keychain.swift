import Foundation
import Security

/// Stores one Codable value per account in the Keychain. When an access group is
/// given it is tried first and the default group is used if the entitlement is
/// missing (e.g. unsigned simulator builds).
public protocol SecureStore: Sendable {
   func load(_ account: String) throws -> Data?
   func save(_ data: Data, for account: String) throws
   func delete(_ account: String) throws
}

public struct KeychainError: Error, Equatable {
   public let status: OSStatus
}

public struct KeychainStore: SecureStore {
   let service: String
   let accessGroup: String?

   public init(service: String = SharedIDs.keychainService, accessGroup: String? = KeychainStore.sharedAccessGroup) {
      self.service = service
      self.accessGroup = accessGroup
   }

   /// `$(AppIdentifierPrefix)com.kof22.post.shared`, read from the app's Info.plist
   /// (`KoF22KeychainGroup`) because the team prefix is only known at build time.
   public static var sharedAccessGroup: String? {
      Bundle.main.object(forInfoDictionaryKey: "KoF22KeychainGroup") as? String
   }

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

   private var groups: [String?] {
      accessGroup.map { [$0, nil] } ?? [nil]
   }

   public func load(_ account: String) throws -> Data? {
      for group in groups {
         var q = query(account, group: group)
         q[kSecReturnData as String] = true
         q[kSecMatchLimit as String] = kSecMatchLimitOne
         var item: CFTypeRef?
         let status = SecItemCopyMatching(q as CFDictionary, &item)
         switch status {
         case errSecSuccess: return item as? Data
         case errSecItemNotFound, errSecMissingEntitlement: continue
         default: throw KeychainError(status: status)
         }
      }
      return nil
   }

   public func save(_ data: Data, for account: String) throws {
      var lastStatus: OSStatus = errSecSuccess
      for group in groups {
         let q = query(account, group: group)
         let update: [String: Any] = [kSecValueData as String: data]
         var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
         if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
         }
         if status == errSecSuccess { return }
         lastStatus = status
         if status != errSecMissingEntitlement { break }
      }
      throw KeychainError(status: lastStatus)
   }

   public func delete(_ account: String) throws {
      for group in groups {
         let status = SecItemDelete(query(account, group: group) as CFDictionary)
         guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
            throw KeychainError(status: status)
         }
      }
   }
}

/// In-memory store for tests and previews.
public final class MemorySecureStore: SecureStore, @unchecked Sendable {
   private let lock = NSLock()
   private var items: [String: Data] = [:]

   public init() {}

   public func load(_ account: String) throws -> Data? { lock.withLock { items[account] } }
   public func save(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
   public func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
}
