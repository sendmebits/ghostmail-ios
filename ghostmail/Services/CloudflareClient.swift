import Foundation
import SwiftData
import Combine
import SwiftUI

class CloudflareClient: ObservableObject {
    private var baseURL = "https://api.cloudflare.com/client/v4"
    @Published private(set) var accountId: String
    @Published private(set) var zoneId: String
    @Published private(set) var apiToken: String
    @Published var isAuthenticated: Bool
    @Published private(set) var accountName: String = ""
    // Multi-zone support
    struct CloudflareZone: Codable, Hashable {
        var accountId: String
        var zoneId: String
        var apiToken: String
        var accountName: String
        var domainName: String
    }
    @Published private(set) var zones: [CloudflareZone] = []
    
    @AppStorage("forwardingEmail") private var forwardingEmail: String = ""
    @Published private(set) var forwardingAddresses: Set<String> = []
    @AppStorage("defaultForwardingAddress") private var defaultForwardingAddress: String = ""
    @AppStorage("showWebsitesInList") private var showWebsitesInList: Bool = true
    @AppStorage("showWebsiteLogo") private var showWebsiteLogo: Bool = true
    
    @Published private(set) var domainName: String = ""
    
    // Cache for API responses to avoid redundant calls
    private var forwardingAddressesCache: Set<String> = []
    private var lastForwardingAddressesFetch: Date = .distantPast
    private let cacheValidityDuration: TimeInterval = 300 // 5 minutes
    
    init(accountId: String = "", zoneId: String = "", apiToken: String = "") {
        // Load stored credentials
        let defaults = UserDefaults.standard
        self.accountId = (defaults.string(forKey: "accountId") ?? accountId).trimmingCharacters(in: .whitespacesAndNewlines)
        self.zoneId = (defaults.string(forKey: "zoneId") ?? zoneId).trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = (defaults.string(forKey: "apiToken") ?? apiToken).trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAuthenticated = defaults.bool(forKey: "isAuthenticated")

        // Load multi-zone configuration if present; migrate from single if needed
        if let data = defaults.data(forKey: "cloudflareZones"),
           let decoded = try? JSONDecoder().decode([CloudflareZone].self, from: data) {
            self.zones = decoded
        } else {
            self.zones = []
        }
        // Migration: if we have single-zone credentials but no zones array, create it
        if !self.accountId.isEmpty, !self.zoneId.isEmpty, !self.apiToken.isEmpty, self.zones.isEmpty {
            // We'll fill accountName/domainName after fetch
            self.zones = [CloudflareZone(accountId: self.accountId, zoneId: self.zoneId, apiToken: self.apiToken, accountName: self.accountName, domainName: self.domainName)]
            persistZones()
        }
    }

    // MARK: - Privacy-safe logging helpers
    private func maskId(_ value: String, first: Int = 2, last: Int = 4) -> String {
        guard !value.isEmpty else { return "[empty]" }
        if value.count <= first + last { return "\(value.prefix(1))…\(value.suffix(1))" }
        return "\(value.prefix(first))…\(value.suffix(last))"
    }

    private func maskedURL(_ url: URL, accountId: String? = nil, zoneId: String? = nil) -> String {
        var s = url.absoluteString
        if let zid = zoneId, !zid.isEmpty { s = s.replacingOccurrences(of: zid, with: maskId(zid)) }
        if let aid = accountId, !aid.isEmpty { s = s.replacingOccurrences(of: aid, with: maskId(aid)) }
        return s
    }
    
    private var headers: [String: String] {
        [
            "Authorization": "Bearer \(apiToken)",
            "Content-Type": "application/json"
        ]
    }
    
    struct CloudflareError: LocalizedError {
        let message: String
        
        var errorDescription: String? {
            message
        }
    }
    
    func verifyToken() async throws -> Bool {
        try await verifyToken(using: apiToken)
    }

    // Verify an arbitrary token (used for adding additional zones)
    func verifyToken(using token: String) async throws -> Bool {
        // First try user token verification
        let userTokenResult = await verifyUserToken(using: token)
        if userTokenResult.isValid {
            print("[Cloudflare] Token verified as user token")
            return true
        }
        
        // If user token verification fails, try to validate as account token
        print("[Cloudflare] User token verification failed (\(userTokenResult.error ?? "unknown error")), attempting to validate as account token")
        let accountTokenValid = await validateAccountToken(using: token)
        
        if accountTokenValid {
            print("[Cloudflare] Token verified as account token")
            return true
        }
        
        // Both verification methods failed
        print("[Cloudflare] Both user and account token verification failed")
        throw CloudflareError(message: "Invalid API token. Please ensure your token has the correct permissions for Email Routing and Zone access.")
    }
    
    // Helper function to verify user tokens
    private func verifyUserToken(using token: String) async -> (isValid: Bool, error: String?) {
        let url = URL(string: "\(baseURL)/user/tokens/verify")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        
        print("[Cloudflare] Verifying user token: GET \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Cloudflare] User token verification failed: Invalid HTTP response")
                return (false, "Invalid response from server")
            }
            
            if httpResponse.statusCode == 200 {
                if let responseString = String(data: data, encoding: .utf8) {
                    print("[Cloudflare] User token verification successful: \(responseString)")
                }
                return (true, nil)
            } else {
                let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                print("[Cloudflare] User token verification failed: status=\(httpResponse.statusCode), body=\(responseBody)")
                return (false, "User token verification failed with status \(httpResponse.statusCode)")
            }
        } catch {
            print("[Cloudflare] User token verification error: \(error)")
            return (false, error.localizedDescription)
        }
    }
    
    // Helper function to validate account tokens by attempting to use them
    private func validateAccountToken(using token: String) async -> Bool {
        // For account tokens, we'll try to list accounts to validate the token works
        let url = URL(string: "\(baseURL)/accounts")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        
        print("[Cloudflare] Validating account token by listing accounts: GET \(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Cloudflare] Account token validation failed: Invalid HTTP response")
                return false
            }
            
            if httpResponse.statusCode == 200 {
                print("[Cloudflare] Account token validation successful")
                return true
            } else {
                let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                print("[Cloudflare] Account token validation failed: status=\(httpResponse.statusCode), body=\(responseBody)")
                return false
            }
        } catch {
            print("[Cloudflare] Account token validation error: \(error)")
            return false
        }
    }
    
    // Get email rules from Cloudflare (returns custom type to avoid circular dependencies)
    func getEmailRules() async throws -> [CloudflareEmailRule] {
        // Fetch domain name if needed (cached)
        if domainName.isEmpty {
            try await fetchDomainName()
        }
        
        // Fetch all entries from Cloudflare in chunks of 100 (increased from 50)
        var allRules: [EmailRule] = []
        var currentPage = 1
        let perPage = 100  // Increased page size for fewer API calls
        
        while true {
            let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules?page=\(currentPage)&per_page=\(perPage)")!
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            
        let msg1 = "Requesting URL: \(maskedURL(url, zoneId: zoneId))"
        print(msg1); LogBuffer.shared.add(msg1)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudflareError(message: "Invalid response from server")
            }
            
            if httpResponse.statusCode != 200 {
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Error response: \(errorString)")
                }
                
                if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                    throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
                }
                throw CloudflareError(message: "Server returned status code \(httpResponse.statusCode)")
            }
            
            let cloudflareResponse = try JSONDecoder().decode(CloudflareResponse<[EmailRule]>.self, from: data)
            
            guard cloudflareResponse.success else {
                throw CloudflareError(message: "API request was not successful")
            }
            
            allRules.append(contentsOf: cloudflareResponse.result)
            
            // Check if we've fetched all pages
            if let resultInfo = cloudflareResponse.result_info {
                if allRules.count >= resultInfo.total_count {
                    break
                }
                currentPage += 1
            } else {
                // If no result_info, assume we've got all results
                break
            }
        }
        
        // Print the total number of rules fetched
        print("Total email rules fetched: \(allRules.count)")
        
        // Collect all unique forwarding addresses and update cache
        let forwards = Set(allRules.compactMap { rule -> String? in
            // Only consider forward actions
            guard let forwardAction = rule.actions.first(where: { $0.type == "forward" }),
                  let values = forwardAction.value,
                  let firstValue = values.first else { return nil }
            return firstValue
        })
        
        // Update forwarding addresses cache from rules
        await MainActor.run {
            self.forwardingAddresses = forwards
            self.forwardingAddressesCache = forwards
            self.lastForwardingAddressesFetch = Date()
        }
        
        // Convert to CloudflareEmailRule and ensure there are no duplicates by email address
        var uniqueRules: [CloudflareEmailRule] = []
        var seenEmailAddresses = Set<String>()
        
        for rule in allRules {
            // Skip rules that don't have email forwarding
            guard let forwardAction = rule.actions.first(where: { $0.type == "forward" }),
                  let forwardTo = forwardAction.value?.first else {
                continue
            }
            
            // Skip catch-all rules or rules without a "to" matcher
            guard let matcher = rule.matchers.first,
                  matcher.type == "literal",
                  matcher.field == "to",
                  let emailAddress = matcher.value else {
                continue
            }
            
            // Skip if we've already seen this email address
            if seenEmailAddresses.contains(emailAddress) {
                print("⚠️ Skipping duplicate Cloudflare rule for: \(emailAddress)")
                continue
            }
            
            seenEmailAddresses.insert(emailAddress)
            print("Creating alias for \(emailAddress) with forward to: \(forwardTo)")
            
            let alias = CloudflareEmailRule(
                emailAddress: emailAddress,
                cloudflareTag: rule.tag,
                isEnabled: rule.enabled,
                forwardTo: forwardTo,
                zoneId: self.zoneId
            )
            
            uniqueRules.append(alias)
        }
        
        return uniqueRules
    }

    // Fetch rules for a specific zone
    func getEmailRules(for zone: CloudflareZone) async throws -> [CloudflareEmailRule] {
        // Build request for that zone
        // Fetch domain/account if needed
        if zone.domainName.isEmpty || zone.accountName.isEmpty {
            // Try to fetch details (not mutating self.zones here)
            _ = try await fetchZoneDetails(accountId: zone.accountId, zoneId: zone.zoneId, token: zone.apiToken)
        }

        // Fetch all entries from Cloudflare in chunks of 100
        var allRules: [EmailRule] = []
        var currentPage = 1
        let perPage = 100
        while true {
            let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules?page=\(currentPage)&per_page=\(perPage)")!
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = [
                "Authorization": "Bearer \(zone.apiToken)",
                "Content-Type": "application/json"
            ]
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                    throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
                }
                throw CloudflareError(message: "Failed to fetch rules for zone \(maskId(zone.zoneId))")
            }
            let cloudflareResponse = try JSONDecoder().decode(CloudflareResponse<[EmailRule]>.self, from: data)
            guard cloudflareResponse.success else { break }
            allRules.append(contentsOf: cloudflareResponse.result)
            if let info = cloudflareResponse.result_info, allRules.count < info.total_count {
                currentPage += 1
            } else { break }
        }

        // Build unique rule list
        var uniqueRules: [CloudflareEmailRule] = []
        var seenEmailAddresses = Set<String>()
        for rule in allRules {
            guard let forwardAction = rule.actions.first(where: { $0.type == "forward" }), let forwardTo = forwardAction.value?.first else { continue }
            guard let matcher = rule.matchers.first, matcher.type == "literal", matcher.field == "to", let emailAddress = matcher.value else { continue }
            if seenEmailAddresses.contains(emailAddress) { continue }
            seenEmailAddresses.insert(emailAddress)
            uniqueRules.append(CloudflareEmailRule(emailAddress: emailAddress, cloudflareTag: rule.tag, isEnabled: rule.enabled, forwardTo: forwardTo, zoneId: zone.zoneId))
        }
        return uniqueRules
    }

    // Fetch rules across all configured zones
    func getEmailRulesAllZones() async throws -> [CloudflareEmailRule] {
        var aggregated: [CloudflareEmailRule] = []
        for zone in zones {
            let rules = try await getEmailRules(for: zone)
            aggregated.append(contentsOf: rules)
        }
        return aggregated
    }
    
    func createEmailRule(emailAddress: String, forwardTo: String) async throws -> EmailRule {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        
        let rule = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": [
                [
                    "type": "forward",
                    "value": [forwardTo]
                ]
            ],
            "enabled": true,
            "priority": 0
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: rule)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareResponse<EmailRule>.self, from: data)
        return response.result
    }

    // Overload to create a rule in a specified zone using that zone's token
    func createEmailRule(emailAddress: String, forwardTo: String, in zone: CloudflareZone) async throws -> EmailRule {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]

        let rule = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": [
                [
                    "type": "forward",
                    "value": [forwardTo]
                ]
            ],
            "enabled": true,
            "priority": 0
        ] as [String: Any]

        request.httpBody = try JSONSerialization.data(withJSONObject: rule)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CloudflareResponse<EmailRule>.self, from: data)
        return response.result
    }
    
    @MainActor
    func updateCredentials(accountId: String, zoneId: String, apiToken: String) {
        self.accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.zoneId = zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let defaults = UserDefaults.standard
    defaults.set(self.accountId, forKey: "accountId")
    defaults.set(self.zoneId, forKey: "zoneId")
    defaults.set(self.apiToken, forKey: "apiToken")
        
        // Clear cache when credentials change
        forwardingAddressesCache = []
        lastForwardingAddressesFetch = .distantPast
        
        // Fetch the domain name when credentials are updated
        Task {
            do {
                try await fetchDomainName()
            } catch {
                print("Error fetching domain name: \(error)")
            }
        }

        // Also ensure zones contains/updates primary zone
        if let idx = zones.firstIndex(where: { $0.zoneId == zoneId }) {
            zones[idx].accountId = accountId
            zones[idx].apiToken = apiToken
        } else {
            zones.insert(CloudflareZone(accountId: accountId, zoneId: zoneId, apiToken: apiToken, accountName: accountName, domainName: domainName), at: 0)
        }
        persistZones()
    }
    
    @MainActor
    func logout() {
        accountId = ""
        zoneId = ""
        apiToken = ""
        isAuthenticated = false
        
        // Clear cache on logout
        forwardingAddressesCache = []
        lastForwardingAddressesFetch = .distantPast
        
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "accountId")
        defaults.removeObject(forKey: "zoneId")
        defaults.removeObject(forKey: "apiToken")
        defaults.removeObject(forKey: "isAuthenticated")
    zones = []
    defaults.removeObject(forKey: "cloudflareZones")
    }
    
    func updateEmailRule(tag: String, emailAddress: String, isEnabled: Bool, forwardTo: String) async throws {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = headers
        
        let rule = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": [
                [
                    "type": "forward",
                    "value": [forwardTo]
                ]
            ],
            "enabled": isEnabled,
            "priority": 0
        ] as [String: Any]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: rule)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
            }
            throw CloudflareError(message: "Failed to update email rule")
        }
    }

    // Overload to update a rule in a specified zone using that zone's token
    func updateEmailRule(tag: String, emailAddress: String, isEnabled: Bool, forwardTo: String, in zone: CloudflareZone) async throws {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]

        let rule = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": [
                [
                    "type": "forward",
                    "value": [forwardTo]
                ]
            ],
            "enabled": isEnabled,
            "priority": 0
        ] as [String: Any]

        request.httpBody = try JSONSerialization.data(withJSONObject: rule)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
            }
            throw CloudflareError(message: "Failed to update email rule in specified zone")
        }
    }
    
    var emailDomain: String {
        // Use the fetched domain name, or fall back to a placeholder
        domainName.isEmpty ? "Loading..." : domainName
    }
    
    func createFullEmailAddress(username: String) -> String {
        "\(username)@\(emailDomain)"
    }
    
    func extractUsername(from email: String) -> String {
        email.components(separatedBy: "@").first ?? email
    }
    
    // Ensure we have the current forwarding addresses available - now with caching
    func ensureForwardingAddressesLoaded() async throws {
        // Check if we have valid cached data
        let cacheAge = Date().timeIntervalSince(lastForwardingAddressesFetch)
        if !forwardingAddressesCache.isEmpty && cacheAge < cacheValidityDuration {
            print("Using cached forwarding addresses (age: \(Int(cacheAge))s)")
            await MainActor.run {
                self.forwardingAddresses = forwardingAddressesCache
            }
            return
        }
        
        if forwardingAddresses.isEmpty {
            print("Forwarding addresses not loaded, fetching now...")
            
            do {
                try await refreshForwardingAddresses()
                
                // Add fallback logic if we couldn't get any verified addresses
                if forwardingAddresses.isEmpty {
                    print("Warning: No verified forwarding addresses found. Using default email as fallback.")
                    
                    // Check if we at least have a default forwarding email stored
                    if !forwardingEmail.isEmpty {
                        print("Using stored default email as fallback: \(forwardingEmail)")
                        await MainActor.run {
                            self.forwardingAddresses = [forwardingEmail]
                            self.forwardingAddressesCache = [forwardingEmail]
                        }
                    } else if !accountId.isEmpty {
                        // As a last resort, create a dummy fallback to prevent UI issues
                        let fallbackEmail = "default@\(emailDomain)"
                        print("No stored email available. Using generated fallback: \(fallbackEmail)")
                        await MainActor.run {
                            self.forwardingAddresses = [fallbackEmail]
                            self.forwardingAddressesCache = [fallbackEmail]
                        }
                    } else {
                        print("Cannot generate fallback address - missing domain information.")
                        throw CloudflareError(message: "No forwarding addresses available and unable to create fallback.")
                    }
                }
            } catch {
                print("Error in ensureForwardingAddressesLoaded: \(error.localizedDescription)")
                throw error
            }
        } else {
            print("Using \(forwardingAddresses.count) cached forwarding addresses")
        }
    }
    
    var currentDefaultForwardingAddress: String {
        // If the stored default is in the available addresses, use it
        if forwardingAddresses.contains(defaultForwardingAddress) {
            return defaultForwardingAddress
        }
        // Otherwise return the first available address or empty string
        return forwardingAddresses.first ?? ""
    }
    
    func setDefaultForwardingAddress(_ address: String) {
        print("Setting default forwarding address to: \(address)")
        // Only set if it's a valid forwarding address
        if forwardingAddresses.contains(address) || address.isEmpty {
            defaultForwardingAddress = address
            print("Default forwarding address set successfully")
        } else {
            print("Warning: Attempted to set invalid forwarding address: \(address)")
        }
    }
    
    func deleteEmailRule(tag: String) async throws {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = headers
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
            }
            throw CloudflareError(message: "Failed to delete email rule")
        }
    }

    // Overload to delete a rule in a specified zone using that zone's token
    func deleteEmailRule(tag: String, in zone: CloudflareZone) async throws {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                throw CloudflareError(message: errorResponse.errors.first?.message ?? "Unknown error")
            }
            throw CloudflareError(message: "Failed to delete email rule in specified zone")
        }
    }
    
    var shouldShowWebsitesInList: Bool {
        get { showWebsitesInList }
        set { showWebsitesInList = newValue }
    }

    var shouldShowWebsiteLogos: Bool {
        get { showWebsiteLogo }
        set { showWebsiteLogo = newValue }
    }
    
    func fetchDomainName() async throws {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        
        // Log request with redacted headers
        var logHeaders = headers
        if logHeaders["Authorization"] != nil { logHeaders["Authorization"] = "Bearer [REDACTED]" }
    let msg2 = "[Cloudflare] GET \(maskedURL(url, zoneId: zoneId)) — headers: \(logHeaders)"
    print(msg2); LogBuffer.shared.add(msg2)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Validate response and log diagnostic details on failure
        guard let httpResponse = response as? HTTPURLResponse else {
            let m = "[Cloudflare] Zone details: invalid HTTP response for zoneId=\(maskId(zoneId))"
            print(m); LogBuffer.shared.add(m)
            throw CloudflareError(message: "Failed to fetch zone details")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let m = "[Cloudflare] Zone details fetch failed — zoneId=\(maskId(zoneId)), status=\(httpResponse.statusCode), url=\(maskedURL(url, zoneId: zoneId)), body=\(body)"
            print(m); LogBuffer.shared.add(m)
            if let apiErr = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data), let first = apiErr.errors.first {
                let m2 = "[Cloudflare] API error: code=\(first.code) message=\(first.message)"
                print(m2); LogBuffer.shared.add(m2)
            }
            throw CloudflareError(message: "Failed to fetch zone details")
        }
        
        struct ZoneResponse: Codable {
            struct Account: Codable {
                let id: String
                let name: String
            }
            struct Result: Codable {
                let name: String
                let account: Account
            }
            let result: Result
            let success: Bool
        }
        
        let zoneResponse = try JSONDecoder().decode(ZoneResponse.self, from: data)

        if zoneResponse.success {
            let m3 = "[Cloudflare] Zone details OK — zoneId=\(maskId(zoneId)), domain=\(zoneResponse.result.name), account=\(zoneResponse.result.account.name)"
            print(m3); LogBuffer.shared.add(m3)
            await MainActor.run {
                self.domainName = zoneResponse.result.name
                self.accountName = zoneResponse.result.account.name
                if let idx = self.zones.firstIndex(where: { $0.zoneId == self.zoneId }) {
                    self.zones[idx].domainName = self.domainName
                    self.zones[idx].accountName = self.accountName
                    self.persistZones()
                }
            }
        } else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let m4 = "[Cloudflare] Zone details response success=false — zoneId=\(maskId(zoneId)), body=\(body)"
            print(m4); LogBuffer.shared.add(m4)
            throw CloudflareError(message: "Failed to get domain name from zone response")
        }
    }
    
    func refreshForwardingAddresses() async throws {
        print("Refreshing forwarding addresses...")
        
        // Check credentials are valid
        if accountId.isEmpty || zoneId.isEmpty || apiToken.isEmpty {
            print("Error: Missing Cloudflare credentials")
            throw CloudflareError(message: "Missing Cloudflare credentials. Please check your account ID, zone ID, and API token.")
        }
        
        // Check cache first
        let cacheAge = Date().timeIntervalSince(lastForwardingAddressesFetch)
        if !forwardingAddressesCache.isEmpty && cacheAge < cacheValidityDuration {
            print("Using cached forwarding addresses (age: \(Int(cacheAge))s)")
            await MainActor.run {
                self.forwardingAddresses = forwardingAddressesCache
            }
            return
        }
        
        do {
            // Fetch fresh from the Cloudflare API
            print("Calling fetchForwardingAddresses() directly")
            try await fetchForwardingAddresses()
            print("Successfully refreshed forwarding addresses. Count: \(self.forwardingAddresses.count)")
            
            // Update cache
            await MainActor.run {
                self.forwardingAddressesCache = self.forwardingAddresses
                self.lastForwardingAddressesFetch = Date()
            }
            
            // Print the first few addresses for debugging (limited for privacy)
            if !self.forwardingAddresses.isEmpty {
                let previewCount = min(2, self.forwardingAddresses.count)
                let preview = Array(self.forwardingAddresses).prefix(previewCount)
                
                // Redact parts of the email addresses for privacy in logs
                let redactedAddresses = preview.map { email -> String in
                    let components = email.split(separator: "@")
                    if components.count == 2 {
                        let username = String(components[0])
                        let domain = String(components[1])
                        let redactedUsername = username.count > 3 ? 
                            "\(username.prefix(1))...\(username.suffix(1))" : "..."
                        return "\(redactedUsername)@\(domain)"
                    }
                    return "redacted@example.com"
                }
                print("Available addresses (sample): \(redactedAddresses.joined(separator: ", "))")
            } else {
                print("Warning: No forwarding addresses found!")
            }
        } catch {
            print("Error refreshing forwarding addresses: \(error.localizedDescription)")
            if let cfError = error as? CloudflareError {
                print("Cloudflare API error: \(cfError.message)")
            }
            // Re-throw the error so callers can handle it
            throw error
        }
    }
    
    func fetchForwardingAddresses() async throws {
    let msgFA0 = "Fetching forwarding addresses directly from Cloudflare API"
    print(msgFA0); LogBuffer.shared.add(msgFA0)
        // Get the full API URL with account ID
        let addressEndpoint = "\(baseURL)/accounts/\(accountId)/email/routing/addresses"
    let msgFA1 = "API Endpoint: \(maskedURL(URL(string: addressEndpoint)!, accountId: accountId))"
    print(msgFA1); LogBuffer.shared.add(msgFA1)
        
        let url = URL(string: addressEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        
        // Add logging of headers (without the actual API token for security)
        var logHeaders = headers
        if logHeaders["Authorization"] != nil {
            logHeaders["Authorization"] = "Bearer [REDACTED]"
        }
    let msgFA2 = "Request headers: \(logHeaders)"
    print(msgFA2); LogBuffer.shared.add(msgFA2)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            let error = CloudflareError(message: "Invalid HTTP response")
            let m = "Error: Invalid HTTP response"
            print(m); LogBuffer.shared.add(m)
            throw error
        }
        
    let msgFA3 = "Response status code: \(httpResponse.statusCode)"
    print(msgFA3); LogBuffer.shared.add(msgFA3)
        
        if httpResponse.statusCode != 200 {
            // Log the response body to help diagnose issues
            if let errorText = String(data: data, encoding: .utf8) {
                let m = "Error response: \(errorText)"
                print(m); LogBuffer.shared.add(m)
            }
            
            let error = CloudflareError(message: "Failed to fetch forwarding addresses (HTTP \(httpResponse.statusCode))")
            let m = "Error: \(error.message)"
            print(m); LogBuffer.shared.add(m)
            throw error
        }
        
        do {
            let addressResponse = try JSONDecoder().decode(AddressResponse.self, from: data)
            
            if addressResponse.success {
                // Log the raw result for debugging
                print("API returned \(addressResponse.result.count) total addresses")
                
                // Consider an address verified if it has a non-nil, non-empty verified timestamp
                let verifiedAddresses = Set(
                    addressResponse.result
                        .filter { emailAddress in 
                            // Log verification status
                            let isVerified = emailAddress.verified != nil && !emailAddress.verified!.isEmpty
                            if !isVerified {
                                print("Skipping unverified address: \(emailAddress.email)")
                            }
                            return isVerified
                        }
                        .map { $0.email }
                )
                
                print("Fetched \(verifiedAddresses.count) verified forwarding addresses out of \(addressResponse.result.count) total")
                
                if verifiedAddresses.isEmpty && !addressResponse.result.isEmpty {
                    print("Warning: Found addresses but none are verified. This may indicate a verification issue.")
                    // Show verification status of all addresses for debugging
                    for (index, address) in addressResponse.result.enumerated() {
                        print("Address \(index+1): \(address.email), Verified: \(address.verified ?? "null")")
                    }
                }
                
                await MainActor.run {
                    self.forwardingAddresses = verifiedAddresses
                }
            } else {
                let errorMessage = addressResponse.errors.first?.message ?? "Failed to get forwarding addresses from response"
                print("API returned success=false: \(errorMessage)")
                throw CloudflareError(message: errorMessage)
            }
        } catch let decodingError as DecodingError {
            // Better error handling for JSON decoding issues
            print("Decoding error: \(decodingError)")
            if let responseText = String(data: data, encoding: .utf8) {
                print("Response data: \(responseText)")
            }
            throw CloudflareError(message: "Failed to decode API response: \(decodingError.localizedDescription)")
        } catch {
            print("Other error: \(error)")
            throw error
        }
    }

    // Fetch forwarding addresses for an arbitrary account+token
    func fetchForwardingAddresses(accountId: String, token: String) async throws -> Set<String> {
    let addressEndpoint = "\(baseURL)/accounts/\(accountId)/email/routing/addresses"
        let url = URL(string: addressEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let errorText = String(data: data, encoding: .utf8) { print("Error response: \(errorText)") }
            throw CloudflareError(message: "Failed to fetch forwarding addresses for account \(maskId(accountId))")
        }
        let addressResponse = try JSONDecoder().decode(AddressResponse.self, from: data)
        if !addressResponse.success { throw CloudflareError(message: addressResponse.errors.first?.message ?? "Unknown error") }
        let verified = Set(addressResponse.result.filter { ($0.verified ?? "").isEmpty == false }.map { $0.email })
        return verified
    }

    // Refresh forwarding addresses across all configured zones (grouped by account)
    func refreshForwardingAddressesAllZones() async throws {
        // Define a concrete key type to avoid tuple Hashable issues
        struct AccountKey: Hashable { let accountId: String; let token: String }
        var accountKeys = Set<AccountKey>()
        for z in zones {
            accountKeys.insert(AccountKey(accountId: z.accountId, token: z.apiToken))
        }

        // Fetch sets sequentially and collect; avoid mutating across suspension points
        var collected: [Set<String>] = []
        for key in accountKeys {
            let set = try await fetchForwardingAddresses(accountId: key.accountId, token: key.token)
            collected.append(set)
        }

        let unionAll = collected.reduce(into: Set<String>()) { partial, next in
            partial.formUnion(next)
        }

        await MainActor.run {
            self.forwardingAddresses = unionAll
            self.forwardingAddressesCache = unionAll
            self.lastForwardingAddressesFetch = Date()
        }
    }

    // Add a new zone configuration (verifies token and fetches domain/account names)
    func addZone(accountId: String, zoneId: String, apiToken: String) async throws {
        let accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let zoneId = zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Verify token
        guard try await verifyToken(using: apiToken) else {
            throw CloudflareError(message: "Invalid API token")
        }
        // Fetch details
        let details = try await fetchZoneDetails(accountId: accountId, zoneId: zoneId, token: apiToken)
        let newZone = CloudflareZone(accountId: accountId, zoneId: zoneId, apiToken: apiToken, accountName: details.accountName, domainName: details.domainName)
        await MainActor.run {
            // Avoid duplicates
            if !self.zones.contains(where: { $0.zoneId == zoneId }) {
                self.zones.append(newZone)
                self.persistZones()
            }
        }
    }

    // Persist zones to UserDefaults
    private func persistZones() {
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: "cloudflareZones")
        }
    }

    // Remove a zone locally without touching Cloudflare or iCloud.
    // If the removed zone is the current primary, switch to another configured zone if available,
    // otherwise perform a full logout.
    @MainActor
    func removeZone(zoneId removedZoneId: String) {
        // Remove from zones list first
        zones.removeAll { $0.zoneId == removedZoneId }
        persistZones()

        // If we removed the active/primary zone, promote another zone or logout
        if self.zoneId == removedZoneId {
            if let newPrimary = zones.first {
                // Promote first remaining zone to primary credentials
                accountId = newPrimary.accountId
                zoneId = newPrimary.zoneId
                apiToken = newPrimary.apiToken
                accountName = newPrimary.accountName
                domainName = newPrimary.domainName

                let defaults = UserDefaults.standard
                defaults.set(accountId, forKey: "accountId")
                defaults.set(zoneId, forKey: "zoneId")
                defaults.set(apiToken, forKey: "apiToken")
                defaults.set(true, forKey: "isAuthenticated")

                // Clear forwarding cache to avoid stale state across accounts
                forwardingAddressesCache = []
                lastForwardingAddressesFetch = .distantPast
            } else {
                // No zones left — same as a full logout
                logout()
            }
        }
    }

    // Fetch zone details (domain/account names) without mutating current state
    func fetchZoneDetails(accountId: String, zoneId: String, token: String) async throws -> (domainName: String, accountName: String) {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json"
        ]
        // Log request with redacted headers
    print("[Cloudflare] GET \(maskedURL(url, zoneId: zoneId)) — headers: [Authorization: Bearer [REDACTED], Content-Type: application/json]")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[Cloudflare] Zone details (add zone): invalid HTTP response for zoneId=\(maskId(zoneId))")
            throw CloudflareError(message: "Failed to fetch zone details")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            print("[Cloudflare] Zone details fetch failed (add zone) — zoneId=\(maskId(zoneId)), status=\(httpResponse.statusCode), url=\(maskedURL(url, zoneId: zoneId)), body=\(body)")
            if let apiErr = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data), let first = apiErr.errors.first {
                print("[Cloudflare] API error: code=\(first.code) message=\(first.message)")
            }
            throw CloudflareError(message: "Failed to fetch zone details")
        }
        struct ZoneResponse: Codable {
            struct Account: Codable { let id: String; let name: String }
            struct Result: Codable { let name: String; let account: Account }
            let result: Result
            let success: Bool
        }
        let zoneResponse = try JSONDecoder().decode(ZoneResponse.self, from: data)
        guard zoneResponse.success else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            print("[Cloudflare] Zone details response success=false (add zone) — zoneId=\(maskId(zoneId)), body=\(body)")
            throw CloudflareError(message: "Failed to get domain name from zone response")
        }
    print("[Cloudflare] Zone details OK (add zone) — zoneId=\(maskId(zoneId)), domain=\(zoneResponse.result.name), account=\(zoneResponse.result.account.name)")
        return (domainName: zoneResponse.result.name, accountName: zoneResponse.result.account.name)
    }
}

struct CloudflareResponse<T: Codable>: Codable {
    let result: T
    let success: Bool
    let errors: [CloudflareErrorDetail]
    let messages: [String]
    let result_info: ResultInfo?
}

struct ResultInfo: Codable {
    let page: Int
    let per_page: Int
    let total_count: Int
    let count: Int
}

struct CloudflareErrorResponse: Codable {
    let success: Bool
    let errors: [CloudflareErrorDetail]
}

struct CloudflareErrorDetail: Codable {
    let code: Int
    let message: String
}

struct EmailRule: Codable {
    let id: String
    let tag: String
    let name: String
    let matchers: [Matcher]
    let actions: [Action]
    let enabled: Bool
    let priority: Int
}

struct Matcher: Codable {
    let type: String
    let field: String?
    let value: String?
}

struct Action: Codable {
    let type: String
    let value: [String]?
}

struct AddressResponse: Codable {
    struct EmailAddress: Codable {
        let id: String
        let tag: String
        let email: String
        let verified: String?  // Made optional to handle null values
        let created: String
        let modified: String
    }
    let result: [EmailAddress]
    let success: Bool
    let errors: [CloudflareErrorDetail]
    let messages: [String]
    let result_info: ResultInfo
}

// Define a custom type for the return value to avoid circular dependencies
struct CloudflareEmailRule {
    let emailAddress: String
    let cloudflareTag: String
    let isEnabled: Bool
    let forwardTo: String
    let zoneId: String
    
    // Add any other properties needed for email rules
} 
