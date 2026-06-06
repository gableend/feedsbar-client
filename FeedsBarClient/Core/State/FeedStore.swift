import SwiftUI
import Observation
import Combine
import Network
import OSLog

private let log = Logger(subsystem: "bar.feeds.client", category: "feedstore")

@Observable
@MainActor
final class FeedStore {
    
    // MARK: - Models
    
    struct WeatherInfo: Sendable {
        let temp: String
        let condition: String
        let icon: String // SF Symbol
    }
    
    enum AppPhase {
        case booting
        case running
        case error(String)
    }

    // MARK: - State
    
    var phase: AppPhase = .booting
    var statusMessage: String = "Initializing..."
    var lastUpdated: Date?

    /// Reachability, for calm offline degradation. We keep painting the last
    /// cached ticker and show a quiet indicator rather than an alarm when the
    /// network drops. Updated off a background NWPathMonitor.
    var isOnline: Bool = true

    /// Focus mode: when set, the ticker is pinned to this topic's items. Toggled
    /// by tapping the rotating orb; cleared by tapping it again or the chip.
    var focusedTopicID: String?

    // Source of Truth
    var topics: [Topic] = []
    var orbs: [Orb] = []
    var items: [FeedItem] = []
    var feeds: [FeedIndexItem] = []
    var currentWeather: WeatherInfo?

    // MARK: - Private Properties

    private let api = FeedAPI()
    private var heartbeatTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "bar.feeds.client.pathmonitor")

    // MARK: - Focus Mode

    /// The orb currently focused, if any.
    var focusedOrb: Orb? {
        guard let id = focusedTopicID else { return nil }
        return orbs.first { $0.id == id }
    }

    /// Toggle focus for a topic — tapping the same orb again exits focus.
    func toggleFocus(_ topicID: String) {
        focusedTopicID = (focusedTopicID == topicID) ? nil : topicID
    }

    func clearFocus() { focusedTopicID = nil }

    // MARK: - Connectivity

    private func startConnectivityMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                // Reconnected after a drop — refresh now instead of waiting out
                // the 5-minute heartbeat.
                if online && wasOffline {
                    await self.refreshAll()
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    /// Calm wording for the empty-state error: only call it "Connection Failed"
    /// when we're actually online (a server problem); say "Offline" otherwise.
    private var connectionFailureMessage: String {
        isOnline ? "Connection Failed. Retrying…" : "Offline — reconnecting…"
    }

    /// Short "updated 3m ago" string for the offline indicator. Nil until the
    /// first successful (or cached) load.
    var relativeLastUpdated: String? {
        guard let lastUpdated else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: lastUpdated, relativeTo: Date())
    }

    // MARK: - Feed Enable/Disable

    /// Hard cap on how many feeds actually drive the ticker. The items-batch
    /// endpoint accepts at most this many feed_ids per request; beyond it we
    /// silently take the first N. Surfaced in the Sources tab so enabling more
    /// than this doesn't read as a "my feed isn't showing up" bug.
    static let activeFeedCap = 20

    /// Feeds the user has enabled (active and not disabled). May exceed
    /// `activeFeedCap`, in which case only the first `activeFeedCap` reach the
    /// ticker — see `isOverFeedCap`.
    var enabledFeedCount: Int {
        let disabled = disabledIDs
        return feeds.filter { ($0.isActive ?? true) && !disabled.contains($0.id) }.count
    }

    /// True when more feeds are enabled than the ticker will pull from.
    var isOverFeedCap: Bool { enabledFeedCount > FeedStore.activeFeedCap }

    /// The feed IDs actually sent to the items-batch endpoint: active + enabled,
    /// capped to `activeFeedCap`, in manifest order. Single source of truth for
    /// the fetch *and* the debug screen, so "what the ticker pulls" can never
    /// drift from what we request.
    var activeFeedIDsForBatch: [String] {
        let disabled = disabledIDs
        return feeds
            .filter { ($0.isActive ?? true) && !disabled.contains($0.id) }
            .prefix(FeedStore.activeFeedCap)
            .map { $0.id }
    }

    // Stored property so @Observable tracks reads and any view computing
    // `isFeedEnabled(id)` re-renders the instant this Set changes.
    // Mirrored to UserDefaults on every write for persistence.
    private static let disabledIDsKey = "disabledFeedIDs"
    private(set) var disabledIDs: Set<String> = {
        let raw = UserDefaults.standard.string(forKey: "disabledFeedIDs") ?? ""
        return Set(raw.split(separator: ",").map(String.init))
    }()

    private func writeDisabledIDs() {
        UserDefaults.standard.set(
            disabledIDs.sorted().joined(separator: ","),
            forKey: FeedStore.disabledIDsKey
        )
    }

    func isFeedEnabled(_ id: String) -> Bool {
        !disabledIDs.contains(id)
    }

    func toggleFeed(_ id: String) {
        if disabledIDs.contains(id) { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        setActiveCuratedID(nil)
        writeDisabledIDs()
        eagerClearItemsIfNoneActive()
        scheduleDebouncedRefresh()
    }

    /// Batch enable/disable — avoids triggering a refresh per feed when the
    /// Sources tab flips a whole category on or off.
    func setFeedsEnabled(_ ids: [String], enabled: Bool) {
        guard !ids.isEmpty else { return }
        if enabled {
            for id in ids { disabledIDs.remove(id) }
        } else {
            for id in ids { disabledIDs.insert(id) }
        }
        setActiveCuratedID(nil)
        writeDisabledIDs()
        eagerClearItemsIfNoneActive()
        scheduleDebouncedRefresh()
    }

    /// When the enabled-feed set becomes empty, don't wait for the 300ms
    /// debounce + network round-trip to clear the ticker — do it synchronously
    /// so the UI reflects the user's intent instantly. Previously, items
    /// would keep cycling until refreshItemsOnly fired and set self.items=[],
    /// which read as "residual feeds in the ticker" when toggling through
    /// source types manually.
    private func eagerClearItemsIfNoneActive() {
        let disabled = self.disabledIDs
        let anyActive = self.feeds.contains { f in
            (f.isActive ?? true) && !disabled.contains(f.id)
        }
        if !anyActive {
            self.items = []
            self.statusMessage = "No active feeds"
        }
    }

    /// Replace the enabled set with exactly the given feed IDs. Everything
    /// else is disabled. Single disk write + single debounced refresh.
    /// Used by the Curated tab when activating a bundle.
    ///
    /// `curatedID` lets dynamic bundles (e.g. "pulse") tell refreshItemsOnly
    /// to pass a recency window to the server so the ticker only shows
    /// fresh items, not whatever happens to be latest-per-feed.
    func applyCuratedSet(_ ids: [String], curatedID: String? = nil) {
        guard !feeds.isEmpty else { return }
        let keep = Set(ids)
        var next = Set<String>()
        for f in feeds where !keep.contains(f.id) { next.insert(f.id) }
        disabledIDs = next
        setActiveCuratedID(curatedID)
        writeDisabledIDs()
        scheduleDebouncedRefresh()
    }

    /// Which curated bundle (if any) the user most recently activated.
    /// Persisted to UserDefaults alongside `disabledIDs` so dynamic bundles
    /// (Pulse) keep their recency-filter behaviour across sessions, not just
    /// the enabled feed set. Cleared on any manual toggle.
    private static let activeCuratedIDKey = "activeCuratedID"
    private(set) var activeCuratedID: String? = {
        let raw = UserDefaults.standard.string(forKey: activeCuratedIDKey) ?? ""
        return raw.isEmpty ? nil : raw
    }()

    private func setActiveCuratedID(_ id: String?) {
        activeCuratedID = id
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: FeedStore.activeCuratedIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FeedStore.activeCuratedIDKey)
        }
    }

    /// Debounce refreshes triggered by user toggling feeds. A burst of
    /// toggles (e.g. Enable All, or per-category switch) collapses into a
    /// single network round-trip rather than racing with each other.
    private var pendingRefreshTask: Task<Void, Never>?
    private func scheduleDebouncedRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // Toggling feeds only affects the items batch — skip the manifest
            // and orbs round-trips so the ticker snaps back in ~1 network hop
            // instead of waiting on three serialised fetches.
            await self?.refreshItemsOnly()
        }
    }
    
    // MARK: - Persistence
    // Snapshot of the last successful refresh so a cold launch can render
    // immediately from cache while the network fetch runs in the background.
    private struct CachedSnapshot: Codable {
        var topics: [Topic]
        var feeds: [FeedIndexItem]
        var orbs: [Orb]
        var items: [FeedItem]
        var cachedAt: Date
    }
    // v2 keeps the shape identical to v1 but rotates the storage key so a
    // snapshot persisted before keyword_urls shipped doesn't re-hydrate on
    // launch with stale Orb objects. Switching keys forces one network
    // round-trip of fresh data on the next cold launch, after which the new
    // snapshot carries the richer shape and everything steady-states.
    // v3 rotates the key for the Orb shape change (velocity / volume / top_items
    // added) — forces one fresh fetch so the cache carries the richer orbs.
    private let cacheKey = "feedstore.snapshot.v3"

    private func hydrateFromCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(CachedSnapshot.self, from: data) else { return }
        self.topics = snap.topics
        self.feeds = snap.feeds
        self.orbs = snap.orbs
        self.items = snap.items
        self.lastUpdated = snap.cachedAt
        if !snap.items.isEmpty {
            self.phase = .running
            self.statusMessage = "Live"
        }
    }

    private func persistSnapshot() {
        // Build the snapshot from main-actor state, then hand the JSON encode +
        // UserDefaults write to a background task. This runs on every 5-minute
        // heartbeat with a payload of tens of KB; doing it inline blocks the
        // main actor and contributes to the periodic UI hitches.
        let snap = CachedSnapshot(
            topics: self.topics,
            feeds: self.feeds,
            orbs: self.orbs,
            items: self.items,
            cachedAt: Date()
        )
        let key = cacheKey
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snap) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    // MARK: - Lifecycle

    func boot() {
        guard heartbeatTask == nil else { return }

        // 0. Paint immediately from the last cache so the user never sees
        //    an empty ticker on cold launch.
        hydrateFromCache()

        // Watch reachability so we can degrade calmly offline and snap back
        // the moment the connection returns.
        startConnectivityMonitor()

        heartbeatTask = Task {
            if items.isEmpty {
                statusMessage = "Connecting to Signal Layer..."
            }

            // 1. Initial fresh fetch
            await refreshAll()

            // 2. Heartbeat loop (every 5 minutes)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                await refreshAll()
            }
        }
    }
    
    // MARK: - Orchestration
    
    /// Parallel fetch of all signals (Manifest, Orbs, Weather, and Items).
    /// Each section handles its own 304 independently so a toggled feed still
    /// triggers a fresh items batch even when the manifest is unchanged.
    func refreshAll() async {
        async let manifestReq = api.getManifest()
        async let orbsReq = api.getOrbs()
        async let weatherReq = fetchWeather()

        // 1) Manifest: update topics/feeds when changed, fall back to cached
        //    self.feeds on 304 (so the items batch below still runs with the
        //    current toggle state).
        do {
            let manifest = try await manifestReq
            self.topics = manifest.topics
            self.feeds = manifest.feedIndex
        } catch let e as URLError where e.code == .cancelled {
            // 304 — keep existing self.topics / self.feeds
        } catch {
            log.error("manifest fetch failed: \(String(describing: error), privacy: .public)")
            if items.isEmpty {
                self.phase = .error(connectionFailureMessage)
                return
            }
        }

        // 2) Items batch — key is derived from the current enabled-feed set.
        //    Toggling a feed changes the URL → new ETag key → fresh response.
        let activeFeedIDs = self.activeFeedIDsForBatch

        do {
            if activeFeedIDs.isEmpty {
                self.items = []
                self.phase = .running
                self.statusMessage = "No active feeds found"
            } else {
                let sinceMinutes: Int? = activeCuratedID == "pulse" ? 120 : nil
                let batch = try await api.getBatchItems(
                    feedIDs: Array(activeFeedIDs),
                    sinceMinutes: sinceMinutes
                )
                // Keep server order (newest-first) at the store layer; the
                // ticker applies the user's feedMix preference on render.
                self.items = batch.items
                self.lastUpdated = Date()
                self.phase = .running
                self.statusMessage = "Live"
            }
        } catch let e as URLError where e.code == .cancelled {
            // 304 — items unchanged for this exact enabled set, keep them.
            self.phase = .running
            self.statusMessage = "Live"
        } catch {
            log.error("items fetch failed: \(String(describing: error), privacy: .public)")
            if items.isEmpty {
                self.phase = .error(connectionFailureMessage)
            }
        }

        // 3) Orbs — background, ticker is already live by this point.
        do {
            let fetchedOrbs = try await orbsReq
            self.orbs = fetchedOrbs.orbs
        } catch let e as URLError where e.code == .cancelled {
            // 304 — keep cached
        } catch {
            log.error("orbs fetch failed: \(String(describing: error), privacy: .public)")
        }

        // 4) Weather (mocked today)
        self.currentWeather = (try? await weatherReq) ?? self.currentWeather

        // Persist so the next cold launch starts populated.
        persistSnapshot()
    }
    
    /// Fast path for user-triggered toggles: only refetches the items batch
    /// using the current cached manifest. Avoids the manifest + orbs fetches
    /// that `refreshAll()` does on heartbeat.
    func refreshItemsOnly() async {
        let activeFeedIDs = self.activeFeedIDsForBatch

        // Dynamic curated sets (Pulse) want a tight recency window so the
        // ticker doesn't surface yesterday's items from feeds that happened
        // to make the cut based on a single fresh post.
        let sinceMinutes: Int? = activeCuratedID == "pulse" ? 120 : nil

        do {
            if activeFeedIDs.isEmpty {
                self.items = []
                self.phase = .running
                self.statusMessage = "No active feeds found"
            } else {
                let batch = try await api.getBatchItems(
                    feedIDs: Array(activeFeedIDs),
                    sinceMinutes: sinceMinutes
                )
                self.items = batch.items
                self.lastUpdated = Date()
                self.phase = .running
                self.statusMessage = "Live"
            }
        } catch let e as URLError where e.code == .cancelled {
            self.phase = .running
            self.statusMessage = "Live"
        } catch {
            log.error("items-only fetch failed: \(String(describing: error), privacy: .public)")
        }

        persistSnapshot()
    }

    // MARK: - Private Signal Fetchers
    
    private func fetchWeather() async throws -> WeatherInfo {
        // Mocking Dublin baseline for now.
        // Future: Integrate CoreLocation or a dedicated /v1_weather endpoint.
        return WeatherInfo(temp: "12°C", condition: "Cloudy", icon: "cloud.sun.fill")
    }
}

// MARK: - READ STORE
/// Tracks which items the user has opened, persisted so reads survive across
/// sessions. Kept separate from FeedStore (which churns its `items` on every
/// refresh) so read state outlives any single batch. Lives as a shared
/// ObservableObject — TickerRow observes it and dims read items in place
/// without forcing the marquee strip to rebuild (opacity doesn't change layout).
@MainActor
final class ReadStore: ObservableObject {
    static let shared = ReadStore()

    private static let key = "readItemIDs.v1"
    /// Bound the history so a long-running install doesn't grow UserDefaults
    /// without limit. Oldest reads fall off first.
    private static let cap = 5000

    // `order` is most-recent-last for FIFO trimming; `ids` mirrors it for O(1)
    // membership checks during render.
    private var order: [String]
    private var ids: Set<String>

    /// Bumped on every mutation so observers re-render. The id sets are private
    /// so views can't accidentally depend on their identity.
    @Published private(set) var revision = 0

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: ReadStore.key) ?? []
        order = saved
        ids = Set(saved)
    }

    var count: Int { ids.count }

    func isRead(_ id: String) -> Bool { ids.contains(id) }

    func markRead(_ id: String) {
        guard !id.isEmpty, !ids.contains(id) else { return }
        ids.insert(id)
        order.append(id)
        if order.count > ReadStore.cap {
            let overflow = order.count - ReadStore.cap
            for dropped in order.prefix(overflow) { ids.remove(dropped) }
            order.removeFirst(overflow)
        }
        persist()
        revision &+= 1
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        order.removeAll()
        persist()
        revision &+= 1
    }

    private func persist() {
        UserDefaults.standard.set(order, forKey: ReadStore.key)
    }
}

// MARK: - FILTER STORE
/// User keyword filters: muted phrases hide matching items from the ticker;
/// followed phrases pull matching items to the front. Persisted across
/// sessions. Shared ObservableObject so the ticker re-filters live and the
/// Settings UI and orb context menus stay in sync.
@MainActor
final class FilterStore: ObservableObject {
    static let shared = FilterStore()

    private static let mutedKey = "mutedPhrases.v1"
    private static let followedKey = "followedPhrases.v1"

    @Published private(set) var muted: [String]
    @Published private(set) var followed: [String]

    private init() {
        muted = UserDefaults.standard.stringArray(forKey: FilterStore.mutedKey) ?? []
        followed = UserDefaults.standard.stringArray(forKey: FilterStore.followedKey) ?? []
    }

    /// Lowercased views for substring matching against item titles.
    var mutedLowercased: [String] { muted.map { $0.lowercased() } }
    var followedLowercased: [String] { followed.map { $0.lowercased() } }

    func isMuted(_ phrase: String) -> Bool {
        muted.contains { $0.caseInsensitiveCompare(phrase) == .orderedSame }
    }

    func isFollowed(_ phrase: String) -> Bool {
        followed.contains { $0.caseInsensitiveCompare(phrase) == .orderedSame }
    }

    func addMuted(_ phrase: String) {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !isMuted(p) else { return }
        muted.append(p)
        // Muting a phrase you were following is contradictory — drop the follow.
        followed.removeAll { $0.caseInsensitiveCompare(p) == .orderedSame }
        persist()
    }

    func removeMuted(_ phrase: String) {
        muted.removeAll { $0.caseInsensitiveCompare(phrase) == .orderedSame }
        persist()
    }

    func toggleMuted(_ phrase: String) {
        isMuted(phrase) ? removeMuted(phrase) : addMuted(phrase)
    }

    func addFollowed(_ phrase: String) {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !isFollowed(p) else { return }
        followed.append(p)
        muted.removeAll { $0.caseInsensitiveCompare(p) == .orderedSame }
        persist()
    }

    func removeFollowed(_ phrase: String) {
        followed.removeAll { $0.caseInsensitiveCompare(phrase) == .orderedSame }
        persist()
    }

    func toggleFollowed(_ phrase: String) {
        isFollowed(phrase) ? removeFollowed(phrase) : addFollowed(phrase)
    }

    private func persist() {
        UserDefaults.standard.set(muted, forKey: FilterStore.mutedKey)
        UserDefaults.standard.set(followed, forKey: FilterStore.followedKey)
    }
}

