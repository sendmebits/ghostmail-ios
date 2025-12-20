//
//  ContentView.swift
//  ghostmail
//
//  Created by sendmebits on 2025-01-16.
//

import SwiftUI
import SwiftData

@MainActor
struct ContentView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @Query private var emailAliases: [EmailAlias]
    @State private var needsRefresh = false
    @State private var showingCreateSheet = false
    @State private var deepLinkWebsite: String? = nil
    @AppStorage("themePreference") private var themePreferenceRaw: String = "Auto"
    
    private var themeColorScheme: ColorScheme? {
        switch themePreferenceRaw {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }
    
    var body: some View {
        NavigationStack {
            if cloudflareClient.isAuthenticated {
                EmailListView(searchText: $searchText, needsRefresh: $needsRefresh)
            } else {
                AuthenticationView()
            }
        }
        .preferredColorScheme(themeColorScheme)
        .sheet(isPresented: $showingCreateSheet, onDismiss: { deepLinkWebsite = nil }) {
            EmailCreateView(initialWebsite: deepLinkWebsite)
                .id(deepLinkWebsite ?? "manual-create")
        }
        .onReceive(deepLinkRouter.$pendingWebsiteHost.compactMap { $0 }) { host in
            // Empty string means open create sheet without a preset website
            deepLinkWebsite = host.isEmpty ? nil : host
            showingCreateSheet = true
            // Clear after presenting to avoid repeats
            deepLinkRouter.pendingWebsiteHost = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghostmailOpenCreate)) { _ in
            // Handle quick action notification by triggering deep link
            if let url = URL(string: "ghostmail://create") {
                deepLinkRouter.handle(url: url)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: EmailAlias.self, inMemory: true)
}
