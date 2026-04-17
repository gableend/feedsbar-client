import SwiftUI
import AppKit

@main
struct FeedsBarClientApp: App {
    @State private var store = FeedStore()
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false
    @AppStorage("showSettingsAtStartup") private var showSettingsAtStartup = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch store.phase {
                case .booting:
                    LoadingSplashView(size: 2)
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
            .frame(maxWidth: .infinity)
            .background(WindowAccessor { window in
                guard let window else { return }
                // Floating overlay: no chrome, transparent, always on top, all Spaces
                window.styleMask = [.borderless]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                window.isMovableByWindowBackground = false
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true

                // Hand off frame/level management to the controller (reads prefs from UserDefaults)
                TickerWindowController.shared.attach(window: window)
            })
            .task {
                await store.boot()
            }
            .task {
                // Show Settings on first launch, or every launch if the user opted in.
                // Previously slept 600ms waiting for the ticker to stabilise — removed
                // now that settings hydrates from cached state and doesn't need live data.
                let showNow = !hasLaunchedBefore || showSettingsAtStartup
                hasLaunchedBefore = true
                if showNow {
                    SettingsWindowManager.shared.show(store: store)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
