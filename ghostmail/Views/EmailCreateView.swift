import SwiftUI
import SwiftData
import UIKit

struct EmailCreateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @AppStorage("zoneId") private var zoneId = ""
    @AppStorage("defaultZoneId") private var defaultZoneId: String = ""
    @AppStorage("defaultDomain") private var defaultDomain: String = ""
    
    @State private var username = ""
    @State private var website = ""
    @State private var notes = ""
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var forwardTo = ""
    @FocusState private var isUsernameFocused: Bool
    @State private var selectedZoneId: String = ""
    @State private var selectedDomain: String = ""
    
    var onEmailCreated: ((String) -> Void)?
    
    init(initialWebsite: String? = nil, onEmailCreated: ((String) -> Void)? = nil) {
        self.onEmailCreated = onEmailCreated
        // Load the default forwarding address exactly as in SettingsView
        let savedDefault = UserDefaults.standard.string(forKey: "defaultForwardingAddress") ?? ""
        _forwardTo = State(initialValue: savedDefault)
        if let w = initialWebsite, !w.isEmpty {
            _website = State(initialValue: w)
        }
    }

    private var hasMultipleZones: Bool {
        cloudflareClient.zones.count > 1
    }

    private var selectedZone: CloudflareClient.CloudflareZone? {
        cloudflareClient.zones.first(where: { $0.zoneId == selectedZoneId })
    }

    private var selectedDomainFallback: String {
        if let z = selectedZone, !z.domainName.isEmpty { return z.domainName }
        if selectedZoneId == cloudflareClient.zoneId { return cloudflareClient.emailDomain }
        // Fallback to current emailDomain if unknown; during create we'll resolve precisely
        return cloudflareClient.emailDomain
    }
    
    // Get all available domains (main domains + subdomains) across all zones
    private var availableDomains: [String] {
        var domains: [String] = []
        
        for zone in cloudflareClient.zones {
            // Add main domain
            if !zone.domainName.isEmpty {
                domains.append(zone.domainName)
            }
            
            // Add subdomains only if enabled for this zone
            if zone.subdomainsEnabled {
                domains.append(contentsOf: zone.subdomains)
            }
        }
        
        return domains.isEmpty ? [cloudflareClient.emailDomain] : domains.sorted()
    }
    
    // Find which zone owns the selected domain
    private var zoneForSelectedDomain: CloudflareClient.CloudflareZone? {
        for zone in cloudflareClient.zones {
            if zone.domainName.lowercased() == selectedDomain.lowercased() {
                return zone
            }
            if zone.subdomains.contains(where: { $0.lowercased() == selectedDomain.lowercased() }) {
                return zone
            }
        }
        return selectedZone
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Email Alias") {
                    HStack {
                        TextField("alias", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .focused($isUsernameFocused)
                        
                        // Show domain picker if there are multiple domains available across all zones
                        if availableDomains.count > 1 {
                            Picker("", selection: $selectedDomain) {
                                ForEach(availableDomains, id: \.self) { domain in
                                    Text("@\(domain)").tag(domain)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        } else {
                            Text("@\(selectedDomain.isEmpty ? cloudflareClient.emailDomain : selectedDomain)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Destination Email") {
                    if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("", selection: $forwardTo) {
                            ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                        .pickerStyle(.menu)
                        .onAppear {
                            // Ensure we have a valid selection for the Picker
                            if forwardTo.isEmpty && !cloudflareClient.forwardingAddresses.isEmpty {
                                forwardTo = cloudflareClient.forwardingAddresses.first ?? ""
                            }
                        }
                    } else {
                        Text("No forwarding addresses available")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Website") {
                    TextField("Website (optional)", text: $website)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                
                Section("Notes") {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Create Email Alias")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button("Create") {
                        createEmailAlias()
                    }
                    .disabled(username.isEmpty || isLoading)
                }
            }
            .disabled(isLoading)
            .alert("Error", isPresented: $showError, presenting: error) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
        }
        .task {
            isUsernameFocused = true

            // Set default forwarding address to the one selected in settings
            if forwardTo.isEmpty {
                let defaultAddress = cloudflareClient.currentDefaultForwardingAddress
                if !defaultAddress.isEmpty {
                    print("Setting forwarding address to default from settings: \(defaultAddress)")
                    forwardTo = defaultAddress
                } else {
                    print("No default forwarding address set in settings.")
                }
            }

            // Initialize selected domain from saved default domain
            if selectedDomain.isEmpty {
                if !defaultDomain.isEmpty {
                    selectedDomain = defaultDomain
                    // Find the zone that owns this domain
                    for zone in cloudflareClient.zones {
                        if zone.domainName == defaultDomain || zone.subdomains.contains(defaultDomain) {
                            selectedZoneId = zone.zoneId
                            break
                        }
                    }
                } else {
                    selectedDomain = selectedDomainFallback
                }
            }
            
            // Initialize selected zone id if not set (for backward compatibility)
            if selectedZoneId.isEmpty {
                if cloudflareClient.zones.count > 1, !defaultZoneId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   cloudflareClient.zones.contains(where: { $0.zoneId == defaultZoneId }) {
                    selectedZoneId = defaultZoneId
                } else {
                    selectedZoneId = cloudflareClient.zoneId
                }
            }
        }
    }
    
    private func createEmailAlias() {
        Task {
            isLoading = true
            do {
                // Use the selected domain (which could be main domain or subdomain)
                let domain = selectedDomain.isEmpty ? selectedDomainFallback : selectedDomain
                
                // Resolve target zone based on the selected domain
                let zone = zoneForSelectedDomain ?? cloudflareClient.zones.first(where: { $0.zoneId == cloudflareClient.zoneId })

                let fullEmailAddress = "\(username)@\(domain)"
                let rule: EmailRule
                if let z = zone {
                    rule = try await cloudflareClient.createEmailRule(emailAddress: fullEmailAddress, forwardTo: forwardTo, in: z)
                } else {
                    rule = try await cloudflareClient.createEmailRule(emailAddress: fullEmailAddress, forwardTo: forwardTo)
                }
                
                // Get the minimum sortIndex from existing aliases
                let existingAliases = try modelContext.fetch(FetchDescriptor<EmailAlias>())
                let minSortIndex = existingAliases.map { $0.sortIndex }.min() ?? 0
                
                let newAlias = EmailAlias(emailAddress: fullEmailAddress, forwardTo: forwardTo, isManuallyCreated: true, zoneId: zone?.zoneId ?? cloudflareClient.zoneId)
                newAlias.website = website
                newAlias.notes = notes
                newAlias.cloudflareTag = rule.tag
                newAlias.sortIndex = minSortIndex - 1  // Set to less than the minimum
                // Ensure new alias is scoped to the current Cloudflare zone
                newAlias.zoneId = (zone?.zoneId ?? cloudflareClient.zoneId).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Set the user identifier to ensure cross-device ownership
                newAlias.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                
                modelContext.insert(newAlias)
                try modelContext.save()
                
                // Notify parent view and dismiss
                dismiss()
                
                // Copy to clipboard and show toast in parent view after dismissal
                // Wait for sheet dismissal animation to complete before showing toast
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                    UIPasteboard.general.string = fullEmailAddress
                    onEmailCreated?(fullEmailAddress)
                }
            } catch {
                self.error = error
                self.showError = true
            }
            isLoading = false
        }
    }
}
