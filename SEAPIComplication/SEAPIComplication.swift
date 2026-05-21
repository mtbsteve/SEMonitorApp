import WidgetKit
import SwiftUI

/// Shared App Group ID — MUST match Watch app's AppConfig.appGroupID and both
/// entitlement files exactly. A mismatch silently breaks the complication.
private let appGroupID = "group.com.mtbsteve.semonitor"

// MARK: - Timeline entry

struct SolarEntry: TimelineEntry {
    let date: Date
    /// Current PV power in kW.
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
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SolarEntry>) -> Void) {
        let now = Date()
        let entry = read()
        // Refresh every 15 min — matches the Watch app's auto-refresh cadence.
        let next = now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func read() -> SolarEntry {
        guard let d = UserDefaults(suiteName: appGroupID) else {
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
