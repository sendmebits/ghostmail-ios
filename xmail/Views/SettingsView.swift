import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EmailAlias.emailAddress) private var emailAliases: [EmailAlias]
    @State private var selectedDefaultAddress: String = ""
    @State private var showWebsites: Bool = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account ID")
                        Text(cloudflareClient.accountId)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zone ID")
                        Text(cloudflareClient.zoneId)
                            .foregroundStyle(.secondary)
                        Text("@\(cloudflareClient.emailDomain)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cloudflare Account")
                }
                
                Section {
                    if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Default Destination", selection: $selectedDefaultAddress) {
                            ForEach(Array(cloudflareClient.forwardingAddresses), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                    } else {
                        Text("No forwarding addresses available")
                            .foregroundStyle(.secondary)
                    }
                    
                    Toggle("Show Websites in List", isOn: $showWebsites)
                } header: {
                    Text("Xmail Settings")
                }
                
                Section {
                    Button(role: .destructive) {
                        // Clear local data
                        emailAliases.forEach { modelContext.delete($0) }
                        try? modelContext.save()
                        
                        // Logout from CloudflareClient
                        cloudflareClient.logout()
                        dismiss()
                    } label: {
                        HStack {
                            Text("Logout")
                            Spacer()
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            selectedDefaultAddress = cloudflareClient.currentDefaultForwardingAddress
            showWebsites = cloudflareClient.shouldShowWebsitesInList
        }
        .onChange(of: selectedDefaultAddress) {
            cloudflareClient.setDefaultForwardingAddress(selectedDefaultAddress)
        }
        .onChange(of: showWebsites) {
            cloudflareClient.shouldShowWebsitesInList = showWebsites
        }
    }
} 
