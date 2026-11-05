import SwiftUI

/// Shared refresh button used identically on all three screens — white,
/// consistent size, spins while loading, with trailing padding so it clears
/// the scroll / page indicator on the right edge.
struct RefreshButton: View {
    @EnvironmentObject var store: SEStore

    var body: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                           value: store.isLoading)
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading)
        .padding(.trailing, 8)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: SEStore

    var body: some View {
        Group {
            if !store.hasConfig {
                SetupView()
            } else if store.isLoading && store.snapshot.fetchedAt == .distantPast {
                LoadingView()
            } else if let err = store.error, store.snapshot.fetchedAt == .distantPast {
                ErrorView(message: err)
            } else {
                MainTabs()
            }
        }
        .task {
            if store.hasConfig && store.snapshot.fetchedAt == .distantPast {
                await store.refresh()
            }
        }
    }
}

// MARK: - Tabs

private struct MainTabs: View {
    var body: some View {
        TabView {
            OverviewView()
            PowerChartView()
            BatteryChartView()
        }
        .tabViewStyle(.verticalPage)
    }
}

// MARK: - Setup

/// Shown when the build carries no usable SolarEdge grant.
///
/// There is deliberately nothing to type here. The V2 API reaches a site with
/// an OAuth bearer token, and minting one needs a browser consent screen plus
/// a client secret — neither of which exists on a watch. Credentials are
/// therefore baked in at build time from `Secrets.xcconfig`, so the only fix
/// is on the Mac. Demo mode remains available so the UI is still explorable.
struct SetupView: View {
    @EnvironmentObject var store: SEStore

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow)

                Text("SE Monitor")
                    .font(.system(size: 14, weight: .bold))

                Text("No SolarEdge credentials in this build.")
                    .font(.system(size: 10, weight: .medium))
                    .multilineTextAlignment(.center)

                Text("Copy Secrets.xcconfig.example to Secrets.xcconfig, run tools/se-token.sh to authorize your site, then rebuild. See the README.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Use Demo Data") {
                    store.demoMode = true
                    Task { await store.refresh() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow)
                .cornerRadius(8)
            }
            .padding()
        }
    }
}

// MARK: - Loading / error

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                .scaleEffect(0.8)
            Text("Fetching…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct ErrorView: View {
    @EnvironmentObject var store: SEStore
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Retry") { Task { await store.refresh() } }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)

                Button("Reset") { store.clearConfig() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding()
        }
    }
}
