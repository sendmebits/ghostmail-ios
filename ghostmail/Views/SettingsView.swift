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
    @AppStorage("showWebsiteLogo") private var showWebsiteLogo: Bool = true
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
    @Environment(\.openURL) private var openURL
    @State private var showAddZoneSheet = false {
        didSet {
            if showAddZoneSheet {
                UserDefaults.standard.set("", forKey: "addZone.accountId")
                UserDefaults.standard.set("", forKey: "addZone.zoneId")
                UserDefaults.standard.set("", forKey: "addZone.apiToken")
            }
        }
    }
    @AppStorage("defaultZoneId") private var defaultZoneId: String = ""
    @State private var zoneToRemove: CloudflareClient.CloudflareZone? = nil
    @State private var showRemoveZoneAlert: Bool = false
    
    init() {
        // Initialize selectedDefaultAddress with the current saved value
        let savedDefault = UserDefaults.standard.string(forKey: "defaultForwardingAddress") ?? ""
        _selectedDefaultAddress = State(initialValue: savedDefault)
    }

    // Precompute additional zones (exclude the primary zone)
    private var additionalZones: [CloudflareClient.CloudflareZone] {
        cloudflareClient.zones.filter { $0.zoneId != cloudflareClient.zoneId }
    }

    // Entry count helper for a specific zone
    private func entryCount(for zoneId: String) -> Int {
    emailAliases.filter { $0.zoneId == zoneId && $0.isLoggedOut == false }.count
    }

    private var sortedForwardingAddresses: [String] {
        Array(cloudflareClient.forwardingAddresses).sorted()
    }

    private var primaryZoneId: String {
        cloudflareClient.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func zoneDisplayName(_ zone: CloudflareClient.CloudflareZone) -> String {
        zone.domainName.isEmpty ? zone.zoneId : zone.domainName
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
            // Delete CloudKit data for the current Zone ID only
            let container = CKContainer.default()
            let database = container.privateCloudDatabase

            do {
                // First, mark all local data as not syncing to prevent re-upload
                try modelContext.save()

                // Ensure we have a zoneId to target; we must not delete zones for other accounts
                let targetZoneFragment = cloudflareClient.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                if targetZoneFragment.isEmpty {
                    print("No Cloudflare zoneId available – skipping iCloud zone deletion to avoid accidental data loss")
                    await MainActor.run { isLoading = false }
                    return
                }

                // Fetch all zones but only attempt to delete those that appear to belong to the current Cloudflare zone
                var allZones: [CKRecordZone] = []

                // Retry zone fetching up to 3 times with exponential backoff
                for attempt in 1...3 {
                    do {
                        allZones = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecordZone], Error>) in
                            container.privateCloudDatabase.fetchAllRecordZones { zones, error in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else if let zones = zones {
                                    continuation.resume(returning: zones)
                                } else {
                                    continuation.resume(throwing: NSError(domain: "CloudKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "No zones returned and no error"]))
                                }
                            }
                        }
                        break
                    } catch {
                        if attempt == 3 { throw error }
                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 500_000_000))
                        print("Retrying zone fetch, attempt \(attempt + 1)...")
                    }
                }

                // Filter zones to only those that likely belong to the current Cloudflare zoneId.
                // We deliberately avoid deleting the _defaultZone and we only proceed if a zone's name
                // contains the Cloudflare zoneId fragment. This is a conservative heuristic to avoid
                // accidentally removing unrelated users' data.
                let candidateZones = allZones.filter { zone in
                    let name = zone.zoneID.zoneName
                    return name != "_defaultZone" && name.contains(targetZoneFragment)
                }

                if candidateZones.isEmpty {
                    print("No matching iCloud record zones found for zoneId '\(targetZoneFragment)'. Skipping deletion.")
                    await MainActor.run { isLoading = false }
                    return
                }

                var hadDeletionFailures = false
                var zoneDeletionErrors: [Error] = []

                for zone in candidateZones {
                    let zoneID = zone.zoneID
                    var zoneDeleted = false
                    for attempt in 1...3 {
                        do {
                            try await database.deleteRecordZone(withID: zoneID)
                            zoneDeleted = true
                            print("Successfully deleted zone: \(zoneID.zoneName)")
                            break
                        } catch let zoneError as NSError {
                            if zoneError.code == CKError.unknownItem.rawValue {
                                print("Zone \(zoneID.zoneName) doesn't exist or was already deleted")
                                zoneDeleted = true
                                break
                            }

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

                            if attempt == 3 {
                                hadDeletionFailures = true
                                zoneDeletionErrors.append(zoneError)
                                print("Failed to delete zone \(zoneID.zoneName) after 3 attempts: \(zoneError.localizedDescription)")
                            }
                        }
                    }

                    if !zoneDeleted { hadDeletionFailures = true }
                }

                await MainActor.run {
                    if hadDeletionFailures {
                        print("⚠️ iCloud sync disabled, but some data couldn't be deleted from iCloud for zoneId: \(targetZoneFragment).")
                        if let firstError = zoneDeletionErrors.first {
                            print("Error detail: \(firstError.localizedDescription)")
                        }
                    } else {
                        print("✅ iCloud sync disabled. Selected zone data successfully removed from iCloud for zoneId: \(targetZoneFragment).")
                    }

                    isLoading = false
                }
            } catch {
                print("Error managing iCloud data: \(error.localizedDescription)")
                await MainActor.run {
                    iCloudSyncEnabled = false
                    isLoading = false
                }
            }
        }
    }
    
    // (Removed debug/testing helper functions related to CloudKit testing and diagnostics)
    
    var body: some View {
        NavigationStack {
            List {
                // About section (moved to top)
                Section {
                    InfoRow(title: "App Version") {
                        AppVersionValueView()
                    }
                    InfoRow(title: "Website") {
                        let site = "https://github.com/sendmebits/ghostmail-ios"
                        Text(site)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .onTapGesture {
                                if let url = URL(string: site) {
                                    openURL(url)
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIPasteboard.general.string = site
                                let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                            }
                            .contextMenu {
                                Button {
                                    if let url = URL(string: site) {
                                        openURL(url)
                                    }
                                } label: {
                                    Text("Open Website")
                                    Image(systemName: "safari")
                                }

                                Button {
                                    UIPasteboard.general.string = site
                                } label: {
                                    Text("Copy Website")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                    }
                } header: {
                    Text("About")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                // Cloudflare Account grouped as separate sections (no outer shading)
                Section {
                    InfoRow(title: "Account ID for \(cloudflareClient.accountName)") {
                        Text(cloudflareClient.accountId)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .onLongPressGesture(minimumDuration: 0.5) {
                                if !cloudflareClient.accountId.isEmpty {
                                    UIPasteboard.general.string = cloudflareClient.accountId
                                    let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                                }
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = cloudflareClient.accountId
                                } label: {
                                    Text("Copy Account ID")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                    }
                } header: {
                    Text("Cloudflare Account")
                        .textCase(.uppercase)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                // Primary zone section
                Section {
                    InfoRow(title: "Zone ID for \(cloudflareClient.emailDomain)") {
                        Text(cloudflareClient.zoneId)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .onLongPressGesture(minimumDuration: 0.5) {
                                if !cloudflareClient.zoneId.isEmpty {
                                    UIPasteboard.general.string = cloudflareClient.zoneId
                                    let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                                }
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = cloudflareClient.zoneId
                                } label: {
                                    Text("Copy Zone ID")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                    }
                    InfoRow(title: "Entries") {
                        let count = entryCount(for: primaryZoneId)
                        Text("\(count) Addresses Created")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        // Prepare removal of the primary zone
                        zoneToRemove = CloudflareClient.CloudflareZone(
                            accountId: cloudflareClient.accountId,
                            zoneId: cloudflareClient.zoneId,
                            apiToken: "", // token not needed for removal
                            accountName: cloudflareClient.accountName,
                            domainName: cloudflareClient.domainName
                        )
                        showRemoveZoneAlert = true
                    } label: {
                        Label("Remove This Zone", systemImage: "trash")
                    }
                }

                // Additional zone sections
                ForEach(additionalZones, id: \.zoneId) { z in
                    Section {
                        InfoRow(title: "Zone ID for \(zoneDisplayName(z))") {
                            Text(z.zoneId)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = z.zoneId
                                    } label: {
                                        Text("Copy Zone ID")
                                        Image(systemName: "doc.on.doc")
                                    }
                                }
                        }
                        InfoRow(title: "Entries") {
                            let count = entryCount(for: z.zoneId)
                            Text("\(count) Addresses Created")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            zoneToRemove = z
                            showRemoveZoneAlert = true
                        } label: {
                            Label("Remove This Zone", systemImage: "trash")
                        }
                    }
                }
                // Add Zone entry point
                Section {
                    Button {
                        showAddZoneSheet = true
                    } label: {
                        Label("Add Zone (Domain)", systemImage: "plus.circle")
                    }
                }
                
                // Settings section
                Section {
                    // Default Domain (only when multiple zones)
                    if cloudflareClient.zones.count > 1 {
                        Picker("Default Domain", selection: $defaultZoneId) {
                            ForEach(cloudflareClient.zones, id: \.zoneId) { z in
                                Text(zoneDisplayName(z)).tag(z.zoneId)
                            }
                        }
                        .pickerStyle(.menu)
                        .onAppear {
                            if defaultZoneId.isEmpty {
                                defaultZoneId = cloudflareClient.zoneId
                            }
                        }
                    }

            if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Default Destination", selection: $selectedDefaultAddress) {
                ForEach(sortedForwardingAddresses, id: \.self) { address in
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

                    Toggle("Show Website Logo", isOn: $showWebsiteLogo)
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
                // ...existing code...
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
            .alert("Remove Zone?", isPresented: $showRemoveZoneAlert) {
                Button("Cancel", role: .cancel) { zoneToRemove = nil }
                Button("Remove", role: .destructive) {
                    guard let z = zoneToRemove else { return }
                    // Do not delete anything from iCloud; just mark local aliases as logged out
                    let targetZoneId = z.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                    for alias in emailAliases where alias.zoneId == targetZoneId {
                        alias.isLoggedOut = true
                    }
                    try? modelContext.save()

                    // Remove zone from client (and possibly promote another as primary)
                    cloudflareClient.removeZone(zoneId: targetZoneId)
                    // Clear default domain if it pointed to this zone
                    if defaultZoneId == targetZoneId {
                        defaultZoneId = cloudflareClient.zoneId
                    }
                    // If list filter was locked to this zone, reset it to All
                    let ud = UserDefaults.standard
                    if ud.string(forKey: "EmailListView.domainFilterZoneId") == targetZoneId {
                        ud.set("all", forKey: "EmailListView.domainFilterType")
                        ud.removeObject(forKey: "EmailListView.domainFilterZoneId")
                    }
                    zoneToRemove = nil
                }
            } message: {
                let name = zoneToRemove?.domainName.isEmpty == false ? zoneToRemove!.domainName : (zoneToRemove?.zoneId ?? "this zone")
                Text("This will remove \(name) from this device. Your Cloudflare configuration and iCloud data will remain intact.")
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
        .sheet(isPresented: $showAddZoneSheet) {
            NavigationStack {
                AddZoneView(onSuccess: {
                    showAddZoneSheet = false
                })
                .navigationTitle("Add Zone (Domain)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAddZoneSheet = false }
                    }
                }
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
                    // Then fetch addresses directly from Cloudflare API (all zones when available)
                    if cloudflareClient.zones.count > 1 {
                        try await cloudflareClient.refreshForwardingAddressesAllZones()
                    } else {
                        try await cloudflareClient.refreshForwardingAddresses()
                    }
                    
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
                        showWebsiteLogo = cloudflareClient.shouldShowWebsiteLogos
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

// Duplicate ZoneCard removed

// ZoneCard removed; using native Section groupings

// Small helper view to show app version; keeps the main view simpler for the type-checker
private struct AppVersionValueView: View {
    private var versionText: String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(appVersion) (\(buildNumber))"
    }

    var body: some View {
        let val = versionText
        return Text(val)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(.secondary)
            .onLongPressGesture(minimumDuration: 0.5) {
                UIPasteboard.general.string = val
                let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = val
                } label: {
                    Text("Copy Version")
                    Image(systemName: "doc.on.doc")
                }
            }
    }
}
