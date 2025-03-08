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
    
    @AppStorage("forwardingEmail") private var forwardingEmail: String = ""
    @Published private(set) var forwardingAddresses: Set<String> = []
    @AppStorage("defaultForwardingAddress") private var defaultForwardingAddress: String = ""
    @AppStorage("showWebsitesInList") private var showWebsitesInList: Bool = true
    
    @Published private(set) var domainName: String = ""
    
    init(accountId: String = "", zoneId: String = "", apiToken: String = "") {
        // Load stored credentials
        let defaults = UserDefaults.standard
        self.accountId = defaults.string(forKey: "accountId") ?? accountId
        self.zoneId = defaults.string(forKey: "zoneId") ?? zoneId
        self.apiToken = defaults.string(forKey: "apiToken") ?? apiToken
        self.isAuthenticated = defaults.bool(forKey: "isAuthenticated")
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
        let url = URL(string: "\(baseURL)/user/tokens/verify")!
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }
        return true
    }
    
    // Get email rules from Cloudflare (returns custom type to avoid circular dependencies)
    func getEmailRules() async throws -> [CloudflareEmailRule] {
        if domainName.isEmpty {
            try await fetchDomainName()
        }
        
        // Fetch forwarding addresses first
        try await refreshForwardingAddresses()
        
        // Fetch all entries from Cloudflare in chunks of 50
        var allRules: [EmailRule] = []
        var currentPage = 1
        let perPage = 50  // Match the server's actual per_page value
        
        while true {
            let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules?page=\(currentPage)&per_page=\(perPage)")!
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            
            print("Requesting URL: \(url.absoluteString)")
            
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
        
        // Collect all unique forwarding addresses
        let forwards = Set(allRules.compactMap { rule -> String? in
            // Only consider forward actions
            guard let forwardAction = rule.actions.first(where: { $0.type == "forward" }),
                  let values = forwardAction.value,
                  let firstValue = values.first else { return nil }
            return firstValue
        })
        
        await MainActor.run {
            self.forwardingAddresses = forwards
        }
        
        return allRules.compactMap { rule in
            // Skip rules that don't have email forwarding
            guard let forwardAction = rule.actions.first(where: { $0.type == "forward" }),
                  let forwardTo = forwardAction.value?.first else {
                return nil
            }
            
            // Skip catch-all rules or rules without a "to" matcher
            guard let matcher = rule.matchers.first,
                  matcher.type == "literal",
                  matcher.field == "to",
                  let emailAddress = matcher.value else {
                return nil
            }
            
            print("Creating alias for \(emailAddress) with forward to: \(forwardTo)")
            
            let alias = CloudflareEmailRule(
                emailAddress: emailAddress,
                cloudflareTag: rule.tag,
                isEnabled: rule.enabled,
                forwardTo: forwardTo
            )
            
            return alias
        }
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
    
    @MainActor
    func updateCredentials(accountId: String, zoneId: String, apiToken: String) {
        self.accountId = accountId
        self.zoneId = zoneId
        self.apiToken = apiToken
        
        let defaults = UserDefaults.standard
        defaults.set(accountId, forKey: "accountId")
        defaults.set(zoneId, forKey: "zoneId")
        defaults.set(apiToken, forKey: "apiToken")
        
        // Fetch the domain name when credentials are updated
        Task {
            do {
                try await fetchDomainName()
            } catch {
                print("Error fetching domain name: \(error)")
            }
        }
    }
    
    @MainActor
    func logout() {
        accountId = ""
        zoneId = ""
        apiToken = ""
        isAuthenticated = false
        
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "accountId")
        defaults.removeObject(forKey: "zoneId")
        defaults.removeObject(forKey: "apiToken")
        defaults.removeObject(forKey: "isAuthenticated")
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
    
    // Ensure we have the current forwarding addresses available
    func ensureForwardingAddressesLoaded() async throws {
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
                        }
                    } else if !accountId.isEmpty {
                        // As a last resort, create a dummy fallback to prevent UI issues
                        let fallbackEmail = "default@\(emailDomain)"
                        print("No stored email available. Using generated fallback: \(fallbackEmail)")
                        await MainActor.run {
                            self.forwardingAddresses = [fallbackEmail]
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
    
    var shouldShowWebsitesInList: Bool {
        get { showWebsitesInList }
        set { showWebsitesInList = newValue }
    }
    
    private func fetchDomainName() async throws {
        let url = URL(string: "\(baseURL)/zones/\(zoneId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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
            await MainActor.run {
                self.domainName = zoneResponse.result.name
                self.accountName = zoneResponse.result.account.name
            }
        } else {
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
        
        do {
            // Always fetch fresh from the Cloudflare API, never from cache or iCloud
            print("Calling fetchForwardingAddresses() directly")
            try await fetchForwardingAddresses()
            print("Successfully refreshed forwarding addresses. Count: \(self.forwardingAddresses.count)")
            
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
        print("Fetching forwarding addresses directly from Cloudflare API")
        // Get the full API URL with account ID
        let addressEndpoint = "\(baseURL)/accounts/\(accountId)/email/routing/addresses"
        print("API Endpoint: \(addressEndpoint)")
        
        let url = URL(string: addressEndpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        
        // Add logging of headers (without the actual API token for security)
        var logHeaders = headers
        if logHeaders["Authorization"] != nil {
            logHeaders["Authorization"] = "Bearer [REDACTED]"
        }
        print("Request headers: \(logHeaders)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            let error = CloudflareError(message: "Invalid HTTP response")
            print("Error: Invalid HTTP response")
            throw error
        }
        
        print("Response status code: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            // Log the response body to help diagnose issues
            if let errorText = String(data: data, encoding: .utf8) {
                print("Error response: \(errorText)")
            }
            
            let error = CloudflareError(message: "Failed to fetch forwarding addresses (HTTP \(httpResponse.statusCode))")
            print("Error: \(error.message)")
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
    
    // Add any other properties needed for email rules
} 
