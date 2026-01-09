import SwiftUI
import SwiftData
import Foundation

@MainActor
struct AuthenticationView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @State private var accountId = ""
    @State private var zoneId = ""
    @State private var apiToken = ""
    @State private var useQuickAuth = false
    @State private var quickAuthString = ""
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var currentReauthIndex = 0  // Track which zone we're re-authenticating
    
    /// Detect if this is an iCloud restore scenario where we have zone data but no credentials
    private var isICloudRestoreScenario: Bool {
        !cloudflareClient.zones.isEmpty && !cloudflareClient.hasValidCredentials
    }
    
    /// Get zones that need re-authentication
    private var zonesNeedingReauth: [CloudflareClient.CloudflareZone] {
        cloudflareClient.zonesNeedingReauth
    }
    
    /// Current zone being re-authenticated (if in restore flow)
    private var currentZoneToReauth: CloudflareClient.CloudflareZone? {
        guard isICloudRestoreScenario, currentReauthIndex < zonesNeedingReauth.count else { return nil }
        return zonesNeedingReauth[currentReauthIndex]
    }
    
    var body: some View {
        ScrollView {
        VStack(spacing: 32) {
            // iCloud Restore Banner
            if isICloudRestoreScenario {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.blue)
                        Text("Device Restored")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    
                    Text("Your email aliases were restored from iCloud, but credentials need to be re-entered for security.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    // Show progress for multi-zone re-auth
                    let totalZones = zonesNeedingReauth.count
                    if totalZones > 1 {
                        HStack(spacing: 4) {
                            Text("Zone \(currentReauthIndex + 1) of \(totalZones)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                            
                            // Progress dots
                            HStack(spacing: 4) {
                                ForEach(0..<totalZones, id: \.self) { index in
                                    Circle()
                                        .fill(index <= currentReauthIndex ? Color.accentColor : Color.gray.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    
                    // Show current domain being authenticated
                    if let currentZone = currentZoneToReauth, !currentZone.domainName.isEmpty {
                        Text("Current: \(currentZone.domainName)")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top)
            }
            
            // Header
            VStack(spacing: 16) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 60, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.bottom, 8)
                
                Text(isICloudRestoreScenario ? "Welcome Back" : "Welcome to Ghost Mail")
                    .font(.system(.title, design: .rounded, weight: .bold))
                
                Text(isICloudRestoreScenario 
                    ? "Please re-enter your Cloudflare API token" 
                    : "Please sign in with your Cloudflare credentials")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, isICloudRestoreScenario ? 16 : 40)
            
            // Auth Form
            VStack(spacing: 24) {
                // Hide Quick Auth toggle in restore scenario (we have the IDs already)
                if !isICloudRestoreScenario {
                Toggle("Quick Auth", isOn: $useQuickAuth)
                    .tint(.accentColor)
                    .padding(.horizontal)
                }
                
                if useQuickAuth && !isICloudRestoreScenario {
                    AuthTextField(
                        text: $quickAuthString,
                        placeholder: "Account ID:Zone ID:Token",
                        systemImage: "key.fill"
                    )
                } else {
                    VStack(spacing: 16) {
                        // In restore scenario, show read-only Account/Zone IDs
                        if isICloudRestoreScenario {
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.secondary)
                                    Text("Account ID")
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(accountId.isEmpty ? "—" : "\(accountId.prefix(4))...\(accountId.suffix(4))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                                
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundColor(.secondary)
                                    Text("Zone ID")
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(zoneId.isEmpty ? "—" : "\(zoneId.prefix(4))...\(zoneId.suffix(4))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                            }
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            AuthTextField(
                                text: $accountId,
                                placeholder: "Account ID",
                                systemImage: "person.fill",
                                helpTitle: "Account ID",
                                helpMessage: """
                                Log in to your Cloudflare dashboard, choose a zone/domain, on the bottom right of the screen in the API section: copy "Account ID" and "Zone ID"
                                """,
                                helpURL: "https://dash.cloudflare.com/"
                            )
                            
                            AuthTextField(
                                text: $zoneId,
                                placeholder: "Zone ID",
                                systemImage: "globe",
                                helpTitle: "Zone ID",
                                helpMessage: """
                                Log in to your Cloudflare dashboard, choose a zone/domain, on the bottom right of the screen in the API section: copy "Account ID" and "Zone ID"
                                """,
                                helpURL: "https://dash.cloudflare.com/"
                            )
                        } // End else (not restore scenario)
                        
                        // API Token field - always shown in both flows
                        AuthTextField(
                            text: $apiToken,
                            placeholder: "API Token",
                            systemImage: "key.fill",
                            helpTitle: "API Token",
                            helpMessage: """
                            In Cloudflare, create new token (choose Custom token)
                            
                            Permissions:
                            1) Account > Email Routing Addresses > Read
                            2) Zone > Email Routing Rules > Edit
                            3) Zone > Zone Settings > Read
                            """,
                            helpURL: "https://dash.cloudflare.com/profile/api-tokens"
                        )
                    }
                }
                
                // Login Button
                Button(action: authenticate) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(isICloudRestoreScenario && zonesNeedingReauth.count > 1 && currentReauthIndex < zonesNeedingReauth.count - 1 
                                ? "Continue" 
                                : "Sign In")
                                .font(.system(.body, design: .rounded, weight: .medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)
                .padding(.top, 8)
                
                // Skip button for multi-zone restore (can add remaining zones later in Settings)
                if isICloudRestoreScenario && zonesNeedingReauth.count > 1 {
                    Button(action: skipRemainingZones) {
                        Text("Skip Remaining Zones")
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal)
            
            Spacer()
        }
        }  // End ScrollView
        .onAppear {
            // Pre-fill account/zone IDs if we have restored zone data (iCloud restore scenario)
            updateFieldsForCurrentZone()
        }
        .onChange(of: currentReauthIndex) { _, _ in
            updateFieldsForCurrentZone()
        }
        .alert("Authentication Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage.isEmpty ? "Please check your credentials and try again." : errorMessage)
        }
    }
    
    /// Update the form fields for the current zone being re-authenticated
    private func updateFieldsForCurrentZone() {
        if let zone = currentZoneToReauth {
            accountId = zone.accountId
            zoneId = zone.zoneId
            apiToken = ""  // Clear token for new entry
        } else if isICloudRestoreScenario, let firstZone = cloudflareClient.zones.first {
            // Fallback for first zone
            if accountId.isEmpty { accountId = firstZone.accountId }
            if zoneId.isEmpty { zoneId = firstZone.zoneId }
        }
    }
    
    /// Skip remaining zones and proceed with authenticated zones only
    private func skipRemainingZones() {
        // Remove zones that haven't been authenticated
        let unauthenticatedZoneIds = zonesNeedingReauth.map { $0.zoneId }
        for zoneId in unauthenticatedZoneIds {
            cloudflareClient.removeZone(zoneId: zoneId)
        }
    }
    
    /// Authenticate a restored zone by updating just its API token
    private func authenticateRestoredZone(_ zone: CloudflareClient.CloudflareZone) {
        guard !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter the API token for this zone"
            showError = true
            return
        }
        
        isLoading = true
        
        Task {
            do {
                // Update just this zone's token
                try await cloudflareClient.updateZoneToken(
                    zoneId: zone.zoneId,
                    apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                await MainActor.run {
                    isLoading = false
                    
                    // Check if there are more zones to authenticate
                    let remainingZones = cloudflareClient.zonesNeedingReauth
                    if remainingZones.isEmpty {
                        // All zones authenticated - we're done
                        print("[AuthenticationView] All zones re-authenticated successfully")
                        
                        // Trigger a sync to refresh data
                        Task {
                            try? await cloudflareClient.refreshForwardingAddressesAllZones()
                        }
                    } else {
                        // Move to next zone
                        currentReauthIndex += 1
                        apiToken = ""  // Clear for next entry
                        print("[AuthenticationView] Moving to next zone, \(remainingZones.count) remaining")
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    private func authenticate() {
        // Handle iCloud restore re-authentication flow
        if isICloudRestoreScenario, let currentZone = currentZoneToReauth {
            authenticateRestoredZone(currentZone)
            return
        }
        
        // Normal authentication flow
        if useQuickAuth {
            let components = quickAuthString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard components.count == 3 else {
                errorMessage = "Invalid quick auth format. Please use 'Account ID:Zone ID:Token'"
                showError = true
                return
            }
            accountId = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            zoneId = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            apiToken = String(components[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        isLoading = true
        
        Task {
            do {
                // First update the credentials
                cloudflareClient.updateCredentials(
                    accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
                    zoneId: zoneId.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                // Verify the token
                let isValid = try await cloudflareClient.verifyToken()
                
                await MainActor.run {
                    if isValid {
                        // Set authenticated state
                        UserDefaults.standard.set(true, forKey: "isAuthenticated")
                        cloudflareClient.isAuthenticated = true
                        
                        // Loading forwarding addresses needs to be done in a separate Task
                        print("Setting up task to load forwarding addresses")
                        
                        // Then restore any data that was previously logged out
                        let loggedOutDescriptor = FetchDescriptor<EmailAlias>(
                            predicate: #Predicate<EmailAlias> { alias in
                                alias.isLoggedOut == true
                            }
                        )
                        let loggedOutAliases = (try? modelContext.fetch(loggedOutDescriptor)) ?? []
                        
                        // Restore logged out aliases
                        if !loggedOutAliases.isEmpty {
                            print("Restoring \(loggedOutAliases.count) previously logged out aliases")
                            for alias in loggedOutAliases {
                                alias.isLoggedOut = false
                            }
                            try? modelContext.save()
                        }
                        
                        // Fetch data from Cloudflare and merge with existing data
                        Task {
                            do {
                                // First load the forwarding addresses
                                print("Loading forwarding addresses immediately after login")
                                try await cloudflareClient.refreshForwardingAddresses()
                                
                                // Then fetch email rules
                                let cloudflareAliases = try await cloudflareClient.getEmailRules()
                                
                                // Get existing aliases from SwiftData
                                let descriptor = FetchDescriptor<EmailAlias>(
                                    predicate: #Predicate<EmailAlias> { alias in
                                        alias.isLoggedOut == false
                                    }
                                )
                                let existingAliases = (try? modelContext.fetch(descriptor)) ?? []
                                
                                // Create a map of email addresses to aliases, handling potential duplicates
                                var existingAliasDict: [String: EmailAlias] = [:]
                                for alias in existingAliases {
                                    // Only add if not already present or if newer
                                    if let existing = existingAliasDict[alias.emailAddress] {
                                        if (alias.created ?? Date.distantPast) > (existing.created ?? Date.distantPast) {
                                            existingAliasDict[alias.emailAddress] = alias
                                        }
                                    } else {
                                        existingAliasDict[alias.emailAddress] = alias
                                    }
                                }
                                
                                // Process each Cloudflare alias
                                for cloudflareAlias in cloudflareAliases {
                                    if let existingAlias = existingAliasDict[cloudflareAlias.emailAddress] {
                                        // Update existing alias with Cloudflare data while preserving metadata
                                        existingAlias.isEnabled = cloudflareAlias.isEnabled
                                        existingAlias.cloudflareTag = cloudflareAlias.cloudflareTag
                                        existingAlias.forwardTo = cloudflareAlias.forwardTo
                                    } else {
                                        // Create a new EmailAlias instead of trying to insert the CloudflareEmailRule
                                        let newAlias = EmailAlias(
                                            emailAddress: cloudflareAlias.emailAddress,
                                            forwardTo: cloudflareAlias.forwardTo,
                                            zoneId: cloudflareClient.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                                        )
                                        newAlias.cloudflareTag = cloudflareAlias.cloudflareTag
                                        newAlias.isEnabled = cloudflareAlias.isEnabled
                                        
                                        // Now insert the EmailAlias
                                        modelContext.insert(newAlias)
                                    }
                                }
                                
                                try modelContext.save()
                                
                                // Check and auto-enable analytics if the API has permission
                                await cloudflareClient.checkAndEnableAnalyticsIfPermitted()
                            } catch {
                                print("Error syncing data: \(error)")
                            }
                        }
                    } else {
                        errorMessage = "Invalid credentials. Please check and try again."
                        showError = true
                        cloudflareClient.logout()
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    cloudflareClient.logout()
                    isLoading = false
                }
            }
        }
    }
}

struct HelpPopup: View {
    let title: String
    let message: String
    let url: String
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(message)
                .font(.subheadline)
            
            Link(destination: URL(string: url)!) {
                HStack {
                    Text("Open Cloudflare Dashboard")
                    Image(systemName: "arrow.up.right")
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .frame(maxWidth: 300)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }
}

// Helper view for consistent text field styling
struct AuthTextField: View {
    @Binding var text: String
    let placeholder: String
    let systemImage: String
    var helpTitle: String = ""
    var helpMessage: String = ""
    var helpURL: String = ""
    @State private var showingHelp = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            TextField(placeholder, text: $text)
                .submitLabel(.next)
                .autocorrectionDisabled()
            
            if !helpMessage.isEmpty {
                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 20))
                }
                .popover(isPresented: $showingHelp) {
                    HelpPopup(
                        title: helpTitle,
                        message: helpMessage,
                        url: helpURL,
                        isPresented: $showingHelp
                    )
                }
            }
        }
        .padding()
        .background(.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
} 
