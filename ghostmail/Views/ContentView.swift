//
//  ContentView.swift
//  ghostmail
//
//  Created by sendmebits on 2025-01-16.
//

import SwiftUI
import SwiftData

@MainActor
struct ContentView: View {
    enum SortOrder {
        case alphabetical
        case cloudflareOrder
    }
    
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @Query private var emailAliases: [EmailAlias]
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var needsRefresh = false
    @State private var sortOrder = SortOrder.cloudflareOrder
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    
    var body: some View {
        NavigationStack {
            if cloudflareClient.isAuthenticated {
                EmailListView(searchText: $searchText, needsRefresh: $needsRefresh)
                    .overlay {
                        if isLoading {
                            ProgressView()
                        }
                    }
                    .alert("Error Fetching Emails", isPresented: $showError, presenting: error) { _ in
                        Button("Retry") {
                            Task {
                                await fetchEmailRules()
                            }
                        }
                        Button("OK", role: .cancel) { }
                    } message: { error in
                        Text(error.localizedDescription)
                    }
            } else {
                AuthenticationView()
            }
        }
    }
    
    private func logout() {
        // Mark aliases as logged out instead of deleting them
        for alias in emailAliases {
            alias.isLoggedOut = true
        }
        try? modelContext.save()
        
        // Logout from CloudflareClient
        cloudflareClient.logout()
    }
    
    private func fetchEmailRules() async {
        guard isLoading == false else { return }
        isLoading = true
        
        do {
            let rules = try await cloudflareClient.getEmailRules()
            
            // Create a dictionary of existing aliases by email address, handling potential duplicates
            var existingAliases: [String: EmailAlias] = [:]
            for alias in emailAliases {
                // Only add if not already present or if newer
                if let existing = existingAliases[alias.emailAddress] {
                    if (alias.created ?? Date.distantPast) > (existing.created ?? Date.distantPast) {
                        existingAliases[alias.emailAddress] = alias
                    }
                } else {
                    existingAliases[alias.emailAddress] = alias
                }
            }
            
            // Get email addresses from Cloudflare rules
            let cloudflareEmails = rules.map { $0.emailAddress }
            let newEmailAddresses = Set(cloudflareEmails)
            
            // Remove aliases that no longer exist in Cloudflare
            emailAliases.forEach { alias in
                if !newEmailAddresses.contains(alias.emailAddress) {
                    modelContext.delete(alias)
                }
            }
            
            // Update or create aliases while preserving order
            // Start index at 1 to leave room for new items at index 0
            for (index, rule) in rules.enumerated() {
                let emailAddress = rule.emailAddress
                let alias: EmailAlias
                
                if let existingAlias = existingAliases[emailAddress] {
                    // Use existing alias
                    alias = existingAlias
                } else {
                    // Create new alias
                    alias = EmailAlias(emailAddress: emailAddress, forwardTo: rule.forwardTo)
                    alias.created = nil  // Ensure no creation date for Cloudflare-fetched entries
                    
                    modelContext.insert(alias)
                }
                
                // Update alias properties
                alias.cloudflareTag = rule.cloudflareTag
                alias.isEnabled = rule.isEnabled
                alias.sortIndex = index + 1  // Shift indices up by 1
            }
            
            try modelContext.save()
        } catch {
            self.error = error
            self.showError = true
        }
        
        isLoading = false
    }
    
    var sortedEmails: [EmailAlias] {
        let filtered = filteredEmails
        switch sortOrder {
        case .alphabetical:
            return filtered.sorted { $0.emailAddress < $1.emailAddress }
        case .cloudflareOrder:
            // Use the sortIndex to preserve Cloudflare's order
            return filtered.sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    
    var filteredEmails: [EmailAlias] {
        if searchText.isEmpty {
            return emailAliases
        }
        return emailAliases.filter { email in
            email.emailAddress.localizedCaseInsensitiveContains(searchText) ||
            email.website.localizedCaseInsensitiveContains(searchText)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: EmailAlias.self, inMemory: true)
}
