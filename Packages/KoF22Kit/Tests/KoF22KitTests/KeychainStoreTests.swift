/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Security
import Testing

@testable import KoF22Kit

/// A scripted stand-in for the Security framework. Each call takes the next status from
/// its queue (or the fallback status once the queue is empty) and records the query.
final class FakeKeychain: @unchecked Sendable {
   /// One recorded call.
   struct Call {
      /// Which operation ran: copy, update, add or delete.
      let operation: String
      /// The query or attributes passed to it.
      let attributes: [String: Any]
   }

   /// Guards the mutable state.
   private let lock = NSLock()
   /// Statuses returned in order, per operation.
   private var statuses: [String: [OSStatus]]
   /// Returned by an operation whose queue is empty.
   private let fallbackStatus: OSStatus
   /// The value `copyMatching` hands back on success.
   private let storedData: Data?
   /// Every call in order.
   private var recorded: [Call] = []

   /// Creates a keychain that answers from `statuses` and returns `storedData` on a
   /// successful lookup.
   init(statuses: [String: [OSStatus]] = [:], fallbackStatus: OSStatus = errSecSuccess, storedData: Data? = nil) {
      self.statuses = statuses
      self.fallbackStatus = fallbackStatus
      self.storedData = storedData
   }

   /// The calls made so far.
   var calls: [Call] { lock.withLock { recorded } }

   /// Records a call and returns its scripted status.
   private func respond(_ operation: String, _ attributes: CFDictionary) -> OSStatus {
      let dictionary = (attributes as NSDictionary as? [String: Any]) ?? [:]
      return lock.withLock {
         recorded.append(Call(operation: operation, attributes: dictionary))
         guard var queue = statuses[operation], !queue.isEmpty else { return fallbackStatus }
         let status = queue.removeFirst()
         statuses[operation] = queue
         return status
      }
   }

   /// Operations wired to this fake.
   var operations: KeychainOperations {
      KeychainOperations(
         copyMatching: { query, result in
            let status = self.respond("copy", query)
            if status == errSecSuccess { result?.pointee = self.storedData.map { $0 as CFData } }
            return status
         },
         update: { query, _ in self.respond("update", query) },
         add: { attributes, _ in self.respond("add", attributes) },
         delete: { query in self.respond("delete", query) }
      )
   }
}

@Suite struct KeychainStoreTests {
   let sharedGroup = "TEAM.com.kof22.post.shared"

   func makeStore(_ keychain: FakeKeychain, accessGroup: String? = "TEAM.com.kof22.post.shared") -> KeychainStore {
      KeychainStore(service: "test.service", accessGroup: accessGroup, operations: keychain.operations)
   }

   @Test func defaultStoreUsesTheSharedServiceAndTheRealKeychain() {
      let store = KeychainStore()
      #expect(store.service == SharedIDs.keychainService)
      #expect(store.accessGroup == KeychainStore.sharedAccessGroup)
      #expect(KeychainStore.sharedAccessGroup == nil)
   }

   @Test func loadReadsFromTheSharedGroupFirst() throws {
      let keychain = FakeKeychain(storedData: Data("tokens".utf8))
      let data = try makeStore(keychain).load("tokens.live")
      #expect(data == Data("tokens".utf8))
      let query = try #require(keychain.calls.first?.attributes)
      #expect(keychain.calls.count == 1)
      #expect(query[kSecAttrAccessGroup as String] as? String == sharedGroup)
      #expect(query[kSecAttrService as String] as? String == "test.service")
      #expect(query[kSecAttrAccount as String] as? String == "tokens.live")
      #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
      #expect(query[kSecReturnData as String] as? Bool == true)
   }

   @Test func loadFallsBackToTheDefaultGroupWithoutTheEntitlement() throws {
      let keychain = FakeKeychain(statuses: ["copy": [errSecMissingEntitlement]], storedData: Data("fallback".utf8))
      let data = try makeStore(keychain).load("tokens.live")
      #expect(data == Data("fallback".utf8))
      #expect(keychain.calls.count == 2)
      #expect(keychain.calls.last?.attributes[kSecAttrAccessGroup as String] == nil)
   }

   @Test func loadReturnsNilWhenNoGroupHasTheItem() throws {
      let keychain = FakeKeychain(fallbackStatus: errSecItemNotFound)
      #expect(try makeStore(keychain, accessGroup: nil).load("tokens.mock") == nil)
      #expect(keychain.calls.count == 1)
   }

   @Test func loadThrowsForAnyOtherStatus() {
      let keychain = FakeKeychain(fallbackStatus: errSecInteractionNotAllowed)
      #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try makeStore(keychain).load("tokens.live") }
      #expect(keychain.calls.count == 1)
   }

   @Test func saveUpdatesAnExistingItemInPlace() throws {
      let keychain = FakeKeychain()
      try makeStore(keychain).save(Data("new".utf8), for: "tokens.live")
      #expect(keychain.calls.map(\.operation) == ["update"])
   }

   @Test func saveAddsAMissingItemReadableAfterFirstUnlock() throws {
      let keychain = FakeKeychain(statuses: ["update": [errSecItemNotFound]])
      try makeStore(keychain).save(Data("new".utf8), for: "tokens.live")
      #expect(keychain.calls.map(\.operation) == ["update", "add"])
      let added = try #require(keychain.calls.last?.attributes)
      #expect(added[kSecValueData as String] as? Data == Data("new".utf8))
      #expect(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
      #expect(added[kSecAttrAccessGroup as String] as? String == sharedGroup)
   }

   @Test func saveFallsBackToTheDefaultGroupWithoutTheEntitlement() throws {
      let keychain = FakeKeychain(statuses: ["update": [errSecMissingEntitlement]])
      try makeStore(keychain).save(Data("new".utf8), for: "tokens.live")
      #expect(keychain.calls.map(\.operation) == ["update", "update"])
      #expect(keychain.calls.last?.attributes[kSecAttrAccessGroup as String] == nil)
   }

   @Test func saveStopsAtTheFirstRealFailure() {
      let keychain = FakeKeychain(statuses: ["update": [errSecItemNotFound], "add": [errSecDuplicateItem]])
      #expect(throws: KeychainError(status: errSecDuplicateItem)) { try makeStore(keychain).save(Data(), for: "tokens.live") }
      #expect(keychain.calls.map(\.operation) == ["update", "add"])
   }

   @Test func saveReportsTheMissingEntitlementWhenEveryGroupLacksIt() {
      let keychain = FakeKeychain(fallbackStatus: errSecMissingEntitlement)
      #expect(throws: KeychainError(status: errSecMissingEntitlement)) { try makeStore(keychain).save(Data(), for: "tokens.live") }
      #expect(keychain.calls.count == 2)
   }

   @Test func deleteClearsEveryGroupAndToleratesMissingItems() throws {
      let keychain = FakeKeychain(statuses: ["delete": [errSecMissingEntitlement, errSecItemNotFound]])
      try makeStore(keychain).delete("tokens.live")
      #expect(keychain.calls.map(\.operation) == ["delete", "delete"])
   }

   @Test func deleteThrowsForAnyOtherStatus() {
      let keychain = FakeKeychain(fallbackStatus: errSecInteractionNotAllowed)
      #expect(throws: KeychainError(status: errSecInteractionNotAllowed)) { try makeStore(keychain).delete("tokens.live") }
   }

   @Test func memoryStoreKeepsValuesPerAccount() throws {
      let store = MemorySecureStore()
      try store.save(Data("a".utf8), for: "one")
      #expect(try store.load("one") == Data("a".utf8))
      #expect(try store.load("two") == nil)
      try store.delete("one")
      #expect(try store.load("one") == nil)
   }
}
