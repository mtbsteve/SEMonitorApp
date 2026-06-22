import Foundation

/// Thin async/await client for the SolarEdge Monitoring API.
///
/// All endpoints take the API key as the `api_key` query parameter, per the
/// API spec. The key is appended to every URL — never sent as a header.
enum SolarEdgeAPI {

    // MARK: - Top-level fetches

    static func fetchSites(apiKey: String) async throws -> [Site] {
        let url = build(path: "/sites/list", apiKey: apiKey, query: [
            URLQueryItem(name: "size", value: "5"),
            URLQueryItem(name: "sortProperty", value: "Name"),
        ])
        let env: SitesEnvelope = try await get(url)
        return env.list
    }

    /// Today's energy totals per meter (kWh), via energyDetails with
    /// timeUnit=DAY (midnight→now) — the SolarEdge-authoritative daily figure
    /// that matches the portal. This is a DIFFERENT pipeline from the QUARTER
    /// series: DAY excludes overnight battery-discharge that the raw 15-min
    /// Production meter includes, so totals MUST come from DAY, not from
    /// summing QUARTER slots. Keys: "Production", "Consumption", "FeedIn",
    /// "Purchased", "SelfConsumption".
    static func fetchEnergyToday(siteId: Int, apiKey: String, now: Date = Date()) async throws -> [String: Double] {
        let midnight = Calendar.current.startOfDay(for: now)
        let url = build(path: "/site/\(siteId)/energyDetails", apiKey: apiKey, query: [
            URLQueryItem(name: "timeUnit", value: "DAY"),
            URLQueryItem(name: "startTime", value: SolarEdgeDate.format(midnight)),
            URLQueryItem(name: "endTime", value: SolarEdgeDate.format(now)),
        ])
        let env: EnergyDetailsEnvelope = try await get(url)
        var out: [String: Double] = [:]
        for m in env.energyDetails.meters {
            out[m.type] = m.values.compactMap { $0.value }.reduce(0, +) / 1000.0
        }
        return out
    }

    /// Current power flow — gives panel-side PV power directly (PV.currentPower
    /// in W), which inherently excludes grid charging. Also returns storage
    /// charge level (%). Same source HA uses for its solar_power sensor.
    static func fetchPowerFlow(siteId: Int, apiKey: String) async throws
        -> (pvKW: Double?, storageSoC: Double?, gridKW: Double?, loadKW: Double?)
    {
        let url = build(path: "/site/\(siteId)/currentPowerFlow", apiKey: apiKey)
        let env: PowerFlowEnvelope = try await get(url)
        let f = env.siteCurrentPowerFlow
        // currentPowerFlow reports in kW already (unit "kW") for this endpoint.
        return (f.PV?.currentPower, f.STORAGE?.chargeLevel, f.GRID?.currentPower, f.LOAD?.currentPower)
    }

    /// 24h energy history + today's totals, from energyDetails at 15-min
    /// (QUARTER_OF_AN_HOUR) resolution — the SolarEdge-authoritative figures
    /// the Home Assistant integration reads, which match the portal. This
    /// replaces the old powerDetails + battery-reconstruction approach.
    ///
    /// 24h power series for the chart, from powerDetails (15-min, in W → kW).
    /// Returns (solar AC, consumption, net grid) where net grid = Purchased −
    /// FeedIn (positive = importing). The chart's Solar line is corrected to
    /// panel-side in the Store by adding per-slot battery charge; the totals
    /// shown on the Overview come from energyDetails DAY (HA method), not here.
    static func fetchPowerHistory(siteId: Int, apiKey: String, now: Date = Date()) async throws
        -> (solar: [HistorySeries.Point], consumption: [HistorySeries.Point], grid: [HistorySeries.Point])
    {
        let start = now.addingTimeInterval(-24 * 3600)
        let url = build(path: "/site/\(siteId)/powerDetails", apiKey: apiKey, query: [
            URLQueryItem(name: "startTime", value: SolarEdgeDate.format(start)),
            URLQueryItem(name: "endTime", value: SolarEdgeDate.format(now)),
        ])
        let env: PowerDetailsEnvelope = try await get(url)

        func points(_ meter: PowerDetails.Meter?) -> [HistorySeries.Point] {
            (meter?.values ?? []).compactMap { p in
                guard let v = p.value, let t = SolarEdgeDate.parse(p.date) else { return nil }
                return HistorySeries.Point(t: t, v: v / 1000.0)   // W → kW
            }
        }
        var byType: [String: PowerDetails.Meter] = [:]
        for m in env.powerDetails.meters { byType[m.type] = m }

        let production = points(byType["Production"])
        let consumption = points(byType["Consumption"])
        let purchased = points(byType["Purchased"])
        let feedIn = points(byType["FeedIn"])

        var feedInMap: [Date: Double] = [:]
        for p in feedIn { feedInMap[p.t] = p.v }
        let purchasedMap = Dictionary(uniqueKeysWithValues: purchased.map { ($0.t, $0.v) })
        let allDates = Set(purchased.map(\.t)).union(feedInMap.keys)
        let net: [HistorySeries.Point] = allDates.sorted().map { t in
            HistorySeries.Point(t: t, v: (purchasedMap[t] ?? 0) - (feedInMap[t] ?? 0))
        }

        return (production, consumption, net)
    }

    /// Per-battery State-of-Charge over the last 24h (chart + chips), plus the
    /// combined signed battery power per timestamp (kW; + = charging, − =
    /// discharging) used to correct the chart's Solar line to panel-side PV.
    static func fetchBatteryHistory(siteId: Int, apiKey: String, now: Date = Date()) async throws
        -> (series: [[HistorySeries.Point]], latestSoC: [Double], combinedPowerKW: [HistorySeries.Point],
            todayChargeKWh: Double, todayDischargeKWh: Double, todayGridChargeKWh: Double)
    {
        let start = now.addingTimeInterval(-24 * 3600)
        let url = build(path: "/site/\(siteId)/storageData", apiKey: apiKey, query: [
            URLQueryItem(name: "startTime", value: SolarEdgeDate.format(start)),
            URLQueryItem(name: "endTime", value: SolarEdgeDate.format(now)),
        ])
        do {
            let env: StorageDataEnvelope = try await get(url)
            var series: [[HistorySeries.Point]] = []
            var latest: [Double] = []
            var combinedByT: [Date: Double] = [:]
            let sampleHours = 1.0 / 12.0
            let todayStart = Calendar.current.startOfDay(for: now)
            var chargeWh = 0.0, dischargeWh = 0.0, gridWh = 0.0
            for batt in env.storageData.batteries {
                let pts: [HistorySeries.Point] = batt.telemetries.compactMap { tel in
                    guard let soc = tel.stateOfCharge, let t = SolarEdgeDate.parse(tel.timeStamp)
                    else { return nil }
                    return HistorySeries.Point(t: t, v: soc)
                }
                series.append(pts)
                if let last = pts.last { latest.append(last.v) }
                for tel in batt.telemetries {
                    guard let t = SolarEdgeDate.parse(tel.timeStamp), let p = tel.power else { continue }
                    combinedByT[t, default: 0] += p / 1000.0   // W → kW
                    if t >= todayStart {
                        if p > 0 { chargeWh += p * sampleHours } else if p < 0 { dischargeWh += -p * sampleHours }
                        gridWh += tel.acGridCharging ?? 0
                    }
                }
            }
            let combined = combinedByT.sorted { $0.key < $1.key }
                .map { HistorySeries.Point(t: $0.key, v: $0.value) }
            return (series, latest, combined, chargeWh / 1000, dischargeWh / 1000, gridWh * 0.9 / 1000)
        } catch SolarEdgeError.http(let code) where code == 400 || code == 404 {
            return ([], [], [], 0, 0, 0)
        }
    }

    // MARK: - Plumbing

    private static func build(path: String, apiKey: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: AppConfig.baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query + [URLQueryItem(name: "api_key", value: apiKey)]
        return comps.url!
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SEAPIApp/1.0 watchOS", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SolarEdgeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SolarEdgeError.network("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SolarEdgeError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SolarEdgeError.decoding(String(describing: error))
        }
    }
}
