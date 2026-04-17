import SwiftUI
import Combine
import QuartzCore

// MARK: - PREFERENCE KEY FOR ROW WIDTHS
struct RowWidthKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
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

/// MARK: - ENGINE
@MainActor
final class TickerEngine: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var visibleItems: [TickerItem] = []

    private var spacing: CGFloat = 60
    private var bufferSize: Int = 15
    private var allItems: [TickerItem] = []
    
    // Tracks the index in `allItems` of the very first item currently visible.
    private var firstSourceIndex: Int = 0
    
    private var itemWidths: [UUID: CGFloat] = [:]
    private var timer: AnyCancellable?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private(set) var paused: Bool = false
    private var speed: Double = 1.0

    func configure(items: [TickerItem], bufferSize: Int, spacing: CGFloat, speed: Double) {
        // Filter duplicates or unwanted domains
        self.allItems = items.filter { !$0.sourceDomain.lowercased().contains("meteo.com") }
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

    func updateWidthsOnce(_ widths: [UUID: CGFloat]) {
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

        guard dt > 0, dt < 0.1 else { return }
        guard !paused else { return }
        guard !visibleItems.isEmpty else { return }

        // Move content Left (offset decreases)
        let moveDist = CGFloat(dt * 60.0 * speed)
        offset -= moveDist
        recycleIfNeeded()
    }

    private func recycleIfNeeded() {
        guard !allItems.isEmpty else { return }

        // 1. FORWARD RECYCLING (Scrolling Right / Content moving Left)
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

        // 2. BACKWARD RECYCLING (Scrolling Left / Content moving Right)
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
    @ObservedObject var feedManager: FeedManager
    @ObservedObject var coordinator: AppCoordinator
    
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0

    var body: some View {
        ZStack(alignment: .leading) {
            FeedsTheme.background.opacity(coordinator.isMiniMode ? 0.0 : tickerOpacity).ignoresSafeArea()
            
            if feedManager.isReady && !coordinator.isMiniMode {
                ZStack(alignment: .leading) {
                    TickerAnimationLayer(
                        feedManager: feedManager,
                        tickerSize: coordinator.tickerSize,
                        scrollSpeed: $scrollSpeed,
                        tickerOpacity: tickerOpacity
                    )
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    
                    LinearGradient(
                        gradient: Gradient(colors: [FeedsTheme.background, FeedsTheme.background.opacity(0)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 40)
                }
                .padding(.leading, blockWidth(coordinator.tickerSize))
            } else if !feedManager.isReady {
                LoadingSplashView(size: coordinator.tickerSize)
            }
            
            FixedBrandBlock(
                coordinator: coordinator,
                feedManager: feedManager,
                size: coordinator.tickerSize,
                background: FeedsTheme.background
            )
            .zIndex(10)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: heightForSize(coordinator.tickerSize))
        .contentShape(Rectangle())
        .contextMenu {
            Toggle("Mini Mode", isOn: $coordinator.isMiniMode)
            Divider()
            Button { self.feedManager.softRefresh() } label: { Label("Remix Feed", systemImage: "shuffle") }
            Button { self.feedManager.hardRefresh() } label: { Label("Refresh Now", systemImage: "arrow.clockwise") }
            Divider()
            Menu {
                Button("Top") { coordinator.tickerPositionString = "top" }
                Button("Bottom") { coordinator.tickerPositionString = "bottom" }
            } label: { Label("Position", systemImage: "arrow.up.and.down.square") }
            Menu {
                Button("Compact") { coordinator.tickerSize = 1 }
                Button("Standard") { coordinator.tickerSize = 2 }
                Button("Large") { coordinator.tickerSize = 4 }
            } label: { Label("Size", systemImage: "arrow.up.left.and.arrow.down.right") }
            Toggle("Always on Top", isOn: $coordinator.alwaysOnTop)
            Divider()
            Button("Settings...") { coordinator.openSettings() }
            Button("Quit FeedBar") { NSApp.terminate(nil) }
        }
    }

    private func heightForSize(_ size: Int) -> CGFloat { size == 1 ? 48 : (size == 4 ? 108 : 72) }
    private func blockWidth(_ size: Int) -> CGFloat { size == 1 ? 190 : (size == 4 ? 300 : 230) }
}

// MARK: - FIXED SIGNAL WIDGET
struct FixedBrandBlock: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var feedManager: FeedManager
    let size: Int
    let background: Color

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                background
                HStack(spacing: 8) {
                    Button(action: { coordinator.openSettings() }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(FeedsTheme.secondaryText.opacity(0.5))
                            .font(.system(size: settingsIconSize(size)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)

                    WeatherSegment(feedManager: feedManager, size: size)
                        .padding(.trailing, 4)
                    
                    SignalRotationOrb(feedManager: feedManager, size: size)
                }
                .padding(.trailing, 15)
                .overlay(
                    Button(action: { withAnimation { coordinator.isMiniMode.toggle() } }) {
                        Image(systemName: coordinator.isMiniMode ? "chevron.right" : "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(FeedsTheme.secondaryText.opacity(0.9))
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    , alignment: .topTrailing
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            
            LinearGradient(
                gradient: Gradient(colors: [background, background.opacity(0)]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 30)
        }
    }
    private func settingsIconSize(_ size: Int) -> CGFloat { size == 1 ? 12 : (size == 4 ? 20 : 16) }
}

// MARK: - ROTATING SIGNAL ORB
struct SignalRotationOrb: View {
    @ObservedObject var feedManager: FeedManager
    let size: Int
    
    enum SignalMode { case news, future, trends, science, sports, research }
    @State private var mode: SignalMode = .news
    @State private var hovered = false
    let timer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            orbView
            if size != 1 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modeTitle).font(.system(size: 8, weight: .bold)).foregroundColor(FeedsTheme.secondaryText.opacity(0.7))
                    let words = modeSummary.split(separator: " ").map(String.init)
                    VStack(alignment: .leading, spacing: -2) {
                        ForEach(words.prefix(3), id: \.self) { word in
                            Text(word.uppercased()).font(.system(size: summaryFontSize, weight: .black, design: .monospaced))
                                .foregroundColor(modeColor.opacity(0.9)).fixedSize()
                        }
                    }.id(mode).transition(.opacity)
                }.frame(width: 110, alignment: .leading)
            }
        }
        .onHover { hovered = $0 }
        .onTapGesture { withAnimation { advanceMode() } }
        .onReceive(timer) { _ in if !hovered { withAnimation { advanceMode() } } }
    }

    private var orbView: some View {
        ZStack {
            Circle().fill(orbColor.opacity(0.25)).frame(width: orbSize * 1.4, height: orbSize * 1.4).blur(radius: 6)
            Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white.opacity(0.6), orbColor]), center: .topLeading, startRadius: 1, endRadius: orbSize))
                .frame(width: orbSize, height: orbSize).shadow(color: orbColor.opacity(0.5), radius: 5)
        }
    }

    private func advanceMode() {
        switch mode {
        case .news: mode = .future; case .future: mode = .trends; case .trends: mode = .science
        case .science: mode = .sports; case .sports: mode = .research; case .research: mode = .news
        }
    }
    
    private var orbColor: Color {
        switch mode {
        case .news:
            let sentiment = self.feedManager.newsSentiment
            switch sentiment?.level {
            case .green: return .green
            case .amber: return .orange
            case .red: return .red
            default: return .gray
            }
        case .future: return Color.cyan
        case .trends: return Color(hex: "D946EF")
        case .science: return Color(hex: "10B981")
        case .sports: return Color(hex: "F59E0B")
        case .research: return Color(hex: "8B5CF6")
        }
    }
    
    private var modeColor: Color {
        switch mode {
        case .news: return FeedsTheme.utility; case .future: return Color.cyan
        case .trends: return Color(hex: "F0ABFC"); case .science: return Color(hex: "34D399")
        case .sports: return Color(hex: "FCD34D"); case .research: return Color(hex: "A78BFA")
        }
    }
    
    private var modeTitle: String {
        switch mode {
        case .news: return "NEWS SENTIMENT"; case .future: return "FUTURE SIGNALS"; case .trends: return "GLOBAL TRENDS"
        case .science: return "SCIENCE FRONTIERS"; case .sports: return "SPORTS PULSE"; case .research: return "AI RESEARCH VIBE"
        }
    }
    
    private var modeSummary: String {
        switch mode {
        case .news: return self.feedManager.newsSentiment?.threeWordSummary ?? "COMPUTING..."
        case .future: return self.feedManager.aiFutureSummary
        case .trends: return self.feedManager.aiTrendSummary
        case .science: return self.feedManager.aiScienceSummary
        case .sports: return self.feedManager.aiSportsSummary
        case .research: return self.feedManager.aiResearchSummary
        }
    }

    private var orbSize: CGFloat { size == 1 ? 10 : (size == 4 ? 20 : 14) }
    private var summaryFontSize: CGFloat { size == 4 ? 11 : 9 }
}

// MARK: - WEATHER SEGMENT
struct WeatherSegment: View {
    @ObservedObject var feedManager: FeedManager
    let size: Int
    @AppStorage("weatherCity") private var city = "Dublin"
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.orange).frame(width: dotSize(size), height: dotSize(size))
            VStack(alignment: .leading, spacing: -2) {
                Text(city.uppercased()).font(.system(size: cityLabelSize(size), weight: .black)).foregroundColor(FeedsTheme.utility)
                Text(self.feedManager.currentWeatherTemp ?? "--°C").font(.system(size: tempValueSize(size), weight: .bold)).foregroundColor(.white)
            }.fixedSize()
        }
    }
    private func dotSize(_ size: Int) -> CGFloat { size == 1 ? 4 : (size == 4 ? 8 : 6) }
    private func cityLabelSize(_ size: Int) -> CGFloat { size == 1 ? 7 : (size == 4 ? 12 : 9) }
    private func tempValueSize(_ size: Int) -> CGFloat { size == 1 ? 13 : (size == 4 ? 26 : 18) }
}

// MARK: - ANIMATION LAYER
struct TickerAnimationLayer: View {
    @ObservedObject var feedManager: FeedManager
    let tickerSize: Int
    @Binding var scrollSpeed: Double
    let tickerOpacity: Double
    
    @StateObject private var engine = TickerEngine()
    @StateObject private var scrollManager = ScrollManager()
    @State private var isDragging = false
    @State private var isWheeling = false
    @State private var cursorPushed = false
    @State private var lastDragTranslation: CGFloat = 0
    
    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 60) {
                ForEach(engine.visibleItems) { item in
                    TickerRow(item: item, size: tickerSize)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: RowWidthKey.self, value: [item.id: proxy.size.width])
                        })
                }
            }
            .offset(x: engine.offset)
            .onPreferenceChange(RowWidthKey.self) { engine.updateWidthsOnce($0) }
            .onHover { hovering in
                scrollManager.isHovering = hovering
                withAnimation(.easeOut(duration: 0.2)) { engine.setPaused(hovering || isDragging || isWheeling) }
            }
            .gesture(
                DragGesture().onChanged { value in
                    isDragging = true; engine.setPaused(true)
                    if !cursorPushed { NSCursor.closedHand.push(); cursorPushed = true }
                    let delta = value.translation.width - lastDragTranslation
                    engine.manualScroll(delta: delta)
                    lastDragTranslation = value.translation.width
                }.onEnded { _ in
                    isDragging = false; lastDragTranslation = 0
                    if cursorPushed { NSCursor.pop(); cursorPushed = false }
                    engine.setPaused(scrollManager.isHovering)
                }
            )
        }
        .onAppear {
            let items = self.feedManager.items
            engine.configure(items: items, bufferSize: 15, spacing: 60, speed: scrollSpeed)
            engine.start()
            scrollManager.onScroll = { rawDelta in
                isWheeling = true; engine.setPaused(true)
                engine.manualScroll(delta: rawDelta * 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isWheeling = false
                    engine.setPaused(scrollManager.isHovering || isDragging)
                }
            }
            scrollManager.startMonitor()
        }
        .onDisappear { engine.stop(); scrollManager.stopMonitor() }
        .onChange(of: scrollSpeed) { _, newVal in engine.setSpeed(newVal) }
        .onChange(of: self.feedManager.itemsRevision) { _, _ in
            let items = self.feedManager.items
            engine.configure(items: items, bufferSize: 15, spacing: 60, speed: scrollSpeed)
        }
    }
}

/// MARK: - ROW
struct TickerRow: View {
    let item: TickerItem
    let size: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            // 1. Icon
            TickerIconView(item: item, size: size)

            // 2. Media (Thumbnail) - Only if present
            if let mediaURL = item.mediaURL {
                AsyncImage(url: mediaURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
                .frame(width: mediaWidth(size), height: mediaHeight(size))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // 3. Text Stack
            VStack(alignment: .leading, spacing: 2) {
                // EYEBROW: Category • 10:00 AM
                Text(item.signalLabelWithDate)
                    .font(.system(size: labelFontSize(size), weight: .black, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.accentColor.opacity(0.15))
                    )
                    .foregroundColor(item.accentColor)
                    .fixedSize()

                // HEADLINE + DOMAIN
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: mainFontSize(size), weight: .bold)) // Bolder headline
                        .foregroundColor(FeedsTheme.primaryText)
                        .fixedSize(horizontal: true, vertical: false) // Important: Forces text to expand fully

                    // THE DOMAIN (e.g. "hacker news")
                    Text(cleanSource(item))
                        .font(.system(size: mainFontSize(size) - 2, weight: .medium, design: .default))
                        .foregroundColor(FeedsTheme.secondaryText) // Distinct grey color
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.articleURL) }
    }

    // Helper to make the source look like "hacker news" instead of "news.ycombinator.com"
    private func cleanSource(_ item: TickerItem) -> String {
        // Use the source name if available (usually cleaner), otherwise domain
        let raw = item.sourceName.isEmpty ? item.sourceDomain : item.sourceName
        return raw.lowercased()
            .replacingOccurrences(of: ".com", with: "") // ✅ FIXED: Added colon
            .replacingOccurrences(of: ".org", with: "")
            .replacingOccurrences(of: ".net", with: "")
            .replacingOccurrences(of: "www.", with: "")
    }

    // Helper Sizing Methods
    private func mediaWidth(_ size: Int) -> CGFloat { size == 1 ? 38 : (size == 4 ? 90 : 60) }
    private func mediaHeight(_ size: Int) -> CGFloat { size == 1 ? 24 : (size == 4 ? 60 : 40) }
    private func mainFontSize(_ size: Int) -> CGFloat { size == 1 ? 15 : (size == 4 ? 30 : 22) }
    private func labelFontSize(_ size: Int) -> CGFloat { size == 1 ? 9 : (size == 4 ? 13 : 10) }
}

// MARK: - ICON VIEW
struct TickerIconView: View {
    let item: TickerItem
    let size: Int
    @ObservedObject private var faviconStore = FaviconStore.shared
    
    // ✅ FIX: Match the server download size
    private let iconFetchSize = 128
    
    var body: some View {
        ZStack {
            if let domain = domainFor(item), let img = faviconStore.image(for: domain, size: iconFetchSize) { // 👈 Use 128
                ZStack {
                    Circle().fill(Color.white).frame(width: iconSize + 6, height: iconSize + 6)
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).grayscale(1.0).frame(width: iconSize, height: iconSize).clipShape(Circle())
                }
            } else {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: iconSize + 8, height: iconSize + 8)
                    Image(systemName: fallbackSymbol(for: item)).font(.system(size: iconSize, weight: .semibold)).foregroundColor(item.accentColor)
                }.onAppear { if let d = domainFor(item) { faviconStore.load(domain: d, size: iconFetchSize) } } // 👈 Use 128
            }
        }.frame(width: boxSize, height: boxSize)
    }
    private var boxSize: CGFloat { size == 1 ? 28 : (size == 4 ? 54 : 40) }
    private var iconSize: CGFloat { size == 1 ? 16 : (size == 4 ? 32 : 24) }
    private func domainFor(_ item: TickerItem) -> String? {
        var s = item.sourceDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("www.") { s.removeFirst(4) }; return s.isEmpty ? nil : s
    }
    private func fallbackSymbol(for item: TickerItem) -> String {
        let label = item.signalLabel.lowercased()
        return label.contains("topic") ? "magnifyingglass" : (label.contains("trend") ? "chart.line.uptrend.xyaxis" : "newspaper")
    }
}
