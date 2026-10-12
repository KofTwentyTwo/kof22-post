/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// Answers diagnostics requests by URL path, recording each request.
final class RoutedLoader: @unchecked Sendable {
   /// One canned reply: a status and body, or a transport failure.
   enum Route {
      /// An HTTP response.
      case http(Int, String)
      /// A transport error.
      case failure(URLError.Code)
   }

   /// Guards `seen`.
   private let lock = NSLock()
   /// Replies keyed by a suffix of the URL path.
   private let routes: [String: Route]
   /// The requests received.
   private var seen: [URLRequest] = []

   /// Creates a loader with `routes`; unmatched paths fail with `cannotFindHost`.
   init(_ routes: [String: Route]) { self.routes = routes }

   /// The requests received so far.
   var requests: [URLRequest] { lock.withLock { seen } }

   /// The loader to inject.
   var loader: HTTPLoader {
      { request in
         self.lock.withLock { self.seen.append(request) }
         let path = request.url?.path() ?? ""
         let route = self.routes.first { path.hasSuffix($0.key) }?.value ?? .failure(.cannotFindHost)
         switch route {
         case .http(let status, let body): return try reply(request, status: status, body: body)
         case .failure(let code): throw URLError(code)
         }
      }
   }
}

@Suite struct ServiceDiagnosticsTests {
   let issuer = OAuthConfig.kof22.issuer.absoluteString

   func healthy() throws -> [String: RoutedLoader.Route] {
      [
         "openid-configuration": .http(200, #"{"issuer":"\#(issuer)","jwks_uri":"x"}"#),
         "versions.json": .http(200, try #require(String(bytes: try Fixture.data("versions"), encoding: .utf8))),
         "blog/query": .http(200, #"{"pageNo":1,"pageSize":1,"count":2,"records":[{"id":2}]}"#),
         "token/": .http(405, ""),
      ]
   }

   @Test func allChecksPassAgainstHealthyServices() async throws {
      let routes = RoutedLoader(try healthy())
      let checks = await ServiceDiagnostics(load: routes.loader).run()
      #expect(checks.map(\.id) == ["oidc", "versions", "read", "token"])
      #expect(checks.allSatisfy { $0.passed })
      #expect(checks[1].detail == "v1 1.1.0")
      #expect(checks[2].detail == "2 blogs")
      #expect(checks[3].detail == "HTTP 405 from https://auth.kof22.com/application/o/token/")
      #expect(routes.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.httpMethod == "GET" })
      let read = try #require(routes.requests.first { $0.url?.path().hasSuffix("blog/query") == true })
      #expect(read.url?.query() == "pageSize=1")
      #expect(read.timeoutInterval == ServiceDiagnostics.checkTimeout)
   }

   @Test func missingDiscoveryDocumentFails() async throws {
      var routes = try healthy()
      routes["openid-configuration"] = .http(404, "<html>not found</html>")
      let check = await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkDiscovery()
      #expect(!check.passed)
      #expect(check.detail.hasPrefix("HTTP 404"))
   }

   @Test(arguments: [#"{"jwks_uri":"x"}"#, "not json", #"["array"]"#])
   func discoveryWithoutAnIssuerFails(body: String) async throws {
      var routes = try healthy()
      routes["openid-configuration"] = .http(200, body)
      let check = await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkDiscovery()
      #expect(check == DiagnosticCheck(id: "oidc", title: "Sign-in provider", passed: false, detail: "The discovery document has no issuer"))
   }

   @Test func discoveryForAnotherIssuerFails() async throws {
      var routes = try healthy()
      routes["openid-configuration"] = .http(200, #"{"issuer":"https://elsewhere.example/"}"#)
      let check = await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkDiscovery()
      #expect(!check.passed)
      #expect(check.detail.contains("elsewhere"))
   }

   @Test func versionFailuresAreReported() async throws {
      var routes = try healthy()
      routes["versions.json"] = .http(503, "")
      #expect(await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkVersions().detail == "HTTP 503")
      routes["versions.json"] = .http(200, "{}")
      let unreadable = await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkVersions()
      #expect(!unreadable.passed)
      #expect(unreadable.detail == "The version list is not readable")
   }

   @Test func versionWithoutACurrentEntryStillPasses() async throws {
      var routes = try healthy()
      routes["versions.json"] = .http(200, #"{"currentVersion":"v2","supportedVersions":["v2"],"versions":[]}"#)
      let check = await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkVersions()
      #expect(check.passed)
      #expect(check.detail == "v2 (no semver)")
   }

   @Test func readFailuresAreReported() async throws {
      var routes = try healthy()
      routes["blog/query"] = .http(429, "")
      #expect(await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkAnonymousRead().detail == "HTTP 429")
      routes["blog/query"] = .http(200, #"{"pageNo":1}"#)
      #expect(await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkAnonymousRead().passed == false)
      routes["blog/query"] = .http(200, #"{"records":[]}"#)
      #expect(await ServiceDiagnostics(load: RoutedLoader(routes).loader).checkAnonymousRead().detail == "Readable")
   }

   @Test func unreachableHostsFailEveryCheck() async {
      let checks = await ServiceDiagnostics(load: RoutedLoader([:]).loader).run()
      #expect(checks.allSatisfy { !$0.passed })
      #expect(checks.allSatisfy { $0.detail == URLError(.cannotFindHost).localizedDescription })
   }

   @Test func defaultDiagnosticsUseProduction() {
      #expect(ServiceDiagnostics().config == .production)
   }
}
