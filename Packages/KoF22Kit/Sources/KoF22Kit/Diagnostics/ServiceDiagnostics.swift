/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The result of one connectivity check, shown as a row in Settings.
public struct DiagnosticCheck: Sendable, Equatable, Identifiable {
   /// A stable identifier: `oidc`, `versions`, `read` or `token`.
   public let id: String
   /// What was checked, for the row title.
   public let title: String
   /// Whether the check passed.
   public let passed: Bool
   /// What was found: a version, a count, a status code or why it failed.
   public let detail: String

   /// Creates a result.
   public init(id: String, title: String, passed: Bool, detail: String) {
      self.id = id
      self.title = title
      self.passed = passed
      self.detail = detail
   }
}

/// Checks that the services the app depends on answer as expected: the sign-in
/// provider's discovery document, the API's version list, an anonymous read, and the
/// token endpoint's host. It sends no credentials and writes nothing; each check is one
/// GET with a short timeout.
public struct ServiceDiagnostics: Sendable {
   /// Each check gives up after this long.
   static let checkTimeout: TimeInterval = 10
   /// The HTTP status of a successful check.
   static let okStatus = 200

   /// The hosts and sign-in settings to check.
   let config: AppConfig
   /// Performs the requests; tests inject a stub.
   let load: HTTPLoader

   /// Creates diagnostics for `config` using `load` for every request.
   public init(config: AppConfig = .production, load: @escaping HTTPLoader = HTTPLoaders.urlSession()) {
      self.config = config
      self.load = load
   }

   /// Runs every check concurrently and returns the results in a fixed order:
   /// sign-in provider, API version, public content, token service.
   public func run() async -> [DiagnosticCheck] {
      async let discovery = checkDiscovery()
      async let versions = checkVersions()
      async let read = checkAnonymousRead()
      async let token = checkTokenEndpoint()
      return await [discovery, versions, read, token]
   }

   /// The issuer's OpenID Connect discovery document: 200, JSON, matching `issuer`.
   func checkDiscovery() async -> DiagnosticCheck {
      let issuer = config.oauth.issuer.absoluteString
      let url = config.oauth.issuer.appending(path: ".well-known/openid-configuration")
      return await check(id: "oidc", title: "Sign-in provider", url: url) { data, status in
         guard status == Self.okStatus else { return (false, "HTTP \(status) for \(url.absoluteString)") }
         guard let found = Self.jsonObject(data)?["issuer"] as? String else { return (false, "The discovery document has no issuer") }
         guard found == issuer else { return (false, "Issuer is \(found), expected \(issuer)") }
         return (true, "Issuer \(issuer)")
      }
   }

   /// `/versions.json`: 200 with the version list; reports the current version's semver.
   func checkVersions() async -> DiagnosticCheck {
      await check(id: "versions", title: "API version", url: config.apiBaseURL.appending(path: "versions.json")) { data, status in
         guard status == Self.okStatus else { return (false, "HTTP \(status)") }
         let versions: APIVersions
         do {
            versions = try JSONDecoder().decode(APIVersions.self, from: data)
         }
         catch {
            Log.api.warning("Diagnostics: versions.json is not readable: \(error.localizedDescription, privacy: .public)")
            return (false, "The version list is not readable")
         }
         let current = versions.versions.first { $0.version == versions.currentVersion }
         return (true, "\(versions.currentVersion) \(current?.semver ?? "(no semver)")")
      }
   }

   /// `/v1/blog/query?pageSize=1`: 200 with a `records` array, without credentials.
   func checkAnonymousRead() async -> DiagnosticCheck {
      let url = config.apiBaseURL.appending(path: "v1/blog/query").appending(queryItems: [URLQueryItem(name: "pageSize", value: "1")])
      return await check(id: "read", title: "Public content", url: url) { data, status in
         guard status == Self.okStatus else { return (false, "HTTP \(status)") }
         guard let page = Self.jsonObject(data), page["records"] is [Any] else { return (false, "The reply has no records") }
         return (true, (page["count"] as? Int).map { "\($0) blogs" } ?? "Readable")
      }
   }

   /// The token endpoint's host answers HTTP at all; any status counts, since a GET
   /// without a grant is expected to be refused.
   func checkTokenEndpoint() async -> DiagnosticCheck {
      let url = config.oauth.tokenURL
      return await check(id: "token", title: "Sign-in token service", url: url) { _, status in
         (true, "HTTP \(status) from \(url.absoluteString)")
      }
   }

   /// Sends one GET without credentials and judges the reply with `evaluate`, which
   /// returns whether the check passed and the detail to show. A request that gets no
   /// response is logged and fails the check with the reason.
   func check(
      id: String, title: String, url: URL, evaluate: (Data, Int) -> (passed: Bool, detail: String)
   ) async -> DiagnosticCheck {
      var request = URLRequest(url: url)
      request.timeoutInterval = Self.checkTimeout
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      do {
         let (data, response) = try await load(request)
         let verdict = evaluate(data, response.statusCode)
         return DiagnosticCheck(id: id, title: title, passed: verdict.passed, detail: verdict.detail)
      }
      catch {
         Log.api.warning("Diagnostics: \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
         return DiagnosticCheck(id: id, title: title, passed: false, detail: error.localizedDescription)
      }
   }

   /// `data` as a JSON object, or nil when it is not one.
   static func jsonObject(_ data: Data) -> [String: Any]? {
      ///////////////////////////////////////////////////////
      // a non-JSON body (an HTML 404 page) is reported by //
      // the caller as a failed check.                     //
      ///////////////////////////////////////////////////////
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
   }
}
