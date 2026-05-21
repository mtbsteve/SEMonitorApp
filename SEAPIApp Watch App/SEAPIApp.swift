import SwiftUI

@main
struct SEAPIAppWatch: App {
    @StateObject private var store = SEStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
