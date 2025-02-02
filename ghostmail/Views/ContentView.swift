//
//  ContentView.swift
//  ghostmail
//
//  Created by Chris Greco on 2025-01-16.
//

import SwiftUI
import SwiftData

@MainActor
struct ContentView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @Query(sort: \EmailAlias.emailAddress) private var emailAliases: [EmailAlias]
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var needsRefresh = false
    
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
        // Clear local data
        emailAliases.forEach { modelContext.delete($0) }
        try? modelContext.save()
        
        // Logout from CloudflareClient
        cloudflareClient.logout()
    }
    
    private func fetchEmailRules() async {
        guard isLoading == false else { return }
        isLoading = true
        
        do {
            let rules = try await cloudflareClient.getEmailRules()
            
            // Create a dictionary of existing aliases by email address
            let existingAliases = Dictionary(
                uniqueKeysWithValues: emailAliases.map { ($0.emailAddress, $0) }
            )
            
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
                let alias: EmailAlias
                
                if let existingAlias = existingAliases[rule.emailAddress] {
                    // Use existing alias
                    alias = existingAlias
                } else {
                    // Create new alias
                    alias = EmailAlias(emailAddress: rule.emailAddress)
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
}

#Preview {
    ContentView()
        .modelContainer(for: EmailAlias.self, inMemory: true)
}
