//
//  ghostmailApp.swift
//  ghostmail
//
//  Created by sendmebits on 2025-01-16.
//

import SwiftUI
import SwiftData
import CloudKit

@main
struct ghostmailApp: App {
    let modelContainer: ModelContainer
    @StateObject private var cloudflareClient = CloudflareClient(accountId: "", zoneId: "", apiToken: "")
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @AppStorage("userIdentifier") private var userIdentifier: String = ""
    
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
    
    // Function to ensure all aliases have a user identifier
    @MainActor
    private static func updateUserIdentifiers(modelContainer: ModelContainer) async {
        let context = modelContainer.mainContext
        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
        
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
                print("Updated user identifiers for \(aliasesNeedingUpdate.count) aliases")
            }
        } catch {
            print("Error updating user identifiers: \(error)")
        }
    }
    
    // Function to force sync of existing data to CloudKit - now optimized
    @MainActor
    private static func forceSyncExistingData(modelContainer: ModelContainer) async {
        print("Checking for data that needs CloudKit sync...")
        let context = modelContainer.mainContext
        
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
                .onAppear {
                    // Perform startup operations asynchronously to avoid blocking UI
                    Task {
                        // If authenticated, refresh forwarding addresses and domain from Cloudflare
                        if cloudflareClient.isAuthenticated {
                            print("App startup: Refreshing forwarding addresses and domain")
                            do {
                                // Single attempt with shorter timeout
                                try await withTimeout(seconds: 10) {
                                    // Fetch domain name first
                                    if cloudflareClient.domainName.isEmpty {
                                        try await cloudflareClient.fetchDomainName()
                                    }
                                    // Then refresh forwarding addresses
                                    try await cloudflareClient.refreshForwardingAddresses()
                                }
                                print("App startup: Successfully refreshed forwarding addresses and domain")
                            } catch {
                                print("App startup: Failed to refresh forwarding addresses: \(error)")
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

                            await ghostmailApp.updateUserIdentifiers(modelContainer: modelContainer)
                            await ghostmailApp.forceSyncExistingData(modelContainer: modelContainer)
                            await checkCloudKitSyncStatus()
                        }
                    }
                }
                .onOpenURL { url in
                    print("[GhostMail] onOpenURL received: \(url.absoluteString)")
                    // Route custom scheme URLs like ghostmail://create?url=...
                    deepLinkRouter.handle(url: url)
                }
        }
        .modelContainer(modelContainer)
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
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
