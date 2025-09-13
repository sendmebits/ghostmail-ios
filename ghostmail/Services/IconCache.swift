import Foundation
import UIKit
import WebKit

final class IconCache {
    static let shared = IconCache()
    private let memoryCache = NSCache<NSString, UIImage>()
    // Cache for hosts that were checked and had no icon available
    private let negativeMemoryCache = NSCache<NSString, NSNumber>()
    private let fileManager = FileManager.default
    private let cacheDir: URL
    // Keep strong references to navigation delegates while rendering SVGs
    private var webViewDelegates: [AnyObject] = []

    // ...existing code...

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

    private func missingFileURL(for host: String) -> URL {
        return cacheDir.appendingPathComponent(filename(for: host) + ".missing")
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
    // image(for:) starting for host

        if let cached = memoryCache.object(forKey: host as NSString) {
            // cache hit in-memory
            return cached
        }

        // Fast-path: if we previously determined this host has no icon, avoid network
        if negativeMemoryCache.object(forKey: host as NSString) != nil {
            // negative cache skip
            return nil
        }

        // Also check for a persisted "missing" marker on disk
        let missingURL = missingFileURL(for: host)
        if fileManager.fileExists(atPath: missingURL.path) {
            negativeMemoryCache.setObject(NSNumber(value: true), forKey: host as NSString)
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
            if let img = try await fetchBestIconFromSite(host: host) {
                memoryCache.setObject(img, forKey: host as NSString)
                if let data = img.pngData() {
                    try? data.write(to: fileURL, options: .atomic)
                }
                try? fileManager.removeItem(at: missingURL)
                negativeMemoryCache.removeObject(forKey: host as NSString)
                // fetched icon via site crawl
                return img
            }
        } catch {
            // ignore and fall back to other endpoints
            // site crawl failed
        }

        // Attempt network fetches in order: prefer DuckDuckGo (try ip2 then ip3) then Google Favicons.
        // Percent-encode the host to be safe when inserted into the URL.
        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        var googleURLString: String = "https://www.google.com/s2/favicons?sz=64"
        if var comps = URLComponents(string: "https://www.google.com/s2/favicons") {
            comps.queryItems = [
                URLQueryItem(name: "domain", value: host),
                URLQueryItem(name: "sz", value: "64")
            ]
            googleURLString = comps.url?.absoluteString ?? googleURLString
        }

        let endpoints = [
            "https://icons.duckduckgo.com/ip2/\(encodedHost).ico",
            "https://icons.duckduckgo.com/ip3/\(encodedHost).ico",
            googleURLString
        ]
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"

        for endpoint in endpoints {
            guard let iconURL = URL(string: endpoint) else { continue }
            // trying endpoint \(iconURL.absoluteString)
            var req = URLRequest(url: iconURL)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15

            do {
                let (data, response) = try await fetchDataIgnoringTaskCancellation(for: req)
                if let http = response as? HTTPURLResponse {
                    // endpoint response \(http.statusCode) bytes=\(data.count)
                    if http.statusCode == 200 {
                        if let img = await imageFromDownloadedData(data, url: iconURL) {
                            memoryCache.setObject(img, forKey: host as NSString)
                            try? data.write(to: fileURL, options: .atomic)
                            // If we previously created a missing marker, remove it now
                            try? fileManager.removeItem(at: missingURL)
                            negativeMemoryCache.removeObject(forKey: host as NSString)
                            // downloaded image from endpoint
                            return img
                        } else {
                            // downloaded data but could not decode image
                        }
                    }
                }
            } catch {
                // endpoint request failed: \(error)
                // Try next endpoint on error
                continue
            }
        }

        // No icon found: persist a small marker so we don't re-query repeatedly
        let markerData = Data()
        try? markerData.write(to: missingURL, options: .atomic)
        negativeMemoryCache.setObject(NSNumber(value: true), forKey: host as NSString)

        return nil
    }

    /// Force a refresh for the given website: clear any cached state and attempt
    /// to re-download the icon from the network (DuckDuckGo first, then Google).
    /// This is useful for pull-to-refresh scenarios where the app should try
    /// to update a previously-missing or stale icon for a single host.
    func refreshImage(for website: String) async -> UIImage? {
        guard let host = hostFromWebsite(website) else { return nil }

    // Clear any in-memory caches and on-disk missing marker so we actually try
        memoryCache.removeObject(forKey: host as NSString)
        negativeMemoryCache.removeObject(forKey: host as NSString)
        let fileURL = fileURL(for: host)
        let missingURL = missingFileURL(for: host)
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: missingURL)

        // First try crawling the site for link rel icons and /favicon.ico
        do {
            if let img = try await fetchBestIconFromSite(host: host) {
                memoryCache.setObject(img, forKey: host as NSString)
                if let data = img.pngData() {
                    try? data.write(to: fileURL, options: .atomic)
                }
                try? fileManager.removeItem(at: missingURL)
                negativeMemoryCache.removeObject(forKey: host as NSString)
                return img
            }
        } catch {
            // ignore and fall back to other endpoints
        }

        // Same endpoints as the regular fetch path. Try DuckDuckGo ip2 first, then ip3.
        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        var googleURLString: String = "https://www.google.com/s2/favicons?sz=64"
        if var comps = URLComponents(string: "https://www.google.com/s2/favicons") {
            comps.queryItems = [
                URLQueryItem(name: "domain", value: host),
                URLQueryItem(name: "sz", value: "64")
            ]
            googleURLString = comps.url?.absoluteString ?? googleURLString
        }

        let endpoints = [
            "https://icons.duckduckgo.com/ip2/\(encodedHost).ico",
            "https://icons.duckduckgo.com/ip3/\(encodedHost).ico",
            googleURLString
        ]

        for endpoint in endpoints {
            guard let iconURL = URL(string: endpoint) else { continue }
    // refresh trying endpoint \(iconURL.absoluteString)
            var req = URLRequest(url: iconURL)
            let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15

            do {
                let (data, response) = try await fetchDataIgnoringTaskCancellation(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            // refresh endpoint response \(http.statusCode) bytes=\(data.count)
            if let img = await imageFromDownloadedData(data, url: iconURL) {
                        memoryCache.setObject(img, forKey: host as NSString)
                        try? data.write(to: fileURL, options: .atomic)
                        try? fileManager.removeItem(at: missingURL)
                        negativeMemoryCache.removeObject(forKey: host as NSString)
                        return img
                    }
                }
            } catch {
                // refresh endpoint request failed: \(error)
                continue
            }
        }

        // Still not found: write missing marker and set negative cache
        let markerData = Data()
        try? markerData.write(to: missingURL, options: .atomic)
        negativeMemoryCache.setObject(NSNumber(value: true), forKey: host as NSString)

        return nil
    }

    // Try to convert downloaded data into UIImage. If it's raster (PNG/JPEG/etc) use UIImage.
    // If it's SVG (content-type or data looks like SVG) attempt to rasterize via WKWebView.
    private func imageFromDownloadedData(_ data: Data, url: URL) async -> UIImage? {
        // Fast path: try UIImage
        if let img = UIImage(data: data) {
            // decoded raster image directly from url
            return img
        }

        // Check for SVG by content or URL extension
        let lower = url.path.lowercased()
        var looksLikeSVG = false
        if let prefix = String(data: data.prefix(256), encoding: .utf8) {
            looksLikeSVG = prefix.contains("<svg")
        }
        if lower.hasSuffix(".svg") || looksLikeSVG {
            // attempting SVG rasterization
            if let raster = await rasterizeSVGData(data) {
                // svg rasterization succeeded
                return raster
            } else {
                // svg rasterization failed
            }
        }

        return nil
    }

    /// Perform a URLRequest using URLSession dataTask completion handler so the request
    /// isn't automatically cancelled when the calling Swift concurrency Task is cancelled.
    private func fetchDataIgnoringTaskCancellation(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let d = data, let r = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (d, r))
            }
            task.resume()
        }
    }

    // Rasterize SVG data by loading into a hidden WKWebView and snapshotting at desired size.
    private func rasterizeSVGData(_ data: Data, targetSize: CGSize = CGSize(width: 64, height: 64)) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            DispatchQueue.main.async {
                let webView = WKWebView(frame: CGRect(origin: .zero, size: targetSize))
                webView.isOpaque = false
                webView.backgroundColor = .clear

                // Keep a delegate to retain the webView until completion
                class Delegate: NSObject, WKNavigationDelegate {
                    var onFinish: ((UIImage?) -> Void)?
                    override init() { self.onFinish = nil; super.init() }
                    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                        // Snapshot the webview's content
                        webView.takeSnapshot(with: nil) { image, error in
                            self.onFinish?(image)
                        }
                    }
                    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                        self.onFinish?(nil)
                    }
                    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                        self.onFinish?(nil)
                    }
                }

                let delegate = Delegate()
                // assign onFinish after delegate exists to avoid capturing before initialization
                delegate.onFinish = { [weak self, weak delegate] image in
                    // cleanup
                    if let strongSelf = self, let d = delegate {
                        if let idx = strongSelf.webViewDelegates.firstIndex(where: { $0 === d }) {
                            strongSelf.webViewDelegates.remove(at: idx)
                        }
                    }
                    webView.removeFromSuperview()
                    continuation.resume(returning: image)
                }

                webView.navigationDelegate = delegate
                self.webViewDelegates.append(delegate)

                // Load the SVG data as HTML blob
                let svgString = String(data: data, encoding: .utf8) ?? ""
                let html = "<html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;padding:0;display:flex;align-items:center;justify-content:center;\">\(svgString)</body></html>"

                // loading SVG into WKWebView for rasterization
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    /// Synchronous check to quickly determine whether we previously marked this host as missing.
    /// Useful for avoiding UI spinners when the icon is known to be absent.
    func hasMissingIcon(for website: String) -> Bool {
        guard let host = hostFromWebsite(website) else { return false }
        if negativeMemoryCache.object(forKey: host as NSString) != nil { return true }
        let missingURL = missingFileURL(for: host)
        if fileManager.fileExists(atPath: missingURL.path) {
            negativeMemoryCache.setObject(NSNumber(value: true), forKey: host as NSString)
            return true
        }
        return false
    }

    // MARK: - Site crawling for link rel icons

    /// Fetch the site's root HTML and attempt to discover <link rel> icon tags and /favicon.ico.
    /// Returns the best UIImage found (preferring larger PNG/SVG where possible), or nil.
    private func fetchBestIconFromSite(host: String) async throws -> UIImage? {
        // Build base URL
        guard let baseURL = URL(string: "https://\(host)") else { return nil }

        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 15

        do {
            let (data, response) = try await fetchDataIgnoringTaskCancellation(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            // Parse link rel icon tags
            let links = parseIconLinks(from: html)

            // Construct candidate URLs (absolute) and include /favicon.ico as fallback
            var candidateURLs: [URL] = []
            for href in links {
                if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                    candidateURLs.append(url)
                }
            }

            if let faviconURL = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL {
                candidateURLs.append(faviconURL)
            }

            // Remove duplicates while preserving order
            var seen = Set<String>()
            candidateURLs = candidateURLs.filter { url in
                let s = url.absoluteString
                if seen.contains(s) { return false }
                seen.insert(s)
                return true
            }

            // Download candidates and pick best by preference: prefer PNG/SVG and larger sizes
            var bestImage: UIImage? = nil
            var bestScore = 0

            for url in candidateURLs {
                var r = URLRequest(url: url)
                r.timeoutInterval = 15
                do {
                    let (d, resp) = try await fetchDataIgnoringTaskCancellation(for: r)
                    if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                        if let img = await imageFromDownloadedData(d, url: url) {
                            // Score: prefer larger pixel area
                            let score = Int(img.size.width * img.size.height)
                            if score > bestScore {
                                bestScore = score
                                bestImage = img
                            }
                        } else {
                            continue
                        }
                    }
                } catch {
                    continue
                }
            }

            return bestImage
        } catch {
            return nil
        }
    }

    /// Very small HTML parser to extract href attributes from <link rel="icon"|"apple-touch-icon" ...>
    private func parseIconLinks(from html: String) -> [String] {
        var results: [String] = []

        // A simple regex to capture link rel tags with href. This is intentionally lightweight.
        // It looks for: <link ... rel="...icon..." ... href="..."> and captures the href value.
        let pattern = "(?i)<link[^>]+rel=[\'\"]?([^\'\">]+)[\'\"]?[^>]*href=[\'\"]?([^\'\">]+)[\'\"]?[^>]*>"

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            for m in matches {
                if m.numberOfRanges >= 3, let relRange = Range(m.range(at: 1), in: html), let hrefRange = Range(m.range(at: 2), in: html) {
                    let rel = String(html[relRange]).lowercased()
                    let href = String(html[hrefRange])
                    // prefer rels that contain "icon"
                    if rel.contains("icon") {
                        results.append(href)
                    }
                }
            }
        }

        return results
    }
}

// IconCache interacts with UIKit/WebKit objects which are not Sendable. The
// continuation/closure used for SVG rasterization executes on the main thread
// and is safe, so declare unchecked Sendable conformance to satisfy the
// compiler for captures inside @Sendable closures.
extension IconCache: @unchecked Sendable {}
