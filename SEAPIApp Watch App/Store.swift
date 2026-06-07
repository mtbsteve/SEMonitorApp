import SwiftUI
import Combine
import WidgetKit

@MainActor
final class SEStore: ObservableObject {

    // MARK: - Persisted credentials / config
    //
    // Stored in the App Group's UserDefaults so the complication target
    // (a separate process) can also read the API key + site ID and fetch
    // its own timeline data when the watch app isn't running.
    private static let groupStore = UserDefaults(suiteName: AppConfig.appGroupID)

    @AppStorage("seapi_api_key", store: SEStore.groupStore) var apiKey: String = ""
    @AppStorage("seapi_last_key", store: SEStore.groupStore) var lastEnteredKey: String = ""
    @AppStorage("seapi_site_id", store: SEStore.groupStore) var siteId: Int = 0
    @AppStorage("seapi_site_name", store: SEStore.groupStore) var siteName: String = ""
    @AppStorage("seapi_currency", store: SEStore.groupStore) var currency: String = "EUR"

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

            // All values read directly from SolarEdge's own aggregation — the
            // same sources the Home Assistant integration uses, which match
            // the portal. No battery reconstruction:
            //   • energyDetails (15-min) → 24h chart series + today's totals
            //   • currentPowerFlow       → live PV / grid / load / battery SoC
            //   • storageData            → 24h per-battery SoC for the chart
            // Daily totals from timeUnit=DAY (authoritative, matches portal).
            // Chart series from timeUnit=QUARTER (15-min shape). NOW from
            // currentPowerFlow. Battery SoC from storageData.
            async let energyDay = SolarEdgeAPI.fetchEnergyToday(siteId: siteId, apiKey: apiKey)
            async let energyHist = SolarEdgeAPI.fetchEnergyHistory(siteId: siteId, apiKey: apiKey)
            async let flow = SolarEdgeAPI.fetchPowerFlow(siteId: siteId, apiKey: apiKey)
            async let battery = SolarEdgeAPI.fetchBatteryHistory(siteId: siteId, apiKey: apiKey)
            let (day, e, f, b) = try await (energyDay, energyHist, flow, battery)

            // energyDetails "Production"/"Consumption" are AC-side: on this
            // DC-coupled battery site Production includes battery discharge and
            // misses PV that charged the battery, so it does NOT equal the
            // portal's panel-side figure. Reconstruct via energy balance:
            //   Production  = AC_Production + (charge − discharge) − grid_charge
            //   Consumption = AC_Production + Purchased − FeedIn − grid_charge
            // Both are exact when no grid charging occurred; on grid-charge
            // nights they carry a bounded residual (Battery 2 never reports
            // ACGridCharging). Exported (FeedIn) is grid-metered and exact.
            let acProd = day["Production"] ?? 0
            let purchased = day["Purchased"] ?? 0
            let exported = day["FeedIn"] ?? 0
            let gridCharge = b.todayGridChargeKWh
            let netBattery = b.todayChargeKWh - b.todayDischargeKWh

            let production = max(0, acProd + netBattery - gridCharge)
            let consumption = max(0, acProd + purchased - exported - gridCharge)

            // Current PV power straight from the power-flow PV node — panel-side,
            // inherently excludes grid charging, reads 0 at night.
            let currentPower = f.pvKW ?? 0

            let snap = Snapshot(
                siteId: siteId,
                siteName: siteName.isEmpty ? "Site \(siteId)" : siteName,
                currency: currency,
                currentPowerKW: max(0, currentPower),
                todayEnergyKWh: production,
                todayExportedKWh: exported > 0 ? exported : nil,
                todayConsumptionKWh: consumption > 0 ? consumption : nil,
                lifetimeEnergyKWh: nil,
                batterySoC: b.latestSoC,
                fetchedAt: Date()
            )
            #if DEBUG
            print(String(format: "☀️ Production=%.2f, Consumption=%.2f, Exported=%.2f kWh | NOW PV=%.2f kW",
                         production, consumption, exported, max(0, currentPower)))
            #endif

            self.snapshot = snap
            self.history = HistorySeries(
                solar: e.solar,
                consumption: e.consumption,
                grid: e.grid,
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
    /// Also stamps `last_api_fetch` so the complication's TimelineProvider knows
    /// the cache is fresh and skips its own (quota-consuming) fetch.
    func saveComplicationData() {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else { return }
        d.set(snapshot.currentPowerKW ?? 0, forKey: "complication_power")
        d.set(snapshot.batterySoC, forKey: "complication_soc")
        d.set(snapshot.currency, forKey: "complication_currency")
        d.set(Date(), forKey: "complication_updated")
        d.set(Date(), forKey: "last_api_fetch")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
