import SwiftUI
import Combine

struct SignalClusterView: View {
    let store: FeedStore
    let size: Int
    
    @State private var orbIndex = 0
    let timer = Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 16) {
            // 1. WEATHER (Pinned to the far left)
            if let weather = store.currentWeather {
                HStack(spacing: 8) {
                    Image(systemName: weather.icon)
                        .font(.system(size: iconSize))
                        .foregroundColor(FeedsTheme.utility)
                    
                    VStack(alignment: .leading, spacing: -2) {
                        Text("LOCAL")
                            .font(.system(size: labelSize, weight: .black))
                            .foregroundColor(FeedsTheme.utility)
                        Text(weather.temp)
                            .font(.system(size: valueSize, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }

            Divider()
                .frame(height: 14)
                .background(FeedsTheme.divider)

            // 2. ORB (The Pulsing Sentiment)
            if !store.orbs.isEmpty {
                let orb = store.orbs[orbIndex % store.orbs.count]
                
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(sentimentColor(orb).opacity(0.3))
                            .frame(width: orbSize * 1.5, height: orbSize * 1.5)
                            .blur(radius: 4)
                        Circle()
                            .fill(sentimentColor(orb))
                            .frame(width: orbSize, height: orbSize)
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(orb.topicLabel.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(FeedsTheme.secondaryText)
                        Text(orb.sentiment?.label?.uppercased() ?? "SCANNING...")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(sentimentColor(orb))
                    }
                }
                .onReceive(timer) { _ in
                    withAnimation { orbIndex += 1 }
                }
            }
        }
        .padding(.leading, 15)
    }

    // Dynamic Sizing
    private var iconSize: CGFloat { size == 1 ? 12 : (size == 4 ? 22 : 16) }
    private var labelSize: CGFloat { size == 1 ? 7 : (size == 4 ? 11 : 9) }
    private var valueSize: CGFloat { size == 1 ? 12 : (size == 4 ? 24 : 16) }
    private var orbSize: CGFloat { size == 1 ? 8 : (size == 4 ? 16 : 12) }

    private func sentimentColor(_ orb: Orb) -> Color {
        let s = orb.sentiment?.score ?? 50
        return s > 60 ? FeedsTheme.success : (s < 40 ? .red : FeedsTheme.utility)
    }
}
