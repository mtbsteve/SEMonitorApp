import SwiftUI
import Charts

struct PowerChartView: View {
    @EnvironmentObject var store: SEStore

    private var solarPoints: [HistorySeries.Point] {
        HistorySeries.carryingForward(store.history.solar, to: Date())
    }
    private var consumptionPoints: [HistorySeries.Point] {
        HistorySeries.carryingForward(store.history.consumption, to: Date())
    }
    private var gridPoints: [HistorySeries.Point] {
        HistorySeries.carryingForward(store.history.grid, to: Date())
    }

    /// Tight Y domain that fits actual values, always including 0 as a baseline
    /// so positive (solar/cons) and negative (grid export) regions are visible.
    private var powerYDomain: ClosedRange<Double> {
        let all = solarPoints.map(\.v) + consumptionPoints.map(\.v) + gridPoints.map(\.v)
        guard let lo = all.min(), let hi = all.max() else { return -1...1 }
        let bottom = Swift.min(lo, 0)
        let top = Swift.max(hi, 0)
        let span = top - bottom
        let pad = span > 0 ? span * 0.1 : 1.0
        return (bottom - pad)...(top + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SE Monitor")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Text("Power — 24h (kW)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading)
            }

            if solarPoints.isEmpty && consumptionPoints.isEmpty && gridPoints.isEmpty {
                ContentUnavailableView("No history", systemImage: "chart.xyaxis.line")
            } else {
                Chart {
                    ForEach(solarPoints, id: \.t) { p in
                        LineMark(x: .value("t", p.t), y: .value("kW", p.v))
                            .foregroundStyle(by: .value("series", "Solar"))
                    }
                    ForEach(consumptionPoints, id: \.t) { p in
                        LineMark(x: .value("t", p.t), y: .value("kW", p.v))
                            .foregroundStyle(by: .value("series", "Cons."))
                    }
                    ForEach(gridPoints, id: \.t) { p in
                        LineMark(x: .value("t", p.t), y: .value("kW", p.v))
                            .foregroundStyle(by: .value("series", "Grid"))
                    }
                }
                .chartForegroundStyleScale([
                    "Solar": .yellow,
                    "Cons.": .red,
                    "Grid": .cyan
                ])
                .chartYScale(domain: powerYDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
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
