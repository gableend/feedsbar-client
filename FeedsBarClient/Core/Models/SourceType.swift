import SwiftUI

/// The kind of signal a feed represents. The server carries this through
/// the manifest + items_batch endpoints; the client uses it for per-type
/// icons, grouping in the Sources tab, and future per-type affordances.
///
/// `.rss` is the default when the server omits the field (old clients,
/// pre-migration payloads). Keep this enum's rawValues in lockstep with
/// the DB CHECK constraint on feeds.source_type.
enum SourceType: String, Codable, CaseIterable, Hashable {
    case rss
    case hackernews
    case github
    case substack
    case youtube
    case medium
    case reddit
    case podcast
    case newsapi

    var displayName: String {
        switch self {
        case .rss: return "RSS"
        case .hackernews: return "Hacker News"
        case .github: return "GitHub"
        case .substack: return "Substack"
        case .youtube: return "YouTube"
        case .medium: return "Medium"
        case .reddit: return "Reddit"
        case .podcast: return "Podcasts"
        case .newsapi: return "News APIs"
        }
    }

    /// SF Symbol used in the Sources tab overview and per-feed accents.
    var sfSymbol: String {
        switch self {
        case .rss: return "dot.radiowaves.left.and.right"
        case .hackernews: return "flame.fill"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .substack: return "envelope.fill"
        case .youtube: return "play.rectangle.fill"
        case .medium: return "doc.richtext"
        case .reddit: return "bubble.left.and.bubble.right.fill"
        case .podcast: return "mic.fill"
        case .newsapi: return "newspaper.fill"
        }
    }

    /// Tint colour for the Sources tab type card.
    var tint: Color {
        switch self {
        case .rss: return FeedsTheme.ai
        case .hackernews: return Color(red: 1.00, green: 0.40, blue: 0.00)      // HN orange
        case .github: return Color(white: 0.85)
        case .substack: return Color(red: 1.00, green: 0.42, blue: 0.25)        // Substack orange
        case .youtube: return Color(red: 1.00, green: 0.17, blue: 0.17)         // YT red
        case .medium: return Color(white: 0.95)
        case .reddit: return Color(red: 1.00, green: 0.27, blue: 0.00)          // reddit orange
        case .podcast: return Color(red: 0.60, green: 0.40, blue: 0.85)         // purple
        case .newsapi: return FeedsTheme.newsHighContrast
        }
    }

    /// Day-1 foundation only ships RSS ingestion end-to-end. Non-RSS types
    /// show as "Coming soon" placeholders in the Sources tab until feeds of
    /// that type are seeded server-side.
    var isIngestionReady: Bool {
        switch self {
        case .rss: return true
        default: return false
        }
    }
}
