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
    
    init() {
        // First, read the iCloud sync preference from UserDefaults directly
        // instead of accessing self.iCloudSyncEnabled
        let syncEnabled = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
        
        do {
            // Create a model configuration based on iCloud sync preference
            let config: ModelConfiguration
            
            if syncEnabled {
                // CloudKit-enabled configuration
                config = ModelConfiguration(cloudKitDatabase: .automatic)
            } else {
                // Local-only configuration
                config = ModelConfiguration(isStoredInMemoryOnly: false)
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
            
            // Setup notification for iCloud account changes
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil,
                queue: .main) { notification in
                    print("iCloud account state changed")
                    print("Changes: \(notification.userInfo ?? [:])")
            }
            
            // Add general CloudKit account change observer
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name.CKAccountChanged,
                object: nil,
                queue: .main) { _ in
                    print("CloudKit account changed - may affect sync status")
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
                }
        }
        .modelContainer(modelContainer)
    }
}
