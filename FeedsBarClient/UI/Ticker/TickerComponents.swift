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
                    Button(action: { /* Open Settings logic */ }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(FeedsTheme.secondaryText.opacity(0.5))
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
                            .foregroundColor(FeedsTheme.secondaryText.opacity(0.9))
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
            
            HStack(spacing: 8) {
                // The Orb itself
                ZStack {
                    Circle().fill(orbColor(orb).opacity(0.25)).frame(width: orbSize * 1.4, height: orbSize * 1.4).blur(radius: 6)
                    Circle().fill(RadialGradient(gradient: Gradient(colors: [Color.white.opacity(0.6), orbColor(orb)]), center: .topLeading, startRadius: 1, endRadius: orbSize))
                        .frame(width: orbSize, height: orbSize).shadow(color: orbColor(orb).opacity(0.5), radius: 5)
                }
                
                if size != 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(orb.topicLabel.uppercased()).font(.system(size: 8, weight: .bold)).foregroundColor(FeedsTheme.secondaryText.opacity(0.7))
                        Text(orb.sentiment?.label?.uppercased() ?? "SCANNING...")
                            .font(.system(size: summaryFontSize, weight: .black, design: .monospaced))
                            .foregroundColor(orbColor(orb).opacity(0.9))
                            .fixedSize()
                    }
                    .frame(width: 110, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .onHover { hovered = $0 }
            .onReceive(timer) { _ in
                if !hovered { withAnimation { orbIndex += 1 } }
            }
        }
    }

    private func orbColor(_ orb: Orb) -> Color {
        let s = orb.sentiment?.score ?? 50
        if s > 60 { return FeedsTheme.success }
        if s < 40 { return .red }
        return FeedsTheme.utility
    }
    
    private var orbSize: CGFloat { size == 1 ? 10 : (size == 4 ? 20 : 14) }
    private var summaryFontSize: CGFloat { size == 4 ? 11 : 9 }
}

// MARK: - TICKER ANIMATION LAYER (BRIDGE)
struct TickerAnimationLayer: View {
    let store: FeedStore
    let tickerSize: Int
    @Binding var scrollSpeed: Double
    
    @StateObject private var engine = TickerEngine()
    @StateObject private var scrollManager = ScrollManager()
    @State private var isDragging = false
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
            engine.configure(items: store.items, bufferSize: 15, spacing: 60, speed: scrollSpeed)
            engine.start()
            scrollManager.onScroll = { engine.manualScroll(delta: $0) }
            scrollManager.startMonitor()
        }
        .onDisappear { engine.stop(); scrollManager.stopMonitor() }
        .onChange(of: store.items) { _, newItems in
            engine.configure(items: newItems, bufferSize: 15, spacing: 60, speed: scrollSpeed)
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

            VStack(alignment: .leading, spacing: 2) {
                Text(item.signalLabelWithDate)
                    .font(.system(size: labelFontSize(size), weight: .black, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(item.accentColor.opacity(0.15)))
                    .foregroundColor(item.accentColor)
                    .fixedSize()

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
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
            if let urlStr = item.url, let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
        }
    }

    private func mainFontSize(_ size: Int) -> CGFloat { size == 1 ? 15 : (size == 4 ? 30 : 22) }
    private func labelFontSize(_ size: Int) -> CGFloat { size == 1 ? 9 : (size == 4 ? 13 : 10) }
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
