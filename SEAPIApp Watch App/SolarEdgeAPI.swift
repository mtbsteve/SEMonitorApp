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

    /// Diagnostic only — fetch and log the equipment list. Not used by the UI;
    /// the response is only useful via the 🌐 console log during debugging.
    @discardableResult
    static func debugFetchEquipment(siteId: Int, apiKey: String) async throws -> Data {
        let url = build(path: "/equipment/\(siteId)/list", apiKey: apiKey)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        #if DEBUG
        if let s = String(data: data, encoding: .utf8) {
            print("🌐 /equipment/\(siteId)/list → \(s.prefix(5000))")
        }
        #endif
        return data
    }

    static func fetchOverview(siteId: Int, apiKey: String) async throws -> SiteOverview {
        let url = build(path: "/site/\(siteId)/overview", apiKey: apiKey)
        let env: OverviewEnvelope = try await get(url)
        return env.overview
    }

    /// 15-min resolution detailed power for the last 24h.
    /// Returns (solar kW, consumption kW, net grid kW, feedIn kW). Net grid is
    /// `Purchased - FeedIn` so positive = import, negative = export. `feedIn`
    /// is positive when exporting to grid.
    static func fetchPowerHistory(siteId: Int, apiKey: String, now: Date = Date()) async throws
        -> (solar: [HistorySeries.Point], consumption: [HistorySeries.Point],
            grid: [HistorySeries.Point], feedIn: [HistorySeries.Point])
    {
        let start = now.addingTimeInterval(-24 * 3600)
        let url = build(path: "/site/\(siteId)/powerDetails", apiKey: apiKey, query: [
            URLQueryItem(name: "startTime", value: SolarEdgeDate.format(start)),
            URLQueryItem(name: "endTime", value: SolarEdgeDate.format(now)),
        ])
        let env: PowerDetailsEnvelope = try await get(url)

        // SolarEdge reports power in W. Convert to kW for charts.
        func points(_ meter: PowerDetails.Meter?) -> [HistorySeries.Point] {
            (meter?.values ?? []).compactMap { p in
                guard let v = p.value, let t = SolarEdgeDate.parse(p.date) else { return nil }
                return HistorySeries.Point(t: t, v: v / 1000.0)
            }
        }

        var byType: [String: PowerDetails.Meter] = [:]
        for m in env.powerDetails.meters { byType[m.type] = m }

        let production = points(byType["Production"])
        let consumption = points(byType["Consumption"])
        let purchased = points(byType["Purchased"])
        let feedIn = points(byType["FeedIn"])

        #if DEBUG
        // Diagnostic: meter types present and today's integrated kWh per meter.
        // Helps diagnose which meters are missing or under-reporting.
        let todayStart = Calendar.current.startOfDay(for: now)
        func todayKWh(_ pts: [HistorySeries.Point]) -> Double {
            pts.filter { $0.t >= todayStart }.reduce(0.0) { $0 + $1.v * 0.25 }
        }
        let summary = env.powerDetails.meters.map { m -> String in
            let pts = points(m)
            return "\(m.type)=\(String(format: "%.2f", todayKWh(pts)))kWh(\(pts.count)pts)"
        }.joined(separator: " ")
        print("📊 powerDetails meters: \(summary)")
        #endif

        // Net grid = purchased - feedIn (positive = import, negative = export).
        // Both series share the same 15-min grid, but be defensive and align by t.
        var feedInMap: [Date: Double] = [:]
        for p in feedIn { feedInMap[p.t] = p.v }
        var net: [HistorySeries.Point] = []
        net.reserveCapacity(max(purchased.count, feedIn.count))
        let allDates = Set(purchased.map(\.t)).union(feedInMap.keys)
        let purchasedMap = Dictionary(uniqueKeysWithValues: purchased.map { ($0.t, $0.v) })
        for t in allDates.sorted() {
            let p = purchasedMap[t] ?? 0
            let f = feedInMap[t] ?? 0
            net.append(HistorySeries.Point(t: t, v: p - f))
        }

        return (production, consumption, net, feedIn)
    }

    /// Per-battery SoC telemetry for the last 24h, plus today's NET battery
    /// energy delta in kWh (positive = batteries gained energy on net,
    /// negative = batteries net-discharged).
    ///
    /// Energy balance for DC-coupled SolarEdge Home Batteries:
    ///     PV_total = AC_Production + (charge_DC − discharge_DC_via_AC)
    /// Charge bypasses the AC bus (DC→DC) and is missing from
    /// `/powerDetails.Production`, while discharge passes through the inverter
    /// and IS already counted there. So the right correction to add to
    /// AC Production to recover "panel-side" PV is the NET delta, not the
    /// gross charge.
    static func fetchBatteryHistory(siteId: Int, apiKey: String, now: Date = Date()) async throws
        -> (series: [[HistorySeries.Point]], latestSoC: [Double], todayNetChargeKWh: Double,
            combinedPowerKW: [HistorySeries.Point])
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
            // Telemetries are sampled every 5 min (= 1/12 hour) per the SE spec.
            let sampleHours = 1.0 / 12.0
            let todayStart = Calendar.current.startOfDay(for: now)
            var chargeWh: Double = 0
            var dischargeWh: Double = 0
            // Combined signed power across all batteries, keyed by sample timestamp.
            // Positive = batteries charging on net (PV → battery, DC), negative =
            // batteries discharging on net (battery → inverter → AC).
            var combinedByT: [Date: Double] = [:]
            for batt in env.storageData.batteries {
                let pts: [HistorySeries.Point] = batt.telemetries.compactMap { tel in
                    guard let soc = tel.stateOfCharge, let t = SolarEdgeDate.parse(tel.timeStamp)
                    else { return nil }
                    return HistorySeries.Point(t: t, v: soc)
                }
                series.append(pts)
                if let last = pts.last { latest.append(last.v) }
                for tel in batt.telemetries {
                    guard let t = SolarEdgeDate.parse(tel.timeStamp), let p = tel.power
                    else { continue }
                    combinedByT[t, default: 0] += p / 1000.0    // W → kW
                    if t >= todayStart {
                        if p > 0 { chargeWh += p * sampleHours }
                        else if p < 0 { dischargeWh += -p * sampleHours }
                    }
                }
            }
            let combinedPowerKW = combinedByT
                .sorted { $0.key < $1.key }
                .map { HistorySeries.Point(t: $0.key, v: $0.value) }
            let netKWh = (chargeWh - dischargeWh) / 1000.0
            #if DEBUG
            print(String(format: "🔋 today batteries: charged %.2f kWh, discharged %.2f kWh, net %+.2f kWh (n=%d)",
                         chargeWh / 1000, dischargeWh / 1000, netKWh, env.storageData.batteryCount))
            #endif
            return (series, latest, netKWh, combinedPowerKW)
        } catch SolarEdgeError.http(let code) where code == 400 || code == 404 {
            return ([], [], 0, [])
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
        #if DEBUG
        if let s = String(data: data, encoding: .utf8) {
            print("🌐 \(url.path) → \(s.prefix(20000))")
        }
        #endif
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SolarEdgeError.decoding(String(describing: error))
        }
    }
}
