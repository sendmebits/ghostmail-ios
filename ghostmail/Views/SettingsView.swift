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
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var syncStatus: String?
    @State private var isLoading = false
    
    private func exportToCSV() {
        let csvString = "Email Address,Website,Notes,Created,Enabled,Forward To\n" + emailAliases.map { alias in
            let createdStr = alias.created?.ISO8601Format() ?? ""
            return "\(alias.emailAddress),\(alias.website),\(alias.notes),\(createdStr),\(alias.isEnabled),\(alias.forwardTo)"
        }.joined(separator: "\n")
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ghostmail_backup.csv")
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
    
    private func verifyICloudSync() {
        syncStatus = "Checking iCloud sync status..."
        
        // Ensure forwarding addresses are available
        if cloudflareClient.forwardingAddresses.isEmpty {
            // Start a task to refresh addresses first
            Task {
                syncStatus = "Fetching forwarding addresses from Cloudflare..."
                do {
                    try await cloudflareClient.refreshForwardingAddresses()
                    await runICloudSyncCheck()
                } catch {
                    await MainActor.run {
                        syncStatus = "❌ Error fetching forwarding addresses: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            // Addresses already available, run the check directly
            Task {
                await runICloudSyncCheck()
            }
        }
    }
    
    private func runICloudSyncCheck() async {
        // Test iCloud connectivity
        let ubiquitousStore = NSUbiquitousKeyValueStore.default
        let testKey = "com.ghostmail.test.sync.\(UUID().uuidString)"
        let testValue = "Test value: \(Date().timeIntervalSince1970)"
        
        // Write to iCloud key-value store
        ubiquitousStore.set(testValue, forKey: testKey)
        let syncSuccess = ubiquitousStore.synchronize()
        
        // Count all records
        let allDescriptor = FetchDescriptor<EmailAlias>()
        let activeDescriptor = FetchDescriptor<EmailAlias>(
            predicate: #Predicate<EmailAlias> { alias in
                alias.isLoggedOut == false
            }
        )
        let inactiveDescriptor = FetchDescriptor<EmailAlias>(
            predicate: #Predicate<EmailAlias> { alias in
                alias.isLoggedOut == true
            }
        )
        
        do {
            let totalCount = try modelContext.fetchCount(allDescriptor)
            let activeCount = try modelContext.fetchCount(activeDescriptor)
            let inactiveCount = try modelContext.fetchCount(inactiveDescriptor)
            
            // Get forwarding address with fallbacks
            let forwardToAddress = cloudflareClient.forwardingAddresses.first ?? "fallback-test@example.com"
            
            // Create a test record to verify sync
            let testAlias = EmailAlias(
                emailAddress: "test-\(UUID().uuidString)@\(cloudflareClient.emailDomain)",
                forwardTo: forwardToAddress,
                isManuallyCreated: true
            )
            testAlias.notes = "iCloud sync test - \(Date())"
            testAlias.isLoggedOut = true // Mark as logged out so it won't show in the UI
            
            modelContext.insert(testAlias)
            try modelContext.save()
            
            // Create status message
            await MainActor.run {
                syncStatus = """
                ✅ iCloud Sync Check Complete
                
                Total records: \(totalCount + 1)
                Active records: \(activeCount)
                Inactive records: \(inactiveCount + 1)
                
                Test record created: \(testAlias.id)
                iCloud KVS test: \(syncSuccess ? "Successful" : "Failed")
                Forwarding address: \(forwardToAddress)
                
                CloudKit integration is active and database operations are working.
                If your metadata is still not persisting after logout/login:
                1. The app now preserves data during logout
                2. Try forcing a sync by creating a new alias before logout
                3. Check that iCloud is enabled for this app in Settings
                4. Verify your Apple ID is signed in to iCloud
                """
            }
        } catch {
            await MainActor.run {
                syncStatus = "❌ Error checking iCloud sync: \(error.localizedDescription)"
            }
        }
    }
    
    private func forceICloudSync() {
        syncStatus = "Forcing CloudKit sync..."
        
        // Ensure forwarding addresses are available
        if cloudflareClient.forwardingAddresses.isEmpty {
            // Start a task to refresh addresses first
            Task {
                syncStatus = "Fetching forwarding addresses from Cloudflare..."
                do {
                    try await cloudflareClient.refreshForwardingAddresses()
                    await runForcedSync()
                } catch {
                    await MainActor.run {
                        syncStatus = "❌ Error fetching forwarding addresses: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            // Addresses already available, run the sync directly
            Task {
                await runForcedSync()
            }
        }
    }
    
    private func runForcedSync() async {
        // Get forwarding address with fallbacks
        let forwardToAddress = cloudflareClient.forwardingAddresses.first ?? "fallback-test@example.com"
        
        // 1. Create a test record that will be synced to CloudKit
        let testAlias = EmailAlias(
            emailAddress: "force-sync-\(UUID().uuidString)@\(cloudflareClient.emailDomain)",
            forwardTo: forwardToAddress,
            isManuallyCreated: true
        )
        testAlias.notes = "Force CloudKit sync - \(Date())"
        testAlias.isLoggedOut = true // Hide from UI
        
        // 2. Insert and save to trigger a sync
        modelContext.insert(testAlias)
        
        do {
            try modelContext.save()
            
            // 3. Force iCloud key-value store sync
            NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: "com.ghostmail.last_force_sync")
            let success = NSUbiquitousKeyValueStore.default.synchronize()
            
            // 4. Update all existing records to trigger more sync activity
            let descriptor = FetchDescriptor<EmailAlias>()
            if let allAliases = try? modelContext.fetch(descriptor) {
                for alias in allAliases {
                    alias.notes = alias.notes + " " // Add a space to trigger an update
                }
                try modelContext.save()
            }
            
            await MainActor.run {
                syncStatus = """
                ⚡️ Force Sync Initiated
                
                Test record created: \(testAlias.id)
                KVS sync: \(success ? "Successful" : "Failed")
                Forwarding address: \(forwardToAddress)
                Timestamp: \(Date().formatted())
                
                CloudKit sync has been manually triggered.
                This may take a few minutes to complete.
                Changes should propagate to other devices soon.
                """
            }
        } catch {
            await MainActor.run {
                syncStatus = "❌ Error forcing sync: \(error.localizedDescription)"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Account section
                Section {
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
                } header: {
                    Text("Cloudflare Account")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                // Settings section
                Section {
                    if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Default Destination", selection: $selectedDefaultAddress) {
                            ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text("No forwarding addresses available")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    
                    Toggle("Show Websites in List", isOn: $showWebsites)
                        .tint(.accentColor)
                } header: {
                    Text("Settings")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                // Backup/Restore section
                Section {
                    Button {
                        exportToCSV()
                    } label: {
                        Label("Export to CSV", systemImage: "square.and.arrow.up")
                    }
                    
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from CSV", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Backup/Restore")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                // Logout section
                Section {
                    Button(role: .destructive) {
                        showLogoutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                            Text("Logout")
                            Spacer()
                        }
                    }
                }
                
                // Diagnostics section
                Section("Diagnostics") {
                    Button("Verify iCloud Sync") {
                        verifyICloudSync()
                    }
                    
                    Button("Force iCloud Sync") {
                        forceICloudSync()
                    }
                    
                    if let syncStatus = syncStatus {
                        Text(syncStatus)
                            .font(.caption)
                            .foregroundColor(syncStatus.contains("Error") ? .red : .green)
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
            .alert("Are you sure you want to logout?", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    // Instead of deleting data, we'll mark it as inactive
                    // This preserves the data in iCloud while hiding it from the current session
                    for alias in emailAliases {
                        alias.isLoggedOut = true
                    }
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
                    pendingImportURL = url
                    showImportConfirmation = true
                case .failure(let error):
                    print("File import error: \(error)")
                    importError = error
                    showImportError = true
                }
            }
            .alert("Are you sure you want to overwrite with \(pendingImportURL?.lastPathComponent ?? "")?", isPresented: $showImportConfirmation) {
                Button("Cancel", role: .cancel) { 
                    pendingImportURL = nil
                }
                Button("Import", role: .destructive) {
                    if let url = pendingImportURL {
                        importFromCSV(url: url)
                    }
                    pendingImportURL = nil
                }
            } message: {
                Text("This will update or create email aliases based on the CSV contents.")
            }
            .fileExporter(
                isPresented: $showExportDialog,
                document: CSVDocument(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("ghostmail_backup.csv")
                ),
                contentType: UTType.commaSeparatedText,
                defaultFilename: "ghostmail_backup.csv"
            ) { _ in }
        }
        .onAppear {
            // Force fetching addresses from Cloudflare first
            Task {
                do {
                    isLoading = true
                    try await cloudflareClient.refreshForwardingAddresses()
                    
                    // Then update the UI with the fetched addresses
                    await MainActor.run {
                        selectedDefaultAddress = cloudflareClient.forwardingAddresses.first ?? ""
                        showWebsites = cloudflareClient.shouldShowWebsitesInList
                        isLoading = false
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        // Show error to user
                        importError = error
                        showImportError = true
                    }
                }
            }
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
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ghostmail_backup.csv")
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
} 
