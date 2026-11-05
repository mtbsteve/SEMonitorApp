import Foundation
import SwiftUI

// MARK: - Shared app constants

enum AppConfig {
    /// Shared App Group between Watch app and Complication. MUST match in both
    /// entitlement files and both Swift constants — a mismatch silently breaks
    /// the complication (it shows "—").
    static let appGroupID = "group.com.mtbsteve.semonitor"

    /// Foreground auto-refresh cadence.
    ///
    /// This timer only runs while the app is in the foreground, so in practice
    /// it fires rarely — the dominant cost is one refresh per app launch. The
    /// real protection against SolarEdge's hard monthly credit wall is
    /// `CreditBudget`, not this interval. See `SEConfig.swift`.
    static let refreshInterval: TimeInterval = 15 * 60

    static let demoToken = "demo"
}

// MARK: - App-level snapshots (Codable for shared-defaults cache)

/// Instantaneous values used by the header card and complication.
struct Snapshot: Codable, Equatable {
    var siteId: Int
    var siteName: String
    var currency: String
    /// Current PV power in kW — latest sample of the `/power` series
    /// (panel-side).
    var currentPowerKW: Double?
    /// Today's panel-side PV production in kWh (`overview.production.total`).
    var todayEnergyKWh: Double?
    /// Today's energy exported to grid in kWh (`overview.production.toGrid`).
    var todayExportedKWh: Double?
    /// Today's house consumption in kWh (`overview.consumption.total`).
    var todayConsumptionKWh: Double?
    /// Lifetime energy in kWh (not populated; kept for cache compatibility).
    var lifetimeEnergyKWh: Double?
    /// Per-battery state-of-charge percentages (0…100) at the latest telemetry.
    var batterySoC: [Double]
    var fetchedAt: Date

    static let empty = Snapshot(
        siteId: 0,
        siteName: "—",
        currency: "EUR",
        currentPowerKW: nil,
        todayEnergyKWh: nil,
        todayExportedKWh: nil,
        todayConsumptionKWh: nil,
        lifetimeEnergyKWh: nil,
        batterySoC: [],
        fetchedAt: .distantPast
    )
}

/// 24h chart series — power in kW, battery SoC in %.
struct HistorySeries: Codable, Equatable {
    struct Point: Codable, Equatable {
        let t: Date
        let v: Double
    }
    /// Panel-side PV production in kW.
    var solar: [Point]
    /// House consumption in kW.
    var consumption: [Point]
    /// Net grid in kW. Positive = importing, negative = exporting.
    var grid: [Point]
    /// One series per battery, SoC in % (0…100).
    var batteries: [[Point]]

    static let empty = HistorySeries(solar: [], consumption: [], grid: [], batteries: [])

    /// SolarEdge's API ends history at the last reported sample. Pad to `date`
    /// so charts extend to the right edge instead of stopping mid-axis.
    static func carryingForward(_ series: [Point], to date: Date) -> [Point] {
        guard let last = series.last, date > last.t else { return series }
        return series + [Point(t: date, v: last.v)]
    }
}

// MARK: - Errors

enum SolarEdgeError: LocalizedError {
    case http(Int)
    case decoding(String)
    case network(String)
    case invalidConfig
    /// Secrets.xcconfig is missing, still holds placeholders, or the client
    /// credentials were rejected.
    case notConfigured
    /// The refresh token is spent or past its 14-day idle life. Only re-running
    /// the consent flow on a Mac can fix this.
    case authExpired
    case oauth(String)
    /// HTTP 429, per-minute CPM exceeded. Retryable shortly.
    case rateLimit
    /// HTTP 429, monthly credit allowance exhausted. Not retryable until the
    /// billing cycle resets; the Free tier has no overage.
    case creditLimit
    /// Our own self-imposed daily cap, which exists to keep us away from
    /// `creditLimit`.
    case budgetExhausted

    var errorDescription: String? {
        switch self {
        case .http(let code):
            switch code {
            case 401: return "Not authorized (401). Token may be revoked."
            case 403: return "Forbidden (403). Tier or scope restriction."
            default:  return "HTTP \(code) error"
            }
        case .decoding(let msg): return "Decode error: \(msg)"
        case .network(let msg):  return "Network error: \(msg)"
        case .invalidConfig:     return "Invalid configuration."
        case .notConfigured:     return "No SolarEdge credentials in this build. See README."
        case .authExpired:       return "Authorization expired. Re-run the consent flow on your Mac."
        case .oauth(let msg):    return "OAuth error: \(msg)"
        case .rateLimit:         return "Rate limit hit. Try again in a minute."
        case .creditLimit:       return "Monthly API credit limit reached. Resets next billing cycle."
        // Deliberately does not interpolate CreditBudget: the complication
        // target compiles Models.swift but not SEConfig.swift.
        case .budgetExhausted:   return "Daily API budget used. Showing cached data."
        }
    }
}
