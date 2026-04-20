import Foundation
import OSLog

private let log = Logger(subsystem: "bar.feeds.client", category: "feedapi")

actor FeedAPI {
    private let session: URLSession
    private let decoder: JSONDecoder
    
    // Pointing to your production Netlify functions.
    // Using the failable initialiser + explicit precondition so a typo
    // during maintenance crashes with a clear message rather than via
    // an implicit force-unwrap at module init time.
    private let baseURL: URL = {
        guard let url = URL(string: "https://feedsbar-edge-api.netlify.app/.netlify/functions/") else {
            preconditionFailure("FeedAPI baseURL is malformed")
        }
        return url
    }()
    
    // ETag Memory Cache: Path -> ETag String
    private var etagCache: [String: String] = [:]

    init() {
            let config = URLSessionConfiguration.default
            // We do our own ETag-based caching (etagCache + If-None-Match). Don't
            // let NSURLCache double-cache and keep serving stale payloads from disk
            // after the CDN has fresh data — bit us on the Topic.orb_color rollout.
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
            
            self.decoder = JSONDecoder()
            
            // ✅ Robust Date Strategy: Handles both "2023-10-27T10:00:00Z" and "2023-10-27T10:00:00.123Z"
            self.decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateStr = try container.decode(String.self)
                
                // 1. Try ISO8601 with fractional seconds (most common from Supabase)
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFormatter.date(from: dateStr) {
                    return date
                }
                
                // 2. Try ISO8601 without fractional seconds
                isoFormatter.formatOptions = [.withInternetDateTime]
                if let date = isoFormatter.date(from: dateStr) {
                    return date
                }
                
                // 3. Fallback for older formats
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                if let date = formatter.date(from: dateStr) {
                    return date
                }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(dateStr)")
            }
        }

    /// Generic fetch wrapper with ETag logic and transient-5xx retry.
    private func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }

        let maxAttempts = 3
        var lastStatus = 0
        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            if let cachedTag = etagCache[endpoint] {
                request.setValue(cachedTag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            // 304 Not Modified — pass-through "no change" signal
            if http.statusCode == 304 {
                throw URLError(.cancelled)
            }

            if (200...299).contains(http.statusCode) {
                // Decode FIRST, cache the ETag only on success. If we cache
                // the ETag before a failed decode, every subsequent request
                // sends If-None-Match, the server happily returns 304, and
                // the client keeps its stale cache forever — a single schema
                // mismatch becomes a permanent stuck state. Saw this happen
                // the day we shipped keyword_urls: one decode hiccup and
                // the orbs never refreshed until snapshot/v1 got wiped.
                let decoded = try decoder.decode(T.self, from: data)
                if let newTag = http.value(forHTTPHeaderField: "Etag") {
                    etagCache[endpoint] = newTag
                }
                return decoded
            }

            lastStatus = http.statusCode
            // Retry on 5xx; give up immediately on 4xx
            if http.statusCode >= 500 && attempt < maxAttempts {
                let delay = UInt64(300_000_000) * UInt64(attempt) // 0.3s, 0.6s
                try? await Task.sleep(nanoseconds: delay)
                continue
            }
            break
        }

        log.error("server error \(lastStatus, privacy: .public) for \(endpoint, privacy: .public) (after retries)")
        throw URLError(.badServerResponse)
    }

    // MARK: - Public Endpoints

    func getManifest() async throws -> ManifestResponse {
        return try await fetch("v1_manifest")
    }

    func getOrbs() async throws -> OrbsResponse {
        return try await fetch("v1_orbs")
    }
    
    func getBatchItems(
        feedIDs: [String],
        limitPerFeed: Int = 5,
        sinceMinutes: Int? = nil
    ) async throws -> ItemsBatchResponse {
        let ids = feedIDs.joined(separator: ",")
        guard let encodedIds = ids.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
             throw URLError(.badURL)
        }
        var path = "v1_items_batch?feed_ids=\(encodedIds)&limit_per_feed=\(limitPerFeed)"
        if let sinceMinutes, sinceMinutes > 0 {
            path += "&since_minutes=\(sinceMinutes)"
        }
        return try await fetch(path)
    }

    /// POST user feedback to the edge-api, which stashes it in Buttondown.
    /// Throws on any non-2xx so the UI can show an error state.
    func sendFeedback(rating: Int, comment: String, email: String?, appVersion: String?, macos: String?) async throws {
        guard let url = URL(string: "feedback", relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var payload: [String: Any] = ["rating": rating, "comment": comment]
        if let email, !email.isEmpty { payload["email"] = email }
        if let appVersion { payload["app_version"] = appVersion }
        if let macos { payload["macos"] = macos }
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
