import SwiftUI
import AppKit

// MARK: - THEME EXTENSIONS
extension FeedsTheme {
    static let surface = Color(hex: "16181D")
    static let inputBackground = Color(hex: "000000").opacity(0.4)
    static let success = Color(hex: "34C759")
    static let newsHighContrast = Color(hex: "7E8BA8")
}

// MARK: - HEX INITIALIZER (Master Copy)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - WINDOW ACCESSOR
struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.callback(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - TOGGLE STYLES
struct SignalSwitchStyle: ToggleStyle {
    var onColor: Color = FeedsTheme.ai
    var offColor: Color = Color.white.opacity(0.15)
    var knobColor: Color = .white
    var width: CGFloat = 36
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? onColor : offColor).frame(width: width, height: height)
                Circle().fill(knobColor).frame(width: height - 4, height: height - 4).padding(2)
            }
        }.buttonStyle(.plain)
    }
}
