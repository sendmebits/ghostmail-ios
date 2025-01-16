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
        let url = URL(string: "\(baseURL)/zones/\(zoneId)/email/routing/rules?page=1&per_page=50")!
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
        
        // Collect all unique forwarding addresses
        let forwards = Set(cloudflareResponse.result.compactMap { rule -> String? in
            rule.actions.first { $0.type == "forward" }?.value.first
        })
        
        await MainActor.run {
            self.forwardingAddresses = forwards
        }
        
        return cloudflareResponse.result.map { rule in
            let emailAddress = rule.matchers.first { $0.field == "to" }?.value ?? ""
            // Get the forwarding address or use the default if none is found
            let forwardTo = rule.actions.first { $0.type == "forward" }?.value.first ?? currentDefaultForwardingAddress
            let alias = EmailAlias(emailAddress: emailAddress)
            alias.cloudflareTag = rule.tag
            alias.isEnabled = rule.enabled
            alias.forwardTo = forwardTo  // This should never be empty now
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
        // Extract domain from zone ID, or use a default
        // This should match your Cloudflare email routing domain
        "sendmebits.com"
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
    
    var shouldShowWebsitesInList: Bool {
        get { showWebsitesInList }
        set { showWebsitesInList = newValue }
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
