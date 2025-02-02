import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EmailAlias.emailAddress) private var emailAliases: [EmailAlias]
    @State private var selectedDefaultAddress: String = ""
    @State private var showWebsites: Bool = true
    @State private var showLogoutAlert: Bool = false
    @State private var showFileImporter = false
    @State private var showExportDialog = false
    @State private var importError: Error?
    @State private var showImportError = false
    
    private func exportToCSV() {
        let csvString = "Email Address,Website,Notes,Created,Enabled,Forward To\n" + emailAliases.map { alias in
            let createdStr = alias.created?.ISO8601Format() ?? ""
            return "\(alias.emailAddress),\(alias.website),\(alias.notes),\(createdStr),\(alias.isEnabled),\(alias.forwardTo)"
        }.joined(separator: "\n")
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("email_aliases.csv")
        do {
            try csvString.write(to: tempURL, atomically: true, encoding: .utf8)
            showExportDialog = true
        } catch {
            print("Export error: \(error)")
        }
    }
    
    private func importFromCSV(url: URL) {
        do {
            let securityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if securityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let csvString = try String(contentsOf: url, encoding: .utf8)
            let rows = csvString.components(separatedBy: .newlines)
            
            // Skip header row
            for row in rows.dropFirst() where !row.isEmpty {
                let fields = row.components(separatedBy: ",")
                guard fields.count >= 6 else { continue }
                
                let emailAddress = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let website = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let created = ISO8601DateFormatter().date(from: fields[3].trimmingCharacters(in: .whitespacesAndNewlines))
                let isEnabled = fields[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
                let forwardTo = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check if alias already exists
                if let existingAlias = emailAliases.first(where: { $0.emailAddress == emailAddress }) {
                    // Update existing alias
                    existingAlias.website = website
                    existingAlias.notes = notes
                    existingAlias.isEnabled = isEnabled
                    existingAlias.forwardTo = forwardTo
                    existingAlias.created = created  // Always overwrite the created date, even if nil
                    
                    // Update Cloudflare if the email is enabled or forward address changed
                    if let tag = existingAlias.cloudflareTag {
                        Task {
                            try await cloudflareClient.updateEmailRule(
                                tag: tag,
                                emailAddress: emailAddress,
                                isEnabled: isEnabled,
                                forwardTo: forwardTo
                            )
                        }
                    }
                } else {
                    // Create new Cloudflare rule first
                    Task {
                        do {
                            let rule = try await cloudflareClient.createEmailRule(
                                emailAddress: emailAddress,
                                forwardTo: forwardTo
                            )
                            
                            // Create new alias with Cloudflare tag
                            let newAlias = EmailAlias(emailAddress: emailAddress, forwardTo: forwardTo, isManuallyCreated: created != nil)
                            newAlias.website = website
                            newAlias.notes = notes
                            newAlias.created = created  // This will be nil if not in CSV
                            newAlias.isEnabled = isEnabled
                            newAlias.cloudflareTag = rule.tag
                            modelContext.insert(newAlias)
                            try modelContext.save()
                        } catch {
                            print("Error creating Cloudflare rule for \(emailAddress): \(error)")
                            importError = error
                            showImportError = true
                        }
                    }
                }
            }
            
            try modelContext.save()
        } catch {
            print("Import error: \(error)")
            importError = error
            showImportError = true
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Account section
                    DetailSection(title: "Cloudflare Account") {
                        VStack(alignment: .leading, spacing: 16) {
                            InfoRow(title: "Account ID") {
                                Text(cloudflareClient.accountId)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text(cloudflareClient.accountName)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            InfoRow(title: "Zone ID") {
                                Text(cloudflareClient.zoneId)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text("@\(cloudflareClient.emailDomain)")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            InfoRow(title: "Entries") {
                                Text("\(emailAliases.count) Addresses Created")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    // Settings section
                    DetailSection(title: "Xmail Settings") {
                        VStack(alignment: .leading, spacing: 16) {
                            if !cloudflareClient.forwardingAddresses.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Default Destination")
                                        .font(.system(.subheadline, design: .rounded))
                                    Picker("", selection: $selectedDefaultAddress) {
                                        ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                            Text(address).tag(address)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            } else {
                                Text("No forwarding addresses available")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Toggle("Show Websites in List", isOn: $showWebsites)
                                .tint(.accentColor)
                        }
                    }
                    
                    // Backup/Restore section
                    DetailSection(title: "Backup/Restore") {
                        VStack(spacing: 12) {
                            Button {
                                exportToCSV()
                            } label: {
                                Label("Export to CSV", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            
                            Button {
                                showFileImporter = true
                            } label: {
                                Label("Import from CSV", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    // Logout section
                    Button(role: .destructive) {
                        showLogoutAlert = true
                    } label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 10)
                }
                .padding()
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
            .alert("Are you sure you want to logout?", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    // Clear local data
                    emailAliases.forEach { modelContext.delete($0) }
                    try? modelContext.save()
                    
                    // Logout from CloudflareClient
                    cloudflareClient.logout()
                    dismiss()
                }
            } message: {
                Text("This will clear all local data and you'll need to sign in again.")
            }
            .alert("Import Error", isPresented: $showImportError, presenting: importError) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.plainText, .commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importFromCSV(url: url)
                case .failure(let error):
                    print("File import error: \(error)")
                    importError = error
                    showImportError = true
                }
            }
            .fileExporter(
                isPresented: $showExportDialog,
                document: CSVDocument(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("email_aliases.csv")
                ),
                contentType: UTType.commaSeparatedText,
                defaultFilename: "email_aliases.csv"
            ) { _ in }
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

// Helper view for info rows
struct InfoRow<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.body, design: .rounded))
            content
        }
    }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    
    let url: URL
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("email_aliases.csv")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
} 
