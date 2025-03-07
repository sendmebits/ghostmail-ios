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
    
    init() {
        do {
            let schema = Schema([EmailAlias.self])
            
            // Enable CloudKit logging
            let cloudKitLogger = NSUbiquitousKeyValueStore.default
            cloudKitLogger.set(true, forKey: "com.apple.coredata.cloudkit.logging")
            cloudKitLogger.synchronize()
            
            // Log CloudKit container setup
            print("Setting up CloudKit with container: iCloud.com.sendmebits.ghostmail")
            
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.sendmebits.ghostmail")
            )
            
            // Enable sync with iCloud
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            
            // Verify container setup
            print("ModelContainer initialized successfully with CloudKit integration")
            
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
