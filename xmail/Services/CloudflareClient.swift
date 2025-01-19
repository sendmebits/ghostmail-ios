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
    
    func getEmailRules() async throws -> [EmailAlias] {
        if domainName.isEmpty {
            try await fetchDomainName()
        }
        
        // Fetch forwarding addresses first
        try await fetchForwardingAddresses()
        
        // Fetch all entries from Cloudflare in chunks of 100
        var allRules: [EmailRule] = []
        var currentPage = 1
        let perPage = 100  // Increased to 100 to reduce number of API calls
        
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
                let totalPages = (resultInfo.total_count + perPage - 1) / perPage
                if currentPage >= totalPages {
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
            let forwardTo = rule.actions.first { $0.type == "forward" }?.value.first
            print("Found forwarding address: \(forwardTo ?? "nil") for email: \(rule.matchers.first?.value ?? "unknown")")
            return forwardTo
        })
        
        await MainActor.run {
            self.forwardingAddresses = forwards
        }
        
        return allRules.map { rule in
            let emailAddress = rule.matchers.first { $0.field == "to" }?.value ?? ""
            let forwardTo = rule.actions.first { $0.type == "forward" }?.value.first ?? ""
            
            print("Creating alias for \(emailAddress) with forward to: \(forwardTo)")
            
            let alias = EmailAlias(
                emailAddress: emailAddress,
                forwardTo: forwardTo
            )
            alias.cloudflareTag = rule.tag
            alias.isEnabled = rule.enabled
            
            print("Created alias with forward to: \(alias.forwardTo)")
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
    
    var currentDefaultForwardingAddress: String {
        // If the stored default is in the available addresses, use it
        if forwardingAddresses.contains(defaultForwardingAddress) {
            return defaultForwardingAddress
        }
        // Otherwise return the first available address or empty string
        return forwardingAddresses.first ?? ""
    }
    
    func setDefaultForwardingAddress(_ address: String) {
        defaultForwardingAddress = address
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
            struct Result: Codable {
                let name: String
            }
            let result: Result
            let success: Bool
        }
        
        let zoneResponse = try JSONDecoder().decode(ZoneResponse.self, from: data)
        
        if zoneResponse.success {
            await MainActor.run {
                self.domainName = zoneResponse.result.name
            }
        } else {
            throw CloudflareError(message: "Failed to get domain name from zone response")
        }
    }
    
    private func fetchForwardingAddresses() async throws {
        let url = URL(string: "\(baseURL)/accounts/\(accountId)/email/routing/addresses")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CloudflareError(message: "Failed to fetch forwarding addresses")
        }
        
        let addressResponse = try JSONDecoder().decode(AddressResponse.self, from: data)
        
        if addressResponse.success {
            // Consider an address verified if it has a verified timestamp
            let verifiedAddresses = Set(
                addressResponse.result
                    .filter { !$0.verified.isEmpty }
                    .map { $0.email }
            )
            
            await MainActor.run {
                self.forwardingAddresses = verifiedAddresses
            }
        } else {
            let errorMessage = addressResponse.errors.first?.message ?? "Failed to get forwarding addresses from response"
            throw CloudflareError(message: errorMessage)
        }
    }
}

struct CloudflareResponse<T: Codable>: Codable {
    let result: T
    let success: Bool
    let errors: [CloudflareErrorDetail]?
    let messages: [String]?
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
    let field: String
    let value: String
}

struct Action: Codable {
    let type: String
    let value: [String]
}

struct AddressResponse: Codable {
    struct EmailAddress: Codable {
        let id: String
        let tag: String
        let email: String
        let verified: String  // This is a timestamp string, not a boolean
        let created: String
        let modified: String
    }
    let result: [EmailAddress]
    let success: Bool
    let errors: [CloudflareErrorDetail]
    let messages: [String]
    let result_info: ResultInfo
} 
