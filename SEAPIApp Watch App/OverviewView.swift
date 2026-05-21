import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: SEStore

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                header

                CurrentPowerCard(power: store.snapshot.currentPowerKW)

                statsGrid

                if !store.snapshot.batterySoC.isEmpty {
                    batterySummary
                }

                if let err = store.error {
                    Text(err)
                        .font(.system(size: 8))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                if let updated = store.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }

                if store.isDemo {
                    Button("Exit Demo Mode") { store.clearConfig() }
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("SE Monitor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(store.snapshot.siteName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.isLoading)
            }
            .buttonStyle(.plain)
        }
    }

    private var statsGrid: some View {
        HStack(spacing: 0) {
            statCell("Production Today", value: kWh(store.snapshot.todayEnergyKWh), unit: "kWh", color: .green)
            Divider().frame(height: 24)
            statCell("Exported Today", value: kWh(store.snapshot.todayExportedKWh), unit: "kWh", color: .cyan)
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func statCell(_ label: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(unit).font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }

    private var batterySummary: some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.75")
                .font(.system(size: 11))
                .foregroundColor(.green)
            ForEach(0..<store.snapshot.batterySoC.count, id: \.self) { i in
                HStack(spacing: 1) {
                    Text("B\(i + 1)").font(.system(size: 8)).foregroundColor(.secondary)
                    Text("\(Int(store.snapshot.batterySoC[i].rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                if i < store.snapshot.batterySoC.count - 1 {
                    Text("•").font(.system(size: 8)).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    // formatting helpers
    private func kWh(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }
    private func lifetime(_ kWh: Double?) -> String {
        guard let kWh else { return "—" }
        return String(format: "%.1f", kWh / 1000.0)   // MWh
    }
}

// MARK: - Current power card (large)

struct CurrentPowerCard: View {
    let power: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(formatted)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("kW").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)
        }
        .padding(8)
        .background(Color.white.opacity(0.07))
        .cornerRadius(9)
    }

    private var formatted: String {
        guard let p = power else { return "—" }
        return String(format: "%.2f", p)
    }
    private var icon: String {
        guard let p = power else { return "sun.max" }
        return p > 0.05 ? "sun.max.fill" : "moon.zzz.fill"
    }
    private var color: Color {
        guard let p = power else { return .gray }
        return p > 0.05 ? .yellow : .gray
    }
}
