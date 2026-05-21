import SwiftUI

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

struct SetupView: View {
    @EnvironmentObject var store: SEStore
    @State private var keyInput: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow)

                Text("SE Monitor")
                    .font(.system(size: 14, weight: .bold))

                Text("Enter your SolarEdge Account-level API key (from Monitoring portal → Admin → API Access).")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                TextField("API Key", text: $keyInput)
                    .font(.system(size: 10, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save & Connect") {
                    let cleaned = sanitize(keyInput)
                    store.apiKey = cleaned
                    store.lastEnteredKey = cleaned
                    store.siteId = 0   // force rediscovery
                    Task { await store.refresh() }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow)
                .cornerRadius(8)
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Use Demo Data") {
                    store.apiKey = AppConfig.demoToken
                    Task { await store.refresh() }
                }
                .font(.system(size: 10))
                .foregroundColor(.blue)
            }
            .padding()
        }
        .onAppear {
            if keyInput.isEmpty && store.lastEnteredKey != AppConfig.demoToken {
                keyInput = store.lastEnteredKey
            }
        }
    }

    private func sanitize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
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

                Button("Change API Key") { store.clearConfig() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding()
        }
    }
}
