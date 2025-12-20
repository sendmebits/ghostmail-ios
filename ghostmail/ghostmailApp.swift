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
        print("iCloud sync setting: \(syncEnabled ? "enabled" : "disabled")")
        
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
                print("Initialized with CloudKit configuration and explicit schema")
            } else {
                // Local-only configuration
                config = ModelConfiguration(isStoredInMemoryOnly: false)
                print("Initialized with local-only configuration")
            }
            
            // Initialize the ModelContainer with the correct class and configuration
            modelContainer = try ModelContainer(for: EmailAlias.self, configurations: config)
            
            // After initializing modelContainer, we can now use self safely
            
            // Log CloudKit container setup
            if syncEnabled {
                print("Setting up CloudKit with container: iCloud.com.sendmebits.ghostmail")
            } else {
                print("CloudKit sync is disabled, using local storage only")
            }
            
            // Set up observers only if sync is enabled
            if syncEnabled {
                // CloudKit sync is handled automatically by SwiftData
                print("CloudKit sync enabled - SwiftData will handle sync automatically")
            }
        } catch {
            print("Failed to initialize ModelContainer: \(error)")
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }
    
    // Function to ensure all aliases have a user identifier - optimized for background execution
    private static func updateUserIdentifiers(modelContainer: ModelContainer) async {
        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
        
        // Create a background context
        let context = ModelContext(modelContainer)
        
        do {
            let descriptor = FetchDescriptor<EmailAlias>(
                predicate: #Predicate<EmailAlias> { alias in
                    alias.userIdentifier.isEmpty
                }
            )
            let aliasesNeedingUpdate = try context.fetch(descriptor)
            
            if !aliasesNeedingUpdate.isEmpty {
                for alias in aliasesNeedingUpdate {
                    alias.userIdentifier = userId
                }
                try context.save()
                print("Updated user identifiers for \(aliasesNeedingUpdate.count) aliases (background)")
            }
        } catch {
            print("Error updating user identifiers: \(error)")
        }
    }
    
    // Function to force sync of existing data to CloudKit - optimized for background execution
    private static func forceSyncExistingData(modelContainer: ModelContainer) async {
        print("Checking for data that needs CloudKit sync (background)...")
        // Create a background context
        let context = ModelContext(modelContainer)
        
        do {
            // Only sync aliases that don't have a user identifier or have recent changes
            let descriptor = FetchDescriptor<EmailAlias>(
                predicate: #Predicate<EmailAlias> { alias in
                    alias.userIdentifier.isEmpty
                }
            )
            let aliasesNeedingSync = try context.fetch(descriptor)
            
            if !aliasesNeedingSync.isEmpty {
                print("Found \(aliasesNeedingSync.count) aliases needing sync")
                
                // Update user identifier if empty
                for alias in aliasesNeedingSync {
                    if alias.userIdentifier.isEmpty {
                        alias.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                    }
                }
                
                // Save the context to trigger CloudKit sync
                try context.save()
                print("Successfully saved context, triggering CloudKit sync for \(aliasesNeedingSync.count) aliases")
            } else {
                print("No aliases need CloudKit sync")
            }
            
        } catch {
            print("Error syncing existing data: \(error)")
        }
    }
    
    // Function to check CloudKit sync status - now asynchronous and non-blocking
    @MainActor
    private func checkCloudKitSyncStatus() async {
        print("Checking CloudKit sync status...")
        let cloudContainer = CKContainer.default()
        do {
            let status = try await cloudContainer.accountStatus()
            print("CloudKit account status: \(status)")
            
            // Only perform detailed checks if account is available
            if status == .available {
                // Check if we can access the private database
                let database = cloudContainer.privateCloudDatabase
                do {
                    let zones = try await database.allRecordZones()
                    print("Found \(zones.count) CloudKit record zones")
                } catch {
                    print("Error checking CloudKit database: \(error)")
                }
            } else if status == .noAccount {
                print("CloudKit account not signed in. Please sign in to iCloud.")
            } else if status == .restricted {
                print("CloudKit account restricted. Please check settings.")
            } else if status == .temporarilyUnavailable {
                print("CloudKit account temporarily unavailable. Please try again later.")
            }
        } catch {
            print("Error checking CloudKit status: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudflareClient)
                .environmentObject(deepLinkRouter)
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
                        }
                    }
                    
                    // Update user identifiers and trigger sync on app launch - now non-blocking
                    if iCloudSyncEnabled {
                        // First, clean up any duplicate records so sync doesn't propagate dups
                        do {
                            let deleted = try EmailAlias.deduplicate(in: modelContainer.mainContext)
                            if deleted > 0 { print("Deduplicated \(deleted) aliases on startup") }
                        } catch {
                            print("Error during startup deduplication: \(error)")
                        }

                        Task.detached(priority: .utility) {
                            await ghostmailApp.updateUserIdentifiers(modelContainer: modelContainer)
                            await ghostmailApp.forceSyncExistingData(modelContainer: modelContainer)
                        }
                        await checkCloudKitSyncStatus()
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
        // Check every minute
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
        
        do {
            // Sync email rules - this runs in background and updates SwiftData
            try await cloudflareClient.syncEmailRules(modelContext: modelContainer.mainContext)
            
            // Sync statistics if analytics are enabled
            if showAnalytics {
                await syncEmailStatisticsInBackground()
            }
        } catch {
            print("Foreground sync failed: \(error)")
        }
        
        isUpdating = false
    }
    
    // MARK: - Background Polling (Timer-based)
    
    @MainActor
    private func performBackgroundUpdateIfNeeded() async {
        // Prevent concurrent executions
        guard cloudflareClient.isAuthenticated else { return }
        guard !isUpdating else { return }
        
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateCheck)
        
        if timeSinceLastUpdate >= updateInterval {
            // Set flags immediately to prevent race conditions
            isUpdating = true
            lastUpdateCheck = now
            
            do {
                // Sync email rules from Cloudflare
                try await cloudflareClient.syncEmailRules(modelContext: modelContainer.mainContext)
                
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
    
    /// Sync email statistics in the background and update the cache
    /// This is lightweight and doesn't affect the UI
    private func syncEmailStatisticsInBackground() async {
        var allStats: [EmailStatistic] = []
        
        // Fetch statistics for all zones
        for zone in cloudflareClient.zones {
            do {
                let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                allStats.append(contentsOf: stats)
            } catch {
                print("Background update: Failed to fetch statistics for zone \(zone.zoneId): \(error)")
                // Continue with other zones even if one fails
            }
        }
        
        // Update the cache with fresh statistics
        if !allStats.isEmpty {
            StatisticsCache.shared.save(allStats)
            print("Background update: Statistics cache updated with \(allStats.count) email addresses")
        } else {
            print("Background update: No statistics to cache")
        }
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
