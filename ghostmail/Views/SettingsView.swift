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
    @AppStorage("defaultDomain") private var defaultDomain: String = ""
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
    
    // Resolve zone from an email address' domain (best-effort)
    private func zoneForEmailAddress(_ email: String) -> CloudflareClient.CloudflareZone? {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let domain = parts[1].lowercased()
        // Prefer an exact domain match from configured zones
        if let z = cloudflareClient.zones.first(where: { $0.domainName.lowercased() == domain }) {
            return z
        }
        return nil
    }
    
    private func exportToCSV() {
        let allowedZoneIds = Set(cloudflareClient.zones.map { $0.zoneId.trimmingCharacters(in: .whitespacesAndNewlines) })
        let filtered = emailAliases.filter { allowedZoneIds.contains($0.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let csvString = "Email Address,Website,Notes,Created,Enabled,Forward To\n" + filtered.map { alias in
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
    
    private func showCSVImporter() {
        showFileImporter = true
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
                    
                    // Update Cloudflare if we have a tag, using the alias' zone if available
                    if let tag = existingAlias.cloudflareTag {
                        // Prefer the zone recorded on the alias; otherwise infer by email domain
                        let zone: CloudflareClient.CloudflareZone? =
                            cloudflareClient.zones.first(where: { !$0.zoneId.isEmpty && $0.zoneId == existingAlias.zoneId })
                            ?? zoneForEmailAddress(emailAddress)

                        // Align local alias zone if we could resolve it
                        if let z = zone { existingAlias.zoneId = z.zoneId }

                        Task {
                            if let z = zone {
                                try await cloudflareClient.updateEmailRule(
                                    tag: tag,
                                    emailAddress: emailAddress,
                                    isEnabled: isEnabled,
                                    forwardTo: forwardTo,
                                    in: z
                                )
                            } else {
                                // Fallback to current primary zone
                                try await cloudflareClient.updateEmailRule(
                                    tag: tag,
                                    emailAddress: emailAddress,
                                    isEnabled: isEnabled,
                                    forwardTo: forwardTo
                                )
                            }
                        }
                    }
                } else {
                    // Create new Cloudflare rule first
                    Task {
                        do {
                            // Choose zone by email domain when possible
                            let zone = zoneForEmailAddress(emailAddress)
                            let rule: EmailRule
                            if let z = zone {
                                rule = try await cloudflareClient.createEmailRule(
                                    emailAddress: emailAddress,
                                    forwardTo: forwardTo,
                                    in: z
                                )
                                // If CSV specifies disabled, reflect that state
                                if isEnabled == false {
                                    try await cloudflareClient.updateEmailRule(
                                        tag: rule.tag,
                                        emailAddress: emailAddress,
                                        isEnabled: false,
                                        forwardTo: forwardTo,
                                        in: z
                                    )
                                }
                            } else {
                                rule = try await cloudflareClient.createEmailRule(
                                    emailAddress: emailAddress,
                                    forwardTo: forwardTo
                                )
                                if isEnabled == false {
                                    try await cloudflareClient.updateEmailRule(
                                        tag: rule.tag,
                                        emailAddress: emailAddress,
                                        isEnabled: false,
                                        forwardTo: forwardTo
                                    )
                                }
                            }
                            
                            // Create new alias with Cloudflare tag and zone attribution
                            let newAlias = EmailAlias(
                                emailAddress: emailAddress,
                                forwardTo: forwardTo,
                                isManuallyCreated: created != nil,
                                zoneId: zone?.zoneId ?? cloudflareClient.zoneId
                            )
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
    
    
    // Computed view for complex settings section to help type-checking
    private var settingsSection: some View {
        SettingsSectionView(
            defaultZoneId: $defaultZoneId,
            defaultDomain: $defaultDomain,
            selectedDefaultAddress: $selectedDefaultAddress,
            showWebsites: $showWebsites,
            showWebsiteLogo: $showWebsiteLogo,
            iCloudSyncEnabled: $iCloudSyncEnabled,
            isLoading: isLoading,
            showDeleteICloudDataConfirmation: $showDeleteICloudDataConfirmation,
            sortedForwardingAddresses: sortedForwardingAddresses,
            toggleICloudSync: toggleICloudSync
        )
    }
    
    // (Removed debug/testing helper functions related to CloudKit testing and diagnostics)
    
    // Isolate the complex List subtree to help the type-checker
    private var listContent: AnyView {
        AnyView(
        SettingsListContentView(
            additionalZones: additionalZones,
            primaryEntryCount: entryCount(for: primaryZoneId),
            zoneToRemove: $zoneToRemove,
            showRemoveZoneAlert: $showRemoveZoneAlert,
            showAddZoneSheet: $showAddZoneSheet,
            defaultZoneId: $defaultZoneId,
            defaultDomain: $defaultDomain,
            selectedDefaultAddress: $selectedDefaultAddress,
            showWebsites: $showWebsites,
            showWebsiteLogo: $showWebsiteLogo,
            iCloudSyncEnabled: $iCloudSyncEnabled,
            isLoading: isLoading,
            showDeleteICloudDataConfirmation: $showDeleteICloudDataConfirmation,
            sortedForwardingAddresses: sortedForwardingAddresses,
            toggleICloudSync: { (enabled: Bool) -> Void in toggleICloudSync(enabled) },
            exportToCSV: { () -> Void in exportToCSV() },
            showCSVImporter: { () -> Void in showCSVImporter() },
            logout: { () -> Void in showLogoutAlert = true },
            entryCount: { (zoneId: String) -> Int in entryCount(for: zoneId) }
        ))
    }
    
    var body: some View {
        let v0 = NavigationStack { listContent }
        let v1 = applyNavigation(v0)
        let v2 = applyAlerts(v1)
        let v3 = applyFileOps(v2)
        let v4 = applyLifecycle(v3)
        return v4
    }

    // MARK: - Type-erased modifier steps to ease type checking
    private func applyNavigation<T: View>(_ content: T) -> AnyView {
        AnyView(
            content
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        )
    }

    private func applyAlerts<T: View>(_ content: T) -> AnyView {
        AnyView(
            content
                .alert("Are you sure you want to logout?", isPresented: $showLogoutAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Logout", role: .destructive) {
                        for alias in emailAliases { alias.isLoggedOut = true }
                        try? modelContext.save()
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
                        let targetZoneId = z.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                        for alias in emailAliases where alias.zoneId == targetZoneId { alias.isLoggedOut = true }
                        try? modelContext.save()
                        cloudflareClient.removeZone(zoneId: targetZoneId)
                        if defaultZoneId == targetZoneId { defaultZoneId = cloudflareClient.zoneId }
                        
                        // Clear domain filter if it was filtering on a domain from the removed zone
                        let ud = UserDefaults.standard
                        if let filterDomain = ud.string(forKey: "EmailListView.domainFilterDomain") {
                            // Check if the filtered domain belongs to the removed zone
                            if z.domainName.lowercased() == filterDomain.lowercased() || 
                               z.subdomains.contains(where: { $0.lowercased() == filterDomain.lowercased() }) {
                                ud.set("all", forKey: "EmailListView.domainFilterType")
                                ud.removeObject(forKey: "EmailListView.domainFilterDomain")
                            }
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
        )
    }

    private func applyFileOps<T: View>(_ content: T) -> AnyView {
        AnyView(
            content
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
                        if let url = pendingImportURL { importFromCSV(url: url) }
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
                    Button("Cancel", role: .cancel) { iCloudSyncEnabled = true }
                    Button("Disable", role: .destructive) { disableICloudSync() }
                } message: {
                    Text("This will stop syncing data to iCloud and remove all existing Ghostmail data from your iCloud account for zone \(cloudflareClient.zoneId).")
                }
                .alert("Delete iCloud Data?", isPresented: $showDeleteICloudDataConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) { disableICloudSync() }
                } message: {
                    Text("This will permanently delete all Ghostmail data from your iCloud account for zone \(cloudflareClient.zoneId). This action cannot be undone.")
                }
                .alert("Restart Required", isPresented: $showRestartAlert) {
                    Button("Restart Now") { restartApp() }
                    Button("Later", role: .cancel) { }
                } message: {
                    Text("To properly enable iCloud sync, the app needs to restart. Would you like to restart now?")
                }
                .sheet(isPresented: $showAddZoneSheet) {
                    NavigationStack {
                        AddZoneView(onSuccess: { showAddZoneSheet = false })
                            .navigationTitle("Add Zone (Domain)")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { showAddZoneSheet = false }
                                }
                            }
                    }
                }
        )
    }

    private func applyLifecycle<T: View>(_ content: T) -> AnyView {
        AnyView(
            content
                .onAppear {
                    Task {
                        do {
                            isLoading = true
                            if cloudflareClient.domainName.isEmpty {
                                try await cloudflareClient.fetchDomainName()
                            }
                            if cloudflareClient.zones.count > 1 {
                                try await cloudflareClient.refreshForwardingAddressesAllZones()
                            } else {
                                try await cloudflareClient.refreshForwardingAddresses()
                            }
                            isLoading = false
                        } catch {
                            print("Error fetching addresses: \(error)")
                            isLoading = false
                        }
                    }
                }
                .onChange(of: selectedDefaultAddress) { _, _ in
                    cloudflareClient.setDefaultForwardingAddress(selectedDefaultAddress)
                }
                .onChange(of: showWebsites) { _, _ in
                    cloudflareClient.shouldShowWebsitesInList = showWebsites
                }
        )
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

// A compact subview to isolate the complex List tree and help the type-checker
private struct SettingsListContentView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient

    let additionalZones: [CloudflareClient.CloudflareZone]
    let primaryEntryCount: Int
    @Binding var zoneToRemove: CloudflareClient.CloudflareZone?
    @Binding var showRemoveZoneAlert: Bool
    @Binding var showAddZoneSheet: Bool

    // Settings section bindings/props
    @Binding var defaultZoneId: String
    @Binding var defaultDomain: String
    @Binding var selectedDefaultAddress: String
    @Binding var showWebsites: Bool
    @Binding var showWebsiteLogo: Bool
    @Binding var iCloudSyncEnabled: Bool
    let isLoading: Bool
    @Binding var showDeleteICloudDataConfirmation: Bool
    let sortedForwardingAddresses: [String]
    let toggleICloudSync: (Bool) -> Void

    // Backup/restore + actions
    let exportToCSV: () -> Void
    let showCSVImporter: () -> Void
    let logout: () -> Void

    // Utilities
    let entryCount: (String) -> Int

    var body: some View {
        List {
            AboutSectionView()
            CloudflareAccountSectionView()
            PrimaryZoneSectionView(
                zoneToRemove: $zoneToRemove,
                showRemoveZoneAlert: $showRemoveZoneAlert,
                entryCount: primaryEntryCount
            )

            if cloudflareClient.zones.count > 1 {
                AdditionalZonesSectionView(
                    additionalZones: additionalZones,
                    zoneToRemove: $zoneToRemove,
                    showRemoveZoneAlert: $showRemoveZoneAlert,
                    entryCount: entryCount
                )
            }

            AddZoneSectionView(showAddZoneSheet: $showAddZoneSheet)

            SettingsSectionView(
                defaultZoneId: $defaultZoneId,
                defaultDomain: $defaultDomain,
                selectedDefaultAddress: $selectedDefaultAddress,
                showWebsites: $showWebsites,
                showWebsiteLogo: $showWebsiteLogo,
                iCloudSyncEnabled: $iCloudSyncEnabled,
                isLoading: isLoading,
                showDeleteICloudDataConfirmation: $showDeleteICloudDataConfirmation,
                sortedForwardingAddresses: sortedForwardingAddresses,
                toggleICloudSync: toggleICloudSync
            )

            BackupRestoreSectionView(
                exportToCSV: exportToCSV,
                importFromCSV: showCSVImporter
            )

            SendLogsSectionView()

            LogoutSectionView(logout: logout)
        }
    }
}

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

// MARK: - Section Subviews for better type-checking performance

private struct AboutSectionView: View {
    @Environment(\.openURL) private var openURL
    
    var body: some View {
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
    }
}

private struct CloudflareAccountSectionView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    
    var body: some View {
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
    }
}

private struct PrimaryZoneSectionView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Binding var zoneToRemove: CloudflareClient.CloudflareZone?
    @Binding var showRemoveZoneAlert: Bool
    let entryCount: Int
    @State private var showSubdomainError = false
    @State private var subdomainErrorMessage = ""
    
    private var primaryZone: CloudflareClient.CloudflareZone? {
        cloudflareClient.zones.first(where: { $0.zoneId == cloudflareClient.zoneId })
    }
    
    var body: some View {
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
                Text("\(entryCount) Addresses Created")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            
            Toggle("Enable Sub-Domains for this Zone", isOn: Binding(
                get: { primaryZone?.subdomainsEnabled ?? false },
                set: { newValue in
                    Task {
                        do {
                            try await cloudflareClient.toggleSubdomains(for: cloudflareClient.zoneId, enabled: newValue)
                        } catch {
                            subdomainErrorMessage = error.localizedDescription
                            showSubdomainError = true
                        }
                    }
                }
            ))
            .tint(.accentColor)
            
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
        .alert("Subdomain Error", isPresented: $showSubdomainError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(subdomainErrorMessage)
        }
    }
}

private struct AdditionalZonesSectionView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    let additionalZones: [CloudflareClient.CloudflareZone]
    @Binding var zoneToRemove: CloudflareClient.CloudflareZone?
    @Binding var showRemoveZoneAlert: Bool
    let entryCount: (String) -> Int
    @State private var showSubdomainError = false
    @State private var subdomainErrorMessage = ""
    @State private var errorZoneId = ""
    
    private func zoneDisplayName(_ zone: CloudflareClient.CloudflareZone) -> String {
        zone.domainName.isEmpty ? zone.zoneId : zone.domainName
    }
    
    var body: some View {
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
                    let count = entryCount(z.zoneId)
                    Text("\(count) Addresses Created")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                
                Toggle("Enable Sub-Domains for this Zone", isOn: Binding(
                    get: { z.subdomainsEnabled },
                    set: { newValue in
                        Task {
                            do {
                                try await cloudflareClient.toggleSubdomains(for: z.zoneId, enabled: newValue)
                            } catch {
                                errorZoneId = z.zoneId
                                subdomainErrorMessage = error.localizedDescription
                                showSubdomainError = true
                            }
                        }
                    }
                ))
                .tint(.accentColor)
                
                Button(role: .destructive) {
                    zoneToRemove = z
                    showRemoveZoneAlert = true
                } label: {
                    Label("Remove This Zone", systemImage: "trash")
                }
            }
        }
        .alert("Subdomain Error", isPresented: $showSubdomainError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(subdomainErrorMessage)
        }
    }
}

private struct AddZoneSectionView: View {
    @Binding var showAddZoneSheet: Bool
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @State private var isRefreshingDomains = false
    
    // Check if any zone has subdomains enabled
    private var anyZoneHasSubdomainsEnabled: Bool {
        cloudflareClient.zones.contains(where: { $0.subdomainsEnabled })
    }
    
    var body: some View {
        Section {
            Button {
                showAddZoneSheet = true
            } label: {
                Label("Add Zone (Domain)", systemImage: "plus.circle")
            }
            
            // Only show Refresh Domains button if at least one zone has subdomains enabled
            if anyZoneHasSubdomainsEnabled {
                Button {
                    Task {
                        isRefreshingDomains = true
                        do {
                            try await cloudflareClient.refreshSubdomainsAllZones()
                            print("✅ Subdomains refreshed successfully")
                        } catch {
                            print("❌ Failed to refresh subdomains: \(error)")
                        }
                        isRefreshingDomains = false
                    }
                } label: {
                    HStack {
                        Label("Refresh Domains", systemImage: "arrow.clockwise")
                        if isRefreshingDomains {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshingDomains)
            }
        }
    }
}

private struct SettingsSectionView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Binding var defaultZoneId: String
    @Binding var defaultDomain: String
    @Binding var selectedDefaultAddress: String
    @Binding var showWebsites: Bool
    @Binding var showWebsiteLogo: Bool
    @Binding var iCloudSyncEnabled: Bool
    let isLoading: Bool
    @Binding var showDeleteICloudDataConfirmation: Bool
    let sortedForwardingAddresses: [String]
    let toggleICloudSync: (Bool) -> Void
    
    private func zoneDisplayName(_ zone: CloudflareClient.CloudflareZone) -> String {
        zone.domainName.isEmpty ? zone.zoneId : zone.domainName
    }
    
    // Get all available domains (main domains + subdomains) across all zones
    private var allAvailableDomains: [(domain: String, zoneId: String)] {
        var domains: [(domain: String, zoneId: String)] = []
        
        for zone in cloudflareClient.zones {
            // Add main domain
            if !zone.domainName.isEmpty {
                domains.append((domain: zone.domainName, zoneId: zone.zoneId))
            }
            
            // Add subdomains only if enabled for this zone
            if zone.subdomainsEnabled {
                for subdomain in zone.subdomains {
                    domains.append((domain: subdomain, zoneId: zone.zoneId))
                }
            }
        }
        
        return domains.sorted { $0.domain < $1.domain }
    }
    
    var body: some View {
        Section {
            // Default Domain picker - shows all domains and subdomains
            if cloudflareClient.zones.count > 1 || !(cloudflareClient.zones.first?.subdomains.isEmpty ?? true) {
                Picker("Default Domain", selection: $defaultDomain) {
                    ForEach(allAvailableDomains, id: \.domain) { item in
                        Text(item.domain).tag(item.domain)
                    }
                }
                .pickerStyle(.menu)
                .onAppear {
                    if defaultDomain.isEmpty {
                        defaultDomain = cloudflareClient.emailDomain
                    }
                }
                .onChange(of: defaultDomain) { _, newDomain in
                    // Update defaultZoneId when domain changes
                    if let item = allAvailableDomains.first(where: { $0.domain == newDomain }) {
                        defaultZoneId = item.zoneId
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
        } header: {
            Text("Settings")
                .textCase(.uppercase)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct BackupRestoreSectionView: View {
    let exportToCSV: () -> Void
    let importFromCSV: () -> Void
    
    var body: some View {
        Section {
            Button {
                exportToCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            
            Button {
                importFromCSV()
            } label: {
                Label("Import CSV", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup & Restore")
                .textCase(.uppercase)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

private struct LogoutSectionView: View {
    let logout: () -> Void
    
    var body: some View {
        Section {
            Button(role: .destructive) {
                logout()
            } label: {
                Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

private struct SendLogsSectionView: View {
    @State private var showCopiedToast = false

    var body: some View {
        Section {
            Button {
                let text = LogBuffer.shared.dumpText()
                let logText = text.isEmpty ? "(No recent logs)" : text
                UIPasteboard.general.string = logText
                
                // Haptic feedback
                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()
                
                // Show brief confirmation
                showCopiedToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showCopiedToast = false
                }
            } label: {
                Label("Copy Logs", systemImage: "doc.on.doc")
            }
            
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
