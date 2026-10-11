import Foundation

/// Which backend the app talks to. `mock` runs the in-process mock of the Site API
/// contract so the app is usable before https://api.kof22.com is published.
public enum BackendMode: String, Codable, Sendable, CaseIterable {
    case mock
    case live
}

/// OAuth settings for the Authentik public client, as documented by the backend
/// (`SiteApiDocs`, `SiteApiTokenVerifier`). No secrets: PKCE public client.
public struct OAuthConfig: Sendable, Equatable {
    public var issuer: URL
    public var authorizeURL: URL
    public var tokenURL: URL
    public var revokeURL: URL
    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]

    public var callbackScheme: String { redirectURI.scheme ?? "" }

    public static let kof22 = OAuthConfig(
        issuer: URL(string: "https://auth.kof22.com/application/o/kof22-post-ios/")!,
        authorizeURL: URL(string: "https://auth.kof22.com/application/o/authorize/")!,
        tokenURL: URL(string: "https://auth.kof22.com/application/o/token/")!,
        revokeURL: URL(string: "https://auth.kof22.com/application/o/revoke/")!,
        clientID: "kof22-post-ios",
        redirectURI: URL(string: "com.kof22.post://oauth/callback")!,
        scopes: ["openid", "profile", "email", "offline_access", "kof22:publish"]
    )
}

public struct AppConfig: Sendable, Equatable {
    public var apiBaseURL: URL
    public var websiteURL: URL
    public var oauth: OAuthConfig

    public static let production = AppConfig(
        apiBaseURL: URL(string: "https://api.kof22.com")!,
        websiteURL: URL(string: "https://www.kof22.com")!,
        oauth: .kof22
    )

    /// Base URL the generated client is pointed at in mock mode. Never resolved.
    public static let mockAPIBaseURL = URL(string: "https://mock.api.kof22.invalid")!
}

/// Identifiers shared by the app and its extensions.
public enum SharedIDs {
    public static let appGroup = "group.com.kof22.post"
    public static let keychainService = "com.kof22.post.auth"
    public static let urlScheme = "com.kof22.post"
    public static let backgroundTask = "com.kof22.post.outbox"
}

/// Small settings shared through the App Group defaults so the extensions see them.
public struct SharedSettings: @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: SharedIDs.appGroup) ?? .standard
    }

    public var backendMode: BackendMode {
        get { defaults.string(forKey: "backendMode").flatMap(BackendMode.init) ?? .mock }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "backendMode") }
    }

    public var lastBlogSlug: String? {
        get { defaults.string(forKey: "lastBlogSlug") }
        nonmutating set { defaults.set(newValue, forKey: "lastBlogSlug") }
    }
}
