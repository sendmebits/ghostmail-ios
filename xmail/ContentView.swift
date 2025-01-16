//
//  ContentView.swift
//  xmail
//
//  Created by Chris Greco on 2025-01-16.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @Query private var emailAliases: [EmailAlias]
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            if cloudflareClient.isAuthenticated {
                EmailListView(searchText: $searchText)
                    .task {
                        await fetchEmailRules()
                    }
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
                if let existingAlias = existingAliases[rule.emailAddress] {
                    // Update existing alias's Cloudflare properties
                    existingAlias.cloudflareTag = rule.cloudflareTag
                    existingAlias.isEnabled = rule.isEnabled
                    existingAlias.sortIndex = index + 1  // Shift indices up by 1
                } else {
                    // Create new alias
                    let newAlias = EmailAlias(emailAddress: rule.emailAddress)
                    newAlias.cloudflareTag = rule.cloudflareTag
                    newAlias.isEnabled = rule.isEnabled
                    newAlias.sortIndex = index + 1  // Shift indices up by 1
                    modelContext.insert(newAlias)
                }
            }
            
            try modelContext.save()
        } catch {
            self.error = error
            self.showError = true
        }
        
        isLoading = false
    }
}

struct AuthenticationView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @AppStorage("accountId") private var accountId = ""
    @AppStorage("zoneId") private var zoneId = ""
    @AppStorage("apiToken") private var apiToken = ""
    @State private var useQuickAuth = false
    @State private var quickAuthString = ""
    @State private var isLoading = false
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Cloudflare Authentication")
                .font(.title)
                .padding()
            
            Toggle("Quick Auth", isOn: $useQuickAuth)
                .padding()
            
            if useQuickAuth {
                TextField("Account ID:Zone ID:Token", text: $quickAuthString)
                    .textFieldStyle(.roundedBorder)
                    .padding()
            } else {
                TextField("Account ID", text: $accountId)
                    .textFieldStyle(.roundedBorder)
                TextField("Zone ID", text: $zoneId)
                    .textFieldStyle(.roundedBorder)
                TextField("API Token", text: $apiToken)
                    .textFieldStyle(.roundedBorder)
            }
            
            Button(action: authenticate) {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Login")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            
            Spacer()
        }
        .padding()
        .alert("Authentication Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        }
    }
    
    private func authenticate() {
        if useQuickAuth {
            let components = quickAuthString.split(separator: ":")
            guard components.count == 3 else {
                showError = true
                return
            }
            accountId = String(components[0])
            zoneId = String(components[1])
            apiToken = String(components[2])
        }
        
        // Update the shared client first
        cloudflareClient.updateCredentials(accountId: accountId, zoneId: zoneId, apiToken: apiToken)
        
        Task {
            isLoading = true
            do {
                let verified = try await cloudflareClient.verifyToken()
                if verified {
                    cloudflareClient.isAuthenticated = true
                    UserDefaults.standard.set(true, forKey: "isAuthenticated")
                } else {
                    showError = true
                }
            } catch {
                print("Authentication error: \(error)")
                showError = true
            }
            isLoading = false
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: EmailAlias.self, inMemory: true)
}
