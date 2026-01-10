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
    struct CloudflareZone: Codable, Hashable, Identifiable {
        var id: String { zoneId }  // Use zoneId as the Identifiable id
        var accountId: String
        var zoneId: String
        var apiToken: String
        var accountName: String
        var domainName: String
        var subdomains: [String] = []  // List of discovered subdomains with MX records
        var subdomainsEnabled: Bool = false  // Whether to discover subdomains for this zone
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
        // Load stored credentials from Keychain (migrating from UserDefaults if needed)
        let defaults = UserDefaults.standard
        
        // Check if we need to migrate from UserDefaults to Keychain
        if let oldAccountId = defaults.string(forKey: "accountId"), !oldAccountId.isEmpty {
            KeychainHelper.shared.save(oldAccountId, service: "ghostmail", account: "accountId")
            defaults.removeObject(forKey: "accountId")
        }
        if let oldZoneId = defaults.string(forKey: "zoneId"), !oldZoneId.isEmpty {
            KeychainHelper.shared.save(oldZoneId, service: "ghostmail", account: "zoneId")
            defaults.removeObject(forKey: "zoneId")
        }
        if let oldApiToken = defaults.string(forKey: "apiToken"), !oldApiToken.isEmpty {
            KeychainHelper.shared.save(oldApiToken, service: "ghostmail", account: "apiToken")
            defaults.removeObject(forKey: "apiToken")
        }
        
        // Load from Keychain
        self.accountId = (KeychainHelper.shared.readString(service: "ghostmail", account: "accountId") ?? accountId).trimmingCharacters(in: .whitespacesAndNewlines)
        self.zoneId = (KeychainHelper.shared.readString(service: "ghostmail", account: "zoneId") ?? zoneId).trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = (KeychainHelper.shared.readString(service: "ghostmail", account: "apiToken") ?? apiToken).trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAuthenticated = defaults.bool(forKey: "isAuthenticated")

        // Load multi-zone configuration
        if let data = defaults.data(forKey: "cloudflareZones") {
            // Try to decode as secure persisted zones first
            if let persistedZones = try? JSONDecoder().decode([PersistedCloudflareZone].self, from: data) {
                self.zones = persistedZones.map { pZone in
                    // Load token from Keychain
                    var token = KeychainHelper.shared.readString(service: "ghostmail", account: "apiToken_\(pZone.zoneId)") ?? ""
                    
                    // Fallback: If token is missing and this is the primary zone, use the primary token
                    if token.isEmpty && pZone.zoneId == self.zoneId {
                        token = self.apiToken
                    }
                    
                    return CloudflareZone(
                        accountId: pZone.accountId,
                        zoneId: pZone.zoneId,
                        apiToken: token,
                        accountName: pZone.accountName,
                        domainName: pZone.domainName,
                        subdomains: pZone.subdomains,
                        subdomainsEnabled: pZone.subdomainsEnabled
                    )
                }
                // Ensure all tokens are synced to expected Keychain locations
                // This is important for fixing any partial migration states
                persistZones()
            } 
            // Fallback: Try to decode as old insecure zones (migration path)
            else if let oldZones = try? JSONDecoder().decode([CloudflareZone].self, from: data) {
                print("Migrating zones to secure storage...")
                self.zones = oldZones
                // Trigger persistence which will now save tokens to Keychain and strip them from UserDefaults
                persistZones()
            } else {
                self.zones = []
            }
        } else {
            self.zones = []
        }
        
        // Migration: if we have single-zone credentials but no zones array, create it
        if !self.accountId.isEmpty, !self.zoneId.isEmpty, !self.apiToken.isEmpty, self.zones.isEmpty {
            // We'll fill accountName/domainName after fetch
            self.zones = [CloudflareZone(accountId: self.accountId, zoneId: self.zoneId, apiToken: self.apiToken, accountName: self.accountName, domainName: self.domainName)]
            persistZones()
        }
        
        // MARK: - Handle iCloud Restore Scenario
        // After restoring from iCloud backup, UserDefaults syncs but Keychain doesn't.
        // Detect when isAuthenticated is true but tokens are missing.
        if self.isAuthenticated && !hasValidCredentials {
            print("[CloudflareClient] ⚠️ Credentials missing after iCloud restore. Tokens not found in Keychain.")
            print("[CloudflareClient] Resetting authentication state - user will need to re-enter credentials.")
            LogBuffer.shared.add("[CloudflareClient] Credentials missing (likely iCloud restore). Prompting re-authentication.")
            
            // Reset authentication state but preserve zone configuration (domain names, etc.)
            // so user only needs to re-enter their API tokens
            self.isAuthenticated = false
            UserDefaults.standard.set(false, forKey: "isAuthenticated")
        }
    }
    
    /// Check if we have valid credentials to make API calls.
    /// Returns false if any required token is missing (e.g., after iCloud restore where Keychain didn't sync).
    var hasValidCredentials: Bool {
        // Check primary credentials
        guard !apiToken.isEmpty else { return false }
        
        // For multi-zone setups, ensure all zones have tokens
        // (though we allow operation if at least primary zone has a token)
        if zones.isEmpty {
            return !accountId.isEmpty && !zoneId.isEmpty
        }
        
        // Check that at least one zone has a valid token
        return zones.contains { !$0.apiToken.isEmpty }
    }
    
    /// Returns zones that need re-authentication (have zone data but no API token)
    var zonesNeedingReauth: [CloudflareZone] {
        zones.filter { $0.apiToken.isEmpty && !$0.zoneId.isEmpty }
    }
    
    /// Update the API token for a specific zone (used during re-authentication flow)
    @MainActor
    func updateZoneToken(zoneId: String, apiToken: String) async throws {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let index = zones.firstIndex(where: { $0.zoneId == zoneId }) else {
            throw CloudflareError(message: "Zone not found")
        }
        
        // Verify the token works for this zone
        guard try await verifyToken(using: token) else {
            throw CloudflareError(message: "Invalid API token")
        }
        
        // Update the zone with the new token
        zones[index].apiToken = token
        
        // If this is the primary zone, also update the primary credentials
        if zoneId == self.zoneId {
            self.apiToken = token
            KeychainHelper.shared.save(token, service: "ghostmail", account: "apiToken")
        }
        
        // Save to Keychain
        KeychainHelper.shared.save(token, service: "ghostmail", account: "apiToken_\(zoneId)")
        
        // Persist zone changes
        persistZones()
        
        // If all zones now have tokens and we were unauthenticated, set authenticated
        if !isAuthenticated && !zones.contains(where: { $0.apiToken.isEmpty }) {
            isAuthenticated = true
            UserDefaults.standard.set(true, forKey: "isAuthenticated")
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
            // Get the action type - support forward, drop, and reject
            guard let action = rule.actions.first,
                  ["forward", "drop", "reject"].contains(action.type) else {
                continue
            }
            
            let actionType = action.type
            let forwardTo = actionType == "forward" ? (action.value?.first ?? "") : ""
            
            // Skip catch-all rules or rules without a "to" matcher
            guard let matcher = rule.matchers.first,
                  matcher.type == "literal",
                  matcher.field == "to",
                  let emailAddress = matcher.value else {
                continue
            }
            
            // Skip if we've already seen this email address
            if seenEmailAddresses.contains(emailAddress) {
                continue
            }
            
            seenEmailAddresses.insert(emailAddress)
            
            let alias = CloudflareEmailRule(
                emailAddress: emailAddress,
                cloudflareTag: rule.tag,
                isEnabled: rule.enabled,
                forwardTo: forwardTo,
                zoneId: self.zoneId,
                actionType: actionType
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
            // Get the action type - support forward, drop, and reject
            guard let action = rule.actions.first,
                  ["forward", "drop", "reject"].contains(action.type) else { continue }
            let actionType = action.type
            let forwardTo = actionType == "forward" ? (action.value?.first ?? "") : ""
            
            guard let matcher = rule.matchers.first, matcher.type == "literal", matcher.field == "to", let emailAddress = matcher.value else { continue }
            if seenEmailAddresses.contains(emailAddress) { continue }
            seenEmailAddresses.insert(emailAddress)
            uniqueRules.append(CloudflareEmailRule(emailAddress: emailAddress, cloudflareTag: rule.tag, isEnabled: rule.enabled, forwardTo: forwardTo, zoneId: zone.zoneId, actionType: actionType))
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
    
    // MARK: - Analytics
    
    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
    }
    
    private struct GraphQLError: Decodable {
        let message: String
    }
    
    private struct EmailRoutingAnalyticsData: Decodable {
        let viewer: Viewer
    }
    
    private struct Viewer: Decodable {
        let zones: [ZoneAnalytics]
    }
    
    private struct ZoneAnalytics: Decodable {
        let emailRoutingAdaptive: [EmailLogEntry]
    }
    
    private struct EmailLogEntry: Decodable {
        let to: String
        let from: String
        let datetime: String
        let action: String  // "forward", "drop", or "reject"
    }

    /// Fetch email statistics with smart delta optimization
    /// - Parameters:
    ///   - zone: The Cloudflare zone to fetch statistics for
    ///   - cachedData: Optional cached statistics to merge with (enables delta fetch)
    ///   - cacheTimestamp: When the cached data was last fetched (enables delta fetch)
    ///   - forceFull: Force a full 7-day fetch even if cache exists
    /// - Returns: Array of EmailStatistic covering the last 7 days
    func fetchEmailStatistics(
        for zone: CloudflareZone,
        cachedData: [EmailStatistic]? = nil,
        cacheTimestamp: Date? = nil,
        forceFull: Bool = false
    ) async throws -> [EmailStatistic] {
        let url = URL(string: "\(baseURL)/graphql")!
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        // Cloudflare raw logs have a 24-hour limit per query.
        // We'll fetch in 24-hour chunks in parallel.
        
        let now = Date()
        let calendar = Calendar.current
        var tasks: [Task<[String: [EmailStatistic.EmailDetail]], Error>] = []
        
        // Smart delta fetch optimization:
        // If we have recent cached data (< 24 hours old), only fetch today's data
        // and merge with cached historical data. This reduces API calls from 7 to 1.
        let daysToFetch: Int
        let useDeltaFetch: Bool
        
        if !forceFull,
           let cacheTime = cacheTimestamp,
           let cached = cachedData,
           !cached.isEmpty {
            let cacheAge = now.timeIntervalSince(cacheTime)
            let cacheAgeHours = cacheAge / 3600
            
            if cacheAgeHours < 24 {
                // Cache is fresh enough - only fetch today, yesterday, and day before for overlap safety
                // This ensures we have full coverage at day boundaries
                daysToFetch = 3
                useDeltaFetch = true
                print("📊 Delta fetch: Cache is \(Int(cacheAgeHours))h old, fetching \(daysToFetch) days only")
            } else {
                // Cache is too old, do full fetch
                daysToFetch = 7
                useDeltaFetch = false
                print("📊 Full fetch: Cache is \(Int(cacheAgeHours))h old")
            }
        } else {
            // No cache or forced full fetch
            daysToFetch = 7
            useDeltaFetch = false
            print("📊 Full fetch: No cache available or forced refresh")
        }
        
        for i in 0..<daysToFetch {
            let endDate = calendar.date(byAdding: .day, value: -i, to: now)!
            let startDate = calendar.date(byAdding: .day, value: -1, to: endDate)!
            
            // Format dates outside the Task to avoid capturing non-Sendable ISO8601DateFormatter
            let startDateString = isoFormatter.string(from: startDate)
            let endDateString = isoFormatter.string(from: endDate)
            
            let task = Task {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.allHTTPHeaderFields = [
                    "Authorization": "Bearer \(zone.apiToken)",
                    "Content-Type": "application/json"
                ]
                
                let query = """
                query Viewer {
                  viewer {
                    zones(filter: {zoneTag: "\(zone.zoneId)"}) {
                      emailRoutingAdaptive(
                        filter: {datetime_geq: "\(startDateString)", datetime_leq: "\(endDateString)"},
                        limit: 10000
                      ) {
                        to
                        from
                        datetime
                        action
                      }
                    }
                  }
                }
                """
                
                let body = ["query": query]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw CloudflareError(message: "Failed to fetch analytics chunk")
                }
                
                let graphQLResponse = try JSONDecoder().decode(GraphQLResponse<EmailRoutingAnalyticsData>.self, from: data)
                
                if let errors = graphQLResponse.errors, let firstError = errors.first {
                    // Ignore "time range too large" errors if they happen for some reason, just return empty
                    print("GraphQL Error: \(firstError.message)")
                    return [String: [EmailStatistic.EmailDetail]]()
                }
                
                guard let logs = graphQLResponse.data?.viewer.zones.first?.emailRoutingAdaptive else {
                    return [String: [EmailStatistic.EmailDetail]]()
                }
                
                // Parse dates inside the task
                let taskIsoFormatter = ISO8601DateFormatter()
                taskIsoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                return logs.reduce(into: [String: [EmailStatistic.EmailDetail]]()) { result, log in
                    let action = EmailRoutingAction(from: log.action)
                    if let date = taskIsoFormatter.date(from: log.datetime) {
                        result[log.to, default: []].append(EmailStatistic.EmailDetail(from: log.from, date: date, action: action))
                    } else {
                        // Fallback for dates without fractional seconds
                        let fallbackFormatter = ISO8601DateFormatter()
                        fallbackFormatter.formatOptions = [.withInternetDateTime]
                        if let date = fallbackFormatter.date(from: log.datetime) {
                            result[log.to, default: []].append(EmailStatistic.EmailDetail(from: log.from, date: date, action: action))
                        }
                    }
                }
            }
            tasks.append(task)
        }
        
        var totalDetails: [String: [EmailStatistic.EmailDetail]] = [:]
        
        for task in tasks {
            do {
                let chunkDetails = try await task.value
                for (email, details) in chunkDetails {
                    totalDetails[email, default: []].append(contentsOf: details)
                }
            } catch {
                print("Failed to fetch chunk: \(error)")
                // Continue with other chunks
            }
        }
        
        // If delta fetch, merge fresh data with cached historical data
        if useDeltaFetch, let cached = cachedData {
            // Calculate the actual start time of our fresh fetch window
            // For i=0: startDate = yesterday at current time
            // For i=daysToFetch-1: startDate = (daysToFetch days ago) at current time
            // We need to keep cached data that's OLDER than our oldest fetch window start
            let oldestFetchStart = calendar.date(byAdding: .day, value: -daysToFetch, to: now)!
            
            // Merge: keep cached details that are older than our fresh fetch window
            for cachedStat in cached {
                let olderDetails = cachedStat.emailDetails.filter { detail in
                    detail.date < oldestFetchStart
                }
                
                if !olderDetails.isEmpty {
                    // Add older cached details to our fresh data
                    totalDetails[cachedStat.emailAddress, default: []].append(contentsOf: olderDetails)
                }
            }
            
            print("📊 Delta merge: Combined fresh data with \(cached.count) cached email addresses")
        }
        
        return totalDetails.map { 
            let sortedDetails = $0.value.sorted { $0.date > $1.date }
            return EmailStatistic(
                emailAddress: $0.key, 
                count: $0.value.count, 
                receivedDates: sortedDetails.map { $0.date },
                emailDetails: sortedDetails
            )
        }
        .sorted { $0.count > $1.count }
    }
    
    func validateAnalyticsPermission(for zone: CloudflareZone) async throws -> Bool {
        let url = URL(string: "\(baseURL)/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]
        
        // Lightweight query to check permissions
        let query = """
        query Viewer {
          viewer {
            zones(filter: {zoneTag: "\(zone.zoneId)"}) {
              emailRoutingAdaptive(limit: 1) {
                to
              }
            }
          }
        }
        """
        
        let body = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
             return false
        }
        
        let graphQLResponse = try JSONDecoder().decode(GraphQLResponse<EmailRoutingAnalyticsData>.self, from: data)
        
        if let errors = graphQLResponse.errors, !errors.isEmpty {
            // If we get errors, likely permission denied or invalid query due to permissions
            return false
        }
        
        return true
    }
    
    // MARK: - Catch-All Rule
    
    /// Fetch the catch-all rule status for a specific zone
    /// - Parameter zone: The zone to check
    /// - Returns: The catch-all status (disabled, forward, drop, etc.)
    func fetchCatchAllStatus(for zone: CloudflareZone) async throws -> CatchAllStatus {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules/catch_all")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareError(message: "Invalid response")
        }
        
        // Log response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("📧 Catch-all GET response (\(httpResponse.statusCode)): \(responseString.prefix(500))")
        }
        
        // Handle different status codes
        if httpResponse.statusCode == 404 {
            // No catch-all rule configured - this is normal for zones without catch-all set up
            print("📧 No catch-all rule configured for this zone (404)")
            return .disabled
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                throw CloudflareError(message: errorResponse.errors.first?.message ?? "Failed to fetch catch-all status")
            }
            throw CloudflareError(message: "Failed to fetch catch-all status (HTTP \(httpResponse.statusCode))")
        }
        
        let catchAllResponse = try JSONDecoder().decode(CatchAllResponse.self, from: data)
        
        guard let rule = catchAllResponse.result else {
            return .disabled
        }
        
        // If not enabled, return disabled
        if !rule.enabled {
            return .disabled
        }
        
        // Determine the action type from the first action
        guard let action = rule.actions.first else {
            return .unknown
        }
        
        switch action.type.lowercased() {
        case "forward":
            return .forward(to: action.value ?? [])
        case "drop":
            return .drop
        case "worker":
            return .worker
        default:
            return .unknown
        }
    }
    
    /// Fetch catch-all status using zone ID (convenience method for primary zone)
    func fetchCatchAllStatus(forZoneId zoneId: String) async throws -> CatchAllStatus {
        guard let zone = zones.first(where: { $0.zoneId == zoneId }) else {
            // Fallback: create a temporary zone struct with primary credentials
            let tempZone = CloudflareZone(
                accountId: self.accountId,
                zoneId: zoneId,
                apiToken: self.apiToken,
                accountName: self.accountName,
                domainName: self.domainName
            )
            return try await fetchCatchAllStatus(for: tempZone)
        }
        return try await fetchCatchAllStatus(for: zone)
    }
    
    // MARK: - Update Catch-All Rule
    
    /// Update the catch-all rule for a zone
    /// - Parameters:
    ///   - zone: The zone to update
    ///   - enabled: Whether catch-all should be enabled
    ///   - action: The action type ("forward" or "drop")
    ///   - forwardTo: Array of email addresses to forward to (only used when action is "forward")
    func updateCatchAllRule(
        for zone: CloudflareZone,
        enabled: Bool,
        action: String = "drop",
        forwardTo: [String] = []
    ) async throws {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules/catch_all")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]
        
        // Build the request body
        var actions: [[String: Any]] = []
        
        if action == "forward" && !forwardTo.isEmpty {
            actions.append([
                "type": "forward",
                "value": forwardTo
            ])
        } else {
            actions.append([
                "type": "drop"
            ])
        }
        
        let body: [String: Any] = [
            "enabled": enabled,
            "matchers": [
                ["type": "all"]
            ],
            "actions": actions,
            "name": "Catch-All Rule"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareError(message: "Invalid response")
        }
        
        // Log the response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("📧 Catch-all update response (\(httpResponse.statusCode)): \(responseString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(CloudflareErrorResponse.self, from: data) {
                let errorMsg = errorResponse.errors.first?.message ?? "Failed to update catch-all rule"
                
                // Check for common error scenarios
                if errorMsg.contains("not enabled") || errorMsg.contains("not configured") {
                    throw CloudflareError(message: "Email Routing is not enabled for this zone. Please enable Email Routing in Cloudflare Dashboard first.")
                }
                
                throw CloudflareError(message: errorMsg)
            }
            
            // Handle 5xx errors that might indicate Email Routing isn't set up
            if httpResponse.statusCode >= 500 {
                throw CloudflareError(message: "Cloudflare server error. Email Routing may not be configured for this zone. Please check the Cloudflare Dashboard.")
            }
            
            throw CloudflareError(message: "Failed to update catch-all rule (HTTP \(httpResponse.statusCode)). This zone may require Email Routing to be configured first in the Cloudflare Dashboard.")
        }
        
        print("✅ Catch-all rule updated successfully for zone \(zone.zoneId)")
    }
    
    /// Update catch-all rule using zone ID (convenience method)
    func updateCatchAllRule(
        forZoneId zoneId: String,
        enabled: Bool,
        action: String = "drop",
        forwardTo: [String] = []
    ) async throws {
        guard let zone = zones.first(where: { $0.zoneId == zoneId }) else {
            throw CloudflareError(message: "Zone not found")
        }
        try await updateCatchAllRule(for: zone, enabled: enabled, action: action, forwardTo: forwardTo)
    }
    
    /// Check analytics permissions for all zones and enable the setting if any zone permits it.
    /// This only enables analytics if currently disabled - it won't override a user's choice to disable.
    /// - Returns: true if analytics was enabled (or already enabled), false if no permission
    @discardableResult
    func checkAndEnableAnalyticsIfPermitted() async -> Bool {
        // Check current setting - don't override if user explicitly enabled/disabled
        let currentSetting = UserDefaults.standard.bool(forKey: "showAnalytics")
        
        // Only auto-enable if currently disabled (first-time setup scenario)
        // If we wanted to always check and potentially enable: remove this early return
        if currentSetting {
            print("[Analytics] Already enabled, skipping permission check")
            return true
        }
        
        // Get all zones with valid tokens
        let validZones = zones.filter { !$0.apiToken.isEmpty }
        guard !validZones.isEmpty else {
            print("[Analytics] No zones with valid tokens, cannot check permissions")
            return false
        }
        
        print("[Analytics] Checking analytics permissions for \(validZones.count) zone(s)")
        
        // Check if ANY zone has analytics permission
        for zone in validZones {
            do {
                let hasPermission = try await validateAnalyticsPermission(for: zone)
                if hasPermission {
                    print("[Analytics] Permission granted for zone \(zone.domainName.isEmpty ? zone.zoneId : zone.domainName) - enabling analytics")
                    await MainActor.run {
                        UserDefaults.standard.set(true, forKey: "showAnalytics")
                    }
                    return true
                }
            } catch {
                print("[Analytics] Error checking permissions for zone: \(error.localizedDescription)")
                // Continue checking other zones
            }
        }
        
        print("[Analytics] No zones have analytics permission")
        return false
    }

    @MainActor
    func updateCredentials(accountId: String, zoneId: String, apiToken: String) {
        self.accountId = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.zoneId = zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        

        // Save to Keychain
        KeychainHelper.shared.save(self.accountId, service: "ghostmail", account: "accountId")
        KeychainHelper.shared.save(self.zoneId, service: "ghostmail", account: "zoneId")
        KeychainHelper.shared.save(self.apiToken, service: "ghostmail", account: "apiToken")
        
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
            // Preserve existing settings when updating credentials
            let existingSubdomainsEnabled = zones[idx].subdomainsEnabled
            let existingSubdomains = zones[idx].subdomains
            zones[idx].accountId = accountId
            zones[idx].apiToken = apiToken
            zones[idx].subdomainsEnabled = existingSubdomainsEnabled
            zones[idx].subdomains = existingSubdomains
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
        // Remove from Keychain
        KeychainHelper.shared.delete(service: "ghostmail", account: "accountId")
        KeychainHelper.shared.delete(service: "ghostmail", account: "zoneId")
        KeychainHelper.shared.delete(service: "ghostmail", account: "apiToken")
        defaults.removeObject(forKey: "isAuthenticated")
    zones = []
    defaults.removeObject(forKey: "cloudflareZones")
    }
    
    func updateEmailRule(tag: String, emailAddress: String, isEnabled: Bool, forwardTo: String, actionType: String = "forward") async throws {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = headers
        
        // Build actions based on action type
        let actions: [[String: Any]]
        if actionType == "forward" {
            actions = [["type": "forward", "value": [forwardTo]]]
        } else {
            actions = [["type": actionType]]  // drop or reject don't need a value
        }
        
        let rule: [String: Any] = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": actions,
            "enabled": isEnabled,
            "priority": 0
        ]
        
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
    func updateEmailRule(tag: String, emailAddress: String, isEnabled: Bool, forwardTo: String, in zone: CloudflareZone, actionType: String = "forward") async throws {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/email/routing/rules/\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]

        // Build actions based on action type
        let actions: [[String: Any]]
        if actionType == "forward" {
            actions = [["type": "forward", "value": [forwardTo]]]
        } else {
            actions = [["type": actionType]]  // drop or reject don't need a value
        }

        let rule: [String: Any] = [
            "matchers": [
                [
                    "type": "literal",
                    "field": "to",
                    "value": emailAddress
                ]
            ],
            "actions": actions,
            "enabled": isEnabled,
            "priority": 0
        ]

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
    
    // Ensure we have the current forwarding addresses available - now with caching
    func ensureForwardingAddressesLoaded() async throws {
        // Check if we have valid cached data
        let cacheAge = Date().timeIntervalSince(lastForwardingAddressesFetch)
        if !forwardingAddressesCache.isEmpty && cacheAge < cacheValidityDuration {
            await MainActor.run {
                self.forwardingAddresses = forwardingAddressesCache
            }
            return
        }
        
        if forwardingAddresses.isEmpty {
            
            do {
                try await refreshForwardingAddresses()
                
                // Add fallback logic if we couldn't get any verified addresses
                if forwardingAddresses.isEmpty {
                    // Check if we at least have a default forwarding email stored
                    if !forwardingEmail.isEmpty {
                        await MainActor.run {
                            self.forwardingAddresses = [forwardingEmail]
                            self.forwardingAddressesCache = [forwardingEmail]
                        }
                    } else if !accountId.isEmpty {
                        // As a last resort, create a dummy fallback to prevent UI issues
                        let fallbackEmail = "default@\(emailDomain)"
                        await MainActor.run {
                            self.forwardingAddresses = [fallbackEmail]
                            self.forwardingAddressesCache = [fallbackEmail]
                        }
                    } else {
                        throw CloudflareError(message: "No forwarding addresses available and unable to create fallback.")
                    }
                }
            } catch {
                throw error
            }
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
            await MainActor.run {
                self.forwardingAddresses = forwardingAddressesCache
            }
            return
        }
        
        do {
            // Fetch fresh from the Cloudflare API
            try await fetchForwardingAddresses()
            
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
                // Consider an address verified if it has a non-nil, non-empty verified timestamp
                let verifiedAddresses = Set(
                    addressResponse.result
                        .filter { $0.verified != nil && !$0.verified!.isEmpty }
                        .map { $0.email }
                )
                
                if verifiedAddresses.isEmpty && !addressResponse.result.isEmpty {
                    print("Warning: Found addresses but none are verified")
                }
                
                await MainActor.run {
                    self.forwardingAddresses = verifiedAddresses
                }
            } else {
                let errorMessage = addressResponse.errors.first?.message ?? "Failed to get forwarding addresses from response"
                throw CloudflareError(message: errorMessage)
            }
        } catch let decodingError as DecodingError {
            throw CloudflareError(message: "Failed to decode API response: \(decodingError.localizedDescription)")
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

    // Persist zones to UserDefaults (excluding sensitive tokens)
    private func persistZones() {
        // Convert to persisted format (excluding tokens)
        let persistedZones = zones.map { zone in
            PersistedCloudflareZone(
                accountId: zone.accountId,
                zoneId: zone.zoneId,
                accountName: zone.accountName,
                domainName: zone.domainName,
                subdomains: zone.subdomains,
                subdomainsEnabled: zone.subdomainsEnabled
            )
        }
        
        if let data = try? JSONEncoder().encode(persistedZones) {
            UserDefaults.standard.set(data, forKey: "cloudflareZones")
        }
        
        // Save tokens to Keychain for each zone
        for zone in zones {
            // Skip saving if token is empty (though it shouldn't be for a valid zone)
            guard !zone.apiToken.isEmpty else { continue }
            KeychainHelper.shared.save(zone.apiToken, service: "ghostmail", account: "apiToken_\(zone.zoneId)")
            
            // If this is the primary zone, also save to the primary key
            if zone.zoneId == self.zoneId {
                KeychainHelper.shared.save(zone.apiToken, service: "ghostmail", account: "apiToken")
            }
        }
    }

    // Remove a zone locally without touching Cloudflare or iCloud.
    // If the removed zone is the current primary, switch to another configured zone if available,
    // otherwise perform a full logout.
    @MainActor
    func removeZone(zoneId removedZoneId: String) {
        // Remove token from Keychain
        KeychainHelper.shared.delete(service: "ghostmail", account: "apiToken_\(removedZoneId)")
        
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
                KeychainHelper.shared.save(accountId, service: "ghostmail", account: "accountId")
                KeychainHelper.shared.save(zoneId, service: "ghostmail", account: "zoneId")
                KeychainHelper.shared.save(apiToken, service: "ghostmail", account: "apiToken")
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

    // Fetch subdomains with MX records for email routing
    func fetchSubdomains(for zone: CloudflareZone) async throws -> [String] {
        let url = URL(string: "\(baseURL)/zones/\(zone.zoneId)/dns_records?type=MX")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = [
            "Authorization": "Bearer \(zone.apiToken)",
            "Content-Type": "application/json"
        ]
        
        print("[Cloudflare] Fetching MX records for zone \(maskId(zone.zoneId))")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            print("[Cloudflare] Failed to fetch DNS records: status=\(statusCode), body=\(body)")
            
            // Check for permissions error (403)
            if statusCode == 403 {
                throw CloudflareError(message: "Unable to check for subdomains\n\nEnsure the API key has permissions:\nZone > DNS > Read")
            }
            
            throw CloudflareError(message: "Failed to fetch DNS records (HTTP \(statusCode))")
        }
        
        struct DNSRecord: Codable {
            let name: String
            let type: String
            let meta: Meta?
            
            struct Meta: Codable {
                let email_routing: Bool?
            }
        }
        
        struct DNSResponse: Codable {
            let result: [DNSRecord]
            let success: Bool
        }
        
        let dnsResponse = try JSONDecoder().decode(DNSResponse.self, from: data)
        guard dnsResponse.success else {
            throw CloudflareError(message: "Failed to decode DNS records")
        }
        
        // Get the top-level domain name to filter it out
        let topLevelDomain = zone.domainName.lowercased()
        
        // Filter for MX records with email_routing enabled, excluding the top-level domain
        let subdomains = dnsResponse.result
            .filter { record in
                record.type == "MX" && 
                (record.meta?.email_routing == true) &&
                record.name.lowercased() != topLevelDomain  // Exclude top-level domain
            }
            .map { $0.name }
            .sorted()
        
        // Remove duplicates
        let uniqueSubdomains = Array(Set(subdomains)).sorted()
        
        print("[Cloudflare] Found \(uniqueSubdomains.count) subdomains with email routing (excluding top-level domain): \(uniqueSubdomains)")
        
        return uniqueSubdomains
    }
    
    // Refresh subdomains for all zones (only for zones with subdomainsEnabled)
    @MainActor
    func refreshSubdomainsAllZones() async throws {
        print("[Cloudflare] Refreshing subdomains for enabled zones")
        
        for (index, zone) in zones.enumerated() {
            // Skip zones that don't have subdomains enabled
            guard zone.subdomainsEnabled else {
                print("[Cloudflare] Skipping subdomain fetch for zone \(maskId(zone.zoneId)) (disabled)")
                continue
            }
            
            do {
                let subdomains = try await fetchSubdomains(for: zone)
                zones[index].subdomains = subdomains
            } catch {
                print("[Cloudflare] Failed to fetch subdomains for zone \(maskId(zone.zoneId)): \(error)")
                // Continue with other zones even if one fails
            }
        }
        
        persistZones()
        print("[Cloudflare] Subdomain refresh complete")
    }
    
    // Toggle subdomain discovery for a specific zone
    // Returns an error if enabling fails, nil on success
    @MainActor
    func toggleSubdomains(for zoneId: String, enabled: Bool) async throws {
        guard let index = zones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        
        // If disabling, just clear and persist
        if !enabled {
            zones[index].subdomainsEnabled = false
            zones[index].subdomains = []
            persistZones()
            return
        }
        
        // If enabling, try to fetch subdomains first to validate permissions
        do {
            let subdomains = try await fetchSubdomains(for: zones[index])
            // Success - now enable and save
            zones[index].subdomainsEnabled = true
            zones[index].subdomains = subdomains
            persistZones()
        } catch {
            // Failed - don't enable, re-throw the error (already formatted in fetchSubdomains)
            print("[Cloudflare] Failed to fetch subdomains after enabling: \(error)")
            throw error
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
    
    // MARK: - Sync Logic
    
    @MainActor
    func syncEmailRules(modelContext: ModelContext) async throws {
        var cloudflareRules = try await getEmailRulesAllZones()
        
        // Handle potential duplicates in Cloudflare rules
        // Keep track of seen email addresses and only include the first occurrence
        var seenEmails = Set<String>()
        cloudflareRules = cloudflareRules.filter { rule in
            guard !seenEmails.contains(rule.emailAddress) else {
                print("⚠️ Skipping duplicate email rule for: \(rule.emailAddress)")
                return false
            }
            seenEmails.insert(rule.emailAddress)
            return true
        }
        
        // Create dictionaries for lookup (now safe because we've removed duplicates)
        let cloudflareRulesByEmail = Dictionary(
            uniqueKeysWithValues: cloudflareRules.map { ($0.emailAddress, $0) }
        )
        
        // Build dictionary for existing aliases across zones, including logged-out ones
        // so we can reactivate instead of creating duplicates
        var existingAliasesMap: [String: EmailAlias] = [:]
        do {
            let descriptor = FetchDescriptor<EmailAlias>()
            let allExisting = try modelContext.fetch(descriptor)
            for alias in allExisting {
                if let current = existingAliasesMap[alias.emailAddress] {
                    // Prefer non-logged-out entries; otherwise prefer the one with richer metadata
                    if current.isLoggedOut && !alias.isLoggedOut {
                        existingAliasesMap[alias.emailAddress] = alias
                    } else if current.isLoggedOut == alias.isLoggedOut {
                        // Tie-breaker: prefer the one with more metadata
                        let currentMeta = (current.notes.isEmpty ? 0 : 1) + (current.website.isEmpty ? 0 : 1)
                        let aliasMeta = (alias.notes.isEmpty ? 0 : 1) + (alias.website.isEmpty ? 0 : 1)
                        if aliasMeta > currentMeta {
                            existingAliasesMap[alias.emailAddress] = alias
                        }
                    }
                } else {
                    existingAliasesMap[alias.emailAddress] = alias
                }
            }
        } catch {
            print("Error fetching existing aliases for refresh: \(error)")
        }
        
        // Remove deleted aliases, but only those that belong to configured zones and are missing there
        let configuredZoneIds = Set(zones.map { $0.zoneId })
        // We need to fetch all aliases again or use the map values to check for deletion
        // Using a fresh fetch to be safe and iterate
        let descriptor = FetchDescriptor<EmailAlias>()
        if let allAliases = try? modelContext.fetch(descriptor) {
            for alias in allAliases {
                // Only consider deleting if alias has a zoneId and belongs to a configured zone
                guard !alias.zoneId.isEmpty, configuredZoneIds.contains(alias.zoneId) else { continue }
                // If no matching rule exists for that email in the aggregated set AND the email does not exist under any zone, delete
                if cloudflareRulesByEmail[alias.emailAddress] == nil {
                    print("Deleting alias not found in any configured zones: \(alias.emailAddress) [zone: \(alias.zoneId)]")
                    modelContext.delete(alias)
                }
            }
        }
        
        // Update or create aliases
        for (index, rule) in cloudflareRules.enumerated() {
            let emailAddress = rule.emailAddress
            let forwardTo = rule.forwardTo
            let actionType = EmailRuleActionType(rawValue: rule.actionType) ?? .forward
            
            if let existing = existingAliasesMap[emailAddress] {
                // Reactivate if it was logged out and update fields
                let newZoneId = rule.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                // Note: withAnimation is a View modifier, we shouldn't use it here in the logic layer.
                // The View observing the data will animate changes if configured to do so.
                existing.isLoggedOut = false
                existing.cloudflareTag = rule.cloudflareTag
                existing.isEnabled = rule.isEnabled
                existing.forwardTo = forwardTo
                existing.actionType = actionType
                existing.sortIndex = index + 1
                existing.zoneId = newZoneId
            } else {
                // Create new alias with proper properties
                let newAlias = EmailAlias(
                    emailAddress: emailAddress,
                    forwardTo: forwardTo,
                    zoneId: rule.zoneId,
                    actionType: actionType
                )
                newAlias.cloudflareTag = rule.cloudflareTag
                newAlias.isEnabled = rule.isEnabled
                newAlias.sortIndex = index + 1
                
                // Set the user identifier to ensure cross-device ownership
                newAlias.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                
                modelContext.insert(newAlias)
            }
        }
        
        // Save once after all updates and run a quick dedup pass to merge any stragglers
        try modelContext.save()
        do {
            let removed = try EmailAlias.deduplicate(in: modelContext)
            if removed > 0 { print("Deduplicated \(removed) aliases during refresh (post-reactivation)") }
        } catch {
            print("Deduplication error: \(error)")
        }
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

// MARK: - Catch-All Rule Types

struct CatchAllRule: Codable {
    let enabled: Bool
    let name: String?
    let matchers: [CatchAllMatcher]
    let actions: [CatchAllAction]
}

struct CatchAllMatcher: Codable {
    let type: String  // "all" for catch-all
}

struct CatchAllAction: Codable {
    let type: String  // "forward", "drop", or "worker"
    let value: [String]?
}

struct CatchAllResponse: Codable {
    let result: CatchAllRule?
    let success: Bool
    let errors: [CloudflareErrorDetail]?
}

/// Represents the catch-all configuration status for a zone
enum CatchAllStatus: Equatable {
    case disabled
    case forward(to: [String])
    case drop
    case worker
    case unknown
    
    var displayText: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .forward(let addresses):
            if addresses.isEmpty {
                return "Forward (no address)"
            }
            return "Forward to \(addresses.joined(separator: ", "))"
        case .drop:
            return "Drop"
        case .worker:
            return "Worker"
        case .unknown:
            return "Unknown"
        }
    }
    
    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        default:
            return true
        }
    }
    
    var systemImage: String {
        switch self {
        case .disabled:
            return "xmark.circle"
        case .forward:
            return "arrow.right.circle"
        case .drop:
            return "trash.circle"
        case .worker:
            return "gearshape.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .disabled:
            return .secondary
        case .forward:
            return .green
        case .drop:
            return .orange
        case .worker:
            return .blue
        case .unknown:
            return .secondary
        }
    }
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
    let forwardTo: String  // Empty string for drop/reject actions
    let zoneId: String
    let actionType: String  // "forward", "drop", or "reject"
    
    // Add any other properties needed for email rules
}

// Internal struct for persisting zones without tokens
struct PersistedCloudflareZone: Codable {
    var accountId: String
    var zoneId: String
    var accountName: String
    var domainName: String
    var subdomains: [String]
    var subdomainsEnabled: Bool
} 
