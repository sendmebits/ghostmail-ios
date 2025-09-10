import Foundation
import UIKit

final class IconCache {
    static let shared = IconCache()
    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDir: URL

    private init() {
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDir = caches.appendingPathComponent("website-icons", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } else {
            cacheDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("website-icons", isDirectory: true)
        }
    }

    private func filename(for host: String) -> String {
        // Keep filename filesystem-safe
        let safe = host.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return safe + ".ico"
    }

    private func fileURL(for host: String) -> URL {
        return cacheDir.appendingPathComponent(filename(for: host))
    }

    private func hostFromWebsite(_ website: String) -> String? {
        var candidate = website.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { return nil }
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard let url = URL(string: candidate), let host = url.host else {
            // As a last resort, try to strip path components
            if let first = candidate.split(separator: "/").first {
                return String(first)
            }
            return nil
        }
        return host
    }

    /// Returns a UIImage if available locally or downloaded from DuckDuckGo icons endpoint.
    /// Returns nil when no icon could be found.
    func image(for website: String) async -> UIImage? {
        guard let host = hostFromWebsite(website) else { return nil }

        if let cached = memoryCache.object(forKey: host as NSString) {
            return cached
        }

        let fileURL = fileURL(for: host)
        if fileManager.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
                memoryCache.setObject(img, forKey: host as NSString)
                return img
            } else {
                // Corrupt file, remove it
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // Attempt network fetchs in order: DuckDuckGo then Google Favicons
        let endpoints = [
            "https://icons.duckduckgo.com/ip3/\(host).ico",
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        ]

        for endpoint in endpoints {
            guard let iconURL = URL(string: endpoint) else { continue }
            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, let img = UIImage(data: data) {
                    memoryCache.setObject(img, forKey: host as NSString)
                    try? data.write(to: fileURL, options: .atomic)
                    return img
                }
            } catch {
                // Try next endpoint on error
                continue
            }
        }

        return nil
    }
}
