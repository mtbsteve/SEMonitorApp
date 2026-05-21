import SwiftUI
import Charts

struct BatteryChartView: View {
    @EnvironmentObject var store: SEStore

    private static let slotColors: [Color] = [.green, .blue, .orange, .pink]

    private var configuredSlots: [(index: Int, points: [HistorySeries.Point])] {
        let now = Date()
        return store.history.batteries.enumerated()
            .compactMap { (i, pts) in
                pts.isEmpty ? nil : (i, HistorySeries.carryingForward(pts, to: now))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SE Monitor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Text("Battery SoC — 24h (%)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
            }

            if configuredSlots.isEmpty {
                ContentUnavailableView("No battery data", systemImage: "battery.25")
            } else {
                Chart {
                    ForEach(configuredSlots, id: \.index) { slot in
                        ForEach(slot.points, id: \.t) { p in
                            LineMark(x: .value("t", p.t), y: .value("SoC", p.v))
                                .foregroundStyle(by: .value("series", "Batt \(slot.index + 1)"))
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: configuredSlots.map { "Batt \($0.index + 1)" },
                    range: configuredSlots.map { Self.slotColors[$0.index % Self.slotColors.count] }
                )
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, spacing: 2)
            }

            if let err = store.error {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
    }
}
