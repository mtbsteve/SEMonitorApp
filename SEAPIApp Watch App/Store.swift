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

            async let overview = SolarEdgeAPI.fetchOverview(siteId: siteId, apiKey: apiKey)
            async let power = SolarEdgeAPI.fetchPowerHistory(siteId: siteId, apiKey: apiKey)
            async let battery = SolarEdgeAPI.fetchBatteryHistory(siteId: siteId, apiKey: apiKey)

            let (ov, p, b) = try await (overview, power, battery)

            let todayStart = Calendar.current.startOfDay(for: Date())

            // Panel-side PV correction. /powerDetails.Production is AC inverter
            // output only — it (a) misses DC PV that charged the batteries and
            // (b) wrongly includes battery→AC discharge as if it were PV. The
            // base correction is to add the signed battery power per slot:
            // charging adds back the DC bypass, discharging cancels the
            // battery's AC contribution.
            //
            // BUT when the battery charges *from the grid* (price-driven
            // top-ups), that charge is NOT solar and must not be added. The
            // SolarEdge `ACGridCharging` telemetry field is unreliable here
            // (on multi-battery sites only the first battery populates it), so
            // we detect grid charging from the reliable aggregate meters
            // instead: the site is importing exactly when net grid = Purchased
            // − FeedIn (= `p.grid`) is positive. The grid-sourced share of the
            // slot's battery charge is therefore:
            //     grid_charge = clamp(netGridImport, 0, batteryChargeDC)
            // and the panel-side PV for the slot is:
            //     PV = AC_Production + batterySigned − grid_charge
            // Examples:
            //   - night, both batteries grid-charging: AC≈0, batt=+2, import≈+2.2
            //         → grid_charge=2 → PV = 0+2−2 = 0  ✓ (no sun)
            //   - midday PV charge while exporting: import<0 → grid_charge=0
            //         → full PV credit  ✓
            //   - discharge slot: chargeDC=0 → grid_charge=0 → discharge still
            //         subtracted  ✓
            //
            // Battery samples (5-min, possibly staggered across batteries) are
            // aggregated into each 15-min Production slot: sum × (5/60) ÷ 0.25.
            let sampleHours = 1.0 / 12.0
            let slotHours = 0.25
            var gridByT: [Date: Double] = [:]
            for pt in p.grid { gridByT[pt.t] = pt.v }
            let correctedSolar: [HistorySeries.Point] = p.solar.map { sample in
                let slotEnd = sample.t.addingTimeInterval(15 * 60)
                let inSlot = b.combinedPowerKW.filter { $0.t >= sample.t && $0.t < slotEnd }
                let sumKW = inSlot.map(\.v).reduce(0, +)
                let batterySignedKW = sumKW * sampleHours / slotHours
                let chargeDC = max(0, batterySignedKW)
                let netImport = max(0, gridByT[sample.t] ?? 0)
                let gridChargeKW = min(chargeDC, netImport)
                let pv = sample.v + batterySignedKW - gridChargeKW
                return HistorySeries.Point(t: sample.t, v: max(0, pv))
            }

            // Production Today = integral of the corrected (panel-side) PV
            // since midnight. Ties the header number exactly to the Solar
            // chart. Fall back to the Overview aggregate only if powerDetails
            // returned nothing for today yet.
            let todayPV = correctedSolar.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }
            let todayProduction = todayPV > 0 ? todayPV : ov.lastDayData.energy / 1000.0

            // Today's grid export, integrated from /powerDetails.FeedIn.
            // Shown instead of "Consumption" because the SE API's Consumption
            // meter under-reports on DC-coupled battery sites, while FeedIn is
            // exact and useful.
            let todayExported = p.feedIn.filter { $0.t >= todayStart }
                .reduce(0.0) { $0 + $1.v * 0.25 }

            // Current panel-side PV: same correction applied to the latest
            // instant. /overview.currentPower is AC inverter output; add the
            // latest battery power, then subtract any grid-sourced charging
            // (latest net import clamped to the charge). At night with the
            // battery grid-charging this correctly reads 0 (no sun).
            let currentACkW = ov.currentPower.power / 1000.0
            let latestBatteryKW = b.combinedPowerKW.last?.v ?? 0
            let currentNetImport = max(0, p.grid.last?.v ?? 0)
            let currentGridChargeKW = min(max(0, latestBatteryKW), currentNetImport)
            let currentPower = max(0, currentACkW + latestBatteryKW - currentGridChargeKW)

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
            // Today's grid-sourced battery charge, computed the same way the
            // correction does (clamp of net import to battery charge per slot).
            let gridChargeToday: Double = p.solar.filter { $0.t >= todayStart }.reduce(0.0) { acc, sample in
                let slotEnd = sample.t.addingTimeInterval(15 * 60)
                let sumKW = b.combinedPowerKW.filter { $0.t >= sample.t && $0.t < slotEnd }
                    .map(\.v).reduce(0, +)
                let chargeDC = max(0, sumKW * sampleHours / slotHours)
                let netImport = max(0, gridByT[sample.t] ?? 0)
                return acc + min(chargeDC, netImport) * 0.25
            }
            print(String(format: "☀️ today PV: AC-only=%.2f, panel-side=%.2f kWh | battery net=%+.2f, grid-charge=%.2f kWh → shown=%.2f",
                         acToday, todayPV, b.todayNetChargeKWh, gridChargeToday, todayProduction))
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
