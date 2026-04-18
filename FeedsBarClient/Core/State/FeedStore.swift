import SwiftUI
import Observation
import Combine
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
    
    // Source of Truth
    var topics: [Topic] = []
    var orbs: [Orb] = []
    var items: [FeedItem] = []
    var feeds: [FeedIndexItem] = []
    var currentWeather: WeatherInfo?

    // MARK: - Private Properties

    private let api = FeedAPI()
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Feed Enable/Disable
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
        activeCuratedID = nil
        writeDisabledIDs()
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
        activeCuratedID = nil
        writeDisabledIDs()
        scheduleDebouncedRefresh()
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
        activeCuratedID = curatedID
        writeDisabledIDs()
        scheduleDebouncedRefresh()
    }

    /// Which curated bundle (if any) the user most recently activated. Nil
    /// after any manual toggle so the recency filter only applies when the
    /// enabled set is still curated.
    private(set) var activeCuratedID: String?

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
    private let cacheKey = "feedstore.snapshot.v1"

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
        let snap = CachedSnapshot(
            topics: self.topics,
            feeds: self.feeds,
            orbs: self.orbs,
            items: self.items,
            cachedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snap) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Lifecycle

    func boot() {
        guard heartbeatTask == nil else { return }

        // 0. Paint immediately from the last cache so the user never sees
        //    an empty ticker on cold launch.
        hydrateFromCache()

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
                self.phase = .error("Connection Failed. Retrying...")
                return
            }
        }

        // 2) Items batch — key is derived from the current enabled-feed set.
        //    Toggling a feed changes the URL → new ETag key → fresh response.
        let disabled = self.disabledIDs
        let activeFeedIDs = self.feeds
            .filter { ($0.isActive ?? true) && !disabled.contains($0.id) }
            .prefix(20)
            .map { $0.id }

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
                self.phase = .error("Connection Failed. Retrying...")
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
        let disabled = self.disabledIDs
        let activeFeedIDs = self.feeds
            .filter { ($0.isActive ?? true) && !disabled.contains($0.id) }
            .prefix(20)
            .map { $0.id }

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

