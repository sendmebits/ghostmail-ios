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
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Email Address") {
                    HStack {
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        Text("@\(cloudflareClient.emailDomain)")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Destination") {
                    if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Forward to", selection: $forwardTo) {
                            ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                Text(address).tag(address)
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
            if forwardTo.isEmpty && !cloudflareClient.forwardingAddresses.isEmpty {
                forwardTo = cloudflareClient.currentDefaultForwardingAddress
            }
        }
    }
    
    private func createEmailAlias() {
        Task {
            isLoading = true
            do {
                let fullEmailAddress = cloudflareClient.createFullEmailAddress(username: username)
                let rule = try await cloudflareClient.createEmailRule(
                    emailAddress: fullEmailAddress,
                    forwardTo: forwardTo
                )
                
                // Get the minimum sortIndex from existing aliases
                let existingAliases = try modelContext.fetch(FetchDescriptor<EmailAlias>())
                let minSortIndex = existingAliases.map { $0.sortIndex }.min() ?? 0
                
                let newAlias = EmailAlias(emailAddress: fullEmailAddress)
                newAlias.website = website
                newAlias.notes = notes
                newAlias.cloudflareTag = rule.tag
                newAlias.forwardTo = forwardTo
                newAlias.sortIndex = minSortIndex - 1  // Set to less than the minimum
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
