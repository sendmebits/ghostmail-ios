import SwiftUI
import SwiftData

struct EmailCreateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @AppStorage("zoneId") private var zoneId = ""
    @AppStorage("defaultZoneId") private var defaultZoneId: String = ""
    
    @State private var username = ""
    @State private var website = ""
    @State private var notes = ""
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var forwardTo = ""
    @FocusState private var isUsernameFocused: Bool
    @State private var selectedZoneId: String = ""
    
    init() {
        // Load the default forwarding address exactly as in SettingsView
        let savedDefault = UserDefaults.standard.string(forKey: "defaultForwardingAddress") ?? ""
        _forwardTo = State(initialValue: savedDefault)
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
                        if hasMultipleZones {
                            Picker("", selection: $selectedZoneId) {
                                ForEach(cloudflareClient.zones, id: \.zoneId) { z in
                                    Text("@\(z.domainName.isEmpty ? "…" : z.domainName)").tag(z.zoneId)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        } else {
                            Text("@\(cloudflareClient.emailDomain)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Destination Email") {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Loading forwarding addresses...")
                                .foregroundStyle(.secondary)
                        }
                    } else if !cloudflareClient.forwardingAddresses.isEmpty {
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

            // Initialize selected zone id using saved default domain when available
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
                // Resolve target zone
                let zone: CloudflareClient.CloudflareZone? = cloudflareClient.zones.first(where: { $0.zoneId == selectedZoneId }) ?? cloudflareClient.zones.first(where: { $0.zoneId == cloudflareClient.zoneId })
                // Resolve domain for the zone
                let domain: String
                if let z = zone {
                    if !z.domainName.isEmpty {
                        domain = z.domainName
                    } else if z.zoneId == cloudflareClient.zoneId && !cloudflareClient.emailDomain.isEmpty {
                        domain = cloudflareClient.emailDomain
                    } else {
                        // Fetch domain name for this zone
                        let details = try await cloudflareClient.fetchZoneDetails(accountId: z.accountId, zoneId: z.zoneId, token: z.apiToken)
                        domain = details.domainName
                    }
                } else {
                    domain = cloudflareClient.emailDomain
                }

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
                dismiss()
            } catch {
                self.error = error
                self.showError = true
            }
            isLoading = false
        }
    }
}
