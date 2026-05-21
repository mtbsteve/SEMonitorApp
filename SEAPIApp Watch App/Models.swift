import Foundation
import SwiftUI

// MARK: - Shared app constants

enum AppConfig {
    /// Shared App Group between Watch app and Complication. MUST match in both
    /// entitlement files and both Swift constants — a mismatch silently breaks
    /// the complication (it shows "—").
    static let appGroupID = "group.com.mtbsteve.seapi"

    static let baseURL = URL(string: "https://monitoringapi.solaredge.com")!

    /// Foreground auto-refresh cadence. With 3 endpoints per refresh
    /// (overview + powerDetails + storageData) this is 96 × 3 = 288 calls/day,
    /// just under SolarEdge's 300/day quota.
    static let refreshInterval: TimeInterval = 15 * 60

    static let demoToken = "demo"
}

// MARK: - API response shapes (Decodable)

/// /sites/list nests responses as `{ "sites": { "count": …, "list": [Site] } }`.
/// The top-level key is sometimes capitalized "Sites" in older responses; we
/// handle both via a custom decoder.
struct SitesEnvelope: Decodable {
    let count: Int
    let list: [Site]

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        let key = root.allKeys.first { $0.stringValue.lowercased() == "sites" }
            ?? AnyKey(stringValue: "sites")!
        let inner = try root.nestedContainer(keyedBy: AnyKey.self, forKey: key)
        self.count = (try? inner.decode(Int.self, forKey: AnyKey(stringValue: "count")!)) ?? 0
        // The docs example uses "list" but the live API returns "site" (singular).
        // Accept either, plus decode each element through OptionalSite so a
        // malformed entry can't drop the whole array.
        let listKey = inner.allKeys.first { ["list", "site"].contains($0.stringValue.lowercased()) }
            ?? AnyKey(stringValue: "site")!
        let optionals = (try? inner.decode([OptionalSite].self, forKey: listKey)) ?? []
        self.list = optionals.compactMap(\.site)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct Site: Decodable, Identifiable {
    let id: Int
    let name: String
    let peakPower: Double?
    let currency: String?
    let status: String?

    /// Lenient decoder: only `id` is required. Anything missing or the wrong
    /// type defaults to nil/empty so one weird site in /sites/list can't blank
    /// the whole array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Site \(self.id)"
        self.peakPower = try? c.decode(Double.self, forKey: .peakPower)
        self.currency = try? c.decode(String.self, forKey: .currency)
        self.status = try? c.decode(String.self, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, peakPower, currency, status
    }
}

/// Wrapper that decodes a Site but swallows per-element errors. Used when
/// decoding the /sites/list array so a single malformed entry doesn't drop
/// every site in the response.
struct OptionalSite: Decodable {
    let site: Site?
    init(from decoder: Decoder) throws {
        self.site = try? Site(from: decoder)
    }
}

struct OverviewEnvelope: Decodable {
    let overview: SiteOverview
}

struct SiteOverview: Decodable, Equatable {
    let lastUpdateTime: String?
    let lifeTimeData: EnergyRevenue
    let lastYearData: EnergyRevenue
    let lastMonthData: EnergyRevenue
    let lastDayData: EnergyRevenue
    let currentPower: CurrentPower

    struct EnergyRevenue: Decodable, Equatable {
        let energy: Double
        let revenue: Double?
    }
    struct CurrentPower: Decodable, Equatable {
        let power: Double
    }
}

struct PowerDetailsEnvelope: Decodable {
    let powerDetails: PowerDetails
}

struct PowerDetails: Decodable {
    let timeUnit: String
    let unit: String
    let meters: [Meter]

    struct Meter: Decodable {
        let type: String
        let values: [PowerPoint]
    }
    struct PowerPoint: Decodable {
        let date: String
        let value: Double?
    }
}

struct StorageDataEnvelope: Decodable {
    let storageData: StorageData
}

struct StorageData: Decodable {
    let batteryCount: Int
    let batteries: [Battery]

    struct Battery: Decodable {
        let serialNumber: String?
        let nameplate: Double?
        let modelNumber: String?
        let telemetryCount: Int?
        let telemetries: [Telemetry]
    }
    struct Telemetry: Decodable {
        let timeStamp: String
        let stateOfCharge: Double?
        let power: Double?
        let batteryState: Int?
        let internalTemp: Double?

        /// SolarEdge docs say the SoC field is `stateOfCharge`, but the live API
        /// for SolarEdge Home Battery sites returns `batteryPercentageState`.
        /// Accept either, preferring the documented name if both somehow appear.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.timeStamp = try c.decode(String.self, forKey: .timeStamp)
            self.stateOfCharge = (try? c.decode(Double.self, forKey: .stateOfCharge))
                ?? (try? c.decode(Double.self, forKey: .batteryPercentageState))
            self.power = try? c.decode(Double.self, forKey: .power)
            self.batteryState = try? c.decode(Int.self, forKey: .batteryState)
            self.internalTemp = try? c.decode(Double.self, forKey: .internalTemp)
        }

        private enum CodingKeys: String, CodingKey {
            case timeStamp, stateOfCharge, batteryPercentageState
            case power, batteryState, internalTemp
        }
    }
}

// MARK: - App-level snapshots (Codable for shared-defaults cache)

/// Instantaneous values used by the header card and complication.
struct Snapshot: Codable, Equatable {
    var siteId: Int
    var siteName: String
    var currency: String
    /// Current PV / production power in kW.
    var currentPowerKW: Double?
    /// Today's PV production in kWh (AC inverter output + net battery delta).
    var todayEnergyKWh: Double?
    /// Today's energy exported to grid in kWh, integrated from /powerDetails.FeedIn.
    var todayExportedKWh: Double?
    /// Lifetime energy in kWh (kept for cached-data compatibility; not shown).
    var lifetimeEnergyKWh: Double?
    /// Per-battery state-of-charge percentages (0…100) at the most recent telemetry.
    var batterySoC: [Double]
    var fetchedAt: Date

    static let empty = Snapshot(
        siteId: 0,
        siteName: "—",
        currency: "EUR",
        currentPowerKW: nil,
        todayEnergyKWh: nil,
        todayExportedKWh: nil,
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
    /// Production (PV) in kW.
    var solar: [Point]
    /// Consumption in kW.
    var consumption: [Point]
    /// Net grid in kW. Positive = importing from grid (Purchased),
    /// negative = exporting to grid (FeedIn).
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

// MARK: - SolarEdge date parsing

enum SolarEdgeDate {
    /// SolarEdge timestamps are "YYYY-MM-DD HH:mm:ss" in the site's time zone.
    /// Without a tz suffix, we interpret them as local time on the device.
    /// For a homeowner watching their own site this is correct in practice.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parse(_ s: String) -> Date? { formatter.date(from: s) }
    static func format(_ d: Date) -> String { formatter.string(from: d) }
}

// MARK: - Errors

enum SolarEdgeError: LocalizedError {
    case http(Int)
    case decoding(String)
    case noSites
    case network(String)
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .http(let code):
            switch code {
            case 401, 403: return "Invalid API key (HTTP \(code))"
            case 429: return "Rate limit hit (HTTP 429). Try again later."
            default: return "HTTP \(code) error"
            }
        case .decoding(let msg): return "Decode error: \(msg)"
        case .noSites: return "No sites found for this account."
        case .network(let msg): return "Network error: \(msg)"
        case .invalidConfig: return "Missing API key or site."
        }
    }
}
