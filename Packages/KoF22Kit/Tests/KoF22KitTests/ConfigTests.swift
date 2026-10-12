/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

@Suite struct AppConfigTests {
   @Test func productionPointsAtTheLiveHosts() {
      let config = AppConfig.production
      #expect(config.apiBaseURL.absoluteString == "https://api.kof22.com")
      #expect(config.websiteURL.absoluteString == "https://www.kof22.com")
      #expect(config.oauth == .kof22)
      #expect(AppConfig.mockAPIBaseURL.host() == "mock.api.kof22.invalid")
   }

   @Test func oauthClientIsThePublicPKCEClient() {
      let oauth = OAuthConfig.kof22
      #expect(oauth.issuer.absoluteString == "https://auth.kof22.com/application/o/kof22-post-ios/")
      #expect(oauth.tokenURL.absoluteString == "https://auth.kof22.com/application/o/token/")
      #expect(oauth.revokeURL.absoluteString == "https://auth.kof22.com/application/o/revoke/")
      #expect(oauth.clientID == "kof22-post-ios")
      #expect(oauth.callbackScheme == SharedIDs.urlScheme)
      #expect(oauth.scopes.contains("offline_access"))
   }

   @Test func callbackSchemeIsEmptyForARedirectWithoutScheme() {
      var oauth = OAuthConfig.kof22
      oauth.redirectURI = URL(literal: "callback")
      #expect(oauth.callbackScheme.isEmpty)
   }

   @Test func sharedIdentifiersMatchTheEntitlements() {
      #expect(SharedIDs.appGroup == "group.com.kof22.post")
      #expect(SharedIDs.keychainService == "com.kof22.post.auth")
      #expect(SharedIDs.backgroundTask == "com.kof22.post.outbox")
      #expect(BackendMode.allCases == [.mock, .live])
   }
}

@Suite struct SharedSettingsTests {
   /// A private defaults suite so tests never touch the App Group's real settings.
   func makeDefaults() throws -> (UserDefaults, String) {
      let name = "kof22-settings-tests-\(UUID().uuidString)"
      return (try #require(UserDefaults(suiteName: name)), name)
   }

   @Test func backendModeDefaultsToMockAndPersists() throws {
      let (defaults, name) = try makeDefaults()
      defer { defaults.removePersistentDomain(forName: name) }
      let settings = SharedSettings(defaults: defaults)
      #expect(settings.backendMode == .mock)
      settings.backendMode = .live
      #expect(SharedSettings(defaults: defaults).backendMode == .live)
   }

   @Test func unknownBackendModeFallsBackToMock() throws {
      let (defaults, name) = try makeDefaults()
      defer { defaults.removePersistentDomain(forName: name) }
      defaults.set("staging", forKey: "backendMode")
      #expect(SharedSettings(defaults: defaults).backendMode == .mock)
   }

   @Test func lastBlogSlugIsRememberedAndCleared() throws {
      let (defaults, name) = try makeDefaults()
      defer { defaults.removePersistentDomain(forName: name) }
      let settings = SharedSettings(defaults: defaults)
      #expect(settings.lastBlogSlug == nil)
      settings.lastBlogSlug = "deep-thoughts"
      #expect(settings.lastBlogSlug == "deep-thoughts")
      settings.lastBlogSlug = nil
      #expect(settings.lastBlogSlug == nil)
   }

   @Test func refusedSuiteNameFallsBackToStandardDefaults() throws {
      #expect(SharedSettings.suite(named: UserDefaults.globalDomain) === UserDefaults.standard)
      let name = "kof22-settings-tests-\(UUID().uuidString)"
      let suite = SharedSettings.suite(named: name)
      defer { suite.removePersistentDomain(forName: name) }
      #expect(suite !== UserDefaults.standard)
   }

   @Test func defaultSettingsReadTheAppGroupSuite() {
      ////////////////////////////////////////////////////////////
      // only reads: the App Group suite must not be changed by //
      // tests.                                                 //
      ////////////////////////////////////////////////////////////
      let mode = SharedSettings().backendMode
      #expect(BackendMode.allCases.contains(mode))
   }
}

@Suite struct SharedContainerTests {
   @Test func prefersTheAppGroupContainer() {
      let group = URL(filePath: "/tmp/group", directoryHint: .isDirectory)
      let support = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
      #expect(SharedContainer.resolveRoot(groupContainer: group, applicationSupport: support) == group)
   }

   @Test func fallsBackToApplicationSupportWithoutTheAppGroup() {
      let support = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
      let root = SharedContainer.resolveRoot(groupContainer: nil, applicationSupport: support)
      #expect(root.path() == "/tmp/support/KoF22Post/")
   }

   @Test func directoryIsCreatedOnFirstUse() throws {
      let root = TestImages.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let folder = SharedContainer.directory("Outbox Photos", root: root)
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)
   }

   @Test func directoryThatCannotBeCreatedIsStillReturned() throws {
      let root = TestImages.temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let blocker = root.appending(path: "not-a-folder")
      try Data("file".utf8).write(to: blocker)
      let folder = SharedContainer.directory("Store", root: blocker)
      #expect(folder.lastPathComponent == "Store")
      #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
   }

   @Test func wellKnownLocationsLiveUnderTheRoot() {
      let root = SharedContainer.rootURL
      #expect(SharedContainer.photosDirectory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
      #expect(SharedContainer.mockDirectory.lastPathComponent == "Mock Backend")
      #expect(SharedContainer.storeURL.lastPathComponent == "KoF22Post.store")
   }
}
