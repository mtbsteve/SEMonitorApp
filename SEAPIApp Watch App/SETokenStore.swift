import Foundation

/// OAuth 2.0 token manager for the SolarEdge V2 API.
///
/// ## Why this is an actor
///
/// SolarEdge **rotates the refresh token on every refresh**: the response
/// carries a new one and the old one dies immediately. Two concurrent
/// refreshes therefore destroy each other's grant — the loser's token is
/// already invalid, and recovering means sending the user back through the
/// browser consent flow. Serializing every refresh through a single actor,
/// with explicit single-flight coalescing, is what prevents that.
///
/// For the same reason the **complication never refreshes**. It reads only the
/// snapshot the watch app cached; it is a separate process, so an actor here
/// cannot protect it. See `SEAPIComplication.swift`.
actor SETokenStore {

    static let shared = SETokenStore()

    private static let tokenURL = URL(string: "https://monitoringapi.solaredge.com/v2/oauth2/token")!

    /// Refresh this long before the token actually expires, so a request in
    /// flight can't straddle the boundary.
    private static let expiryMargin: TimeInterval = 300

    private let defaults = UserDefaults(suiteName: AppConfig.appGroupID)

    private enum Key {
        static let refresh = "se_refresh_token"
        static let access = "se_access_token"
        static let expiry = "se_access_expiry"
        /// The build-time seed we last adopted, so we can tell a rebuild that
        /// carries *new* credentials from an ordinary relaunch.
        static let seed = "se_seed_token"
    }

    /// Coalesces concurrent callers onto one network refresh. An actor
    /// serializes *statements*, but every `await` is a suspension point at
    /// which another caller can enter — so without this, two callers could
    /// each start their own refresh.
    private var inFlight: Task<String, Error>?

    // MARK: - Public

    /// A valid bearer token, refreshing only when the cached one has expired.
    func accessToken() async throws -> String {
        adoptNewSeedIfChanged()

        if let cached = unexpiredCachedToken() { return cached }

        if let existing = inFlight {
            return try await existing.value
        }
        let task = Task<String, Error> { try await performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Wipe tokens (used by `clearConfig`). Does not revoke server-side.
    func clear() {
        defaults?.removeObject(forKey: Key.refresh)
        defaults?.removeObject(forKey: Key.access)
        defaults?.removeObject(forKey: Key.expiry)
        // Clear the seed marker too, so the next launch re-adopts the build's
        // credentials rather than treating them as already seen.
        defaults?.removeObject(forKey: Key.seed)
    }

    // MARK: - Storage

    /// Adopt the build's baked-in refresh token when it differs from the one
    /// we last took, discarding whatever is stored.
    ///
    /// Without this, re-provisioning silently fails to take effect. Stored
    /// tokens normally win over the seed — they have to, because the seed goes
    /// stale the moment the app's first refresh rotates it. But that also
    /// means a *deliberately* refreshed seed (regenerate Secrets.xcconfig,
    /// rebuild) would be ignored in favour of a stored token that may itself
    /// be dead, leaving "Authorization expired" with no way out short of
    /// deleting the app.
    ///
    /// Comparing against the last-adopted seed distinguishes the two cases:
    /// an ordinary relaunch sees an unchanged seed and keeps using the stored
    /// token, while a rebuild carrying new credentials resets to them. So
    /// "regenerate and rebuild" is a reliable recovery path.
    private func adoptNewSeedIfChanged() {
        guard let d = defaults else { return }
        let seed = SEConfig.seedRefreshToken
        guard !seed.isEmpty, !seed.hasPrefix("your_") else { return }

        if d.string(forKey: Key.seed) != seed {
            d.set(seed, forKey: Key.refresh)
            d.set(seed, forKey: Key.seed)
            d.removeObject(forKey: Key.access)
            d.removeObject(forKey: Key.expiry)
        }
    }

    private func unexpiredCachedToken() -> String? {
        guard let d = defaults,
              let token = d.string(forKey: Key.access), !token.isEmpty,
              let expiry = d.object(forKey: Key.expiry) as? Date,
              expiry.timeIntervalSinceNow > 0
        else { return nil }
        return token
    }

    /// The live refresh token: whatever the last rotation stored, falling back
    /// to the build-time seed on first launch.
    private var currentRefreshToken: String {
        let stored = defaults?.string(forKey: Key.refresh) ?? ""
        return stored.isEmpty ? SEConfig.seedRefreshToken : stored
    }

    // MARK: - Refresh

    private func performRefresh() async throws -> String {
        guard SEConfig.isConfigured else { throw SolarEdgeError.notConfigured }

        let refreshToken = currentRefreshToken
        guard !refreshToken.isEmpty, !refreshToken.hasPrefix("your_") else {
            throw SolarEdgeError.notConfigured
        }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // NB: the V2 token endpoint takes a JSON body, NOT form-encoded fields.
        req.httpBody = try JSONEncoder().encode(TokenRequest(
            grant_type: "refresh_token",
            refresh_token: refreshToken,
            client_id: SEConfig.clientID,
            client_secret: SEConfig.clientSecret
        ))

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SolarEdgeError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SolarEdgeError.network("Invalid response")
        }

        guard (200..<300).contains(http.statusCode) else {
            // RFC 6749 error shape: { "error": ..., "error_description": ... }
            if let err = try? JSONDecoder().decode(OAuthError.self, from: data) {
                switch err.error {
                case "invalid_grant", "invalid_request":
                    // The refresh token is spent or past its 14-day idle life.
                    // Only re-running consent on a Mac can fix this.
                    throw SolarEdgeError.authExpired
                case "invalid_client":
                    throw SolarEdgeError.notConfigured
                default:
                    throw SolarEdgeError.oauth(err.error_description ?? err.error)
                }
            }
            throw SolarEdgeError.http(http.statusCode)
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw SolarEdgeError.decoding(String(describing: error))
        }

        // Persist the rotated refresh token FIRST. It is the irreplaceable
        // half of the pair: if we crash between these two writes we lose only
        // a cheap access-token cache, not the grant.
        if let rotated = token.refresh_token, !rotated.isEmpty {
            defaults?.set(rotated, forKey: Key.refresh)
        }
        defaults?.set(token.access_token, forKey: Key.access)
        defaults?.set(Date().addingTimeInterval(TimeInterval(token.expires_in ?? 7200) - Self.expiryMargin),
                      forKey: Key.expiry)

        return token.access_token
    }

    // MARK: - Wire types

    private struct TokenRequest: Encodable {
        let grant_type: String
        let refresh_token: String
        let client_id: String
        let client_secret: String
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String?
        let expires_in: Int?
        let refresh_token: String?
    }

    private struct OAuthError: Decodable {
        let error: String
        let error_description: String?
    }
}
