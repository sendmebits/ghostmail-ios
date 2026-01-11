import SwiftUI
import SwiftData

/// Detail view for managing a single Cloudflare zone's settings
struct ZoneDetailView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EmailAlias.emailAddress) private var emailAliases: [EmailAlias]
    
    let zone: CloudflareClient.CloudflareZone
    @Binding var zoneToRemove: CloudflareClient.CloudflareZone?
    @Binding var showRemoveZoneAlert: Bool
    @Binding var zoneToEditToken: CloudflareClient.CloudflareZone?
    @Binding var zoneToAddToken: CloudflareClient.CloudflareZone?
    
    // Catch-All state
    @State private var catchAllStatus: CatchAllStatus?
    @State private var isLoadingCatchAll = false
    @State private var isUpdatingCatchAll = false
    @State private var showCatchAllError = false
    @State private var catchAllErrorMessage = ""
    @State private var showCatchAllOptions = false
    
    // Subdomain state
    @State private var showSubdomainError = false
    @State private var subdomainErrorMessage = ""
    
    private var domainName: String {
        zone.domainName.isEmpty ? zone.zoneId : zone.domainName
    }
    
    private var entryCount: Int {
        emailAliases.filter { $0.zoneId == zone.zoneId && $0.isLoggedOut == false }.count
    }
    
    private var isMissingToken: Bool {
        zone.apiToken.isEmpty
    }
    
    private var catchAllIsEnabled: Bool {
        catchAllStatus?.isEnabled ?? false
    }
    
    var body: some View {
        List {
            // Warning banner for zones missing API token
            if isMissingToken {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API Token Required")
                                .font(.system(.headline, design: .rounded))
                            Text("This zone needs an API token to sync and manage settings")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    
                    Button {
                        zoneToAddToken = zone
                    } label: {
                        Label("Add API Token", systemImage: "key.fill")
                    }
                }
            }
            
            // Zone Information
            Section("Zone Information") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zone ID")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(zone.zoneId)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                
                HStack {
                    Text("Aliases Created")
                    Spacer()
                    Text("\(entryCount)")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            
            // Email Routing (only if token is present)
            if !isMissingToken {
                Section("Email Routing") {
                    // Catch-All Toggle
                    if isLoadingCatchAll {
                        HStack {
                            Text("Catch-All")
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { catchAllIsEnabled },
                            set: { newValue in
                                if newValue {
                                    showCatchAllOptions = true
                                } else {
                                    Task { await updateCatchAll(enabled: false) }
                                }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text("Catch-All")
                                if isUpdatingCatchAll {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else if let status = catchAllStatus, status.isEnabled {
                                    Text(status == .drop ? "(Drop)" : "(Forward)")
                                        .font(.system(.caption, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.accentColor)
                        .disabled(isUpdatingCatchAll)
                    }
                    
                    // Forward address display
                    if let status = catchAllStatus, case .forward(let addresses) = status, !addresses.isEmpty {
                        HStack {
                            Text("Forward To")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(addresses.joined(separator: ", "))
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            
            // Features (only if token is present)
            if !isMissingToken {
                Section("Features") {
                    Toggle("Enable Sub-Domains", isOn: Binding(
                        get: { zone.subdomainsEnabled },
                        set: { newValue in
                            Task {
                                do {
                                    try await cloudflareClient.toggleSubdomains(for: zone.zoneId, enabled: newValue)
                                } catch {
                                    subdomainErrorMessage = error.localizedDescription
                                    showSubdomainError = true
                                }
                            }
                        }
                    ))
                    .tint(.accentColor)
                }
            }
            
            // API Token
            Section("API Token") {
                if isMissingToken {
                    Button {
                        zoneToAddToken = zone
                    } label: {
                        Label("Add API Token", systemImage: "key.fill")
                    }
                } else {
                    Button {
                        zoneToEditToken = zone
                    } label: {
                        Label("Edit API Token", systemImage: "key.fill")
                    }
                }
            }
            
            // Danger Zone
            Section {
                Button(role: .destructive) {
                    zoneToRemove = zone
                    showRemoveZoneAlert = true
                } label: {
                    Label("Remove This Zone", systemImage: "trash")
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Removing this zone will delete all local data for aliases under this domain. Your Cloudflare settings will not be affected.")
            }
        }
        .navigationTitle(domainName)
        .navigationBarTitleDisplayMode(.large)
        .task {
            if !isMissingToken {
                await loadCatchAllStatus()
            }
        }
        .alert("Subdomain Error", isPresented: $showSubdomainError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(subdomainErrorMessage)
        }
        .alert("Catch-All Error", isPresented: $showCatchAllError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(catchAllErrorMessage)
        }
        .confirmationDialog("Enable Catch-All", isPresented: $showCatchAllOptions, titleVisibility: .visible) {
            Button("Drop (Discard Emails)") {
                Task { await updateCatchAll(enabled: true, action: "drop") }
            }
            Button("Forward to Default") {
                Task { await updateCatchAllWithForward() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose what happens to emails sent to addresses that don't have a routing rule.")
        }
    }
    
    // MARK: - Catch-All Management
    
    private func loadCatchAllStatus() async {
        guard !isLoadingCatchAll else { return }
        isLoadingCatchAll = true
        defer { isLoadingCatchAll = false }
        
        do {
            let status = try await cloudflareClient.fetchCatchAllStatus(forZoneId: zone.zoneId)
            await MainActor.run {
                catchAllStatus = status
            }
        } catch {
            print("Failed to fetch catch-all status: \(error)")
            await MainActor.run {
                catchAllStatus = nil
            }
        }
    }
    
    private func updateCatchAll(enabled: Bool, action: String = "drop", forwardTo: [String] = []) async {
        isUpdatingCatchAll = true
        defer { isUpdatingCatchAll = false }
        
        do {
            try await cloudflareClient.updateCatchAllRule(
                forZoneId: zone.zoneId,
                enabled: enabled,
                action: action,
                forwardTo: forwardTo
            )
            await loadCatchAllStatus()
        } catch {
            await MainActor.run {
                catchAllErrorMessage = error.localizedDescription
                showCatchAllError = true
            }
        }
    }
    
    private func updateCatchAllWithForward() async {
        let defaultAddress = UserDefaults.standard.string(forKey: "defaultForwardingAddress") ?? ""
        let forwardingAddresses = Array(cloudflareClient.forwardingAddresses)
        let addressToUse = defaultAddress.isEmpty ? forwardingAddresses.first ?? "" : defaultAddress
        
        if addressToUse.isEmpty {
            await MainActor.run {
                catchAllErrorMessage = "No forwarding address configured. Please add a forwarding address first."
                showCatchAllError = true
            }
            return
        }
        
        await updateCatchAll(enabled: true, action: "forward", forwardTo: [addressToUse])
    }
}
