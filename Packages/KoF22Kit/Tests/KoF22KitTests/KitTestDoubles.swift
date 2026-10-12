/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Security

@testable import KoF22Kit

/// What `StubURLProtocol` answers for one request.
enum StubReply: Sendable {
   /// An HTTP response with a status code and text body.
   case http(status: Int, body: String)
   /// An HTTP response with a status code and raw body bytes.
   case httpData(status: Int, body: Data)
   /// A response that is not HTTP, as a misbehaving protocol handler might return.
   case nonHTTP
   /// A transport failure.
   case failure(URLError.Code)
}

/// Routes stubbed requests by host, so tests running in parallel each get their own
/// handler without sharing global state.
final class StubRoutes: @unchecked Sendable {
   /// The process-wide routing table used by `StubURLProtocol`.
   static let shared = StubRoutes()

   /// Guards `handlers` and `received`.
   private let lock = NSLock()
   /// The reply for each registered host.
   private var handlers: [String: StubReply] = [:]
   /// The requests seen for each host.
   private var received: [String: [URLRequest]] = [:]

   /// Registers `reply` under a fresh host and returns that host.
   func register(_ reply: StubReply) -> String {
      let host = "stub-\(UUID().uuidString.lowercased()).invalid"
      lock.withLock { handlers[host] = reply }
      return host
   }

   /// Records `request` and returns the reply registered for its host.
   func reply(for request: URLRequest) -> StubReply {
      let host = request.url?.host() ?? ""
      return lock.withLock {
         received[host, default: []].append(request)
         return handlers[host] ?? .failure(.cannotFindHost)
      }
   }

   /// The requests recorded for `host`.
   func requests(for host: String) -> [URLRequest] {
      lock.withLock { received[host] ?? [] }
   }
}

/// A `URLProtocol` that answers from `StubRoutes` so the real `URLSession` code paths run
/// without any network traffic.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
   /// Handles every request on sessions it is installed in.
   override static func canInit(with request: URLRequest) -> Bool { true }

   /// Leaves requests unchanged.
   override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

   /// Delivers the registered reply.
   override func startLoading() {
      guard let client, let url = request.url else { return }
      switch StubRoutes.shared.reply(for: request) {
      case .http(let status, let body):
         deliver(status: status, body: Data(body.utf8), url: url, to: client)
      case .httpData(let status, let body):
         deliver(status: status, body: body, url: url, to: client)
      case .nonHTTP:
         let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
         client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
         client.urlProtocolDidFinishLoading(self)
      case .failure(let code):
         client.urlProtocol(self, didFailWithError: URLError(code))
      }
   }

   /// Sends an HTTP response and its body to the loading system.
   private func deliver(status: Int, body: Data, url: URL, to client: any URLProtocolClient) {
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
      client.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: body)
      client.urlProtocolDidFinishLoading(self)
   }

   /// Nothing to cancel; replies are delivered synchronously.
   override func stopLoading() {}

   /// An ephemeral session that only talks to `StubURLProtocol`.
   static func makeSession() -> URLSession {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [Self.self]
      return URLSession(configuration: configuration)
   }
}

/// A `SecureStore` whose operations can be made to fail, to check how callers cope with
/// an unavailable Keychain.
final class ScriptedSecureStore: SecureStore, @unchecked Sendable {
   /// The failure thrown by operations that are set to fail.
   static let failure = KeychainError(status: errSecInteractionNotAllowed)

   /// Guards the mutable state.
   private let lock = NSLock()
   /// The stored values by account.
   private var items: [String: Data] = [:]
   /// When true, `load` throws.
   private var loadFails = false
   /// When true, `save` throws.
   private var saveFails = false
   /// When true, `delete` throws.
   private var deleteFails = false

   /// Creates a store, optionally with operations that always fail.
   init(loadFails: Bool = false, saveFails: Bool = false, deleteFails: Bool = false) {
      self.loadFails = loadFails
      self.saveFails = saveFails
      self.deleteFails = deleteFails
   }

   /// Puts raw bytes in the store, bypassing the failure switches.
   func seed(_ data: Data, for account: String) {
      lock.withLock { items[account] = data }
   }

   /// The raw bytes stored for `account`.
   func stored(_ account: String) -> Data? {
      lock.withLock { items[account] }
   }

   /// Returns the stored value or throws when loads are set to fail.
   func load(_ account: String) throws -> Data? {
      try lock.withLock {
         if loadFails { throw Self.failure }
         return items[account]
      }
   }

   /// Stores the value or throws when saves are set to fail.
   func save(_ data: Data, for account: String) throws {
      try lock.withLock {
         if saveFails { throw Self.failure }
         items[account] = data
      }
   }

   /// Removes the value or throws when deletes are set to fail.
   func delete(_ account: String) throws {
      try lock.withLock {
         if deleteFails { throw Self.failure }
         items[account] = nil
      }
   }
}
