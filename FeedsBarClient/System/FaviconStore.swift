import SwiftUI
import Combine
import AppKit

@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()
    
    // We publish this ID to force views to redraw when a new icon arrives
    @Published var objectWillChange = ObservableObjectPublisher()
    
    private var images: [String: NSImage] = [:]
    private var activeRequests: Set<String> = []
    
    private init() {}
    
    /// Returns the image if cached, otherwise nil
    func image(for domain: String, size: Int) -> NSImage? {
        let key = cacheKey(domain: domain, size: size)
        return images[key]
    }
    
    /// Triggers a background fetch for the icon
    func load(domain: String, size: Int) {
        let key = cacheKey(domain: domain, size: size)
        
        // 1. If we have it, do nothing
        if images[key] != nil { return }
        
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
        self.images[key] = image
        self.activeRequests.remove(key)
        self.objectWillChange.send() // Notify UI to repaint
    }
    
    private func removeRequest(key: String) {
        self.activeRequests.remove(key)
    }
    
    private func cacheKey(domain: String, size: Int) -> String {
        "\(domain)_\(size)"
    }
}
