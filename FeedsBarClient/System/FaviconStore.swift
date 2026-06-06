import SwiftUI
import Combine
import AppKit

@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    // Bounded icon cache. FeedsBar runs for long, uninterrupted sessions, so a
    // plain [key: NSImage] dictionary grows without limit as the user browses
    // feeds. NSCache caps both the entry count and the byte footprint and
    // evicts automatically under memory pressure.
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // ~50MB
        return cache
    }()
    private var activeRequests: Set<String> = []

    private init() {}

    /// Returns the image if cached, otherwise nil
    func image(for domain: String, size: Int) -> NSImage? {
        let key = cacheKey(domain: domain, size: size)
        return images.object(forKey: key as NSString)
    }

    /// Triggers a background fetch for the icon
    func load(domain: String, size: Int) {
        let key = cacheKey(domain: domain, size: size)

        // 1. If we have it, do nothing
        if images.object(forKey: key as NSString) != nil { return }

        // 2. If we are already fetching it, do nothing
        if activeRequests.contains(key) { return }
        activeRequests.insert(key)

        // 3. Fetch from Google Favicon API
        // This API is highly reliable and free
        let urlStr = "https://www.google.com/s2/favicons?domain=\(domain)&sz=\(size)"
        guard let url = URL(string: urlStr) else { return }

        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 100_000_000) // Tiny throttle

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    await self.cacheImage(key: key, image: image)
                }
            } catch {
                // Silently fail, we'll just show the placeholder
                await self.removeRequest(key: key)
            }
        }
    }

    private func cacheImage(key: String, image: NSImage) {
        self.images.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        self.activeRequests.remove(key)
        self.objectWillChange.send() // Notify UI to repaint
    }

    private func removeRequest(key: String) {
        self.activeRequests.remove(key)
    }

    private func cacheKey(domain: String, size: Int) -> String {
        "\(domain)_\(size)"
    }

    /// Approximate decoded byte size, used to drive NSCache's totalCostLimit.
    private static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        let bytes = rep.pixelsWide * rep.pixelsHigh * 4
        return bytes > 0 ? bytes : 1
    }
}
