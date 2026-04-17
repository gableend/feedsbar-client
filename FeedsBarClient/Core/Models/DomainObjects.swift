import SwiftUI

// MARK: - API MODELS
struct FeedManifest: Codable {
    let topics: [Topic]
    let feedIndex: [FeedIndexItem]
}

struct Topic: Codable, Identifiable {
    let id: String
    let title: String
    let slug: String
}

struct FeedIndexItem: Codable, Identifiable {
    let id: String
    let title: String
    let isActive: Bool?
}

struct OrbResponse: Codable {
    let orbs: [Orb]
}

struct Orb: Codable, Identifiable, Equatable {
    let id: String
    let topicLabel: String
    let sentiment: Sentiment?
    
    struct Sentiment: Codable, Equatable {
        let score: Double?
        let label: String?
    }
}

struct FeedSource: Codable, Equatable {
    let id: String
    let title: String?
    let slug: String?
}

// MARK: - THE CORE ITEM
struct FeedItem: Codable, Identifiable, Equatable {
    let stableId: String
    let title: String
    let url: String?
    let publishedAt: Date?
    let source: FeedSource?
    
    // We use stableId as the id for SwiftUI Identifiable conformance
    var id: String { stableId }
    
    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool {
        lhs.stableId == rhs.stableId
    }
}

// MARK: - UI BRIDGE EXTENSIONS
extension FeedItem {
    // Computed property: No conflict with stored properties
    var sourceDomain: String {
        guard let urlStr = url, let host = URL(string: urlStr)?.host else { return "" }
        let cleanHost = host.lowercased().replacingOccurrences(of: "www.", with: "")
        return cleanHost
    }
    
    var signalLabelWithDate: String {
        // Fix: Use the computed sourceDomain string which is non-optional
        let base = source?.title ?? sourceDomain.components(separatedBy: ".").first ?? "SIGNAL"
        let label = base.isEmpty ? "SIGNAL" : base
        
        guard let date = publishedAt else { return label.uppercased() }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(label.uppercased()) • \(formatter.string(from: date))"
    }
    
    var accentColor: Color {
        FeedsTheme.categoryColor(for: source?.title ?? "")
    }
}

// MARK: - THEME BASE
struct FeedsTheme {
    static let background = Color.black
    static let primaryText = Color.white
    static let secondaryText = Color.gray
    static let ai = Color(red: 0.4, green: 0.6, blue: 1.0)
    static let utility = Color.orange
    static let divider = Color.white.opacity(0.1)
    
    static func categoryColor(for name: String) -> Color {
        let n = name.lowercased()
        if n.contains("ai") || n.contains("research") { return ai }
        if n.contains("weather") || n.contains("local") { return utility }
        return Color(white: 0.4)
    }
}
