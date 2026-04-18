import SwiftUI
import Combine

// MARK: - FIXED SIGNAL WIDGET
struct FixedBrandBlock: View {
    let store: FeedStore
    let size: Int
    @Binding var isMiniMode: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // THE MASK: Solid background color is vital to hide news scrolling behind
                FeedsTheme.background

                HStack(spacing: 8) {
                    // Settings Icon
                    Button(action: { SettingsWindowManager.shared.show(store: store) }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(FeedsTheme.iconTint)
                            .font(.system(size: settingsIconSize(size)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)

                    // Weather Utility
                    WeatherSegment(store: store, size: size)
                        .padding(.trailing, 4)
                    
                    // The Rotating Signal Orb
                    SignalRotationOrb(store: store, size: size)
                }
                .padding(.trailing, 15)
                .overlay(
                    Button(action: { withAnimation { isMiniMode.toggle() } }) {
                        Image(systemName: isMiniMode ? "chevron.right" : "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(FeedsTheme.iconTint)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    , alignment: .topTrailing
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            
            // Edge Shadow Gradient
            LinearGradient(
                gradient: Gradient(colors: [FeedsTheme.background, FeedsTheme.background.opacity(0)]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 30)
        }
    }
    
    private func settingsIconSize(_ size: Int) -> CGFloat { size == 1 ? 12 : (size == 4 ? 20 : 16) }
}

// MARK: - WEATHER SEGMENT
struct WeatherSegment: View {
    let store: FeedStore
    let size: Int
    @AppStorage("weatherCity") private var city = "Dublin"
    
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(FeedsTheme.utility).frame(width: dotSize(size), height: dotSize(size))
            VStack(alignment: .leading, spacing: -2) {
                Text(city.uppercased()).font(.system(size: cityLabelSize(size), weight: .black)).foregroundColor(FeedsTheme.utility)
                Text(store.currentWeather?.temp ?? "--°C").font(.system(size: tempValueSize(size), weight: .bold)).foregroundColor(.white)
            }.fixedSize()
        }
    }
    private func dotSize(_ size: Int) -> CGFloat { size == 1 ? 4 : (size == 4 ? 8 : 6) }
    private func cityLabelSize(_ size: Int) -> CGFloat { size == 1 ? 7 : (size == 4 ? 12 : 9) }
    private func tempValueSize(_ size: Int) -> CGFloat { size == 1 ? 13 : (size == 4 ? 26 : 18) }
}

// MARK: - ROTATING SIGNAL ORB
struct SignalRotationOrb: View {
    let store: FeedStore
    let size: Int

    @State private var orbIndex = 0
    @State private var hovered = false
    let timer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    var body: some View {
        if !store.orbs.isEmpty {
            let orb = store.orbs[orbIndex % store.orbs.count]
            let color = resolveOrbColor(for: orb, topics: store.topics)
            let words = Array((orb.keywords ?? []).prefix(3))

            HStack(spacing: 10) {
                // Glow dot — colored by API display_color/resting_color (sentiment cue).
                ZStack {
                    Circle()
                        .fill(color.opacity(0.3))
                        .frame(width: orbSize * 1.6, height: orbSize * 1.6)
                        .blur(radius: 5)
                    Circle()
                        .fill(color)
                        .frame(width: orbSize, height: orbSize)
                        .shadow(color: color.opacity(0.6), radius: 4)
                }

                if size != 1 {
                    VStack(alignment: .leading, spacing: -1) {
                        // Eyebrow: topic label
                        Text(orb.topicLabel.uppercased())
                            .font(.system(size: eyebrowFontSize, weight: .black))
                            .foregroundColor(color)
                            .padding(.bottom, 2)

                        // Three headline fragments stacked vertically. Each
                        // phrase is clickable when the server paired it with
                        // a representative article URL (v3+ orbs); earlier
                        // payloads fall back to plain text so mixed-version
                        // manifests keep working.
                        if words.isEmpty {
                            Text("SCANNING...")
                                .font(.system(size: keywordFontSize, weight: .bold, design: .monospaced))
                                .foregroundColor(FeedsTheme.secondaryText)
                        } else {
                            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                                OrbPhraseLabel(
                                    text: word.uppercased(),
                                    url: orb.url(forPhraseAt: idx),
                                    fontSize: keywordFontSize
                                )
                            }
                        }
                    }
                    .frame(width: 190, alignment: .leading)
                    .id(orb.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onHover { hovered = $0 }
            .onReceive(timer) { _ in
                if !hovered {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        orbIndex = (orbIndex + 1) % max(store.orbs.count, 1)
                    }
                }
            }
        }
    }

    private var orbSize: CGFloat { size == 1 ? 10 : (size == 4 ? 20 : 14) }
    private var eyebrowFontSize: CGFloat { size == 4 ? 11 : 9 }
    private var keywordFontSize: CGFloat { size == 4 ? 11 : 9 }
}

/// One line of the orb's stacked headline. When the server paired the phrase
/// with a representative article URL, render it as a button that opens the
/// article in the default browser; otherwise fall back to plain text so
/// pre-v3 snapshots and topics without a confident pick don't look inert
/// in a way that invites clicks that do nothing.
private struct OrbPhraseLabel: View {
    let text: String
    let url: URL?
    let fontSize: CGFloat
    @State private var hovered = false

    var body: some View {
        if let url {
            Button(action: {
                NSWorkspace.shared.open(url)
            }) {
                Text(text)
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .underline(hovered, color: .white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .pointerStyle(.link)
            .help(url.host.map { "Open on \($0)" } ?? "Open article")
        } else {
            Text(text)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

// MARK: - TICKER ANIMATION LAYER (BRIDGE)
struct TickerAnimationLayer: View {
    let store: FeedStore
    let tickerSize: Int
    @Binding var scrollSpeed: Double
    @AppStorage("feedMix") private var feedMix: String = "shuffle"  // "shuffle" | "latest"

    @StateObject private var engine = TickerEngine()
    @StateObject private var scrollManager = ScrollManager()
    @State private var isDragging = false
    @State private var lastDragTranslation: CGFloat = 0

    /// Items arranged per the user's feedMix preference.
    /// - shuffle: Fisher-Yates random interleave across feeds
    /// - latest: server order (newest-first per feed)
    private func ordered(_ items: [FeedItem]) -> [FeedItem] {
        feedMix == "latest" ? items : items.shuffled()
    }

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
                withAnimation(.easeOut(duration: 0.2)) { engine.setPaused(hovering || isDragging) }
            }
            .gesture(
                DragGesture().onChanged { value in
                    isDragging = true; engine.setPaused(true)
                    let delta = value.translation.width - lastDragTranslation
                    engine.manualScroll(delta: delta)
                    lastDragTranslation = value.translation.width
                }.onEnded { _ in
                    isDragging = false; lastDragTranslation = 0
                    engine.setPaused(scrollManager.isHovering)
                }
            )
        }
        .onAppear {
            engine.configure(items: ordered(store.items), bufferSize: 15, spacing: 60, speed: scrollSpeed)
            engine.start()
            scrollManager.onScroll = { engine.manualScroll(delta: $0) }
            scrollManager.startMonitor()
        }
        .onDisappear { engine.stop(); scrollManager.stopMonitor() }
        .onChange(of: store.items) { oldItems, newItems in
            // If the ID set hasn't changed, don't reset scroll position.
            let oldIds = Set(oldItems.map(\.id))
            let newIds = Set(newItems.map(\.id))
            if oldIds == newIds { return }
            engine.configure(items: ordered(newItems), bufferSize: 15, spacing: 60, speed: scrollSpeed)
        }
        .onChange(of: feedMix) { _, _ in
            // User toggled order mode — reshuffle immediately.
            engine.configure(items: ordered(store.items), bufferSize: 15, spacing: 60, speed: scrollSpeed)
        }
        .onChange(of: scrollSpeed) { _, newSpeed in
            engine.setSpeed(newSpeed)
        }
    }
}

// MARK: - TICKER ROW
struct TickerRow: View {
    let item: FeedItem
    let size: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            TickerIconView(item: item, size: size)

            if let urlStr = item.imageUrl, let url = URL(string: urlStr) {
                ArticleThumbnail(url: url, width: thumbWidth(size), height: thumbHeight(size))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.signalLabelWithDate)
                    .font(.system(size: labelFontSize(size), weight: .black, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(item.accentColor.opacity(0.15)))
                    .foregroundColor(item.accentColor)
                    .fixedSize()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.displayTitle)
                        .font(.system(size: mainFontSize(size), weight: .bold))
                        .foregroundColor(FeedsTheme.primaryText)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(item.sourceDomain)
                        .font(.system(size: mainFontSize(size) - 2, weight: .medium))
                        .foregroundColor(FeedsTheme.secondaryText)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Color.white.opacity(0.08) : Color.clear))
        .onHover { isHovered = $0 }
        .onTapGesture {
            // Only open http/https links. RSS titles are user-curated but the
            // urls are not — refuse file://, javascript:, etc. before handing
            // off to NSWorkspace.
            if let urlStr = item.url,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func mainFontSize(_ size: Int) -> CGFloat { size == 1 ? 15 : (size == 4 ? 30 : 22) }
    private func labelFontSize(_ size: Int) -> CGFloat { size == 1 ? 9 : (size == 4 ? 13 : 10) }
    private func thumbWidth(_ s: Int) -> CGFloat { s == 1 ? 40 : (s == 4 ? 80 : 56) }
    private func thumbHeight(_ s: Int) -> CGFloat { s == 1 ? 26 : (s == 4 ? 50 : 36) }
}

// MARK: - ARTICLE THUMBNAIL
struct ArticleThumbnail: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .cornerRadius(6)
            case .failure, .empty:
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: width, height: height)
            @unknown default:
                EmptyView()
            }
        }
    }
}

// MARK: - TICKER ICON
struct TickerIconView: View {
    let item: FeedItem
    let size: Int
    @ObservedObject private var faviconStore = FaviconStore.shared
    
    var body: some View {
        ZStack {
            if let img = faviconStore.image(for: item.sourceDomain, size: 128) {
                ZStack {
                    Circle().fill(Color.white).frame(width: iconSize + 6, height: iconSize + 6)
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).grayscale(1.0).frame(width: iconSize, height: iconSize).clipShape(Circle())
                }
            } else {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: iconSize + 8, height: iconSize + 8)
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: iconSize, weight: .semibold)).foregroundColor(item.accentColor)
                }.onAppear { faviconStore.load(domain: item.sourceDomain, size: 128) }
            }
        }.frame(width: boxSize, height: boxSize)
    }
    private var boxSize: CGFloat { size == 1 ? 28 : (size == 4 ? 54 : 40) }
    private var iconSize: CGFloat { size == 1 ? 16 : (size == 4 ? 32 : 24) }
}
