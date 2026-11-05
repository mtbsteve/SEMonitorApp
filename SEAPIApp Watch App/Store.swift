import SwiftUI
import Combine
import WidgetKit

@MainActor
final class SEStore: ObservableObject {

    // MARK: - Persisted state
    //
    // V2 has no user-enterable credential: the site is reached with an OAuth
    // bearer token minted by a browser consent flow, so credentials are baked
    // in at build time (`SEConfig` / Secrets.xcconfig) rather than typed on
    // the watch. All that persists here is demo mode and cosmetic labels.
    private static let groupStore = UserDefaults(suiteName: AppConfig.appGroupID)

    @AppStorage("seapi_demo_mode", store: SEStore.groupStore) var demoMode: Bool = false
    @AppStorage("seapi_site_name", store: SEStore.groupStore) var siteName: String = ""
    @AppStorage("seapi_currency", store: SEStore.groupStore) var currency: String = "EUR"

    // MARK: - Published state

    @Published var snapshot: Snapshot = .empty
    @Published var history: HistorySeries = .empty
    @Published var error: String?
    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date?

    var siteId: Int { SEConfig.siteID }
    var hasConfig: Bool { demoMode || SEConfig.isConfigured }
    var isDemo: Bool { demoMode }

    /// Calls left in today's self-imposed budget — surfaced in the UI so a
    /// stale reading is explainable rather than mysterious.
    var creditsRemainingToday: Int { CreditBudget.remainingToday }

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
        if demoMode {
            applyDemo()
            return
        }

        guard SEConfig.isConfigured else {
            error = SolarEdgeError.notConfigured.localizedDescription
            return
        }

        // Ration ourselves. SolarEdge's Free tier blocks every call for the
        // rest of the billing cycle once the monthly allowance is gone, and
        // there is no overage to buy — so refusing a refresh here is strictly
        // better than risking a multi-day blackout. Cached data stays visible.
        guard CreditBudget.canAfford() else {
            error = SolarEdgeError.budgetExhausted.localizedDescription
            return
        }

        isLoading = true; defer { isLoading = false }
        error = nil

        let id = SEConfig.siteID

        do {
            // Four endpoints, 1 credit each, issued concurrently. If the
            // access token has expired, all four land on
            // SETokenStore.accessToken() at once — the actor's single-flight
            // coalescing is what stops them racing to refresh and mutually
            // invalidating the rotating refresh token.
            async let totalsTask  = SolarEdgeAPI.fetchTodayTotals(siteId: id)
            async let powerTask   = SolarEdgeAPI.fetchPowerSeries(siteId: id)
            async let metersTask  = SolarEdgeAPI.fetchMeterSeries(siteId: id)
            async let batteryTask = SolarEdgeAPI.fetchBatterySoC(siteId: id)

            let (totals, power, meters, battery) =
                try await (totalsTask, powerTask, metersTask, batteryTask)

            // Today's figures come straight from the site overview, which is
            // already panel-side and already excludes grid-sourced battery
            // charging. No reconstruction, no clamping, no efficiency factor —
            // verified equal to the portal (6.94 kWh / 43.3 kWh on 2026-11-03).
            self.snapshot = Snapshot(
                siteId: id,
                siteName: siteName.isEmpty ? "Site \(id)" : siteName,
                currency: currency,
                currentPowerKW: max(0, power.last?.v ?? 0),
                todayEnergyKWh: totals.productionKWh,
                todayExportedKWh: totals.exportedKWh > 0 ? totals.exportedKWh : nil,
                todayConsumptionKWh: totals.consumptionKWh > 0 ? totals.consumptionKWh : nil,
                lifetimeEnergyKWh: nil,
                batterySoC: battery.latestSoC,
                fetchedAt: Date()
            )

            // The Solar line is the raw /power series: it is panel-side, so
            // unlike V1 it needs no per-slot battery correction.
            self.history = HistorySeries(
                solar: power,
                consumption: meters.consumption,
                grid: meters.netGrid,
                batteries: battery.series
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
        siteName = demo.snapshot.siteName
        currency = demo.snapshot.currency
        error = nil
        cache()
        saveComplicationData()
    }

    /// Leave demo mode / clear cached data. Build-time credentials are not
    /// affected — they live in the binary, not in storage.
    func clearConfig() {
        refreshTask?.cancel()
        demoMode = false
        snapshot = .empty
        history = .empty
        error = nil
        lastUpdated = nil
        if let d = UserDefaults(suiteName: AppConfig.appGroupID) {
            for k in ["snapshot", "history", "complication_power", "complication_soc",
                      "complication_currency", "complication_updated", "last_api_fetch"] {
                d.removeObject(forKey: k)
            }
        }
        Task { await SETokenStore.shared.clear() }
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

    /// Write the compact values the complication renders, then reload
    /// timelines. The complication never calls the API itself — see
    /// `SEAPIComplication.swift` — so this is its only data source.
    func saveComplicationData() {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else { return }
        d.set(snapshot.currentPowerKW ?? 0, forKey: "complication_power")
        d.set(snapshot.batterySoC, forKey: "complication_soc")
        d.set(snapshot.currency, forKey: "complication_currency")
        d.set(Date(), forKey: "complication_updated")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
