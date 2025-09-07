import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CloudKit

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
    @State private var isLoading = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @State private var showDisableSyncConfirmation = false
    @State private var showDeleteICloudDataConfirmation = false
    @State private var showRestartAlert = false
    
    init() {
        // Initialize selectedDefaultAddress with the current saved value
        let savedDefault = UserDefaults.standard.string(forKey: "defaultForwardingAddress") ?? ""
        _selectedDefaultAddress = State(initialValue: savedDefault)
    }
    
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
    
    private func toggleICloudSync(_ isEnabled: Bool) {
        if isEnabled {
            // Enable iCloud sync
            enableICloudSync()
        } else {
            // Just disable sync without deleting data
            iCloudSyncEnabled = false
            try? modelContext.save()
        }
    }
    
    private func enableICloudSync() {
        // Update app storage setting
        iCloudSyncEnabled = true
        
        // Show restart alert since ModelContainer needs to be reinitialized
        showRestartAlert = true
    }
    
    private func restartApp() {
        // Exit the app to force restart with new CloudKit configuration
        exit(0)
    }
    
    // (Removed debug/testing helper functions related to CloudKit testing and diagnostics)
    
    private func disableICloudSync() {
        // Update app storage setting
        iCloudSyncEnabled = false
        
        // Update UI to show loading state
        isLoading = true
        
        Task {
            // Delete CloudKit data for the current Zone ID
            let container = CKContainer.default()
            let database = container.privateCloudDatabase
            
            do {
                // First, mark all local data as not syncing to prevent re-upload
                try modelContext.save()
                
                // Use a zone ID based fetch operation instead of querying by recordName
                // This avoids the "recordName not queryable" error
                var zoneIDs: [CKRecordZone.ID] = []
                
                // Retry zone fetching up to 3 times with exponential backoff
                for attempt in 1...3 {
                    do {
                        zoneIDs = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecordZone.ID], Error>) in
                            container.privateCloudDatabase.fetchAllRecordZones { zones, error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else if let zones = zones {
                                    // Extract just the zone IDs from the zones
                                    let zoneIDs = zones.map { $0.zoneID }
                                    continuation.resume(returning: zoneIDs)
                                } else {
                                    continuation.resume(throwing: NSError(domain: "CloudKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "No zones returned and no error"]))
                                }
                            }
                        }
                        // If successful, break out of retry loop
                        break
                    } catch {
                        if attempt == 3 {
                            // On final attempt, propagate the error
                            throw error
                        }
                        // Wait with exponential backoff before retrying
                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 500_000_000))
                        print("Retrying zone fetch, attempt \(attempt + 1)...")
                    }
                }
                
                // Track if any deletions failed
                var hadDeletionFailures = false
                var zoneDeletionErrors: [Error] = []
                
                // For each zone, delete all EmailAlias records
                for zoneID in zoneIDs {
                    // Skip the default zone as it's not used by SwiftData/CloudKit integration
                    if zoneID.zoneName == "_defaultZone" {
                        continue
                    }
                    
                    // Try to delete the zone with retry logic
                    var zoneDeleted = false
                    for attempt in 1...3 {
                        do {
                            // Delete the entire zone and all its records
                            try await database.deleteRecordZone(withID: zoneID)
                            zoneDeleted = true
                            print("Successfully deleted zone: \(zoneID.zoneName)")
                            break
                        } catch let zoneError as NSError {
                            // If zone doesn't exist, that's success for our purposes
                            if zoneError.code == CKError.unknownItem.rawValue {
                                print("Zone \(zoneID.zoneName) doesn't exist or was already deleted")
                                zoneDeleted = true
                                break
                            }
                            
                            // For rate limiting or network errors, retry with backoff
                            if zoneError.code == CKError.serviceUnavailable.rawValue ||
                               zoneError.code == CKError.networkFailure.rawValue ||
                               zoneError.code == CKError.networkUnavailable.rawValue ||
                               zoneError.code == CKError.requestRateLimited.rawValue {
                                
                                if attempt < 3 {
                                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                                    try await Task.sleep(nanoseconds: delay)
                                    print("Retrying zone deletion, attempt \(attempt + 1)...")
                                    continue
                                }
                            }
                            
                            // If we're here on the last attempt, track the failure
                            if attempt == 3 {
                                hadDeletionFailures = true
                                zoneDeletionErrors.append(zoneError)
                                print("Failed to delete zone \(zoneID.zoneName) after 3 attempts: \(zoneError.localizedDescription)")
                            }
                        }
                    }
                    
                    if !zoneDeleted {
                        hadDeletionFailures = true
                    }
                }
                
                // Update UI based on success/failure
                await MainActor.run {
                    if hadDeletionFailures {
                        print("⚠️ iCloud sync disabled, but some data couldn't be deleted from iCloud.")
                        if let firstError = zoneDeletionErrors.first {
                            print("Error detail: \(firstError.localizedDescription)")
                        }
                    } else {
                        print("✅ iCloud sync disabled. All data successfully removed from iCloud.")
                    }
                    
                    // Reset loading state
                    isLoading = false
                }
            } catch {
                print("Error managing iCloud data: \(error.localizedDescription)")
                
                // Ensure settings are still updated even if there was an error
                await MainActor.run {
                    // Make sure the iCloud sync setting stays disabled
                    iCloudSyncEnabled = false
                    // Removed synchronization of ubiquitous key-value store
                    // Reset loading state
                    isLoading = false
                }
            }
        }
    }
    
    // (Removed debug/testing helper functions related to CloudKit testing and diagnostics)
    
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
                    
                    Toggle("Sync metadata to iCloud", isOn: $iCloudSyncEnabled)
                        .tint(.accentColor)
                        .onChange(of: iCloudSyncEnabled) { oldValue, newValue in
                            if oldValue != newValue {
                                toggleICloudSync(newValue)
                            }
                        }
                        .disabled(isLoading)
                    
                    if !iCloudSyncEnabled {
                        Button(role: .destructive) {
                            showDeleteICloudDataConfirmation = true
                        } label: {
                            Label("Delete iCloud Data", systemImage: "trash")
                        }
                    }
                    
                    // Debug/testing buttons removed
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
                
                // App Version section
                Section {
                    InfoRow(title: "App Version") {
                        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
                        Text("\(appVersion) (\(buildNumber))")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
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
            .alert("Import Confirmation", isPresented: $showImportConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Import", role: .destructive) {
                    if let url = pendingImportURL {
                        importFromCSV(url: url)
                    }
                }
            } message: {
                Text("This will import \(pendingImportURL?.lastPathComponent ?? "the selected file") and may create duplicate records. Please check for duplicates after import.")
            }
            .fileExporter(
                isPresented: $showExportDialog,
                document: CSVDocument(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent("ghostmail_backup.csv")
                ),
                contentType: UTType.commaSeparatedText,
                defaultFilename: "ghostmail_backup.csv"
            ) { _ in }
            .alert("Disable iCloud Sync?", isPresented: $showDisableSyncConfirmation) {
                Button("Cancel", role: .cancel) {
                    // Revert the toggle since user canceled
                    iCloudSyncEnabled = true
                }
                Button("Disable", role: .destructive) {
                    disableICloudSync()
                }
            } message: {
                Text("This will stop syncing data to iCloud and remove all existing Ghostmail data from your iCloud account for zone \(cloudflareClient.zoneId).")
            }
            .alert("Delete iCloud Data?", isPresented: $showDeleteICloudDataConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    disableICloudSync()
                }
            } message: {
                Text("This will permanently delete all Ghostmail data from your iCloud account for zone \(cloudflareClient.zoneId). This action cannot be undone.")
            }
            .alert("Restart Required", isPresented: $showRestartAlert) {
                Button("Restart Now") {
                    restartApp()
                }
                Button("Later", role: .cancel) { }
            } message: {
                Text("To properly enable iCloud sync, the app needs to restart. Would you like to restart now?")
            }
        }
        .onAppear {
            // Force fetching addresses from Cloudflare first
            Task {
                do {
                    isLoading = true
                    print("Settings View: Fetching forwarding addresses...")
                    
                    // Fetch domain name first if needed
                    if cloudflareClient.domainName.isEmpty {
                        try await cloudflareClient.fetchDomainName()
                    }
                    // Then fetch addresses directly from Cloudflare API
                    try await cloudflareClient.refreshForwardingAddresses()
                    
                    // Then update the UI with the fetched addresses
                    await MainActor.run {
                        if !cloudflareClient.forwardingAddresses.isEmpty {
                            // Check if the current selected address is still valid
                            if selectedDefaultAddress.isEmpty || !cloudflareClient.forwardingAddresses.contains(selectedDefaultAddress) {
                                // If the saved address is no longer valid, use the current default
                                let oldDefault = selectedDefaultAddress
                                let newDefault = cloudflareClient.currentDefaultForwardingAddress
                                selectedDefaultAddress = newDefault
                                print("Updated default address from '\(oldDefault)' to '\(newDefault)' (saved address no longer available)")
                            } else {
                                print("Preserved user's saved default address: \(selectedDefaultAddress)")
                            }
                        } else {
                            print("Warning: No forwarding addresses available")
                        }
                        
                        showWebsites = cloudflareClient.shouldShowWebsitesInList
                        isLoading = false
                        print("Settings loaded successfully")
                    }
                } catch {
                    await MainActor.run {
                        isLoading = false
                        print("Error fetching forwarding addresses: \(error.localizedDescription)")
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
