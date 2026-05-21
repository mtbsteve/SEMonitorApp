import Foundation

/// Synthetic 24h dataset for demo mode — mimics a sunny day with one battery
/// stack that fills mid-morning and drains in the evening.
enum DemoData {

    struct Bundle {
        let snapshot: Snapshot
        let history: HistorySeries
    }

    static func generate(now: Date = Date()) -> Bundle {
        let cal = Calendar(identifier: .gregorian)
        let startOfDay = cal.startOfDay(for: now)

        // 96 quarter-hour points over the last 24h.
        var solar: [HistorySeries.Point] = []
        var consumption: [HistorySeries.Point] = []
        var grid: [HistorySeries.Point] = []
        var battery: [HistorySeries.Point] = []

        for slot in 0..<96 {
            let t = startOfDay.addingTimeInterval(-24 * 3600 + Double(slot) * 15 * 60)
            let hour = Double(cal.component(.hour, from: t)) + Double(cal.component(.minute, from: t)) / 60.0

            let pv = max(0, 6.5 * gauss(hour, mean: 13.0, sigma: 3.0))
            let load = 0.6 + 0.4 * gauss(hour, mean: 8.0, sigma: 1.5)
                            + 1.8 * gauss(hour, mean: 19.5, sigma: 2.0)
                            + 0.2 * sin(hour * 1.4)
            let net = load - pv               // positive = need from grid/battery, negative = surplus
            let g = max(-3.0, min(3.0, net))  // grid handles up to ±3 kW

            solar.append(.init(t: t, v: pv))
            consumption.append(.init(t: t, v: max(0.2, load)))
            grid.append(.init(t: t, v: g))

            // Battery SoC follows a smooth charge/discharge profile (40% → 95% → 35%).
            let soc = 65.0 + 30.0 * sin((hour - 6) * .pi / 14.0)
            battery.append(.init(t: t, v: max(20, min(98, soc))))
        }

        let currentPV = solar.last?.v ?? 0
        let todayEnergy = solar.reduce(0.0) { $0 + $1.v * 0.25 }   // kW * 0.25h
        // Demo "exported" = positive (export) portion of net grid (we store
        // grid as positive = import, so export samples are negative).
        let todayExportedDemo = grid.reduce(0.0) { acc, p in acc + (p.v < 0 ? -p.v * 0.25 : 0) }
        let latestSoC = battery.last?.v ?? 65

        let snap = Snapshot(
            siteId: 999_999,
            siteName: "Demo Site",
            currency: "EUR",
            currentPowerKW: currentPV,
            todayEnergyKWh: todayEnergy,
            todayExportedKWh: todayExportedDemo,
            lifetimeEnergyKWh: 28_450,
            batterySoC: [latestSoC],
            fetchedAt: now
        )

        let hist = HistorySeries(
            solar: solar,
            consumption: consumption,
            grid: grid,
            batteries: [battery]
        )

        return Bundle(snapshot: snap, history: hist)
    }

    private static func gauss(_ x: Double, mean: Double, sigma: Double) -> Double {
        let z = (x - mean) / sigma
        return exp(-0.5 * z * z)
    }
}
