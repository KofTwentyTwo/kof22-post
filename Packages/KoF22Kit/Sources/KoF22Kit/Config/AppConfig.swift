/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Which backend the app talks to. `mock` runs the in-process mock of the Site API
/// contract so the app is usable before https://api.kof22.com is published.
public enum BackendMode: String, Codable, Sendable, CaseIterable {
   /// The in-process mock backend; no network, no real account.
   case mock
   /// The real Site API and Authentik sign-in.
   case live
}

/// OAuth settings for the Authentik public client, as documented by the backend
/// (`SiteApiDocs`, `SiteApiTokenVerifier`). No secrets: PKCE public client.
public struct OAuthConfig: Sendable, Equatable {
   /// The OpenID Connect issuer.
   public var issuer: URL
   /// Where the browser sign-in starts.
   public var authorizeURL: URL
   /// Where codes and refresh tokens are traded for tokens.
   public var tokenURL: URL
   /// Where tokens are revoked on sign-out.
   public var revokeURL: URL
   /// The public client id; there is no client secret.
   public var clientID: String
   /// The app URL Authentik redirects to after sign-in.
   public var redirectURI: URL
   /// The scopes requested at sign-in.
   public var scopes: [String]

   /// The redirect's URL scheme, which the browser sheet listens for.
   public var callbackScheme: String { redirectURI.scheme ?? "" }

   /// The production Authentik client for KoF22 Post.
   public static let kof22 = Self(
      issuer: URL(literal: "https://auth.kof22.com/application/o/kof22-post-ios/"),
      authorizeURL: URL(literal: "https://auth.kof22.com/application/o/authorize/"),
      tokenURL: URL(literal: "https://auth.kof22.com/application/o/token/"),
      revokeURL: URL(literal: "https://auth.kof22.com/application/o/revoke/"),
      clientID: "kof22-post-ios",
      redirectURI: URL(literal: "com.kof22.post://oauth/callback"),
      scopes: ["openid", "profile", "email", "offline_access", "kof22:publish"]
   )
}

/// The hosts and sign-in settings for one environment.
public struct AppConfig: Sendable, Equatable {
   /// The Site API host.
   public var apiBaseURL: URL
   /// The public website, used for links to published posts.
   public var websiteURL: URL
   /// The sign-in settings.
   public var oauth: OAuthConfig

   /// The live kof22.com environment.
   public static let production = Self(
      apiBaseURL: URL(literal: "https://api.kof22.com"),
      websiteURL: URL(literal: "https://www.kof22.com"),
      oauth: .kof22
   )

   /// Base URL the generated client is pointed at in mock mode. Never resolved.
   public static let mockAPIBaseURL = URL(literal: "https://mock.api.kof22.invalid")
}

/// Identifiers shared by the app and its extensions.
public enum SharedIDs {
   /// The App Group that holds the shared store, photos and settings.
   public static let appGroup = "group.com.kof22.post"
   /// The Keychain service for tokens.
   public static let keychainService = "com.kof22.post.auth"
   /// The app's URL scheme, also used for the OAuth redirect.
   public static let urlScheme = "com.kof22.post"
   /// The background task that drains the outbox.
   public static let backgroundTask = "com.kof22.post.outbox"
   /// The background `URLSession` that PUTs photos to presigned URLs.
   public static let backgroundUploadSession = "com.kof22.post.uploads"
}

/// Small settings shared through the App Group defaults so the extensions see them.
public struct SharedSettings: @unchecked Sendable {
   /// The defaults the settings live in. `UserDefaults` is documented thread-safe, which
   /// is why the type can be `@unchecked Sendable`.
   private let defaults: UserDefaults

   /// Uses `defaults` when given (tests, previews), otherwise the App Group suite.
   public init(defaults: UserDefaults? = nil) {
      self.defaults = defaults ?? Self.suite(named: SharedIDs.appGroup)
   }

   /// The defaults suite `name`, or standard defaults when Foundation refuses the name
   /// (it does for the global domain and the app's own bundle identifier).
   static func suite(named name: String) -> UserDefaults {
      guard let suite = UserDefaults(suiteName: name) else { return .standard }
      return suite
   }

   /// The backend the app uses; mock until the owner switches to live.
   public var backendMode: BackendMode {
      get { defaults.string(forKey: "backendMode").flatMap(BackendMode.init) ?? .mock }
      nonmutating set { defaults.set(newValue.rawValue, forKey: "backendMode") }
   }

   /// How large uploaded photos are; originals unless the owner picks `.large`.
   public var uploadSize: UploadSizePreference {
      get { defaults.string(forKey: "uploadSize").flatMap(UploadSizePreference.init) ?? .original }
      nonmutating set { defaults.set(newValue.rawValue, forKey: "uploadSize") }
   }

   /// The blog chosen for the last post, preselected in the composer.
   public var lastBlogSlug: String? {
      get { defaults.string(forKey: "lastBlogSlug") }
      nonmutating set { defaults.set(newValue, forKey: "lastBlogSlug") }
   }
}
