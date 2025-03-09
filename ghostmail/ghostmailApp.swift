//
//  ghostmailApp.swift
//  ghostmail
//
//  Created by Chris Greco on 2025-01-16.
//

import SwiftUI
import SwiftData
import CloudKit

@main
struct ghostmailApp: App {
    let modelContainer: ModelContainer
    @StateObject private var cloudflareClient = CloudflareClient(accountId: "", zoneId: "", apiToken: "")
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @AppStorage("userIdentifier") private var userIdentifier: String = ""
    
    init() {
        // First, read the iCloud sync preference from UserDefaults directly
        // instead of accessing self.iCloudSyncEnabled
        let syncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        
        // Create a unique user identifier if it doesn't exist yet
        if UserDefaults.standard.string(forKey: "userIdentifier")?.isEmpty ?? true {
            UserDefaults.standard.set(UUID().uuidString, forKey: "userIdentifier")
        }
        
        do {
            // Create a model configuration based on iCloud sync preference
            let config: ModelConfiguration
            
            if syncEnabled {
                // CloudKit-enabled configuration
                config = ModelConfiguration(cloudKitDatabase: .automatic)
                print("Initialized with CloudKit configuration")
            } else {
                // Local-only configuration
                config = ModelConfiguration(isStoredInMemoryOnly: false)
                print("Initialized with local-only configuration")
            }
            
            // Initialize the ModelContainer with the correct class and configuration
            modelContainer = try ModelContainer(for: EmailAlias.self, configurations: config)
            
            // After initializing modelContainer, we can now use self safely
            
            // Enable CloudKit logging
            let cloudKitLogger = NSUbiquitousKeyValueStore.default
            cloudKitLogger.set(true, forKey: "com.apple.coredata.cloudkit.logging")
            cloudKitLogger.synchronize()
            
            // Log CloudKit container setup
            print("Setting up CloudKit with container: iCloud.com.sendmebits.ghostmail")
            
            // Store references to avoid capturing self
            let container = modelContainer
            
            // Setup notification for iCloud account changes
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil,
                queue: .main) { notification in
                    print("iCloud account state changed")
                    print("Changes: \(notification.userInfo ?? [:])")
                    
                    // Avoid capturing self by using Swift Concurrency directly
                    Task { @MainActor in
                        // Force a CloudKit sync by using NSUbiquitousKeyValueStore
                        let syncKey = "com.ghostmail.force_sync_\(Date().timeIntervalSince1970)"
                        NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: syncKey)
                        NSUbiquitousKeyValueStore.default.synchronize()
                        
                        // Let the system know we want fresh data
                        let cloudContainer = CKContainer.default()
                        do {
                            let status = try await cloudContainer.accountStatus()
                            print("CloudKit account status: \(status)")
                        } catch {
                            print("Error checking CloudKit status: \(error)")
                        }
                        
                        // Access mainContext on the MainActor 
                        let context = container.mainContext
                        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                        
                        do {
                            let descriptor = FetchDescriptor<EmailAlias>()
                            let allAliases = try context.fetch(descriptor)
                            
                            var needsSave = false
                            for alias in allAliases {
                                if alias.userIdentifier.isEmpty {
                                    alias.userIdentifier = userId
                                    needsSave = true
                                }
                            }
                            
                            if needsSave {
                                try context.save()
                                print("Updated user identifiers for \(allAliases.count) aliases")
                            }
                        } catch {
                            print("Error updating user identifiers: \(error)")
                        }
                    }
            }
            
            // Add general CloudKit account change observer
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name.CKAccountChanged,
                object: nil,
                queue: .main) { _ in
                    print("CloudKit account changed - may affect sync status")
                    
                    // Avoid capturing self by using Swift Concurrency directly
                    Task { @MainActor in
                        // Force a CloudKit sync by using NSUbiquitousKeyValueStore
                        let syncKey = "com.ghostmail.force_sync_\(Date().timeIntervalSince1970)"
                        NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: syncKey)
                        NSUbiquitousKeyValueStore.default.synchronize()
                        
                        // Let the system know we want fresh data
                        let cloudContainer = CKContainer.default()
                        do {
                            let status = try await cloudContainer.accountStatus()
                            print("CloudKit account status: \(status)")
                        } catch {
                            print("Error checking CloudKit status: \(error)")
                        }
                        
                        // Access mainContext on the MainActor
                        let context = container.mainContext
                        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                        
                        do {
                            let descriptor = FetchDescriptor<EmailAlias>()
                            let allAliases = try context.fetch(descriptor)
                            
                            var needsSave = false
                            for alias in allAliases {
                                if alias.userIdentifier.isEmpty {
                                    alias.userIdentifier = userId
                                    needsSave = true
                                }
                            }
                            
                            if needsSave {
                                try context.save()
                                print("Updated user identifiers for \(allAliases.count) aliases")
                            }
                        } catch {
                            print("Error updating user identifiers: \(error)")
                        }
                    }
            }
            
            // Manually set up periodic sync checks for diagnostics
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                print("Periodic CloudKit sync check - \(Date())")
                NSUbiquitousKeyValueStore.default.synchronize()
            }
            
            // Sync ubiquitous key-value store immediately
            NSUbiquitousKeyValueStore.default.synchronize()
        } catch {
            print("Failed to initialize ModelContainer: \(error)")
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }
    
    // Function to trigger a data refresh through CloudKit
    @MainActor
    private func triggerDataRefresh() async throws {
        print("Triggering CloudKit data refresh")
        
        // Update user identifiers
        await updateUserIdentifiers()
        
        // Force a CloudKit sync by using NSUbiquitousKeyValueStore
        let syncKey = "com.ghostmail.force_sync_\(Date().timeIntervalSince1970)"
        NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: syncKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        
        // Let the system know we want fresh data
        let container = CKContainer.default()
        let status = try await container.accountStatus()
        print("CloudKit account status: \(status)")
        
        print("CloudKit refresh triggered successfully")
    }
    
    // Function to ensure all aliases have a user identifier
    @MainActor
    private func updateUserIdentifiers() async {
        let context = modelContainer.mainContext
        let userId = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
        
        do {
            let descriptor = FetchDescriptor<EmailAlias>()
            let allAliases = try context.fetch(descriptor)
            
            var needsSave = false
            for alias in allAliases {
                if alias.userIdentifier.isEmpty {
                    alias.userIdentifier = userId
                    needsSave = true
                }
            }
            
            if needsSave {
                try context.save()
                print("Updated user identifiers for \(allAliases.count) aliases")
            }
        } catch {
            print("Error updating user identifiers: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudflareClient)
                .onAppear {
                    // If authenticated, refresh forwarding addresses from Cloudflare
                    if cloudflareClient.isAuthenticated {
                        Task {
                            print("App startup: Refreshing forwarding addresses")
                            do {
                                // Try a few times with exponential backoff
                                for attempt in 1...3 {
                                    do {
                                        try await cloudflareClient.refreshForwardingAddresses()
                                        print("App startup: Successfully refreshed forwarding addresses")
                                        break
                                    } catch {
                                        if attempt == 3 {
                                            throw error
                                        }
                                        print("App startup: Attempt \(attempt) failed, retrying after delay...")
                                        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                                    }
                                }
                            } catch {
                                print("App startup: Failed to refresh forwarding addresses after multiple attempts: \(error)")
                            }
                        }
                    }
                    
                    // Update user identifiers and trigger sync on app launch
                    if iCloudSyncEnabled {
                        Task {
                            await updateUserIdentifiers()
                            try? await triggerDataRefresh()
                        }
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}

// Helper function to perform sync operations without capturing self
@MainActor
private func performSync(container: ModelContainer, userId: String) async throws {
    print("Performing sync after notification")
    
    // Update user identifiers - we're on the MainActor so this is safe
    let context = container.mainContext
    
    do {
        let descriptor = FetchDescriptor<EmailAlias>()
        let allAliases = try context.fetch(descriptor)
        
        var needsSave = false
        for alias in allAliases {
            if alias.userIdentifier.isEmpty {
                alias.userIdentifier = userId
                needsSave = true
            }
        }
        
        if needsSave {
            try context.save()
            print("Updated user identifiers for \(allAliases.count) aliases")
        }
    } catch {
        print("Error updating user identifiers: \(error)")
    }
    
    // Force a CloudKit sync by using NSUbiquitousKeyValueStore
    let syncKey = "com.ghostmail.force_sync_\(Date().timeIntervalSince1970)"
    NSUbiquitousKeyValueStore.default.set(Date().timeIntervalSince1970, forKey: syncKey)
    NSUbiquitousKeyValueStore.default.synchronize()
    
    // Let the system know we want fresh data
    let ckContainer = CKContainer.default()
    let status = try await ckContainer.accountStatus()
    print("CloudKit account status: \(status)")
    
    print("CloudKit refresh triggered successfully")
}
