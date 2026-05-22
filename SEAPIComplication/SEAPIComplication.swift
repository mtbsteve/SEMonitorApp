import WidgetKit
import SwiftUI

// MARK: - Timeline entry

struct SolarEntry: TimelineEntry {
    let date: Date
    /// Current panel-side PV power in kW (AC + signed battery, so battery-only
    /// discharge at night reads 0, not the inverter's AC output).
    let power: Double
    /// Per-battery SoC % at the most recent telemetry. Empty = no batteries.
    let batterySoC: [Double]
}

// MARK: - Provider

struct SolarProvider: TimelineProvider {
    func placeholder(in context: Context) -> SolarEntry {
        SolarEntry(date: Date(), power: 3.2, batterySoC: [72])
    }

    func getSnapshot(in context: Context, completion: @escaping (SolarEntry) -> Void) {
        completion(readCache())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SolarEntry>) -> Void) {
        Task {
            let entry = await fetchOrCache()
            // Schedule next refresh in 15 min. WidgetKit may delay this based
            // on system heuristics (battery, usage), but it's the cadence we
            // ask for. Matches the watch app's auto-refresh and stays under
            // SolarEdge's 300/day quota.
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    // MARK: - Fetch / cache

    /// Try to fetch fresh data from the SolarEdge API. If credentials are
    /// missing, the API call fails, or the last fetch was very recent (within
    /// 12 min — sharing quota with the main app), fall back to the cached
    /// snapshot the watch app last wrote.
    private func fetchOrCache() async -> SolarEntry {
        guard let store = UserDefaults(suiteName: AppConfig.appGroupID) else {
            return SolarEntry(date: Date(), power: 0, batterySoC: [])
        }

        let apiKey = store.string(forKey: "seapi_api_key") ?? ""
        let siteId = store.integer(forKey: "seapi_site_id")
        guard !apiKey.isEmpty, apiKey != AppConfig.demoToken, siteId != 0 else {
            return readCache()
        }

        // Quota guard: if the watch app or a previous complication fetch wrote
        // the cache within the last 12 minutes, reuse it instead of hitting
        // the API again. 15 min × (~96 base + complication) would otherwise
        // double the daily API consumption.
        if let lastFetch = store.object(forKey: "last_api_fetch") as? Date,
           Date().timeIntervalSince(lastFetch) < 12 * 60 {
            return readCache()
        }

        do {
            async let overview = SolarEdgeAPI.fetchOverview(siteId: siteId, apiKey: apiKey)
            async let battery = SolarEdgeAPI.fetchBatteryHistory(siteId: siteId, apiKey: apiKey)
            let (ov, b) = try await (overview, battery)

            let currentAC = ov.currentPower.power / 1000.0
            let latestBattery = b.combinedPowerKW.last?.v ?? 0
            let currentPV = max(0, currentAC + latestBattery)
            let socs = b.latestSoC

            let entry = SolarEntry(date: Date(), power: currentPV, batterySoC: socs)

            // Update the cache so the watch app sees this too.
            store.set(currentPV, forKey: "complication_power")
            store.set(socs, forKey: "complication_soc")
            store.set(Date(), forKey: "complication_updated")
            store.set(Date(), forKey: "last_api_fetch")

            return entry
        } catch {
            return readCache()
        }
    }

    private func readCache() -> SolarEntry {
        guard let d = UserDefaults(suiteName: AppConfig.appGroupID) else {
            return SolarEntry(date: Date(), power: 0, batterySoC: [])
        }
        let p = d.double(forKey: "complication_power")
        let soc = (d.array(forKey: "complication_soc") as? [Double]) ?? []
        let date = (d.object(forKey: "complication_updated") as? Date) ?? Date()
        return SolarEntry(date: date, power: p, batterySoC: soc)
    }
}

// MARK: - View

struct SolarComplicationView: View {
    @Environment(\.widgetFamily) var family
    var entry: SolarEntry

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryInline:      inline
        case .accessoryCorner:      corner
        case .accessoryRectangular: rectangular
        @unknown default:           circular
        }
    }

    private var powerString: String { String(format: "%.1f", entry.power) }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "sun.max.fill").font(.system(size: 10))
                Text(powerString).font(.system(size: 14, weight: .bold, design: .monospaced))
                Text("kW").font(.system(size: 8))
            }
        }
    }

    private var inline: some View {
        Label {
            Text("\(powerString) kW")
        } icon: {
            Image(systemName: "sun.max.fill")
        }
    }

    private var corner: some View {
        Text("\(powerString) kW")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .widgetLabel("Solar")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill").foregroundColor(.yellow)
                Text("\(powerString) kW")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            if !entry.batterySoC.isEmpty {
                Text(batteryString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("SE Monitor")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var batteryString: String {
        entry.batterySoC.enumerated().map { i, soc in
            "B\(i + 1) \(Int(soc.rounded()))%"
        }.joined(separator: "  ")
    }
}

// MARK: - Widget

@main
struct SEAPIComplicationBundle: WidgetBundle {
    var body: some Widget {
        SolarComplication()
    }
}

struct SolarComplication: Widget {
    let kind: String = "com.mtbsteve.semonitor.solar"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SolarProvider()) { entry in
            SolarComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SolarEdge Power")
        .description("Current PV power and battery SoC.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner,
            .accessoryRectangular
        ])
    }
}
