import SwiftUI
import Combine

private extension View {
    @ViewBuilder
    func linkPointerCursor() -> some View {
        if #available(macOS 15.0, *) { self.pointerStyle(.link) } else { self }
    }
}

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
    @State private var pulse = false
    let timer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    var body: some View {
        if !store.orbs.isEmpty {
            // Focus pins the orb to the chosen topic; otherwise it auto-rotates.
            let activeOrb = store.focusedOrb ?? store.orbs[orbIndex % store.orbs.count]
            let isFocused = store.focusedOrb?.id == activeOrb.id
            let color = resolveOrbColor(for: activeOrb, topics: store.topics)
            let words = Array((activeOrb.keywords ?? []).prefix(3))
            let intensity = activeOrb.glowIntensity

            HStack(spacing: 10) {
                // Velocity-driven glow dot: brighter, larger, and faster-pulsing
                // when the topic is moving; calm and still when quiet. Also the
                // focus toggle — tap to pin the ticker to this topic.
                ZStack {
                    Circle()
                        .fill(color.opacity(0.25 + 0.35 * intensity))
                        .frame(width: orbSize * CGFloat(1.5 + 0.9 * intensity),
                               height: orbSize * CGFloat(1.5 + 0.9 * intensity))
                        .scaleEffect(pulse ? CGFloat(1.0 + 0.22 * intensity) : 1.0)
                        .blur(radius: CGFloat(5 + 6 * intensity))
                        .animation(
                            intensity > 0.15
                                ? .easeInOut(duration: max(0.8, 2.2 - 1.4 * intensity)).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Circle()
                        .fill(color)
                        .frame(width: orbSize, height: orbSize)
                        .shadow(color: color.opacity(0.6), radius: 4)
                    if isFocused {
                        Circle()
                            .stroke(color, lineWidth: 1.5)
                            .frame(width: orbSize * 2.0, height: orbSize * 2.0)
                    }
                }
                .frame(width: orbSize * 2.0, height: orbSize * 2.0)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleFocus(activeOrb.id) }
                .help(isFocused ? "Exit focus" : "Focus ticker on \(activeOrb.topicLabel)")

                if size != 1 {
                    VStack(alignment: .leading, spacing: -1) {
                        // Eyebrow: topic label (with a scope glyph while focused).
                        HStack(spacing: 4) {
                            if isFocused {
                                Image(systemName: "scope")
                                    .font(.system(size: eyebrowFontSize, weight: .bold))
                                    .foregroundColor(color)
                            }
                            Text(activeOrb.topicLabel.uppercased())
                                .font(.system(size: eyebrowFontSize, weight: .black))
                                .foregroundColor(color)
                        }
                        .padding(.bottom, 2)

                        // Three headline fragments stacked vertically. Each
                        // phrase is clickable when the server paired it with
                        // a representative article URL (v3+ orbs); earlier
                        // payloads fall back to plain text so mixed-version
                        // manifests keep working. Right-click a phrase to
                        // mute or follow it.
                        if words.isEmpty {
                            Text("SCANNING...")
                                .font(.system(size: keywordFontSize, weight: .bold, design: .monospaced))
                                .foregroundColor(FeedsTheme.secondaryText)
                        } else {
                            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                                OrbPhraseLabel(
                                    text: word.uppercased(),
                                    url: activeOrb.url(forPhraseAt: idx),
                                    fontSize: keywordFontSize
                                )
                                .contextMenu {
                                    Button(FilterStore.shared.isMuted(word) ? "Unmute “\(word)”" : "Mute “\(word)”") {
                                        FilterStore.shared.toggleMuted(word)
                                    }
                                    Button(FilterStore.shared.isFollowed(word) ? "Unfollow “\(word)”" : "Follow “\(word)”") {
                                        FilterStore.shared.toggleFollowed(word)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 190, alignment: .leading)
                    .id(activeOrb.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onAppear { pulse = true }
            .onHover { hovered = $0 }
            .onReceive(timer) { _ in
                // Pause auto-rotation while hovering or focused.
                if !hovered && store.focusedOrb == nil {
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
            .linkPointerCursor()
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
    @ObservedObject private var filters = FilterStore.shared

    /// The prepared strip handed to the marquee. Held in @State (not recomputed
    /// in `body`) so a `shuffle` ordering is stable across redraws and only
    /// re-rolls when an input actually changes — otherwise every SwiftUI update
    /// would re-shuffle and the strip would churn.
    @State private var displayItems: [FeedItem] = []

    /// Pure pipeline over the raw items (no store/observable access here, so it
    /// stays free of actor-isolation concerns — callers read the live state and
    /// pass it in):
    ///   1) focus mode — pin to the focused topic (server top_items ∪ keyword
    ///      matches against what we hold; never blanks the ticker)
    ///   2) mute — drop items matching any muted phrase
    ///   3) order — shuffle (Fisher-Yates) or latest (server order)
    ///   4) follow — stable-partition followed items to the front
    private func prepared(_ items: [FeedItem], focus: Orb?, muted: [String], followed: [String]) -> [FeedItem] {
        var result = items

        if let orb = focus {
            let ids = orb.topItemIDs
            let kws = orb.keywordSet
            let focused = result.filter { ids.contains($0.id) || $0.matchesAny(kws) }
            if !focused.isEmpty { result = focused }
        }

        if !muted.isEmpty {
            result = result.filter { !$0.matchesAny(muted) }
        }

        result = feedMix == "latest" ? result : result.shuffled()

        if !followed.isEmpty {
            let hits = result.filter { $0.matchesAny(followed) }
            let rest = result.filter { !$0.matchesAny(followed) }
            result = hits + rest
        }

        return result
    }

    var body: some View {
        // The scroll is driven entirely inside MarqueeTickerView by a CALayer
        // animation on the render server — no per-frame SwiftUI work here.
        MarqueeTickerView(items: displayItems, size: tickerSize, speed: scrollSpeed)
            .onAppear {
                if displayItems.isEmpty {
                    displayItems = prepared(store.items, focus: store.focusedOrb,
                                            muted: filters.mutedLowercased,
                                            followed: filters.followedLowercased)
                }
            }
            .onChange(of: store.items) { oldItems, newItems in
                // If the ID set hasn't changed, keep the current strip + scroll.
                if Set(oldItems.map(\.id)) == Set(newItems.map(\.id)) { return }
                displayItems = prepared(newItems, focus: store.focusedOrb,
                                        muted: filters.mutedLowercased,
                                        followed: filters.followedLowercased)
            }
            .onChange(of: feedMix) { _, _ in
                displayItems = prepared(store.items, focus: store.focusedOrb,
                                        muted: filters.mutedLowercased,
                                        followed: filters.followedLowercased)
            }
            .onChange(of: store.focusedTopicID) { _, _ in
                // Entering / leaving focus narrows or restores the strip.
                displayItems = prepared(store.items, focus: store.focusedOrb,
                                        muted: filters.mutedLowercased,
                                        followed: filters.followedLowercased)
            }
            .onChange(of: filters.muted) { _, _ in
                displayItems = prepared(store.items, focus: store.focusedOrb,
                                        muted: filters.mutedLowercased,
                                        followed: filters.followedLowercased)
            }
            .onChange(of: filters.followed) { _, _ in
                displayItems = prepared(store.items, focus: store.focusedOrb,
                                        muted: filters.mutedLowercased,
                                        followed: filters.followedLowercased)
            }
    }
}

// MARK: - TICKER ROW
struct TickerRow: View {
    let item: FeedItem
    let size: Int
    @State private var isHovered = false
    @ObservedObject private var readStore = ReadStore.shared
    @AppStorage("dimReadItems") private var dimReadItems = true

    /// Whether to fade this row because the user already opened it. Driven by
    /// the shared ReadStore so the dim applies in place (opacity only — no
    /// layout change) without forcing the marquee strip to rebuild.
    private var isRead: Bool { dimReadItems && readStore.isRead(item.id) }

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
        .opacity(isRead ? 0.45 : 1.0)
        .onHover { isHovered = $0 }
        .onTapGesture {
            // Only open http/https links. RSS titles are user-curated but the
            // urls are not — refuse file://, javascript:, etc. before handing
            // off to NSWorkspace.
            if let urlStr = item.url,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                // Mark read first so the row dims even if the open is slow.
                ReadStore.shared.markRead(item.id)
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

/// Process-wide, bounded thumbnail cache. SwiftUI's AsyncImage does not cache
/// across view instances, so in the recycling ticker every item that scrolls
/// back into view re-fetches its image from the network. A shared NSCache keyed
/// by URL serves the second-and-later appearances from memory.
private enum ThumbnailCache {
    static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 100 * 1024 * 1024 // ~100MB
        return cache
    }()
}

struct ArticleThumbnail: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: width, height: height)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let decoded = NSImage(data: data) else { return }
            ThumbnailCache.shared.setObject(decoded, forKey: url as NSURL, cost: data.count)
            image = decoded
        } catch {
            // Leave the placeholder in place on any failure.
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

// MARK: - STATUS CHIPS

/// Shown while focus mode is active. Tapping the ✕ exits focus.
struct FocusChip: View {
    let label: String
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope").font(.system(size: 9, weight: .bold))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .lineLimit(1)
            Button(action: onExit) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .help("Exit focus")
    }
}

/// Quiet offline indicator with a "last updated" stamp. Non-interactive.
struct OfflineChip: View {
    let relative: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash").font(.system(size: 9, weight: .bold))
            Text(relative.map { "Offline · \($0)" } ?? "Offline")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundColor(FeedsTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
