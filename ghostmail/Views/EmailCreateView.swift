import SwiftUI
import SwiftData

struct EmailCreateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @AppStorage("zoneId") private var zoneId = ""
    
    @State private var username = ""
    @State private var website = ""
    @State private var notes = ""
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var forwardTo = ""
    @FocusState private var isUsernameFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Email Address") {
                    HStack {
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .focused($isUsernameFocused)
                        Text("@\(cloudflareClient.emailDomain)")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Destination") {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Loading forwarding addresses...")
                                .foregroundStyle(.secondary)
                        }
                    } else if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Forward to", selection: $forwardTo) {
                            ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                        .pickerStyle(.menu)
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
            
            // Load forwarding addresses from the Cloudflare API
            do {
                isLoading = true
                print("Email Create View: Loading forwarding addresses...")
                
                // Force a fresh load from the API
                try await cloudflareClient.refreshForwardingAddresses()
                
                // Set default forwarding address to the one selected in settings
                if forwardTo.isEmpty {
                    let defaultAddress = cloudflareClient.currentDefaultForwardingAddress
                    if !defaultAddress.isEmpty {
                        print("Setting forwarding address to default from settings: \(defaultAddress)")
                        forwardTo = defaultAddress
                    } else if !cloudflareClient.forwardingAddresses.isEmpty {
                        // Fall back to first address if no default is set
                        let firstAddress = cloudflareClient.forwardingAddresses.first ?? ""
                        print("No default address in settings, using first available: \(firstAddress)")
                        forwardTo = firstAddress
                    }
                }
                
                isLoading = false
                print("Forwarding addresses loaded successfully")
            } catch {
                print("Error loading forwarding addresses: \(error.localizedDescription)")
                self.error = error
                self.showError = true
                isLoading = false
            }
        }
    }
    
    private func createEmailAlias() {
        Task {
            isLoading = true
            do {
                // Get the current iCloud sync setting
                let iCloudSyncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
                
                let fullEmailAddress = cloudflareClient.createFullEmailAddress(username: username)
                let rule = try await cloudflareClient.createEmailRule(
                    emailAddress: fullEmailAddress,
                    forwardTo: forwardTo
                )
                
                // Get the minimum sortIndex from existing aliases
                let existingAliases = try modelContext.fetch(FetchDescriptor<EmailAlias>())
                let minSortIndex = existingAliases.map { $0.sortIndex }.min() ?? 0
                
                let newAlias = EmailAlias(emailAddress: fullEmailAddress, forwardTo: forwardTo, isManuallyCreated: true)
                newAlias.website = website
                newAlias.notes = notes
                newAlias.cloudflareTag = rule.tag
                newAlias.sortIndex = minSortIndex - 1  // Set to less than the minimum
                
                // Set the iCloud sync disabled flag based on the user's preference
                newAlias.iCloudSyncDisabled = !iCloudSyncEnabled
                
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
