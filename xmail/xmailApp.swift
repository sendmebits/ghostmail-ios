//
//  xmailApp.swift
//  xmail
//
//  Created by Chris Greco on 2025-01-16.
//

import SwiftUI
import SwiftData

@main
struct xmailApp: App {
    let modelContainer: ModelContainer
    @StateObject private var cloudflareClient = CloudflareClient(accountId: "", zoneId: "", apiToken: "")
    
    init() {
        do {
            modelContainer = try ModelContainer(for: EmailAlias.self)
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
