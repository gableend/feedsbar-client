import SwiftUI

// MARK: - MAIN VIEW
struct TickerView: View {
    let store: FeedStore

    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0
    @AppStorage("tickerSize") private var tickerSize = 2
    @AppStorage("tickerPosition") private var tickerPosition = "top"
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("feedMix") private var feedMix: String = "shuffle"
    @State private var isMiniMode = false

    var body: some View {
        ZStack(alignment: .leading) {
            // LAYER 1: Master Background
            FeedsTheme.background
                .opacity(isMiniMode ? 0.0 : tickerOpacity)
                .ignoresSafeArea()

            // LAYER 2: Animation Layer (News)
            if !isMiniMode {
                ZStack(alignment: .leading) {
                    TickerAnimationLayer(
                        store: store,
                        tickerSize: tickerSize,
                        scrollSpeed: $scrollSpeed
                    )
                    .clipped()
                    // Calm offline degradation: gently fade the stream so it
                    // reads as "last known" rather than live, while still
                    // scrolling the cached items.
                    .opacity(store.isOnline ? 1.0 : 0.8)

                    // Left Side Fade
                    LinearGradient(
                        gradient: Gradient(colors: [FeedsTheme.background, FeedsTheme.background.opacity(0)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)
                }
                .padding(.leading, blockWidth(tickerSize))
            }

            // LAYER 3: Fixed Signal Area
            FixedBrandBlock(
                store: store,
                size: tickerSize,
                isMiniMode: $isMiniMode
            )
            .zIndex(10)

            // LAYER 4: Status chips — focus + offline, quiet and right-aligned.
            if !isMiniMode {
                HStack(spacing: 8) {
                    Spacer()
                    if let orb = store.focusedOrb {
                        FocusChip(label: orb.topicLabel) { store.clearFocus() }
                    }
                    if !store.isOnline {
                        OfflineChip(relative: store.relativeLastUpdated)
                    }
                }
                .padding(.trailing, 14)
                .zIndex(11)
                .allowsHitTesting(store.focusedOrb != nil)
            }
        }
        .frame(height: heightForSize(tickerSize))
        .contextMenu {
            Toggle("Mini Mode", isOn: $isMiniMode)
            Divider()
            Button {
                Task { await store.refreshAll() }
            } label: {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
            Divider()
            Menu {
                Button("Top") { tickerPosition = "top"; TickerWindowController.shared.applyLayout() }
                Button("Bottom") { tickerPosition = "bottom"; TickerWindowController.shared.applyLayout() }
            } label: { Label("Position", systemImage: "arrow.up.and.down.square") }
            Menu {
                Button("Compact") { tickerSize = 1; TickerWindowController.shared.applyLayout() }
                Button("Standard") { tickerSize = 2; TickerWindowController.shared.applyLayout() }
                Button("Large") { tickerSize = 4; TickerWindowController.shared.applyLayout() }
            } label: { Label("Size", systemImage: "arrow.up.left.and.arrow.down.right") }
            Menu {
                Button("Slow (0.5×)") { scrollSpeed = 0.5 }
                Button("Normal (1×)") { scrollSpeed = 1.0 }
                Button("Quick (2×)") { scrollSpeed = 2.0 }
                Button("Fast (5×)") { scrollSpeed = 5.0 }
                Button("Turbo (10×)") { scrollSpeed = 10.0 }
            } label: { Label("Speed", systemImage: "speedometer") }
            Menu {
                Button("Shuffle") { feedMix = "shuffle" }
                Button("Latest") { feedMix = "latest" }
            } label: { Label("Feed Mix", systemImage: "shuffle") }
            Toggle("Always on Top", isOn: $alwaysOnTop)
                .onChange(of: alwaysOnTop) { _, _ in TickerWindowController.shared.applyLayout() }
            Divider()
            Button("Settings...") { SettingsWindowManager.shared.show(store: store) }
            Button("Quit FeedsBar") { NSApp.terminate(nil) }
        }
    }

    private func heightForSize(_ size: Int) -> CGFloat { size == 1 ? 48 : (size == 4 ? 108 : 72) }
    private func blockWidth(_ size: Int) -> CGFloat { size == 1 ? 190 : (size == 4 ? 360 : 290) }
}
