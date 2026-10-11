import Foundation

/// Presents the browser sign-in and returns the redirect URL. The app implements it
/// with `WebAuthenticationSession`; tests use a stub.
public protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Owns the token set for one backend mode: sign-in, silent refresh (single flight),
/// and sign-out with revocation. Tokens live in the Keychain only.
public actor AuthSession {
    public let mode: BackendMode
    private let oauth: OAuthClient
    private let store: any SecureStore
    private let now: @Sendable () -> Date
    private var tokens: TokenSet?
    private var loaded = false
    private var refreshTask: Task<TokenSet, any Error>?
    /// Bumped on sign-out so a refresh that finishes afterwards is discarded.
    private var generation = 0

    /// Refresh this long before the access token expires.
    static let refreshLeeway: TimeInterval = 60

    public init(
        mode: BackendMode,
        oauth: OAuthClient = OAuthClient(config: .kof22),
        store: any SecureStore = KeychainStore(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.mode = mode
        self.oauth = oauth
        self.store = store
        self.now = now
    }

    private var account: String { "tokens.\(mode.rawValue)" }

    private func current() -> TokenSet? {
        if !loaded {
            loaded = true
            tokens = (try? store.load(account)).flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
        }
        return tokens
    }

    private func persist(_ newTokens: TokenSet?) {
        tokens = newTokens
        loaded = true
        if let newTokens, let data = try? JSONEncoder().encode(newTokens) {
            try? store.save(data, for: account)
        } else {
            try? store.delete(account)
        }
    }

    public var isSignedIn: Bool { current() != nil }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        if mode == .mock {
            persist(TokenSet(
                accessToken: "mock-access-\(UUID().uuidString)",
                refreshToken: "mock-refresh",
                idToken: nil,
                expiresAt: now().addingTimeInterval(30 * 24 * 3600)
            ))
            return
        }
        let pkce = PKCE.generate()
        let state = PKCE.randomURLSafeString(byteCount: 16)
        let callback = try await authenticator.authenticate(
            url: oauth.authorizationURL(pkce: pkce, state: state),
            callbackScheme: oauth.config.callbackScheme
        )
        let code = try oauth.code(fromCallback: callback, expectedState: state)
        persist(try await oauth.exchange(code: code, pkce: pkce, now: now()))
    }

    /// Re-reads the Keychain: the app and the Share Extension share tokens, and
    /// the other process may have refreshed (and rotated) them.
    private func reloadFromStore() -> TokenSet? {
        loaded = false
        return current()
    }

    /// A non-expired access token, refreshing silently when needed.
    public func accessToken() async throws -> String {
        guard var tokens = current() else { throw AuthError.signedOut }
        if !tokens.expires(within: Self.refreshLeeway, now: now()) { return tokens.accessToken }
        guard let stored = reloadFromStore() else { throw AuthError.signedOut }
        tokens = stored
        if !tokens.expires(within: Self.refreshLeeway, now: now()) { return tokens.accessToken }
        return try await refreshed().accessToken
    }

    /// Called after a 401: refresh once even if the token looks valid.
    public func forceRefresh(rejected token: String) async throws -> String {
        guard let tokens = reloadFromStore() else { throw AuthError.signedOut }
        if tokens.accessToken != token { return tokens.accessToken }
        return try await refreshed().accessToken
    }

    private func refreshed() async throws -> TokenSet {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = current()?.refreshToken else {
            persist(nil)
            throw AuthError.sessionExpired
        }
        let mode = mode
        let oauth = oauth
        let instant = now()
        let startedGeneration = generation
        let task = Task<TokenSet, any Error> {
            if mode == .mock {
                return TokenSet(accessToken: "mock-access-\(UUID().uuidString)", refreshToken: refreshToken,
                                idToken: nil, expiresAt: instant.addingTimeInterval(30 * 24 * 3600))
            }
            return try await oauth.refresh(refreshToken, now: instant)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let newTokens = try await task.value
            guard startedGeneration == generation else { throw AuthError.signedOut }
            persist(newTokens)
            return newTokens
        } catch AuthError.sessionExpired {
            // Another process may have rotated the refresh token while we used the old one.
            if let latest = reloadFromStore(), latest.refreshToken != refreshToken {
                return latest
            }
            persist(nil)
            throw AuthError.sessionExpired
        }
    }

    public func signOut() async {
        generation += 1
        refreshTask = nil
        let tokens = current()
        persist(nil)
        guard mode == .live, let tokens else { return }
        if let refresh = tokens.refreshToken {
            await oauth.revoke(refresh, hint: "refresh_token")
        }
        await oauth.revoke(tokens.accessToken, hint: "access_token")
    }
}
