import SwiftUI
import Observation
import Combine

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
    var currentWeather: WeatherInfo?

    // MARK: - Private Properties
    
    private let api = FeedAPI()
    private var heartbeatTask: Task<Void, Never>?
    
    // MARK: - Lifecycle
    
    func boot() {
        guard heartbeatTask == nil else { return }
        
        heartbeatTask = Task {
            statusMessage = "Connecting to Signal Layer..."
            
            // 1. Initial immediate fetch
            await refreshAll()
            
            // 2. Heartbeat loop (every 5 minutes)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                await refreshAll()
            }
        }
    }
    
    // MARK: - Orchestration
    
    /// Parallel fetch of all signals (Manifest, Orbs, Weather, and Items)
    func refreshAll() async {
        do {
            // A. Trigger parallel fetches
            async let manifestReq = api.getManifest()
            async let orbsReq = api.getOrbs()
            async let weatherReq = fetchWeather()
            
            // B. Wait for structural data and weather
            let (manifest, orbsData, weather) = try await (manifestReq, orbsReq, weatherReq)
            
            // Update ambient state
            self.topics = manifest.topics
            self.orbs = orbsData.orbs
            self.currentWeather = weather
            
            // C. Fetch Ticker Items based on Manifest index
            let activeFeedIDs = manifest.feedIndex
                .filter { $0.isActive ?? true }
                .prefix(25)
                .map { $0.id }
            
            if !activeFeedIDs.isEmpty {
                let batch = try await api.getBatchItems(feedIDs: Array(activeFeedIDs))
                
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.items = batch.items
                    self.lastUpdated = Date()
                    self.phase = .running
                    self.statusMessage = "Live"
                }
            } else {
                self.phase = .running
                self.statusMessage = "No active feeds found"
            }
            
        } catch let error as URLError where error.code == .cancelled {
            // This is our ETag 304 signal
            print("FeedStore: Data is fresh (304).")
            self.statusMessage = "Live"
            
        } catch {
            print("FeedStore Error: \(error)")
            if items.isEmpty {
                self.phase = .error("Connection Failed. Retrying...")
            }
        }
    }
    
    // MARK: - Private Signal Fetchers
    
    private func fetchWeather() async throws -> WeatherInfo {
        // Mocking Dublin baseline for now.
        // Future: Integrate CoreLocation or a dedicated /v1_weather endpoint.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return WeatherInfo(temp: "12°C", condition: "Cloudy", icon: "cloud.sun.fill")
    }
}

// MARK: - UI Helpers

extension FeedItem {
    /// Extracts a clean domain string for the FaviconStore (e.g., "techcrunch.com")
    var sourceDomain: String? {
        guard let urlStr = self.url, let components = URLComponents(string: urlStr) else { return nil }
        return components.host?.replacingOccurrences(of: "www.", with: "")
    }
}
