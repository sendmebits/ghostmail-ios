import Foundation
import UIKit

final class IconCache {
    static let shared = IconCache()
    private let memoryCache = NSCache<NSString, UIImage>()
    // Cache for hosts that were checked and had no icon available
    private let negativeMemoryCache = NSCache<NSString, NSNumber>()
    private let transientFailureCache = NSCache<NSString, NSNumber>()
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let maxIconDownloadBytes = 1_000_000
    private let maxHTMLDownloadBytes = 2_000_000
    private let maxManifestDownloadBytes = 250_000
    private let rootRequestTimeout: TimeInterval = 8
    private let iconRequestTimeout: TimeInterval = 5
    private let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private let missingIconRetryInterval: TimeInterval = 7 * 24 * 60 * 60
    private let transientFailureRetryInterval: TimeInterval = 30 * 60
    private let missingMarkerVersion = "v4"

    private init() {
        // Configure memory cache limits to prevent unbounded growth
        memoryCache.countLimit = 200 // Max 200 icons in memory
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // ~50MB max
        
        negativeMemoryCache.countLimit = 500 // Can store more negative results (they're tiny)
        transientFailureCache.countLimit = 200
        
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDir = caches.appendingPathComponent("website-icons", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } else {
            cacheDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("website-icons", isDirectory: true)
        }

        // Apply NSFileProtectionComplete to the whole cache directory so that any
        // cached favicon files (which reveal the alias->website mapping) are
        // encrypted at rest while the device is locked.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: cacheDir.path
        )
    }

    /// Convenience: write data with `.completeFileProtection` set, so the file
    /// content is unreadable when the device is locked.
    private func writeProtected(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Fall back to a plain atomic write so a transient protection error
            // doesn't break favicon caching entirely.
            try? data.write(to: url, options: .atomic)
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

    private func missingFileURL(for host: String) -> URL {
        return cacheDir.appendingPathComponent(filename(for: host) + ".missing")
    }

    private func negativeCacheKey(for host: String) -> NSString {
        host as NSString
    }

    private func clearMissingState(for host: String, missingURL: URL) {
        try? fileManager.removeItem(at: missingURL)
        negativeMemoryCache.removeObject(forKey: negativeCacheKey(for: host))
    }

    private func writeMissingMarker(for host: String, to missingURL: URL) {
        let marker = "\(missingMarkerVersion)|\(Date().timeIntervalSince1970)"
        writeProtected(Data(marker.utf8), to: missingURL)
        negativeMemoryCache.setObject(NSNumber(value: true), forKey: negativeCacheKey(for: host))
    }

    private func missingMarkerCoversCurrentLookup(at missingURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: missingURL.path) else { return false }

        guard let data = try? Data(contentsOf: missingURL),
              let rawMarker = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        let parts = rawMarker.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0] == missingMarkerVersion,
              let timestamp = TimeInterval(parts[1]),
              Date().timeIntervalSince1970 - timestamp < missingIconRetryInterval else {
            // Older markers predate the stronger downloader and should not block a retry.
            return false
        }

        return true
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

    /// Returns a UIImage if available locally or downloaded from the website itself.
    /// Returns nil when no icon could be found.
    func image(for website: String) async -> UIImage? {
        guard let host = hostFromWebsite(website) else { return nil }
    // image(for:) starting for host

        if let cached = memoryCache.object(forKey: host as NSString) {
            // cache hit in-memory
            return cached
        }

        // Fast-path: if we previously determined this host has no icon, avoid network
        if negativeMemoryCache.object(forKey: negativeCacheKey(for: host)) != nil {
            // negative cache skip
            return nil
        }

        // Also check for a persisted "missing" marker on disk
        let missingURL = missingFileURL(for: host)
        if missingMarkerCoversCurrentLookup(at: missingURL) {
            negativeMemoryCache.setObject(NSNumber(value: true), forKey: negativeCacheKey(for: host))
            return nil
        }

        let fileURL = fileURL(for: host)
        if fileManager.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
                // loaded icon from disk
                memoryCache.setObject(img, forKey: host as NSString)
                return img
            } else {
                // Corrupt file, remove it
                // corrupt icon file removed
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // First, try to crawl the site for <link rel="..."> icons and /favicon.ico.
        do {
            // crawling site for icons
            if let (img, data) = try await fetchBestIconFromSite(host: host) {
                memoryCache.setObject(img, forKey: host as NSString)
                // Save the original downloaded data to preserve exact encoding
                writeProtected(data, to: fileURL)
                clearMissingState(for: host, missingURL: missingURL)
                // fetched icon via site crawl
                return img
            }

            // Fallback: if host doesn't start with www, try adding it.
            // Some sites (like brevo.com) don't serve favicons on the root domain and don't redirect correctly.
            if !host.lowercased().hasPrefix("www.") {
                let wwwHost = "www." + host
                if let (img, data) = try await fetchBestIconFromSite(host: wwwHost) {
                    memoryCache.setObject(img, forKey: host as NSString)
                    writeProtected(data, to: fileURL)
                    clearMissingState(for: host, missingURL: missingURL)
                    return img
                }
            }
        } catch {
            // ignore and fall back to other endpoints
            // site crawl failed
        }

        // No icon found: persist a small marker so we don't re-query repeatedly.
        writeMissingMarker(for: host, to: missingURL)

        return nil
    }

    /// Force a refresh for the given website: clear any cached state and attempt
    /// to re-download the icon from the website itself.
    /// This is useful for pull-to-refresh scenarios where the app should try
    /// to update a previously-missing or stale icon for a single host.
    func refreshImage(for website: String) async -> UIImage? {
        guard let host = hostFromWebsite(website) else { return nil }

    // Clear any in-memory caches and on-disk missing marker so we actually try
        memoryCache.removeObject(forKey: host as NSString)
        negativeMemoryCache.removeObject(forKey: negativeCacheKey(for: host))
        let fileURL = fileURL(for: host)
        let missingURL = missingFileURL(for: host)
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: missingURL)

        // First try crawling the site for link rel icons and /favicon.ico
        do {
            if let (img, data) = try await fetchBestIconFromSite(host: host) {
                memoryCache.setObject(img, forKey: host as NSString)
                // Save the original downloaded data to preserve exact encoding
                writeProtected(data, to: fileURL)
                clearMissingState(for: host, missingURL: missingURL)
                return img
            }

            // Fallback: try www. prefix
            if !host.lowercased().hasPrefix("www.") {
                let wwwHost = "www." + host
                if let (img, data) = try await fetchBestIconFromSite(host: wwwHost) {
                    memoryCache.setObject(img, forKey: host as NSString)
                    writeProtected(data, to: fileURL)
                    clearMissingState(for: host, missingURL: missingURL)
                    return img
                }
            }
        } catch {
            // ignore and fall back to other endpoints
        }

        // Still not found: write missing marker and set negative cache
        writeMissingMarker(for: host, to: missingURL)

        return nil
    }

    /// Decodes downloaded favicon bytes into a `UIImage`. Only raster formats
    /// are supported (PNG, JPEG, ICO, GIF, BMP). SVG favicons are intentionally
    /// NOT rendered: doing so previously routed arbitrary remote markup through
    /// `WKWebView`, which is too large an attack surface for a privacy-first
    /// app. A site whose only favicon is SVG simply gets no logo here.
    private func imageFromDownloadedData(_ data: Data, url: URL) -> UIImage? {
        guard data.count <= maxIconDownloadBytes else { return nil }
        return UIImage(data: data)
    }

    private func rootHTMLRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = rootRequestTimeout
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    private func iconRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = iconRequestTimeout
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    /// Perform a URLRequest using URLSession dataTask completion handler so the request
    /// isn't automatically cancelled when the calling Swift concurrency Task is cancelled.
    private func fetchDataIgnoringTaskCancellation(for request: URLRequest, maxBytes: Int? = nil) async throws -> (Data, URLResponse) {
        let maxResponseBytes = maxBytes ?? maxIconDownloadBytes
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let d = data, d.count <= maxResponseBytes, let r = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (d, r))
            }
            task.resume()
        }
    }

    /// Synchronous check to quickly determine whether we previously marked this host as missing.
    /// Useful for avoiding UI spinners when the icon is known to be absent.
    func hasMissingIcon(for website: String) -> Bool {
        guard let host = hostFromWebsite(website) else { return false }
        if negativeMemoryCache.object(forKey: negativeCacheKey(for: host)) != nil { return true }
        let missingURL = missingFileURL(for: host)
        if missingMarkerCoversCurrentLookup(at: missingURL) {
            negativeMemoryCache.setObject(NSNumber(value: true), forKey: negativeCacheKey(for: host))
            return true
        }
        return false
    }

    // MARK: - Site crawling for link rel icons

    /// Fetch predictable same-site icons first, then crawl root HTML for linked icons and manifests.
    /// Returns a tuple of (image, originalData) or nil. The originalData preserves the exact downloaded bytes.
    private func fetchBestIconFromSite(host: String) async throws -> (UIImage, Data)? {
        guard let baseURL = URL(string: "https://\(host)") else { return nil }

        var candidateURLs = commonIconPaths.compactMap {
            URL(string: $0, relativeTo: baseURL)?.absoluteURL
        }

        // Try simple same-site paths before crawling potentially slow or bot-protected pages.
        if let directIcon = await bestDownloadedIcon(from: candidateURLs) {
            return directIcon
        }
        candidateURLs = []

        var manifestURLs = commonManifestPaths.compactMap {
            URL(string: $0, relativeTo: baseURL)?.absoluteURL
        }
        var linkedIconURLs: [URL] = []

        do {
            let (data, response) = try await fetchDataIgnoringTaskCancellation(
                for: rootHTMLRequest(for: baseURL),
                maxBytes: maxHTMLDownloadBytes
            )
            if data.count <= maxHTMLDownloadBytes,
               let http = response as? HTTPURLResponse,
               (http.statusCode == 200 || http.statusCode == 206),
               let html = String(data: data, encoding: .utf8) {
                let documentURL = response.url ?? baseURL
                let links = parseIconLinks(from: html)
                for href in links {
                    if let url = URL(string: href, relativeTo: documentURL)?.absoluteURL {
                        linkedIconURLs.append(url)
                    }
                }

                let linkedManifestURLs = parseManifestLinks(from: html).compactMap {
                    URL(string: $0, relativeTo: documentURL)?.absoluteURL
                }
                manifestURLs = linkedManifestURLs + manifestURLs
                candidateURLs.append(contentsOf: commonIconPaths.compactMap {
                    URL(string: $0, relativeTo: documentURL)?.absoluteURL
                })
            }
        } catch {
            if isTimeoutLike(error) {
                manifestURLs = []
            }
            // Keep going: many sites serve /favicon.ico even when the root page is slow.
        }

        for manifestURL in deduplicated(manifestURLs) {
            candidateURLs.append(contentsOf: await iconURLsFromManifest(manifestURL))
        }

        candidateURLs.append(contentsOf: linkedIconURLs)

        return await bestDownloadedIcon(from: candidateURLs)
    }

    private var commonIconPaths: [String] {
        [
            "/favicon.ico",
            "/favicon.png",
            "/favicon-32x32.png",
            "/favicon-16x16.png",
            "/apple-touch-icon.png",
            "/apple-touch-icon-precomposed.png"
        ]
    }

    private var commonManifestPaths: [String] {
        [
            "/site.webmanifest",
            "/manifest.json"
        ]
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let absoluteString = url.absoluteString
            if seen.contains(absoluteString) { return false }
            seen.insert(absoluteString)
            return true
        }
    }

    private func bestDownloadedIcon(from urls: [URL]) async -> (UIImage, Data)? {
        var bestImage: UIImage?
        var bestData: Data?
        var bestScore = 0
        var timedOutHosts = Set<String>()

        for url in deduplicated(urls) {
            if let host = url.host, timedOutHosts.contains(host) || shouldSkipTransientFailure(for: host) {
                continue
            }

            do {
                let (data, response) = try await fetchDataIgnoringTaskCancellation(
                    for: iconRequest(for: url),
                    maxBytes: maxIconDownloadBytes
                )
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let image = imageFromDownloadedData(data, url: url) else {
                    continue
                }

                let score = Int(image.size.width * image.size.height)
                if score > bestScore {
                    bestScore = score
                    bestImage = image
                    bestData = data
                }
            } catch {
                if isTimeoutLike(error), let host = url.host {
                    timedOutHosts.insert(host)
                    markTransientFailure(for: host)
                }
                continue
            }
        }

        if let bestImage, let bestData {
            return (bestImage, bestData)
        }

        return nil
    }

    private func shouldSkipTransientFailure(for host: String) -> Bool {
        let key = host.lowercased() as NSString
        guard let expiry = transientFailureCache.object(forKey: key)?.doubleValue else { return false }
        if Date().timeIntervalSince1970 < expiry {
            return true
        }

        transientFailureCache.removeObject(forKey: key)
        return false
    }

    private func markTransientFailure(for host: String) {
        let expiry = Date().timeIntervalSince1970 + transientFailureRetryInterval
        transientFailureCache.setObject(NSNumber(value: expiry), forKey: host.lowercased() as NSString)
    }

    private func isTimeoutLike(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorCannotConnectToHost {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isTimeoutLike(underlying)
        }

        return false
    }

    /// Very small HTML parser to extract href attributes from <link rel="icon"|"apple-touch-icon" ...>
    private func parseIconLinks(from html: String) -> [String] {
        linkAttributes(from: html).compactMap { attrs in
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("icon") else { return nil }
            return attrs["href"]
        }
    }

    private func parseManifestLinks(from html: String) -> [String] {
        linkAttributes(from: html).compactMap { attrs in
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("manifest") else { return nil }
            return attrs["href"]
        }
    }

    private func linkAttributes(from html: String) -> [[String: String]] {
        var results: [[String: String]] = []
        let linkPattern = "(?i)<link\\b[^>]*>"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: []) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            for m in matches {
                guard let tagRange = Range(m.range, in: html) else { continue }
                let tag = String(html[tagRange])
                let attrs = attributes(fromHTMLTag: tag)
                if !attrs.isEmpty {
                    results.append(attrs)
                }
            }
        }

        return results
    }

    private func attributes(fromHTMLTag tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"(?i)([a-z0-9:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return attributes
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        for match in regex.matches(in: tag, options: [], range: range) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            let key = String(tag[keyRange]).lowercased()
            var value: String?
            for index in 2...4 where match.range(at: index).location != NSNotFound {
                if let valueRange = Range(match.range(at: index), in: tag) {
                    value = String(tag[valueRange])
                    break
                }
            }
            if let value {
                attributes[key] = value
            }
        }

        return attributes
    }

    private func iconURLsFromManifest(_ manifestURL: URL) async -> [URL] {
        var request = rootHTMLRequest(for: manifestURL)
        request.setValue("application/manifest+json,application/json,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await fetchDataIgnoringTaskCancellation(for: request, maxBytes: maxManifestDownloadBytes)
            guard data.count <= maxManifestDownloadBytes,
                  let http = response as? HTTPURLResponse,
                  (http.statusCode == 200 || http.statusCode == 206),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let icons = object["icons"] as? [[String: Any]] else {
                return []
            }

            return icons.compactMap { icon in
                guard let source = icon["src"] as? String else { return nil }
                return URL(string: source, relativeTo: manifestURL)?.absoluteURL
            }
        } catch {
            return []
        }
    }
}

// IconCache uses UIKit types that aren't Sendable. The cache mutations happen
// from background tasks via thread-safe NSCache, and disk writes are atomic, so
// declare unchecked Sendable conformance to satisfy the compiler for captures
// inside `@Sendable` closures.
extension IconCache: @unchecked Sendable {}
