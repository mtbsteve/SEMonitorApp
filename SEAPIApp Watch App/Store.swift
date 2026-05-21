import SwiftUI
import Combine
import WidgetKit

@MainActor
final class SEStore: ObservableObject {

    // MARK: - Persisted credentials / config

    @AppStorage("seapi_api_key") var apiKey: String = ""
    @AppStorage("seapi_last_key") var lastEnteredKey: String = ""
    @AppStorage("seapi_site_id") var siteId: Int = 0
    @AppStorage("seapi_site_name") var siteName: String = ""
    @AppStorage("seapi_currency") var currency: String = "EUR"

    // MARK: - Published state

    @Published var snapshot: Snapshot = .empty
    @Published var history: HistorySeries = .empty
    @Published var error: String?
    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date?

    var hasConfig: Bool { !apiKey.isEmpty }
    var isDemo: Bool { apiKey == AppConfig.demoToken }

    // MARK: - Lifecycle

    private var refreshTask: Task<Void, Never>?

    init() {
        loadCached()
        if hasConfig {
            Task { await refresh() }
        }
    }

    deinit { refreshTask?.cancel() }

    // MARK: - Refresh

    func refresh() async {
        guard hasConfig else {
            error = "Enter an API key to begin."
            return
        }

        if isDemo {
            applyDemo()
            return
        }

        isLoading = true; defer { isLoading = false }
        error = nil

        do {
            // Discover site once. Cached siteId is reused thereafter; users with
            // a Site-level key (no list permission) won't get here unless they
            // happen to also have list permission, but the demo path covers
            // them and we surface a clear error otherwise.
            if siteId == 0 {
                let sites = try await SolarEdgeAPI.fetchSites(apiKey: apiKey)
                guard let first = sites.first else { throw SolarEdgeError.noSites }
                siteId = first.id
                siteName = first.name
                if let c = first.currency, !c.isEmpty { currency = c }
            }

            async let overview = SolarEdgeAPI.fetchOverview(siteId: siteId, apiKey: apiKey)
            async let power = SolarEdgeAPI.fetchPowerHistory(siteId: siteId, apiKey: apiKey)
            async let battery = SolarEdgeAPI.fetchBatteryHistory(siteId: siteId, apiKey: apiKey)

            let (ov, p, b) = try await (overview, power, battery)

            // The Overview endpoint's lastDayData lags the portal by 5–20 min.
            // /powerDetails comes from inverter telemetry that's much fresher,
            // so integrate today's Production samples client-side. Then adjust
            // by the NET battery delta from /storageData to recover panel-side
            // PV total: for DC-coupled SE Home Batteries, the DC charge half
            // of any battery cycling bypasses the AC bus and is missing from
            // Production, while the discharge half passes through the inverter
            // and is already counted. Net delta (charge − discharge) is the
            // exact correction.
            let todayStart = Calendar.current.startOfDay(for: Date())
            let todayProductionAC = p.solar.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }
            let baseProduction = todayProductionAC > 0
                ? todayProductionAC
                : ov.lastDayData.energy / 1000.0
            let todayProduction = baseProduction + b.todayNetChargeKWh

            // Today's grid export, integrated from /powerDetails.FeedIn.
            // We show this instead of "Consumption" because the SE API's
            // Consumption meter genuinely under-reports on DC-coupled battery
            // sites (no formula derivable from the available API meters can
            // reproduce the portal's Consumption value), while FeedIn is
            // exact and useful.
            let todayExported = p.feedIn.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }

            // Solar chart: show panel-side PV. /powerDetails.Production reports
            // AC inverter output only, which both (a) misses DC PV that charged
            // the batteries and (b) wrongly includes battery → AC discharge as
            // if it were PV. Per 15-min slot, adding the signed combined
            // battery power corrects both: charging adds back the DC bypass;
            // discharging subtracts the battery's AC contribution so night-
            // time battery output doesn't masquerade as solar.
            //
            // Multi-battery sites report at *staggered* timestamps — batt1 at
            // 00:03, batt2 at 00:00, etc. — so each dictionary entry in
            // combinedPowerKW typically holds just one battery's power, not
            // the summed combined power. To recover correct combined power
            // for the slot, treat each sample as 5-min-worth of energy and
            // convert to average kW over the slot's 15 min: sum × 5/60 ÷ 0.25
            // = sum / 3. With 2 batteries × 3 samples each in 15 min that
            // gives 6×p/3 = 2p, doubling correctly to combined power.
            let sampleHours = 1.0 / 12.0
            let slotHours = 0.25
            let correctedSolar: [HistorySeries.Point] = p.solar.map { sample in
                let slotEnd = sample.t.addingTimeInterval(15 * 60)
                let inSlot = b.combinedPowerKW.filter { $0.t >= sample.t && $0.t < slotEnd }
                let sumKW = inSlot.map(\.v).reduce(0, +)
                let avgCombinedKW = sumKW * sampleHours / slotHours
                return HistorySeries.Point(t: sample.t, v: sample.v + avgCombinedKW)
            }

            // /overview.currentPower is a server-side aggregate that refreshes
            // every 15–20 min and frequently reads 0 even when the inverter
            // is producing. Fall back to the most recent corrected-solar
            // sample (≤15 min stale) so the "NOW" card never shows 0 just
            // because the aggregate is behind.
            let currentFromOverview = ov.currentPower.power / 1000.0
            let currentFromHistory = correctedSolar.last?.v ?? 0
            let currentPower = max(currentFromOverview, currentFromHistory)

            // Build snapshot
            let snap = Snapshot(
                siteId: siteId,
                siteName: siteName.isEmpty ? "Site \(siteId)" : siteName,
                currency: currency,
                currentPowerKW: currentPower,
                todayEnergyKWh: todayProduction,
                todayExportedKWh: todayExported > 0 ? todayExported : nil,
                lifetimeEnergyKWh: ov.lifeTimeData.energy / 1000.0,
                batterySoC: b.latestSoC,
                fetchedAt: Date()
            )
            #if DEBUG
            let acToday = p.solar.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }
            let correctedToday = correctedSolar.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }
            print(String(format: "☀️ today solar chart: AC=%.2f kWh, corrected=%.2f kWh (diff %+.2f), expected=%.2f kWh",
                         acToday, correctedToday, correctedToday - acToday, todayProduction))
            #endif

            self.snapshot = snap
            self.history = HistorySeries(
                solar: correctedSolar,
                consumption: p.consumption,
                grid: p.grid,
                batteries: b.series
            )
            self.lastUpdated = Date()
            cache()
            saveComplicationData()
            startAutoRefresh()
        } catch {
            self.error = error.localizedDescription
            refreshTask?.cancel()
        }
    }

    private func applyDemo() {
        let demo = DemoData.generate()
        snapshot = demo.snapshot
        history = demo.history
        lastUpdated = Date()
        siteId = demo.snapshot.siteId
        siteName = demo.snapshot.siteName
        currency = demo.snapshot.currency
        cache()
        saveComplicationData()
    }

    func clearConfig() {
        refreshTask?.cancel()
        apiKey = ""
        siteId = 0
        siteName = ""
        snapshot = .empty
        history = .empty
        error = nil
        lastUpdated = nil
        // Wipe shared cache so the complication doesn't keep showing stale data.
        if let d = UserDefaults(suiteName: AppConfig.appGroupID) {
            for k in ["snapshot", "history", "complication_power", "complication_soc",
                      "complication_currency", "complication_updated"] {
                d.removeObject(forKey: k)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppConfig.refreshInterval) * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Shared cache (App Group)

    private func cache() {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else { return }
        if let s = try? JSONEncoder().encode(snapshot) { d.set(s, forKey: "snapshot") }
        if let h = try? JSONEncoder().encode(history) { d.set(h, forKey: "history") }
    }

    private func loadCached() {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else { return }
        if let s = d.data(forKey: "snapshot"),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: s) {
            self.snapshot = snap
            self.lastUpdated = snap.fetchedAt
        }
        if let h = d.data(forKey: "history"),
           let hist = try? JSONDecoder().decode(HistorySeries.self, from: h) {
            self.history = hist
        }
    }

    /// Write a compact set of values for the complication, plus reload timelines.
    func saveComplicationData() {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else { return }
        d.set(snapshot.currentPowerKW ?? 0, forKey: "complication_power")
        d.set(snapshot.batterySoC, forKey: "complication_soc")
        d.set(snapshot.currency, forKey: "complication_currency")
        d.set(Date(), forKey: "complication_updated")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
