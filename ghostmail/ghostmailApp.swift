//
//  ghostmailApp.swift
//  ghostmail
//
//  Created by Chris Greco on 2025-01-16.
//

import SwiftUI
import SwiftData

@main
struct ghostmailApp: App {
    let modelContainer: ModelContainer
    @StateObject private var cloudflareClient = CloudflareClient(accountId: "", zoneId: "", apiToken: "")
    
    init() {
        do {
            let schema = Schema([EmailAlias.self])
            let modelConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudflareClient)
        }
        .modelContainer(modelContainer)
    }
}
