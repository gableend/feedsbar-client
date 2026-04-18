import SwiftUI
import AppKit
import Combine
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "bar.feeds.client", category: "settings")

// MARK: - TICKER WINDOW CONTROLLER
// Owns the main ticker NSWindow reference and applies layout based on prefs.
@MainActor
final class TickerWindowController: ObservableObject {
    static let shared = TickerWindowController()

    weak var window: NSWindow?
    @Published private(set) var availableScreens: [NSScreen] = NSScreen.screens

    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TickerWindowController.shared.refreshScreens()
                TickerWindowController.shared.applyLayout()
            }
        }
    }

    func attach(window: NSWindow) {
        self.window = window
        applyLayout()
    }

    func refreshScreens() {
        availableScreens = NSScreen.screens
    }

    func applyLayout() {
        guard let window else { return }
        let d = UserDefaults.standard
        let alwaysOnTop = (d.object(forKey: "alwaysOnTop") as? Bool) ?? true
        let tickerSize = d.integer(forKey: "tickerSize") == 0 ? 2 : d.integer(forKey: "tickerSize")
        let position = d.string(forKey: "tickerPosition") ?? "top"
        let preferredMonitor = d.string(forKey: "preferredMonitor") ?? ""

        window.level = alwaysOnTop ? .floating : .normal

        let height = Self.heightForSize(tickerSize)
        let screen = Self.chosenScreen(preferredMonitorID: preferredMonitor) ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame
        let visible = screen.visibleFrame

        let y: CGFloat = (position == "bottom") ? visible.minY : (visible.maxY - height)
        window.setFrame(
            NSRect(x: screenFrame.minX, y: y, width: screenFrame.width, height: height),
            display: true
        )
    }

    static func chosenScreen(preferredMonitorID: String) -> NSScreen? {
        guard !preferredMonitorID.isEmpty else { return NSScreen.main }
        return NSScreen.screens.first { String(Self.screenID($0)) == preferredMonitorID }
    }

    static func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func heightForSize(_ s: Int) -> CGFloat { s == 1 ? 48 : (s == 4 ? 108 : 72) }
}

// MARK: - SETTINGS WINDOW MANAGER
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?
    private override init() { super.init() }

    func show(store: FeedStore) {
        if let window {
            Self.centerOnTickerScreen(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView(store: store))
        Self.centerOnTickerScreen(w)

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pin the settings window to whichever screen the ticker is on so both
    /// surfaces stay together on multi-monitor setups.
    private static func centerOnTickerScreen(_ window: NSWindow) {
        let tickerScreen = TickerWindowController.shared.window?.screen
        let preferred = UserDefaults.standard.string(forKey: "preferredMonitor") ?? ""
        let target = tickerScreen
            ?? TickerWindowController.chosenScreen(preferredMonitorID: preferred)
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let visible = target.visibleFrame
        let wf = window.frame
        let x = visible.midX - wf.width / 2
        let y = visible.midY - wf.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func close() { window?.close() }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

// MARK: - SETTINGS VIEW (tabbed shell)
struct SettingsView: View {
    let store: FeedStore
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable {
        case home = "Home"
        case preferences = "Preferences"
        case curated = "Curated"
        case sources = "Sources"
        case rss = "RSS"
        case about = "About"
    }

    var body: some View {
        HStack(spacing: 0) {
            // SIDEBAR
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("FEEDS").font(.system(size: 14, weight: .heavy, design: .monospaced))
                }
                .foregroundColor(FeedsTheme.primaryText)
                .padding(20)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsSidebarButton(
                        title: tab.rawValue,
                        icon: icon(for: tab),
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
                Spacer()
            }
            .frame(width: 200)
            .background(FeedsTheme.background)

            // CONTENT
            ZStack {
                FeedsTheme.surface.ignoresSafeArea()
                switch selectedTab {
                case .home: HomeTab(store: store)
                case .preferences: PreferencesTab()
                case .curated: CuratedTab(store: store)
                case .sources: SourcesOverviewTab(store: store, onPickRSS: { selectedTab = .rss })
                case .rss: RSSTab(store: store)
                case .about: AboutTab(store: store)
                }
            }
        }
        .frame(width: 800, height: 650)
        .preferredColorScheme(.dark)
    }

    private func icon(for tab: SettingsTab) -> String {
        switch tab {
        case .home: return "house"
        case .preferences: return "slider.horizontal.3"
        case .curated: return "sparkles"
        case .sources: return "square.stack.3d.up"
        case .rss: return "dot.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }
}

struct SettingsSidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
            .foregroundColor(isSelected ? .white : FeedsTheme.secondaryText)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

// MARK: - HOME TAB
struct HomeTab: View {
    let store: FeedStore

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showSettingsAtStartup") private var showSettingsAtStartup = true

    // Cache the tile list so it doesn't rebuild on every unrelated @Observable
    // read (orbs update, items update, etc.). Refreshed via .task(id:) below
    // only when the feed set actually changes.
    @State private var cachedTiles: [SignalTile] = []
    @State private var cachedTilesFingerprint: String = ""

    private let tileSize: CGFloat = 28
    private var gridCols: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 6)]
    }

    var body: some View {
        VStack(spacing: 12) {
            // Brand header
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 34))
                    .foregroundColor(FeedsTheme.ai)
                Button {
                    if let url = URL(string: "https://feeds.bar") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("feeds.bar")
                        .font(.system(size: 22, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(FeedsTheme.primaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open feeds.bar")
                Text("A signal layer for your desktop.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FeedsTheme.secondaryText)
            }
            .padding(.top, 16)

            // Signal board — one tile per unique source domain (cached)
            let tiles = cachedTiles
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SIGNAL BOARD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.ai)
                    Spacer()
                    Text("\(tiles.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(FeedsTheme.secondaryText)
                }
                LazyVGrid(columns: gridCols, spacing: 6) {
                    ForEach(tiles) { tile in
                        SignalTileView(tile: tile, size: tileSize)
                            .help(tile.tooltip)
                    }
                }
                .padding(10)
                .background(FeedsTheme.surface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(FeedsTheme.divider.opacity(0.7), lineWidth: 1))
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 4)

            // Running orbs: compact pills, keywords surfaced on hover.
            if !store.orbs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ORBS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(FeedsTheme.ai)
                        Spacer()
                        Text("\(store.orbs.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(FeedsTheme.secondaryText)
                    }
                    // Two rows: 4 + 3 keeps the widest labels
                    // (BUSINESS BEATS, SCIENCE FRONTIERS…) from overflowing.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ForEach(Array(store.orbs.prefix(4))) { orb in
                                OrbPill(orb: orb, topics: store.topics)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 10) {
                            ForEach(Array(store.orbs.dropFirst(4))) { orb in
                                OrbPill(orb: orb, topics: store.topics)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer(minLength: 4)
            Divider().background(FeedsTheme.divider).padding(.horizontal, 80)

            // Minimize + bottom toggles
            VStack(spacing: 10) {
                Button(action: { SettingsWindowManager.shared.close() }) {
                    Text("MINIMIZE TO FEED BAR")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FeedsTheme.background)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 28)
                        .background(FeedsTheme.utility)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .shadow(radius: 5)

                HStack(spacing: 30) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(CheckboxToggleStyle())
                        .onChange(of: launchAtLogin) { _, val in
                            applyLaunchAtLogin(enabled: val)
                        }
                    Toggle("Show Admin at startup", isOn: $showSettingsAtStartup)
                        .toggleStyle(CheckboxToggleStyle())
                }
                .font(.system(size: 12))
                .foregroundColor(FeedsTheme.secondaryText)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: feedsFingerprint) {
            if feedsFingerprint != cachedTilesFingerprint {
                cachedTilesFingerprint = feedsFingerprint
                cachedTiles = Self.computeSignalTiles(store.feeds)
            }
        }
    }

    /// Build tiles from the active feeds. Dedup by source domain (icon_url collisions
    /// otherwise mean NPR Top Stories / Politics / Technology all show the same icon
    /// three times). Fall back to feed.id when no domain can be derived.
    private static func computeSignalTiles(_ feeds: [FeedIndexItem]) -> [SignalTile] {
        var seen = Set<String>()
        var tiles: [SignalTile] = []
        for feed in feeds where (feed.isActive ?? true) {
            let dedupKey: String = {
                if let d = feed.domain, !d.isEmpty { return "domain:\(d)" }
                if let ic = feed.iconUrl, !ic.isEmpty { return "icon:\(ic)" }
                return "id:\(feed.id)"
            }()
            if seen.insert(dedupKey).inserted {
                tiles.append(
                    SignalTile(
                        id: feed.id,
                        tooltip: feed.title,
                        iconUrl: feed.iconUrl,
                        domain: feed.domain,
                        tint: FeedsTheme.newsHighContrast
                    )
                )
            }
        }
        return tiles
    }

    private var feedsFingerprint: String {
        store.feeds.map(\.id).joined(separator: ",")
    }

    private func applyLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Launch-at-login toggle failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - Signal tile
struct SignalTile: Identifiable, Hashable {
    let id: String
    let tooltip: String
    let iconUrl: String?
    let domain: String?
    let tint: Color
}

struct SignalTileView: View {
    let tile: SignalTile
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                )

            if let urlStr = tile.iconUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size - 12, height: size - 12)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackIcon: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(tile.tint)
    }
}

// MARK: - Orb pill (compact, used in Home tab)
struct OrbPill: View {
    let orb: Orb
    let topics: [Topic]

    var body: some View {
        let color = resolveOrbColor(for: orb, topics: topics)
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 14, height: 14).blur(radius: 3)
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 2)
            }
            Text(orb.topicLabel.uppercased())
                .font(.system(size: 10, weight: .black))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .fixedSize()
        .help(tooltip)
    }

    private var tooltip: String {
        let words = orb.keywords ?? []
        return words.isEmpty ? "Scanning…" : words.joined(separator: " · ")
    }
}

// MARK: - Pointing hand cursor helper
private extension View {
    func pointingHandCursor() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Checkbox toggle style
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(FeedsTheme.secondaryText.opacity(0.6), lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if configuration.isOn {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(FeedsTheme.ai)
                            .frame(width: 14, height: 14)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PREFERENCES TAB
struct PreferencesTab: View {
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("tickerOpacity") private var tickerOpacity = 1.0
    @AppStorage("weatherCity") private var weatherCity = "Dublin"
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("tickerSize") private var tickerSize = 2
    @AppStorage("tickerPosition") private var tickerPosition = "top"
    @AppStorage("preferredMonitor") private var preferredMonitor = ""
    @AppStorage("showSettingsAtStartup") private var showSettingsAtStartup = true
    @AppStorage("feedMix") private var feedMix: String = "shuffle"

    @State private var localScrollSpeed: Double = 1.0
    @State private var localOpacity: Double = 1.0
    @State private var cityInput = ""
    @StateObject private var windowCtrl = TickerWindowController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // STARTUP
                ConfigSection(title: "STARTUP") {
                    ConfigRow(label: "Show Settings at startup") {
                        Toggle("", isOn: $showSettingsAtStartup)
                            .labelsHidden()
                            .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                    }
                }

                // LOCATION
                ConfigSection(title: "LOCAL INTELLIGENCE") {
                    ConfigRow(label: "Weather City") {
                        HStack {
                            TextField("Enter City", text: $cityInput)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(6)
                                .background(FeedsTheme.inputBackground)
                                .cornerRadius(4)
                                .foregroundColor(.white)
                                .frame(width: 140)

                            Button("SAVE") { weatherCity = cityInput }
                                .font(.system(size: 10, weight: .bold))
                                .padding(6)
                                .background(FeedsTheme.ai)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                                .buttonStyle(.plain)
                        }
                        .onAppear { cityInput = weatherCity }
                    }
                }

                // PLACEMENT
                ConfigSection(title: "PLACEMENT") {
                    ConfigRow(label: "Position") {
                        Picker("", selection: $tickerPosition) {
                            Text("Top").tag("top")
                            Text("Bottom").tag("bottom")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                        .onChange(of: tickerPosition) { _, _ in windowCtrl.applyLayout() }
                    }

                    ConfigRow(label: "Monitor") {
                        Picker("", selection: $preferredMonitor) {
                            Text("Main (auto)").tag("")
                            ForEach(windowCtrl.availableScreens, id: \.self) { screen in
                                Text(screen.localizedName)
                                    .tag(String(TickerWindowController.screenID(screen)))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(minWidth: 180)
                        .onChange(of: preferredMonitor) { _, _ in windowCtrl.applyLayout() }
                    }

                    ConfigRow(label: "Ticker Size") {
                        Picker("", selection: $tickerSize) {
                            Text("Compact").tag(1)
                            Text("Standard").tag(2)
                            Text("Large").tag(4)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                        .onChange(of: tickerSize) { _, _ in windowCtrl.applyLayout() }
                    }
                }

                // OPTICS
                ConfigSection(title: "OPTICS") {
                    ConfigRow(label: "Always on Top") {
                        Toggle("", isOn: $alwaysOnTop)
                            .labelsHidden()
                            .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                            .onChange(of: alwaysOnTop) { _, _ in windowCtrl.applyLayout() }
                    }
                    ConfigRow(label: "Background Opacity") {
                        HStack {
                            Text("0%").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localOpacity, in: 0.0...1.0) { editing in
                                if !editing { tickerOpacity = localOpacity }
                            }
                            .tint(FeedsTheme.utility)
                            Text("100%").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }
                        .frame(width: 240)
                        .onAppear { localOpacity = tickerOpacity }
                    }
                }

                // FEED MIX
                ConfigSection(title: "FEED MIX") {
                    ConfigRow(label: "Ordering") {
                        Picker("", selection: $feedMix) {
                            Text("Shuffle").tag("shuffle")
                            Text("Latest").tag("latest")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                }

                // KINETICS
                ConfigSection(title: "STREAM KINETICS") {
                    ConfigRow(label: "Flow Speed") {
                        HStack {
                            Text("Slow").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                            Slider(value: $localScrollSpeed, in: 0.5...20.0) { editing in
                                if !editing { scrollSpeed = localScrollSpeed }
                            }
                            .tint(FeedsTheme.utility)
                            Text("Fast").font(.caption).foregroundColor(FeedsTheme.secondaryText)
                        }
                        .frame(width: 240)
                        .onAppear { localScrollSpeed = scrollSpeed }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }
}

// MARK: - SOURCES OVERVIEW TAB
/// Umbrella view that lists every supported source type as a card.
/// - RSS: drills into the dedicated RSS tab (113+ feeds need their own surface).
/// - Any other type with at least one feed: expands inline with per-feed toggles.
/// - Types with zero feeds: render as a muted "Coming soon" placeholder.
struct SourcesOverviewTab: View {
    let store: FeedStore
    let onPickRSS: () -> Void
    @State private var expanded: Set<SourceType> = []

    private var countsByType: [SourceType: Int] {
        var out: [SourceType: Int] = [:]
        for f in store.feeds {
            out[f.effectiveSourceType, default: 0] += 1
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(SourceType.allCases, id: \.self) { type in
                    SourceTypeCard(
                        store: store,
                        type: type,
                        count: countsByType[type] ?? 0,
                        isExpanded: expanded.contains(type),
                        onTap: {
                            if type == .rss {
                                onPickRSS()
                            } else if (countsByType[type] ?? 0) > 0 {
                                if expanded.contains(type) { expanded.remove(type) }
                                else { expanded.insert(type) }
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(FeedsTheme.secondaryText)
            Text("The signal layer pulls from multiple source types. Tap a type to manage its feeds; types with no sources yet will light up as they're added.")
                .font(.system(size: 12))
                .foregroundColor(FeedsTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

private struct SourceTypeCard: View {
    let store: FeedStore
    let type: SourceType
    let count: Int
    let isExpanded: Bool
    let onTap: () -> Void

    private var feedsOfType: [FeedIndexItem] {
        store.feeds.filter { $0.effectiveSourceType == type }
    }
    private var enabledCount: Int {
        feedsOfType.filter { store.isFeedEnabled($0.id) }.count
    }
    private var hasFeeds: Bool { count > 0 }
    /// RSS drills to its own tab; other types with feeds expand inline;
    /// types with zero feeds are inert placeholders.
    private var isInteractive: Bool { type == .rss || hasFeeds }

    private var statusText: String {
        if hasFeeds { return "\(enabledCount)/\(count) enabled" }
        return "Coming soon"
    }

    private var chevron: String {
        if type == .rss { return "chevron.right" }
        if hasFeeds { return isExpanded ? "chevron.down" : "chevron.right" }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Tap target: icon + title + status. Triggers drill-in or expand.
                Button(action: onTap) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(type.tint.opacity(isInteractive ? 0.18 : 0.10))
                                .frame(width: 40, height: 40)
                            Image(systemName: type.sfSymbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(type.tint.opacity(isInteractive ? 1.0 : 0.55))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.displayName.uppercased())
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundColor(FeedsTheme.primaryText)
                            Text(statusText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(FeedsTheme.secondaryText)
                        }

                        Spacer()

                        if !chevron.isEmpty {
                            Image(systemName: chevron)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(FeedsTheme.iconTint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isInteractive)

                // Master toggle for this type: enables/disables every feed of
                // this source_type in one batched store call. Hidden for types
                // with no feeds (nothing to toggle).
                if hasFeeds {
                    Toggle("", isOn: Binding(
                        get: { enabledCount == count },
                        set: { newOn in
                            let ids = feedsOfType.map { $0.id }
                            store.setFeedsEnabled(ids, enabled: newOn)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isInteractive ? 0.06 : 0.03))
            )
            .opacity(isInteractive ? 1.0 : 0.80)

            if isExpanded && hasFeeds && type != .rss {
                SourceTypeFeedList(store: store, type: type)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Inline list of feeds for a given non-RSS source type. Reuses FeedRow
/// (the same row used in the RSS tab) so toggle/health/count look identical.
private struct SourceTypeFeedList: View {
    let store: FeedStore
    let type: SourceType

    private var feeds: [FeedIndexItem] {
        store.feeds
            .filter { $0.effectiveSourceType == type }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(feeds) { feed in
                FeedRow(
                    title: feed.title,
                    iconUrl: feed.iconUrl,
                    items30d: feed.items30d,
                    health: feed.health,
                    isEnabled: store.isFeedEnabled(feed.id),
                    onToggle: { store.toggleFeed(feed.id) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - RSS TAB
/// Per-feed RSS management. This is the pre-existing "Sources" surface,
/// renamed to "RSS" now that `SourcesOverviewTab` is the umbrella view for
/// all source types.
struct RSSTab: View {
    let store: FeedStore
    @State private var expanded: Set<String> = []
    // Cache the expensive grouping so the body doesn't re-sort 140 feeds
    // every time a toggle flips disabledIDs.
    @State private var cachedGroups: [CategoryGroup] = []
    @State private var cachedFeedsFingerprint: String = ""

    struct CategoryGroup: Identifiable {
        let id: String         // stable per category (slug or "__uncat__")
        let name: String
        let sortOrder: Int
        let feeds: [FeedIndexItem]
    }

    private static func computeGroups(_ feeds: [FeedIndexItem]) -> [CategoryGroup] {
        let by = Dictionary(grouping: feeds) { f -> String in
            f.category?.slug ?? "__uncat__"
        }
        let groups: [CategoryGroup] = by.map { slug, feeds in
            let rep = feeds.first?.category
            return CategoryGroup(
                id: slug,
                name: rep?.name ?? "Uncategorized",
                sortOrder: rep?.sortOrder ?? Int.max,
                feeds: feeds.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            )
        }
        return groups.sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.name < $1.name
        }
    }

    private var totalCount: Int { store.feeds.count }
    private var enabledCount: Int { store.feeds.count - store.disabledIDs.intersection(store.feeds.map(\.id)).count }

    var body: some View {
        VStack(spacing: 0) {
            // Header + master toggle
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FEED FILTERS")
                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
                            .foregroundColor(FeedsTheme.primaryText)
                        Text("\(enabledCount) of \(totalCount) enabled")
                            .font(.system(size: 11))
                            .foregroundColor(FeedsTheme.secondaryText)
                    }
                    Spacer()
                    Button(enabledCount == totalCount ? "DISABLE ALL" : "ENABLE ALL") {
                        let allIds = store.feeds.map { $0.id }
                        store.setFeedsEnabled(allIds, enabled: enabledCount != totalCount)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(FeedsTheme.primaryText)
                    .cornerRadius(4)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(FeedsTheme.surface)

            if store.feeds.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 30))
                        .foregroundColor(FeedsTheme.secondaryText.opacity(0.3))
                    Text("NO FEEDS DETECTED")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FeedsTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(cachedGroups) { group in
                            CategoryDisclosure(
                                group: group,
                                store: store,
                                isExpanded: expanded.contains(group.id),
                                toggleExpanded: {
                                    if expanded.contains(group.id) {
                                        expanded.remove(group.id)
                                    } else {
                                        expanded.insert(group.id)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(FeedsTheme.background)
        .task(id: feedsFingerprint) {
            // Recompute groups only when the feed set actually changes,
            // not on every disabledIDs toggle.
            if feedsFingerprint != cachedFeedsFingerprint {
                cachedFeedsFingerprint = feedsFingerprint
                cachedGroups = Self.computeGroups(store.feeds)
            }
        }
    }

    /// Compact fingerprint of the current feed set for change-detection.
    private var feedsFingerprint: String {
        store.feeds.map(\.id).joined(separator: ",")
    }
}

private struct CategoryDisclosure: View {
    let group: RSSTab.CategoryGroup
    let store: FeedStore
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    private var enabledInCat: Int { group.feeds.filter { store.isFeedEnabled($0.id) }.count }
    private var allOn: Bool { enabledInCat == group.feeds.count }

    var body: some View {
        VStack(spacing: 0) {
            // Category header
            HStack(spacing: 10) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(FeedsTheme.secondaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        Text(group.name.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(FeedsTheme.categoryColor(for: group.name))
                        Text("\(enabledInCat)/\(group.feeds.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(FeedsTheme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { allOn },
                    set: { newOn in
                        store.setFeedsEnabled(group.feeds.map { $0.id }, enabled: newOn)
                    }
                ))
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FeedsTheme.surface)
            .cornerRadius(6)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.feeds) { feed in
                        FeedRow(
                            title: feed.title,
                            iconUrl: feed.iconUrl,
                            items30d: feed.items30d,
                            health: feed.health,
                            isEnabled: store.isFeedEnabled(feed.id),
                            onToggle: { store.toggleFeed(feed.id) }
                        )
                    }
                }
                .background(FeedsTheme.surface.opacity(0.6))
                .cornerRadius(6)
                .padding(.top, 2)
            }
        }
    }
}

struct FeedRow: View {
    let title: String
    let iconUrl: String?
    let items30d: Int?
    let health: FeedIndexItem.Health
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FeedRowIcon(iconUrl: iconUrl, isEnabled: isEnabled)
            FeedHealthDot(health: health, isEnabled: isEnabled)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEnabled ? FeedsTheme.primaryText : FeedsTheme.secondaryText)
                .lineLimit(1)
            if let n = items30d {
                Text("\(n)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(isEnabled ? 0.08 : 0.04))
                    .cornerRadius(4)
                    .help("\(n) items in the last 30 days")
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(SignalSwitchStyle(onColor: FeedsTheme.ai))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(FeedsTheme.background.opacity(0.5)),
            alignment: .bottom
        )
    }
}

private struct FeedHealthDot: View {
    let health: FeedIndexItem.Health
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(isEnabled ? 1.0 : 0.5)
            .help(tooltip)
    }

    private var color: Color {
        switch health {
        case .flowing: return FeedsTheme.success            // green
        case .quiet:   return FeedsTheme.utility            // amber
        case .broken:  return Color(red: 0.90, green: 0.32, blue: 0.32) // red
        }
    }

    private var tooltip: String {
        switch health {
        case .flowing: return "Healthy — item within the last 7 days"
        case .quiet:   return "Quiet — no items in the last 30 days"
        case .broken:  return "Broken — disabled by the ingest worker"
        }
    }
}

/// Icon cell used inside each feed row. Uses the Home tab's SignalTileView
/// dimensions + styling verbatim so dark favicons read the same way.
private struct FeedRowIcon: View {
    let iconUrl: String?
    let isEnabled: Bool
    private let size: CGFloat = 28

    var body: some View {
        SignalTileView(
            tile: SignalTile(
                id: iconUrl ?? "nofeed",
                tooltip: "",
                iconUrl: iconUrl,
                domain: nil,
                tint: FeedsTheme.newsHighContrast
            ),
            size: size
        )
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

// MARK: - CURATED TAB

/// A hand-picked set of feeds. Activating one enables exactly those feeds
/// and disables everything else (mutex-style). "Pulse" is dynamic: the
/// feeds it resolves to depend on which sources have items in the last hour.
struct CuratedBundle: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String      // SF Symbol
    let tint: Color
    let blurb: String
    let feedTitles: [String]
    let isDynamic: Bool

    /// Resolve to concrete feed IDs against the live manifest. For dynamic
    /// bundles this can return an empty list if nothing qualifies right now.
    func resolveFeedIds(in feeds: [FeedIndexItem]) -> [String] {
        if isDynamic && id == "pulse" {
            return feeds
                .filter { ($0.items1h ?? 0) > 0 }
                .sorted { ($0.items1h ?? 0) > ($1.items1h ?? 0) }
                .prefix(10)
                .map { $0.id }
        }
        let wanted = Set(feedTitles.map { $0.lowercased() })
        return feeds
            .filter { wanted.contains($0.title.lowercased()) }
            .map { $0.id }
    }

    /// True when every feed this bundle resolves to is currently enabled.
    /// Uses a subset check (not exact equality) so seeding new feeds that
    /// a bundle references later doesn't silently flip bundles inactive for
    /// existing users. The trade-off: a bundle also reads as "active" when
    /// the user has enabled extras on top — acceptable given the Curated
    /// UI is a one-tap activator, not a canonical view of the user's set.
    func isActive(in store: FeedStore) -> Bool {
        let resolved = Set(resolveFeedIds(in: store.feeds))
        if resolved.isEmpty { return false }
        let enabled = Set(store.feeds.map(\.id)).subtracting(store.disabledIDs)
        return resolved.isSubset(of: enabled)
    }
}

private enum CuratedCatalogue {
    static let all: [CuratedBundle] = [
        CuratedBundle(
            id: "pulse",
            name: "Pulse",
            icon: "bolt.fill",
            tint: FeedsTheme.utility,
            blurb: "Whatever's moving right now — feeds publishing in the last hour.",
            feedTitles: [],
            isDynamic: true
        ),
        CuratedBundle(
            id: "world",
            name: "World Briefing",
            icon: "globe",
            tint: FeedsTheme.newsHighContrast,
            blurb: "Major international news desks.",
            feedTitles: [
                "BBC News", "NPR Top Stories", "Al Jazeera", "Deutsche Welle",
                "The Guardian World", "Sky News", "CBS News", "Radio Free Europe"
            ],
            isDynamic: false
        ),
        CuratedBundle(
            id: "business",
            name: "Business & Markets",
            icon: "chart.line.uptrend.xyaxis",
            tint: Color(red: 0.31, green: 0.82, blue: 0.77),
            blurb: "Finance, markets, corporate strategy.",
            feedTitles: [
                "Bloomberg Markets", "Financial Times", "MarketWatch",
                "The Economist", "Forbes Business", "Business Insider", "Guardian Business"
            ],
            isDynamic: false
        ),
        CuratedBundle(
            id: "tech-ai",
            name: "Tech & AI",
            icon: "cpu",
            tint: FeedsTheme.ai,
            blurb: "Mainstream tech press plus AI-lab voices.",
            feedTitles: [
                "The Verge", "TechCrunch", "Wired", "Ars Technica",
                "Hugging Face Blog", "OpenAI News", "MIT Technology Review", "Google Research"
            ],
            isDynamic: false
        ),
        CuratedBundle(
            id: "makers",
            name: "Makers",
            icon: "hammer.fill",
            tint: Color(red: 0.70, green: 0.56, blue: 0.95),
            blurb: "Dev tools, platforms, engineering posts.",
            feedTitles: [
                "Hacker News", "GitHub Blog", "GitHub Changelog", "Cloudflare Blog",
                "Stripe Blog", "AWS News Blog", "Schneier on Security", "The Register"
            ],
            isDynamic: false
        ),
        CuratedBundle(
            id: "science",
            name: "Science",
            icon: "atom",
            tint: Color(red: 0.416, green: 0.580, blue: 0.788),
            blurb: "Research, discoveries, the natural world.",
            feedTitles: [
                "Nature News", "New Scientist", "Popular Science", "Science Daily",
                "Science Magazine", "IEEE Spectrum", "ZME Science"
            ],
            isDynamic: false
        ),
        CuratedBundle(
            id: "culture",
            name: "Culture",
            icon: "theatermasks.fill",
            tint: Color(red: 0.96, green: 0.45, blue: 0.72),
            blurb: "Film, music, style, ideas.",
            feedTitles: [
                "Rolling Stone", "Billboard", "Variety", "Deadline",
                "Elle", "Vogue", "PetaPixel", "Stratechery"
            ],
            isDynamic: false
        )
    ]
}

struct CuratedTab: View {
    let store: FeedStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CURATED SETS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.ai)
                Text("Pick one to replace your current feed selection. Tweak per-feed in Sources afterwards.")
                    .font(.system(size: 11))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .padding(.bottom, 4)

                ForEach(CuratedCatalogue.all) { bundle in
                    CuratedBundleCard(bundle: bundle, store: store)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}

private struct CuratedBundleCard: View {
    let bundle: CuratedBundle
    let store: FeedStore

    private var resolvedIds: [String] { bundle.resolveFeedIds(in: store.feeds) }
    private var resolvedCount: Int { resolvedIds.count }
    private var isActive: Bool { bundle.isActive(in: store) }
    private var preview: [FeedIndexItem] {
        let set = Set(resolvedIds)
        return store.feeds.filter { set.contains($0.id) }.prefix(6).map { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Glyph
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(bundle.tint.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: bundle.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(bundle.tint)
            }

            // Body
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(bundle.name.uppercased())
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(FeedsTheme.primaryText)
                    Text("\(resolvedCount) \(bundle.isDynamic ? "live" : "feeds")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FeedsTheme.secondaryText)
                    Spacer()
                }
                Text(bundle.blurb)
                    .font(.system(size: 11))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    ForEach(preview) { feed in
                        FeedRowIcon(iconUrl: feed.iconUrl, isEnabled: true)
                            .scaleEffect(0.72, anchor: .leading)
                            .frame(width: 22, height: 22)
                    }
                    if resolvedCount > preview.count {
                        Text("+\(resolvedCount - preview.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(FeedsTheme.secondaryText)
                            .padding(.leading, 4)
                    }
                }
                .frame(height: 24)
            }

            // Action
            Button(action: { store.applyCuratedSet(resolvedIds, curatedID: bundle.id) }) {
                Text(isActive ? "ACTIVE" : "ACTIVATE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? FeedsTheme.success : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isActive ? Color.white.opacity(0.08) : FeedsTheme.ai)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isActive ? FeedsTheme.success.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(resolvedCount == 0 || isActive)
            .opacity(resolvedCount == 0 ? 0.4 : 1.0)
        }
        .padding(14)
        .background(FeedsTheme.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? FeedsTheme.success.opacity(0.5) : FeedsTheme.divider.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - ABOUT TAB
struct AboutTab: View {
    let store: FeedStore
    @State private var feedbackToast: String?
    @State private var showFeedbackSheet = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info["CFBundleVersion"] as? String) ?? "0"
        return "v\(short) (\(build))"
    }

    private var totalItems30d: Int {
        store.feeds.reduce(0) { $0 + ($1.items30d ?? 0) }
    }

    var body: some View {
        VStack(spacing: 24) {
            // Brand
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 42))
                    .foregroundColor(FeedsTheme.ai)
                Button {
                    if let url = URL(string: "https://feeds.bar") { NSWorkspace.shared.open(url) }
                } label: {
                    Text("feeds.bar")
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(FeedsTheme.primaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                Text("A signal layer for your desktop.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FeedsTheme.secondaryText)
                Text(versionString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText.opacity(0.7))
                    .padding(.top, 4)
            }
            .padding(.top, 28)

            // At-a-glance stats
            HStack(spacing: 20) {
                StatBlock(value: "\(store.feeds.count)", label: "FEEDS")
                    .help("Active feeds in your manifest")
                StatBlock(value: "\(store.orbs.count)",  label: "ORBS")
                    .help("Live signal orbs")
                StatBlock(value: "\(totalItems30d)",     label: "ITEMS · LAST 30 DAYS")
                    .help("Total items ingested across all feeds in the last 30 days")
            }
            .padding(.horizontal, 24)

            // Actions
            VStack(spacing: 10) {
                Button(action: { showFeedbackSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.fill")
                        Text("SEND FEEDBACK")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(FeedsTheme.ai)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    if let url = URL(string: "https://feeds.bar") { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("VISIT FEEDS.BAR")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(FeedsTheme.primaryText)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if let msg = feedbackToast {
                Text(msg)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(FeedsTheme.success)
                    .transition(.opacity)
            }

            Spacer()

            Text("Made with ♥ for curious desktops.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(FeedsTheme.secondaryText.opacity(0.6))
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showFeedbackSheet) {
            FeedbackSheet(
                appVersion: versionString,
                onSuccess: {
                    withAnimation { feedbackToast = "Thanks — your feedback has been sent." }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation { feedbackToast = nil }
                    }
                }
            )
        }
    }
}

// MARK: - Feedback sheet
private struct FeedbackSheet: View {
    let appVersion: String
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rating = 0
    @State private var comment = ""
    @State private var email = ""
    @State private var state: SubmitState = .idle
    @FocusState private var commentFocused: Bool

    private enum SubmitState: Equatable {
        case idle, submitting, failed(String)
    }

    private let api = FeedAPI()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("SEND FEEDBACK")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.ai)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FeedsTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            Text("How's it going?")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(FeedsTheme.primaryText)

            // Stars
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        rating = rating == n ? 0 : n
                    } label: {
                        Image(systemName: n <= rating ? "star.fill" : "star")
                            .font(.system(size: 22))
                            .foregroundColor(n <= rating ? FeedsTheme.utility : FeedsTheme.secondaryText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Comment
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT'S ON YOUR MIND?")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                TextEditor(text: $comment)
                    .font(.system(size: 13))
                    .foregroundColor(FeedsTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .background(FeedsTheme.inputBackground)
                    .cornerRadius(4)
                    .frame(height: 120)
                    .focused($commentFocused)
            }

            // Optional email
            VStack(alignment: .leading, spacing: 6) {
                Text("EMAIL (OPTIONAL — IF YOU'D LIKE A REPLY)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(FeedsTheme.inputBackground)
                    .cornerRadius(4)
                    .foregroundColor(FeedsTheme.primaryText)
            }

            // Error, if any
            if case let .failed(msg) = state {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.90, green: 0.32, blue: 0.32))
            }

            Spacer(minLength: 0)

            // Actions
            HStack {
                Spacer()
                Button("CANCEL") { dismiss() }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if state == .submitting {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(state == .submitting ? "SENDING…" : "SEND")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(canSubmit ? FeedsTheme.ai : FeedsTheme.ai.opacity(0.4))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || state == .submitting)
            }
        }
        .padding(24)
        .frame(width: 460, height: 480)
        .background(FeedsTheme.surface)
        .onAppear { commentFocused = true }
    }

    private var canSubmit: Bool {
        rating > 0 || !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        state = .submitting
        Task {
            do {
                try await api.sendFeedback(
                    rating: rating,
                    comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines),
                    appVersion: appVersion,
                    macos: ProcessInfo.processInfo.operatingSystemVersionString
                )
                await MainActor.run {
                    onSuccess()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    state = .failed("Couldn't send — please try again in a minute.")
                }
            }
        }
    }
}

private struct StatBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundColor(FeedsTheme.primaryText)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(FeedsTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(FeedsTheme.surface)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(FeedsTheme.divider.opacity(0.6), lineWidth: 1))
    }
}
