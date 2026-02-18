//
//  ghostmailApp.swift
//  ghostmail
//
//  Created by sendmebits on 2025-01-16.
//

import SwiftUI
import SwiftData
import CloudKit
import Combine

@main
struct ghostmailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    let modelContainer: ModelContainer
    @StateObject private var cloudflareClient = CloudflareClient(accountId: "", zoneId: "", apiToken: "")
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @AppStorage("userIdentifier") private var userIdentifier: String = ""
    @AppStorage("showAnalytics") private var showAnalytics: Bool = false
    
    // Background update state
    @State private var lastUpdateCheck: Date = .distantPast
    @State private var lastForegroundSync: Date = .distantPast
    @State private var updateTimer: Timer?
    @State private var isUpdating: Bool = false
    @State private var isSyncingStatistics: Bool = false  // Guard for statistics sync
    private let updateInterval: TimeInterval = 120 // 2 minutes for background polling
    private let foregroundCooldown: TimeInterval = 30 // 30 seconds for foreground sync
    
    init() {
        // Read iCloud sync preference with a safe default of TRUE when unset
        // Avoid accessing self.iCloudSyncEnabled here to prevent capturing self in init
        let syncEnabled: Bool
        if let stored = UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool {
            syncEnabled = stored
        } else {
            // Default to enabled for first launch so CloudKit mirroring is active
            syncEnabled = true
            UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")
        }
        
        // Create a unique user identifier if it doesn't exist yet
        if UserDefaults.standard.string(forKey: "userIdentifier")?.isEmpty ?? true {
            UserDefaults.standard.set(UUID().uuidString, forKey: "userIdentifier")
        }
        
        do {
            // Create a model configuration based on iCloud sync preference
            let config: ModelConfiguration
            
            if syncEnabled {
                // CloudKit-enabled configuration with explicit schema
                let schema = Schema([EmailAlias.self])
                config = ModelConfiguration(
                    schema: schema, 
                    cloudKitDatabase: .automatic
                )
            } else {
                config = ModelConfiguration(isStoredInMemoryOnly: false)
            }
            
            // Initialize the ModelContainer with the correct class and configuration
            modelContainer = try ModelContainer(for: EmailAlias.self, configurations: config)
            
            // Set up observers only if sync is enabled
            if syncEnabled {
                let container = modelContainer
                // When iCloud pushes changes, debounce and run dedup, then pull metadata.
                var remoteChangeTask: Task<Void, Never>?
                NotificationCenter.default.addObserver(
                    forName: Notification.Name("NSPersistentStoreRemoteChangeNotification"),
                    object: nil,
                    queue: .main
                ) { _ in
                    remoteChangeTask?.cancel()
                    remoteChangeTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        do {
                            _ = try EmailAlias.deduplicate(in: container.mainContext)
                        } catch { }
                        NotificationCenter.default.post(name: .requestCloudKitMetadataPull, object: nil)
                    }
                }
            }
        } catch {
            print("Failed to initialize ModelContainer: \(error)")
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }
    
    /// Ensures all aliases have a user identifier so CloudKit can sync them.
    /// Uses the provided context (prefer mainContext so UI and iCloud stay in sync).
    private static func updateUserIdentifiers(modelContext: ModelContext) async {
        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
        
        do {
            let descriptor = FetchDescriptor<EmailAlias>(
                predicate: #Predicate<EmailAlias> { alias in
                    alias.userIdentifier.isEmpty
                }
            )
            let aliasesNeedingUpdate = try modelContext.fetch(descriptor)
            
            if !aliasesNeedingUpdate.isEmpty {
                for alias in aliasesNeedingUpdate {
                    alias.userIdentifier = userId
                }
                try modelContext.save()
            }
        } catch { }
    }
    
    /// Pulls metadata (notes, website, created) from CloudKit and applies it to
    /// local SwiftData aliases that are missing that metadata.
    /// Called at startup AND after every Cloudflare sync so newly-arrived aliases
    /// pick up metadata from the other device.
    @MainActor
    private func pullMetadataFromCloudKit() async {
        let cloudContainer = CKContainer.default()
        do {
            let status = try await cloudContainer.accountStatus()
            guard status == .available else { return }
            
            let database = cloudContainer.privateCloudDatabase
            let zones = try await database.allRecordZones()
            var cloudMetadata: [String: (notes: String, website: String, created: Date?)] = [:]
            
            for zone in zones {
                var cursor: CKQueryOperation.Cursor? = nil
                repeat {
                    let results: [(CKRecord.ID, Result<CKRecord, Error>)]
                    let nextCursor: CKQueryOperation.Cursor?
                    if let existingCursor = cursor {
                        (results, nextCursor) = try await database.records(continuingMatchFrom: existingCursor, resultsLimit: 200)
                    } else {
                        let query = CKQuery(recordType: "CD_EmailAlias", predicate: NSPredicate(value: true))
                        (results, nextCursor) = try await database.records(matching: query, inZoneWith: zone.zoneID, resultsLimit: 200)
                    }
                    cursor = nextCursor
                    let records = results.compactMap { try? $0.1.get() }
                    for record in records {
                        let email = (record["CD_emailAddress"] as? String ?? "").lowercased()
                        guard !email.isEmpty else { continue }
                        let notes = record["CD_notes"] as? String ?? ""
                        let website = record["CD_website"] as? String ?? ""
                        let created = record["CD_created"] as? Date
                        if let existing = cloudMetadata[email] {
                            let existingRichness = (existing.notes.isEmpty ? 0 : 1) + (existing.website.isEmpty ? 0 : 1)
                            let newRichness = (notes.isEmpty ? 0 : 1) + (website.isEmpty ? 0 : 1)
                            if newRichness > existingRichness {
                                cloudMetadata[email] = (notes: notes, website: website, created: created)
                            }
                        } else {
                            cloudMetadata[email] = (notes: notes, website: website, created: created)
                        }
                    }
                } while cursor != nil
            }
            
            let withMetadata = cloudMetadata.filter { !$0.value.notes.isEmpty || !$0.value.website.isEmpty }
            guard !withMetadata.isEmpty else { return }
            
            let descriptor = FetchDescriptor<EmailAlias>()
            let localAliases = try modelContainer.mainContext.fetch(descriptor)
            var updated = 0
            for alias in localAliases {
                let key = alias.emailAddress.lowercased()
                guard let meta = cloudMetadata[key] else { continue }
                var changed = false
                if alias.notes.isEmpty && !meta.notes.isEmpty {
                    alias.notes = meta.notes
                    changed = true
                }
                if alias.website.isEmpty && !meta.website.isEmpty {
                    alias.website = meta.website
                    changed = true
                }
                if alias.created == nil, let created = meta.created {
                    alias.created = created
                    changed = true
                }
                if changed { updated += 1 }
            }
            if updated > 0 {
                try modelContainer.mainContext.save()
            }
        } catch {
            // CloudKit unavailable or transient error; no need to log
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudflareClient)
                .environmentObject(deepLinkRouter)
                .onReceive(NotificationCenter.default.publisher(for: .requestCloudKitMetadataPull)) { _ in
                    Task { @MainActor in
                        guard iCloudSyncEnabled else { return }
                        await pullMetadataFromCloudKit()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await pullMetadataFromCloudKit()
                    }
                }
                .task {
                    // Perform startup operations asynchronously to avoid blocking UI
                    // If app was launched via Create Alias quick action, route to create view now
                    if appDelegate.pendingCreateQuickAction {
                        // Small delay to ensure view hierarchy is ready
                        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                        // Post notification to trigger the same flow as when app is already running
                        NotificationCenter.default.post(name: .ghostmailOpenCreate, object: nil)
                        appDelegate.pendingCreateQuickAction = false
                    }
                    
                    // Start the periodic timer
                    startUpdateTimer()
                    
                    // If authenticated, refresh data from Cloudflare in parallel for faster startup
                    if cloudflareClient.isAuthenticated {
                        // Run critical startup operations in parallel with timeout
                        await withTaskGroup(of: Void.self) { group in
                            // Task 1: Fetch domain name if needed
                            group.addTask {
                                if await cloudflareClient.domainName.isEmpty {
                                    do {
                                        try await withTimeout(seconds: 5) {
                                            try await cloudflareClient.fetchDomainName()
                                        }
                                    } catch {
                                        print("App startup: Domain name fetch failed: \(error)")
                                    }
                                }
                            }
                            
                            // Task 2: Refresh forwarding addresses
                            group.addTask {
                                do {
                                    try await withTimeout(seconds: 5) {
                                        try await cloudflareClient.refreshForwardingAddresses()
                                    }
                                } catch {
                                    print("App startup: Forwarding addresses refresh failed: \(error)")
                                }
                            }
                            
                            // Task 3: Refresh subdomains (only if enabled)
                            group.addTask {
                                let hasEnabledZones = await cloudflareClient.zones.contains(where: { $0.subdomainsEnabled })
                                if hasEnabledZones {
                                    do {
                                        try await withTimeout(seconds: 8) {
                                            try await cloudflareClient.refreshSubdomainsAllZones()
                                        }
                                    } catch {
                                        print("App startup: Subdomains refresh failed: \(error)")
                                    }
                                }
                            }
                            
                            // Task 4: Preload email statistics (delta fetch for speed)
                            group.addTask {
                                // Check if analytics are enabled before preloading
                                let showAnalytics = UserDefaults.standard.bool(forKey: "showAnalytics")
                                if showAnalytics {
                                    do {
                                        try await withTimeout(seconds: 10) {
                                            await self.preloadEmailStatistics()
                                        }
                                    } catch {
                                        print("App startup: Statistics preload failed: \(error)")
                                    }
                                }
                            }
                        }
                    }
                    
                    // iCloud: allow CloudKit a moment to push remote changes before we dedupe/sync
                    if iCloudSyncEnabled {
                        // Brief delay so other devices' changes can land before we dedupe (reduces races)
                        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                        do {
                            let deleted = try EmailAlias.deduplicate(in: modelContainer.mainContext)
                            if deleted > 0 { print("Deduplicated \(deleted) aliases on startup") }
                        } catch {
                            print("Error during startup deduplication: \(error)")
                        }
                        await ghostmailApp.updateUserIdentifiers(modelContext: modelContainer.mainContext)
                        await pullMetadataFromCloudKit()
                        
                        // Pull metadata from CloudKit so local aliases get notes/website
                        // from the other device if they arrived during startup.
                        await pullMetadataFromCloudKit()
                    }
                }
                .onOpenURL { url in
                    // Route custom scheme URLs like ghostmail://create?url=...
                    deepLinkRouter.handle(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    print("🌐 ghostmailApp: onContinueUserActivity called")
                    if let url = userActivity.webpageURL {
                        deepLinkRouter.handle(url: url)
                    }
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Let iCloud settle then merge duplicates so UI shows latest from other devices
                if iCloudSyncEnabled {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 s
                        do {
                            let deleted = try EmailAlias.deduplicate(in: modelContainer.mainContext)
                            if deleted > 0 { print("Deduplicated \(deleted) aliases after foreground (iCloud)") }
                        } catch {
                            print("Foreground deduplication error: \(error)")
                        }
                    }
                }
                // Trigger immediate foreground sync for snappy data updates
                Task {
                    await performForegroundSyncIfNeeded()
                }
                
                // Ensure timer is running for periodic background updates
                startUpdateTimer()
                
                // Check if there's a pending quick action when scene becomes active
                if appDelegate.pendingCreateQuickAction {
                    NotificationCenter.default.post(name: .ghostmailOpenCreate, object: nil)
                    appDelegate.pendingCreateQuickAction = false
                }
            } else if newPhase == .background {
                // Stop timer when in background to save resources
                stopUpdateTimer()
            }
        }
    }
    
    // MARK: - Background Update Logic
    
    private func startUpdateTimer() {
        stopUpdateTimer()
        // Fire every 60s; performBackgroundUpdateIfNeeded only runs when updateInterval (120s) has elapsed
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task {
                await performBackgroundUpdateIfNeeded()
            }
        }
    }
    
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    // MARK: - Foreground Sync (Immediate on App Return)
    
    /// Performs an immediate sync when the app returns to foreground.
    /// Uses a shorter cooldown (30s) than background polling to feel snappy without being excessive.
    @MainActor
    private func performForegroundSyncIfNeeded() async {
        guard cloudflareClient.isAuthenticated else { return }
        guard !isUpdating else { return }
        
        let now = Date()
        let timeSinceLastForeground = now.timeIntervalSince(lastForegroundSync)
        
        // Use shorter cooldown for foreground returns to feel responsive
        guard timeSinceLastForeground >= foregroundCooldown else { return }
        
        // Update timestamps
        lastForegroundSync = now
        lastUpdateCheck = now // Also reset background timer to avoid double-syncing
        isUpdating = true
        
        // Capture the model context before parallel execution to stay on main actor
        let modelContext = modelContainer.mainContext
        
        // Run email rules and statistics sync in parallel for faster updates
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Sync email rules (needs to run on main actor for model context)
            group.addTask { @MainActor in
                do {
                    try await self.cloudflareClient.syncEmailRules(modelContext: modelContext)
                } catch {
                    print("Foreground sync email rules failed: \(error)")
                }
            }
            
            // Task 2: Sync statistics (if enabled) - runs in parallel
            if showAnalytics {
                group.addTask {
                    await self.syncEmailStatisticsInBackground()
                }
            }
        }
        
        isUpdating = false
        
        // After Cloudflare sync, pull metadata from CloudKit for any newly-arrived aliases.
        // Cloudflare creates bare records (no notes/website); CloudKit has the metadata
        // from the other device. This bridges the gap.
        if iCloudSyncEnabled {
            await pullMetadataFromCloudKit()
        }
    }
    
    // MARK: - Background Polling (Timer-based)
    
    @MainActor
    private func performBackgroundUpdateIfNeeded() async {
        // Prevent concurrent executions
        guard cloudflareClient.isAuthenticated else { return }
        guard !isUpdating else { return }
        
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateCheck)
        
        // Always run a quick dedupe pass on the timer — iCloud may have delivered
        // records from the other device since the last check
        if iCloudSyncEnabled {
            do {
                let merged = try EmailAlias.deduplicate(in: modelContainer.mainContext)
                if merged > 0 { print("Background timer dedup merged \(merged) iCloud records") }
            } catch {
                print("Background timer dedup error: \(error)")
            }
        }
        
        if timeSinceLastUpdate >= updateInterval {
            // Set flags immediately to prevent race conditions
            isUpdating = true
            lastUpdateCheck = now
            
            do {
                // Sync email rules from Cloudflare
                try await cloudflareClient.syncEmailRules(modelContext: modelContainer.mainContext)
                
                // Pull metadata from CloudKit for newly-arrived aliases
                if iCloudSyncEnabled {
                    await pullMetadataFromCloudKit()
                }
                
                // Also sync statistics if analytics are enabled
                if showAnalytics {
                    await syncEmailStatisticsInBackground()
                }
            } catch {
                print("Background update failed: \(error)")
            }
            
            isUpdating = false
        }
    }
    
    // MARK: - Background Statistics Sync
    
    /// Preload email statistics at app startup for faster perceived load time
    /// Uses delta fetching to minimize API calls
    private func preloadEmailStatistics() async {
        print("App startup: Preloading email statistics...")
        await syncEmailStatisticsInBackground()
        print("App startup: Statistics preload complete")
    }
    
    /// Sync email statistics in the background and update the cache
    /// This is lightweight and doesn't affect the UI
    /// Uses smart delta fetching to minimize API calls
    private func syncEmailStatisticsInBackground() async {
        // Prevent concurrent statistics syncing
        guard !isSyncingStatistics else {
            print("📊 Statistics sync already in progress, skipping")
            return
        }
        isSyncingStatistics = true
        defer { isSyncingStatistics = false }
        
        // Load cached data for smart delta fetching
        let cachedData = StatisticsCache.shared.load()
        let cacheTimestamp = UserDefaults.standard.object(forKey: "EmailStatisticsCacheTimestamp") as? Date
        
        // Fetch statistics for all zones in parallel for faster updates
        let allStats = await withTaskGroup(of: [EmailStatistic].self) { group in
            for zone in cloudflareClient.zones {
                group.addTask {
                    do {
                        return try await self.cloudflareClient.fetchEmailStatistics(
                            for: zone,
                            cachedData: cachedData?.statistics,
                            cacheTimestamp: cacheTimestamp,
                            forceFull: false
                        )
                    } catch {
                        print("Background update: Failed to fetch statistics for zone \(zone.zoneId): \(error)")
                        return []
                    }
                }
            }
            
            var results: [EmailStatistic] = []
            for await stats in group {
                results.append(contentsOf: stats)
            }
            return results
        }
        
        // Deduplicate statistics before saving to cache
        let deduplicatedStats = deduplicateStatistics(allStats)
        
        // Update the cache with fresh statistics
        if !deduplicatedStats.isEmpty {
            StatisticsCache.shared.save(deduplicatedStats)
            print("Background update: Statistics cache updated with \(deduplicatedStats.count) email addresses")
        } else {
            print("Background update: No statistics to cache")
        }
    }
    
    /// Deduplicate statistics by email address, merging details and removing duplicate events
    private func deduplicateStatistics(_ stats: [EmailStatistic]) -> [EmailStatistic] {
        var emailDetailsMap: [String: [EmailStatistic.EmailDetail]] = [:]
        
        // Collect all details for each email address
        for stat in stats {
            emailDetailsMap[stat.emailAddress, default: []].append(contentsOf: stat.emailDetails)
        }
        
        // Deduplicate details within each email address by (from, date) pair
        return emailDetailsMap.map { email, details in
            var seenKeys = Set<String>()
            var uniqueDetails: [EmailStatistic.EmailDetail] = []
            
            for detail in details {
                let key = "\(detail.from)|\(detail.date.timeIntervalSince1970)"
                if !seenKeys.contains(key) {
                    seenKeys.insert(key)
                    uniqueDetails.append(detail)
                }
            }
            
            let sortedDetails = uniqueDetails.sorted { $0.date > $1.date }
            return EmailStatistic(
                emailAddress: email,
                count: sortedDetails.count,
                receivedDates: sortedDetails.map { $0.date },
                emailDetails: sortedDetails
            )
        }.sorted { $0.count > $1.count }
    }
}

// Helper function for timeout
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
