import Foundation

/// Thin async/await client for the **SolarEdge Monitoring API v2**.
///
/// V1 was shut down on 2026-11-03. V2 differs in every respect that matters
/// here: plural paths under `/v2/`, a bearer token instead of an `api_key`
/// query parameter, ISO8601 `from`/`to` that require a timezone, and a flat
/// `{period, unit, resolution, values:[{timestamp, value}]}` envelope.
///
/// Timestamps are always sent as **UTC with a `Z` suffix**. A numeric offset
/// such as `+01:00` would have to be percent-encoded as `%2B01:00`, because a
/// literal `+` in a query string decodes to a space — a silent source of
/// HTTP 400s. `Z` sidesteps it entirely.
enum SolarEdgeAPI {

    // MARK: - Today's totals

    /// Today's energy totals, straight from the site overview.
    ///
    /// `production.total` is the **panel-side** figure: it includes
    /// `toStorage`, i.e. PV that charged the battery DC-side without ever
    /// reaching the AC bus, and it excludes energy the battery took from the
    /// grid (grid import is not a PV destination). That is what the SolarEdge
    /// portal shows, verified exactly against it for 2026-11-03:
    /// 6,942.34 Wh here vs 6.94 kWh in the portal.
    ///
    /// This replaces the V1-era energy-balance reconstruction
    /// (`AC_Production + charge − discharge − grid_charge`) entirely. Do not
    /// reintroduce it, and do not apply an efficiency correction factor.
    static func fetchTodayTotals(siteId: Int, now: Date = Date()) async throws
        -> (productionKWh: Double, consumptionKWh: Double, exportedKWh: Double, toStorageKWh: Double)
    {
        let midnight = Calendar.current.startOfDay(for: now)
        let env: OverviewEnvelope = try await get(
            "/sites/\(siteId)/overview",
            query: [("from", SEDate.format(midnight)), ("to", SEDate.format(now))]
        )
        // Wh -> kWh. Absent fields decode to nil and read as 0.
        return (
            productionKWh:  (env.production?.total ?? 0) / 1000,
            consumptionKWh: (env.consumption?.total ?? 0) / 1000,
            exportedKWh:    (env.production?.toGrid ?? 0) / 1000,
            toStorageKWh:   (env.production?.toStorage ?? 0) / 1000
        )
    }

    // MARK: - 24h PV power series

    /// 24h site production power at 15-minute resolution, in kW.
    ///
    /// Panel-side, like `production.total` — confirmed by integrating a full
    /// day and comparing: an AC-side series would fall *below* the day's
    /// panel-side energy by roughly `toStorage` (ratio ≈ 0.73 on 2026-11-03),
    /// whereas this reads slightly above it (≈1.10, rectangle-rule error on
    /// instantaneous samples). So the chart needs **no battery correction**,
    /// unlike the V1 implementation.
    ///
    /// Use for chart shape and the NOW reading only — never for daily totals,
    /// which come from `fetchTodayTotals`.
    static func fetchPowerSeries(siteId: Int, now: Date = Date()) async throws -> [HistorySeries.Point] {
        let start = now.addingTimeInterval(-24 * 3600)
        let env: SeriesEnvelope = try await get(
            "/sites/\(siteId)/power",
            query: [("from", SEDate.format(start)), ("to", SEDate.format(now)),
                    ("resolution", "QUARTER_HOUR")]
        )
        return env.values.points(scale: 1.0 / 1000.0)   // W -> kW
    }

    // MARK: - 24h meter series (consumption + grid)

    /// 24h consumption and net-grid power, in kW.
    ///
    /// `meters` is a **dictionary keyed by meter identity**, mixing physical
    /// serial numbers (e.g. `"1663429397"`) with virtual meters (e.g.
    /// `"CONSUMPTION"`). The serial differs per site, so we locate meters by
    /// which fields they carry rather than by key.
    ///
    /// Net grid is `importPower − exportPower` (positive = importing), summed
    /// across every meter that reports them.
    static func fetchMeterSeries(siteId: Int, now: Date = Date()) async throws
        -> (consumption: [HistorySeries.Point], netGrid: [HistorySeries.Point])
    {
        let start = now.addingTimeInterval(-24 * 3600)
        let env: MetersEnvelope = try await get(
            "/sites/\(siteId)/meters/telemetry",
            query: [("from", SEDate.format(start)), ("to", SEDate.format(now)),
                    ("resolution", "QUARTER_HOUR")]
        )

        var consumption: [HistorySeries.Point] = []
        var importByT: [Date: Double] = [:]
        var exportByT: [Date: Double] = [:]

        for (_, fields) in env.meters {
            if let c = fields["consumptionPower"] {
                // Multiple consumption meters would be unusual; sum defensively.
                for p in c.values.points(scale: 1.0 / 1000.0) {
                    if let i = consumption.firstIndex(where: { $0.t == p.t }) {
                        consumption[i] = .init(t: p.t, v: consumption[i].v + p.v)
                    } else {
                        consumption.append(p)
                    }
                }
            }
            for p in (fields["importPower"]?.values.points(scale: 1.0 / 1000.0) ?? []) {
                importByT[p.t, default: 0] += p.v
            }
            for p in (fields["exportPower"]?.values.points(scale: 1.0 / 1000.0) ?? []) {
                exportByT[p.t, default: 0] += p.v
            }
        }

        let stamps = Set(importByT.keys).union(exportByT.keys).sorted()
        let net = stamps.map {
            HistorySeries.Point(t: $0, v: (importByT[$0] ?? 0) - (exportByT[$0] ?? 0))
        }
        return (consumption.sorted { $0.t < $1.t }, net)
    }

    // MARK: - Battery state of charge

    /// Per-battery State-of-Charge over 24h, in percent, plus the latest
    /// reading per battery.
    ///
    /// `storage` is a dictionary keyed by battery serial number, so we sort
    /// the keys to keep chart colours and the SoC chips stable across
    /// refreshes.
    ///
    /// ⚠️ `stateOfEnergy` is declared with unit `PERCENTAGE` but the values
    /// are a **0…1 fraction** (verified: 0.18889 against `remainingEnergy`
    /// 1653.76 Wh implies an 8,756 Wh pack, and the series reaches exactly
    /// 1.0 when full). Hence the ×100.
    static func fetchBatterySoC(siteId: Int, now: Date = Date()) async throws
        -> (series: [[HistorySeries.Point]], latestSoC: [Double])
    {
        let start = now.addingTimeInterval(-24 * 3600)
        do {
            let env: StorageEnvelope = try await get(
                "/sites/\(siteId)/storage/telemetry",
                query: [("from", SEDate.format(start)), ("to", SEDate.format(now))]
            )
            var series: [[HistorySeries.Point]] = []
            var latest: [Double] = []
            for serial in env.storage.keys.sorted() {
                guard let soe = env.storage[serial]?["stateOfEnergy"] else { continue }
                let pts = soe.values.points(scale: 100)   // 0…1 fraction -> %
                guard !pts.isEmpty else { continue }
                series.append(pts)
                if let last = pts.last { latest.append(last.v) }
            }
            return (series, latest)
        } catch SolarEdgeError.http(let code) where code == 400 || code == 404 {
            // Sites without storage: treat as "no batteries", not an error.
            return ([], [])
        }
    }

    // MARK: - Plumbing

    private static func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        guard SEConfig.isConfigured else { throw SolarEdgeError.notConfigured }

        var comps = URLComponents(string: "https://monitoringapi.solaredge.com/v2" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { throw SolarEdgeError.invalidConfig }

        let token = try await SETokenStore.shared.accessToken()

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SolarEdgeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SolarEdgeError.network("Invalid response")
        }

        // Every V2 endpoint costs 1 credit, charged whether or not we like the
        // answer, so record the spend before inspecting the status code.
        CreditBudget.record(1)

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                // Two distinct 429s, told apart by this header: 0 means the
                // per-minute rate limit (retryable), >0 means the monthly
                // credit allowance is gone (not retryable until the cycle
                // resets, and Free has no overage).
                let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining-minute")
                if let r = remaining, Int(r) ?? 0 > 0 {
                    throw SolarEdgeError.creditLimit
                }
                throw SolarEdgeError.rateLimit
            }
            throw SolarEdgeError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SolarEdgeError.decoding(String(describing: error))
        }
    }
}

// MARK: - V2 wire types

/// A `{unit, values:[{timestamp, value}]}` block — V2's universal series shape.
struct SESeries: Decodable {
    let unit: String?
    let values: [SESample]
}

struct SESample: Decodable {
    let timestamp: String
    let value: Double?
}

extension Array where Element == SESample {
    /// Drop samples with a null value or an unparseable timestamp, convert
    /// units, and sort. V2 uses `null` for gaps rather than omitting the slot.
    func points(scale: Double) -> [HistorySeries.Point] {
        compactMap { s in
            guard let v = s.value, let t = SEDate.parse(s.timestamp) else { return nil }
            return HistorySeries.Point(t: t, v: v * scale)
        }
        .sorted { $0.t < $1.t }
    }
}

/// `/sites/{id}/overview`. One struct covers both sides: production carries
/// `to*` destinations, consumption carries `from*` sources, and the other
/// side's keys simply decode to nil.
struct OverviewEnvelope: Decodable {
    let siteId: Int?
    let production: Flow?
    let consumption: Flow?

    struct Flow: Decodable {
        let total: Double?
        let unit: String?
        // production
        let toSelfConsumption: Double?
        let toStorage: Double?
        let toGrid: Double?
        // consumption
        let fromPv: Double?
        let fromStorage: Double?
        let fromGrid: Double?
    }
}

/// `/sites/{id}/power` and `/sites/{id}/energy`.
struct SeriesEnvelope: Decodable {
    let unit: String?
    let resolution: String?
    let values: [SESample]
}

/// `/sites/{id}/meters/telemetry` — keyed by meter serial or virtual name.
struct MetersEnvelope: Decodable {
    let resolution: String?
    let meters: [String: [String: SESeries]]
}

/// `/sites/{id}/storage/telemetry` — keyed by battery serial number.
struct StorageEnvelope: Decodable {
    let resolution: String?
    let storage: [String: [String: SESeries]]
}

// MARK: - V2 date handling

enum SEDate {

    /// Outgoing `from`/`to`: UTC with a literal `Z`, never a `+hh:mm` offset.
    private static let requestFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    /// Incoming timestamps carry the site's offset, e.g.
    /// `2026-11-04T21:30:00+01:00`.
    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Same, for responses that include fractional seconds.
    private static let fractionalParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func format(_ d: Date) -> String { requestFormatter.string(from: d) }

    static func parse(_ s: String) -> Date? {
        parser.date(from: s) ?? fractionalParser.date(from: s)
    }
}
