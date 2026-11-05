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
        // Ask to be re-rendered in 15 min. WidgetKit may delay this on its own
        // heuristics; either way this only re-reads the shared cache.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [readCache()], policy: .after(next)))
    }

    // MARK: - Cache
    //
    // ## Why the complication makes no API calls
    //
    // Under V1 it fetched `currentPowerFlow` itself with a static API key.
    // That is not possible — nor safe — under V2, for two reasons:
    //
    // 1. **Refresh-token rotation.** V2 uses OAuth, and every refresh issues a
    //    new refresh token while invalidating the old one. The complication is
    //    a *separate process* from the watch app, so an in-process lock cannot
    //    coordinate them. If both refreshed near-simultaneously, one would
    //    invalidate the other's token and the grant would be destroyed —
    //    recoverable only by re-running the browser consent flow on a Mac.
    //
    // 2. **Credits.** Every call costs 1 of the Free tier's 2,000 monthly
    //    credits, with no overage. A complication waking on its own schedule
    //    is an unbounded second consumer of the same allowance.
    //
    // So the watch app is the sole API client and the sole token refresher,
    // and the complication renders whatever that last wrote. The cost is
    // staleness between app launches, which is the right trade here.

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

    /// Upper bound of the circular gauge. Pick generously so typical readings
    /// sweep the ring nicely instead of hitting the rail. Two SE10K inverters
    /// can theoretically deliver 20 kW combined; in practice peak is ~13 kW.
    private static let gaugeMax: Double = 15.0

    /// Sun when producing, moon when not — used by both circular and corner.
    private var producingNow: Bool { entry.power > 0.05 }
    private var sunMoonSymbol: String { producingNow ? "sun.max.fill" : "moon.zzz.fill" }
    private var sunMoonTint: Color { producingNow ? .yellow : .gray }

    private var circular: some View {
        Gauge(value: min(max(entry.power, 0), Self.gaugeMax), in: 0...Self.gaugeMax) {
            EmptyView()
        } currentValueLabel: {
            ZStack {
                // Power value at the geometric centre of the ring.
                Text(powerString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                // "kW" pushed toward the bottom so it lands in the open arc
                // gap between the ring's two endpoints — like "6°" / "13°"
                // on Apple's temperature complication.
                Text("kW")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .offset(y: 16)
            }
            .foregroundStyle(.white)
        }
        .gaugeStyle(.accessoryCircular)
        // Gradient sweeps the ring as production rises:
        //   0 kW (no sun) → red → orange → yellow → green (peak production).
        .tint(Gradient(colors: [.red, .orange, .yellow, .green]))
    }

    private var inline: some View {
        Label {
            Text("\(powerString) kW")
        } icon: {
            Image(systemName: sunMoonSymbol)
        }
    }

    private var corner: some View {
        Image(systemName: sunMoonSymbol)
            .foregroundStyle(sunMoonTint)
            .widgetLabel {
                Text("Solar \(powerString) kW")
            }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: sunMoonSymbol).foregroundColor(sunMoonTint)
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
