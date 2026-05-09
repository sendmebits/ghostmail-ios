import SwiftUI

/// Sheet for adding an API token to a zone that's missing one (e.g., after iCloud restore)
struct AddZoneTokenSheet: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    let zone: CloudflareClient.CloudflareZone
    
    @State private var apiToken = ""
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add API Token")
                            .font(.system(.headline, design: .rounded))
                        Text("Enter the Cloudflare API token for this zone to enable syncing.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section {
                    HStack {
                        Text("Domain")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(zone.domainName.isEmpty ? "Unknown" : zone.domainName)
                            .font(.system(.body, design: .rounded))
                    }
                    
                    HStack {
                        Text("Zone ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(zone.zoneId.prefix(6))...\(zone.zoneId.suffix(4))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section {
                    SecureField("API Token", text: $apiToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Create a token in Cloudflare with Email Routing permissions")
                        .font(.system(.caption, design: .rounded))
                }
                
                Section {
                    Button {
                        saveToken()
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Save Token")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
            .navigationTitle(zone.domainName.isEmpty ? "Add Token" : zone.domainName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func saveToken() {
        isLoading = true
        
        Task {
            do {
                try await cloudflareClient.updateZoneToken(
                    zoneId: zone.zoneId,
                    apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                // Check and auto-enable analytics if this zone's API has permission.
                await cloudflareClient.checkAndEnableAnalyticsIfPermitted()
                
                await MainActor.run {
                    isLoading = false
                    dismiss()
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
}

/// Sheet for editing an existing API token for a zone
struct EditZoneTokenSheet: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    let zone: CloudflareClient.CloudflareZone
    
    @State private var apiToken = ""
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showSuccessToast = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Update API Token")
                                .font(.system(.headline, design: .rounded))
                        }
                        Text("Enter a new Cloudflare API token for this zone. The previous token will be replaced.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section {
                    HStack {
                        Text("Domain")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(zone.domainName.isEmpty ? "Unknown" : zone.domainName)
                            .font(.system(.body, design: .rounded))
                    }
                    
                    HStack {
                        Text("Zone ID")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(zone.zoneId.prefix(6))...\(zone.zoneId.suffix(4))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Zone Info")
                }
                
                Section {
                    SecureField("New API Token", text: $apiToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("New Token")
                } footer: {
                    Text("Create a token in Cloudflare Dashboard > API Tokens with Email Routing edit permissions")
                        .font(.system(.caption, design: .rounded))
                }
                
                Section {
                    Button {
                        updateToken()
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Update Token")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
            .navigationTitle(zone.domainName.isEmpty ? "Edit Token" : zone.domainName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .overlay(
                Group {
                    if showSuccessToast {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Token Updated")
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 32)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showSuccessToast)
            )
        }
    }
    
    private func updateToken() {
        isLoading = true
        
        Task {
            do {
                try await cloudflareClient.updateZoneToken(
                    zoneId: zone.zoneId,
                    apiToken: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                // Check and auto-enable analytics if this zone's API has permission.
                await cloudflareClient.checkAndEnableAnalyticsIfPermitted()
                
                await MainActor.run {
                    isLoading = false
                    showSuccessToast = true
                    
                    // Dismiss after a short delay to show success.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()
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
}
