import Foundation

actor FeedAPI {
    private let session: URLSession
    private let decoder: JSONDecoder
    
    // Pointing to your production Netlify functions
    private let baseURL = URL(string: "https://feedsbar-edge-api.netlify.app/.netlify/functions/")!
    
    // ETag Memory Cache: Path -> ETag String
    private var etagCache: [String: String] = [:]

    init() {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
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

    /// Generic fetch wrapper that handles ETag logic
    private func fetch<T: Decodable>(_ endpoint: String) async throws -> T {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        
        // Inject ETag if we have one for this specific endpoint
        if let cachedTag = etagCache[endpoint] {
            request.setValue(cachedTag, forHTTPHeaderField: "If-None-Match")
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        // 304 Not Modified: Data hasn't changed.
        // We throw a specific error so the Store knows to do nothing.
        if http.statusCode == 304 {
            throw URLError(.cancelled) // Using .cancelled as "No Change" signal
        }
        
        guard (200...299).contains(http.statusCode) else {
            print("Server Error: \(http.statusCode) for \(endpoint)")
            throw URLError(.badServerResponse)
        }
        
        // Capture new ETag
        if let newTag = http.value(forHTTPHeaderField: "Etag") {
            etagCache[endpoint] = newTag
        }
        
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Public Endpoints

    func getManifest() async throws -> ManifestResponse {
        return try await fetch("v1_manifest")
    }

    func getOrbs() async throws -> OrbsResponse {
        return try await fetch("v1_orbs")
    }
    
    func getBatchItems(feedIDs: [String]) async throws -> ItemsBatchResponse {
        // Netlify functions might need comma-separated IDs
        let ids = feedIDs.joined(separator: ",")
        guard let encodedIds = ids.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
             throw URLError(.badURL)
        }
        return try await fetch("v1_items_batch?feed_ids=\(encodedIds)")
    }
}
