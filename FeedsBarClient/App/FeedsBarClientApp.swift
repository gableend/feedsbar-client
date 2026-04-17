import SwiftUI

@main
struct FeedsBarClientApp: App {
    @State private var store = FeedStore()
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                switch store.phase {
                case .booting:
                    LoadingSplashView(size: 2) // We ported this earlier
                case .running:
                    TickerView(store: store)
                case .error(let msg):
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(msg)
                            .padding()
                        Button("Retry") {
                            Task { await store.boot() }
                        }
                    }
                }
            }
            // Ensure window is basically a bar shape
            .frame(minWidth: 800, minHeight: 72)
            .task {
                await store.boot()
            }
        }
        .windowStyle(.hiddenTitleBar) // Make it look like a utility
    }
}
