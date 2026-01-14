import Foundation
import Combine

@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingWebsiteHost: String? = nil

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "ghostmail" else { 
            return 
        }

        // Supported paths: ghostmail://create?url=<encoded>
        let path = url.host?.lowercased() ?? url.path.lowercased()
        if path.contains("create") || url.path.lowercased().contains("create") {
            let website = extractWebsite(from: url)
            if let host = website {
                self.pendingWebsiteHost = host
            } else {
                // Empty string signals "open create with no preset website"
                self.pendingWebsiteHost = ""
            }
        }
    }

    private func extractWebsite(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let qp = components.queryItems ?? []
        if let urlItem = qp.first(where: { $0.name == "url" })?.value {
            // Validate and sanitize the URL parameter
            let sanitized = urlItem.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only allow http/https schemes to prevent javascript: or other malicious schemes
            guard !sanitized.lowercased().hasPrefix("javascript:"),
                  !sanitized.lowercased().hasPrefix("data:"),
                  !sanitized.lowercased().hasPrefix("file:") else {
                print("[Security] Blocked potentially malicious URL scheme in deep link: \(sanitized.prefix(20))...")
                return nil
            }
            
            if let shared = URL(string: sanitized) ?? URL(string: sanitized.removingPercentEncoding ?? "") {
                return normalizeHost(from: shared)
            }
        }
        if let websiteItem = qp.first(where: { $0.name == "website" })?.value {
            // Accept raw host strings too, but validate them
            let sanitized = websiteItem.trimmingCharacters(in: .whitespacesAndNewlines)
            // Block potentially malicious schemes
            guard !sanitized.lowercased().hasPrefix("javascript:"),
                  !sanitized.lowercased().hasPrefix("data:"),
                  !sanitized.lowercased().hasPrefix("file:") else {
                print("[Security] Blocked potentially malicious URL scheme in deep link: \(sanitized.prefix(20))...")
                return nil
            }
            
            if let asUrl = URL(string: sanitized), let host = asUrl.host { return host }
            return sanitized.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        return nil
    }

    private func normalizeHost(from url: URL) -> String? {
        if var host = url.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        // If it came as a bare domain without scheme, attempt to coerce
        if !url.absoluteString.contains("://") {
            let str = url.absoluteString
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            var trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            if trimmed.hasPrefix("www.") { trimmed.removeFirst(4) }
            return trimmed
        }
        return nil
    }
}
