import SwiftUI

// MARK: - API MODELS
struct ManifestResponse: Codable {
    let topics: [Topic]
    let feedIndex: [FeedIndexItem]

    enum CodingKeys: String, CodingKey {
        case topics
        case feedIndex = "feed_index"
    }
}

struct Topic: Codable, Identifiable {
    let id: String
    let title: String
    let slug: String
    let orbColor: String?

    enum CodingKeys: String, CodingKey {
        case id = "topic_id"
        case title = "label"
        case slug
        case orbColor = "orb_color"
    }
}

struct FeedCategory: Codable, Hashable {
    let id: String?
    let name: String?
    let slug: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name
        case slug
        case sortOrder = "sort_order"
    }
}

struct FeedIndexItem: Codable, Identifiable {
    let id: String
    let title: String
    let url: String?
    let iconUrl: String?
    let isActive: Bool?
    let items30d: Int?
    let items1h: Int?
    let lastItemAt: Date?
    let status: String?
    let category: FeedCategory?

    enum CodingKeys: String, CodingKey {
        case id = "feed_id"
        case title
        case url
        case iconUrl = "icon_url"
        case isActive = "is_active"
        case items30d = "items_30d"
        case items1h = "items_1h"
        case lastItemAt = "last_item_at"
        case status
        case category
    }

    /// Health classification used by the Sources tab dot.
    enum Health {
        case flowing   // item arrived in the last 7 days
        case quiet     // active feed, nothing in 30 days
        case broken    // worker disabled it due to fatal errors
    }

    var health: Health {
        if (status ?? "").lowercased() == "broken" { return .broken }
        guard let last = lastItemAt else { return .quiet }
        return last > Date(timeIntervalSinceNow: -7 * 24 * 3600) ? .flowing : .quiet
    }

    /// Lowercase host without `www.`, best-effort.
    var domain: String? {
        guard let url, let host = URL(string: url)?.host else { return nil }
        return host.lowercased().replacingOccurrences(of: "www.", with: "")
    }
}

struct OrbsResponse: Codable {
    let orbs: [Orb]
}

struct ItemsBatchResponse: Codable {
    let items: [FeedItem]
}

struct Orb: Codable, Identifiable, Equatable {
    let id: String
    let topicLabel: String
    let sentiment: Sentiment?
    let keywords: [String]?
    let displayColor: String?
    let restingColor: String?

    struct Sentiment: Codable, Equatable {
        let score: Double?
        let label: String?
    }

    enum CodingKeys: String, CodingKey {
        case id = "topic_id"
        case topicLabel = "topic_label"
        case sentiment
        case keywords
        case displayColor = "display_color"
        case restingColor = "resting_color"
    }
}

struct FeedSource: Codable, Equatable {
    let id: String
    let title: String?
    let slug: String?

    enum CodingKeys: String, CodingKey {
        case id = "feed_id"
        case title
        case slug
    }
}

// MARK: - THE CORE ITEM
struct FeedItem: Codable, Identifiable, Equatable {
    let stableId: String
    let title: String
    let url: String?
    let publishedAt: Date?
    let source: FeedSource?
    let imageUrl: String?

    // We use stableId as the id for SwiftUI Identifiable conformance
    var id: String { stableId }

    enum CodingKeys: String, CodingKey {
        case stableId = "item_id"
        case title
        case url
        case publishedAt = "published_at"
        case source
        case imageUrl = "image_url"
    }

    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool {
        lhs.stableId == rhs.stableId
    }
}

// MARK: - ORB COLOR RESOLUTION
// Single source of truth used by both the ticker (SignalRotationOrb) and
// the settings orb strip (OrbPill). Precedence:
//   1) Server-supplied sentiment colour (display_color != resting_color) —
//      e.g. News Sentiment RYG. Server wins when it has live signal.
//   2) Client-side palette keyed by topic.slug. Kept in the design system so
//      a CDN-cached manifest can never drag the UI back to greys.
//   3) orbNeutral if the server at least sent a resting colour.
//   4) AI blue as a last-ditch fallback.
func resolveOrbColor(for orb: Orb, topics: [Topic]) -> Color {
    func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // 1) Sentiment-driven override from the server.
    if let display = nonEmpty(orb.displayColor),
       let resting = nonEmpty(orb.restingColor),
       display != resting {
        return Color(hex: display)
    }

    // 2) Client palette by slug.
    if let topic = topics.first(where: { $0.id == orb.id }),
       let paletteColor = FeedsTheme.orbPalette[topic.slug] {
        return paletteColor
    }

    // 3) Server signalled a (grey) resting colour — honour it as a neutral.
    if nonEmpty(orb.displayColor) != nil || nonEmpty(orb.restingColor) != nil {
        return FeedsTheme.orbNeutral
    }

    return FeedsTheme.ai
}

// MARK: - UI BRIDGE EXTENSIONS
extension FeedItem {
    // Computed property: No conflict with stored properties
    var sourceDomain: String {
        guard let urlStr = url, let host = URL(string: urlStr)?.host else { return "" }
        let cleanHost = host.lowercased().replacingOccurrences(of: "www.", with: "")
        return cleanHost
    }

    /// Display-safe title. The worker strips HTML on ingest, but we defend in
    /// depth in case a new malformed feed slips through before a redeploy.
    var displayTitle: String {
        var s = title
        // Strip any HTML tags (<a href=...>foo</a> → foo)
        if s.contains("<") {
            s = s.replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
        }
        // Decode the handful of entities most commonly seen in RSS titles.
        if s.contains("&") {
            let entities: [(String, String)] = [
                ("&amp;", "&"),
                ("&quot;", "\""),
                ("&apos;", "'"),
                ("&#39;", "'"),
                ("&lt;", "<"),
                ("&gt;", ">"),
                ("&nbsp;", " ")
            ]
            for (from, to) in entities {
                s = s.replacingOccurrences(of: from, with: to)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var signalLabelWithDate: String {
        let base = source?.title ?? sourceDomain.components(separatedBy: ".").first ?? "SIGNAL"
        let label = base.isEmpty ? "SIGNAL" : base

        guard let date = publishedAt else { return label.uppercased() }

        let cal = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let stamp: String
        if cal.isDateInToday(date) {
            stamp = timeFmt.string(from: date)
        } else {
            let dateFmt = DateFormatter()
            // "Apr 17" in most locales; drops year for recent items.
            dateFmt.setLocalizedDateFormatFromTemplate("MMM d")
            stamp = "\(dateFmt.string(from: date)) \(timeFmt.string(from: date))"
        }
        return "\(label.uppercased()) • \(stamp)"
    }
    
    var accentColor: Color {
        FeedsTheme.categoryColor(for: source?.title ?? "")
    }
}

// MARK: - THEME BASE
struct FeedsTheme {
    static let background = Color.black
    static let primaryText = Color.white
    // Lifted from Color.gray (~#8E8E93) to improve legibility on pure black.
    static let secondaryText = Color(white: 0.68)
    // Used for chrome icons (gear, chevron) — applied directly without .opacity().
    static let iconTint = Color(white: 0.78)
    static let ai = Color(red: 0.4, green: 0.6, blue: 1.0)
    static let utility = Color.orange
    static let divider = Color.white.opacity(0.1)
    // Brighter neutral used for orbs the server marks as "no sentiment"
    // (display_color == resting_color == #999999). Raw #999999 reads as dim on black.
    static let orbNeutral = Color(red: 0.74, green: 0.77, blue: 0.85)

    /// Per-topic orb colour, keyed by slug. Client-side so a CDN-cached manifest
    /// can't drag the UI back to greys. News Sentiment is intentionally absent —
    /// its colour comes from the server's sentiment signal (RYG).
    static let orbPalette: [String: Color] = [
        "ai-vibe":           Color(red: 0.608, green: 0.482, blue: 0.757), // #9B7BC1
        "business-beats":    Color(red: 0.353, green: 0.655, blue: 0.722), // #5AA7B8
        "future-signals":    Color(red: 0.839, green: 0.533, blue: 0.271), // #D68845
        "global-trends":     Color(red: 0.427, green: 0.667, blue: 0.471), // #6DAA78
        "sports-pulse":      Color(red: 0.788, green: 0.420, blue: 0.420), // #C96B6B
        "science-frontiers": Color(red: 0.416, green: 0.580, blue: 0.788)  // #6A94C9
    ]

    static func categoryColor(for name: String) -> Color {
        let n = name.lowercased()
        if n.contains("ai") || n.contains("research") { return ai }
        if n.contains("weather") || n.contains("local") { return utility }
        if n.contains("news") || n.contains("politic") { return newsHighContrast }
        if n.contains("sport") { return Color(red: 0.70, green: 0.56, blue: 0.95) }      // violet
        if n.contains("business") || n.contains("finance") || n.contains("market") {
            return Color(red: 0.31, green: 0.82, blue: 0.77)                              // teal
        }
        if n.contains("entertain") || n.contains("music") || n.contains("celeb") {
            return Color(red: 0.96, green: 0.45, blue: 0.72)                              // pink
        }
        return newsHighContrast
    }
}
