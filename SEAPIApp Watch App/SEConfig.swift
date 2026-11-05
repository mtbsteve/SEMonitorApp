import Foundation

// MARK: - Build-time credentials (Secrets.xcconfig -> Info.plist -> here)

/// SolarEdge V2 OAuth credentials, injected at build time from
/// `Secrets.xcconfig` via `INFOPLIST_KEY_*` substitutions in `project.yml`.
///
/// V2 has no user-enterable API key: a site is reached with an OAuth bearer
/// token, and minting one needs a browser consent flow plus a client secret.
/// That cannot happen on a watch, so SE Monitor is a personal build — you
/// provision your own grant once with `tools/se-token.sh` and bake it in.
/// See "Build your own" in the README.
enum SEConfig {

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var clientID: String { info("SEClientID") }
    static var clientSecret: String { info("SEClientSecret") }

    /// The refresh token baked in at build time. Only ever used to *seed*
    /// storage on first launch — SolarEdge rotates the refresh token on every
    /// refresh, so after the first one the live value lives in the App Group
    /// and this build-time copy is stale. See `SETokenStore`.
    static var seedRefreshToken: String { info("SERefreshToken") }

    static var siteID: Int { Int(info("SESiteID")) ?? 0 }

    /// True when the build carries a usable grant. A placeholder xcconfig
    /// (`your_client_id_here`, `SE_SITE_ID = 0`) deliberately fails this.
    static var isConfigured: Bool {
        !clientID.isEmpty && !clientID.hasPrefix("your_")
            && !clientSecret.isEmpty && !clientSecret.hasPrefix("your_")
            && siteID != 0
    }
}

// MARK: - Credit budget

/// Self-imposed cap on API consumption.
///
/// SolarEdge's Free tier allows **2,000 credits/month at 1 credit per call**,
/// and **overage is not available on Free** — once the allowance is gone every
/// call returns HTTP 429 until the billing cycle anniversary. There is no way
/// to buy your way out mid-month, so the app rations itself rather than
/// risking a multi-day blackout.
///
/// Budget: 4 calls per refresh × 12 refreshes/day ≈ 1,488 credits in a 31-day
/// month, about 74% of the allowance. The rest is headroom for days you open
/// the app more than usual.
enum CreditBudget {

    /// overview + power + meters/telemetry + storage/telemetry
    static let callsPerRefresh = 4

    /// 12 refreshes/day. Raise cautiously: 16/day is ~1,984/month, i.e. no
    /// margin at all in a 31-day month.
    static let maxCallsPerDay = 48

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConfig.appGroupID) }

    private static let dayKey = "credit_day"
    private static let countKey = "credit_count"

    private static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Calls already made today, resetting automatically at local midnight.
    static var spentToday: Int {
        guard let d = defaults else { return 0 }
        guard d.string(forKey: dayKey) == today else { return 0 }
        return d.integer(forKey: countKey)
    }

    static var remainingToday: Int { max(0, maxCallsPerDay - spentToday) }

    static func canAfford(_ calls: Int = callsPerRefresh) -> Bool {
        remainingToday >= calls
    }

    static func record(_ calls: Int) {
        guard let d = defaults else { return }
        if d.string(forKey: dayKey) != today {
            d.set(today, forKey: dayKey)
            d.set(0, forKey: countKey)
        }
        d.set(d.integer(forKey: countKey) + calls, forKey: countKey)
    }
}
