import SwiftUI
import Combine
import QuartzCore

// MARK: - PREFERENCE KEY FOR ROW WIDTHS
struct RowWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - SCROLL MANAGER
final class ScrollManager: ObservableObject {
    @Published var isHovering = false
    private var monitor: Any?
    var onScroll: ((CGFloat) -> Void)?

    func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isHovering else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            self.onScroll?(delta)
            return nil
        }
    }

    func stopMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

/// MARK: - TICKER ENGINE (Full Fidelity)
@MainActor
final class TickerEngine: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var visibleItems: [FeedItem] = []

    private var spacing: CGFloat = 60
    private var bufferSize: Int = 15
    private var allItems: [FeedItem] = []
    
    // Tracks the index in `allItems` of the very first item currently visible.
    private var firstSourceIndex: Int = 0
    
    private var itemWidths: [String: CGFloat] = [:]
    private var timer: AnyCancellable?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private(set) var paused: Bool = false
    private var speed: Double = 1.0

    func configure(items: [FeedItem], bufferSize: Int, spacing: CGFloat, speed: Double) {
        self.allItems = items
        self.bufferSize = bufferSize
        self.spacing = spacing
        self.speed = speed

        self.itemWidths.removeAll()
        self.visibleItems.removeAll()
        self.offset = 0
        self.firstSourceIndex = 0
        self.lastTime = CACurrentMediaTime()

        guard !self.allItems.isEmpty else { return }

        // Seed the initial buffer
        let seedCount = min(bufferSize, self.allItems.count)
        for i in 0..<seedCount {
            visibleItems.append(self.allItems[i])
        }
    }

    func setSpeed(_ speed: Double) { self.speed = speed }
    func setPaused(_ paused: Bool) { self.paused = paused }

    func start() {
        stop()
        lastTime = CACurrentMediaTime()
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.step() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func updateWidthsOnce(_ widths: [String: CGFloat]) {
        for (id, w) in widths where itemWidths[id] == nil && w > 0 {
            itemWidths[id] = w
        }
    }

    func manualScroll(delta: CGFloat) {
        offset += delta
        recycleIfNeeded()
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now

        guard dt > 0, dt < 0.1, !paused, !visibleItems.isEmpty else { return }

        // Move content Left (offset decreases)
        let moveDist = CGFloat(dt * 60.0 * speed)
        offset -= moveDist
        recycleIfNeeded()
    }

    private func recycleIfNeeded() {
        guard !allItems.isEmpty else { return }

        // 1. FORWARD RECYCLING
        while let first = visibleItems.first, let w = itemWidths[first.id] {
            let threshold = -(w + spacing)
            if offset < threshold {
                visibleItems.removeFirst()
                offset += (w + spacing)
                firstSourceIndex = (firstSourceIndex + 1) % allItems.count
                appendNextItem()
            } else {
                break
            }
        }

        // 2. BACKWARD RECYCLING
        while offset > 0 {
            let prevIndex = (firstSourceIndex - 1 + allItems.count) % allItems.count
            let item = allItems[prevIndex]
            
            guard let w = itemWidths[item.id] else { break }
            
            visibleItems.insert(item, at: 0)
            firstSourceIndex = prevIndex
            offset -= (w + spacing)
            
            if visibleItems.count > bufferSize {
                visibleItems.removeLast()
            }
        }
    }

    private func appendNextItem() {
        let nextIndex = (firstSourceIndex + visibleItems.count) % allItems.count
        visibleItems.append(allItems[nextIndex])
    }
}

// MARK: - MAIN VIEW
struct TickerView: View {
    let store: FeedStore

    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0
    @AppStorage("tickerSize") private var tickerSize = 2
    @AppStorage("tickerPosition") private var tickerPosition = "top"
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
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
            Toggle("Always on Top", isOn: $alwaysOnTop)
                .onChange(of: alwaysOnTop) { _, _ in TickerWindowController.shared.applyLayout() }
            Divider()
            Button("Settings...") { SettingsWindowManager.shared.show(store: store) }
            Button("Quit FeedsBar") { NSApp.terminate(nil) }
        }
    }

    private func heightForSize(_ size: Int) -> CGFloat { size == 1 ? 48 : (size == 4 ? 108 : 72) }
    private func blockWidth(_ size: Int) -> CGFloat { size == 1 ? 190 : (size == 4 ? 300 : 230) }
}
