import SwiftUI
import Combine // ✅ Fixes 'autoconnect' error

struct LoadingSplashView: View {
    let size: Int // 1=Compact, 2=Standard, 4=Large
    
    @State private var thought = ""
    @State private var opacity = 0.2
    
    // Cycle text every 2.5 seconds
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            FeedsTheme.background.ignoresSafeArea()
            
            HStack(spacing: 12) {
                // 1. Pulsing Orb
                Circle()
                    .fill(FeedsTheme.ai)
                    .frame(width: orbSize, height: orbSize)
                    .opacity(opacity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            opacity = 1.0
                        }
                    }
                
                // 2. Cryptic Loading Text
                Text(thought)
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .contentTransition(.numericText())
                    .animation(.default, value: thought)
            }
        }
        .onAppear {
            thought = SplashContentProvider.randomThought()
        }
        .onReceive(timer) { _ in
            thought = SplashContentProvider.randomThought()
        }
    }
    
    // Dynamic Sizing
    private var orbSize: CGFloat { size == 1 ? 8 : (size == 4 ? 18 : 10) }
    private var fontSize: CGFloat { size == 1 ? 10 : (size == 4 ? 18 : 13) }
}

// MARK: - CONTENT PROVIDER (Restored)

struct SplashContentProvider {
    static let phrases = [
        "CALIBRATING SIGNAL...",
        "INDEXING WORLD...",
        "SYNCING ORBS...",
        "DETECTING PULSE...",
        "ALIGNING FEEDS...",
        "READING CURRENTS...",
        "FETCHING TRUTH...",
        "OBSERVING...",
        "CONNECTING...",
        "TUNING NOISE..."
    ]
    
    static func randomThought() -> String {
        phrases.randomElement() ?? "LOADING..."
    }
}
