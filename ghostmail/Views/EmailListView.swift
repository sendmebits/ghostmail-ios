import SwiftUI
import UIKit
import SwiftData

/// Filter option for destination address
enum DestinationFilter: Equatable {
    case all
    case address(String)
    
    var label: String {
        switch self {
        case .all: return "All"
        case .address(let addr): return addr
        }
    }
}

struct EmailListView: View {
    @Binding var searchText: String
    @State private var sortOrder: SortOrder = .cloudflareOrder
    @Query private var emailAliases: [EmailAlias]
    @State private var showingCreateSheet = false
    @State private var showingSettings = false
    @State private var isLoading = false
    @State private var isInitialLoad = true
    @State private var error: Error?
    @State private var showError = false
    @State private var showCopyToast = false
    @State private var copiedEmail = ""
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Binding var needsRefresh: Bool
    @State private var toastWorkItem: DispatchWorkItem?

    // Filter state
    @State private var showFilterSheet = false
    @State private var destinationFilter: DestinationFilter = .all
    
    enum SortOrder: String, CaseIterable, Hashable {
        case alphabetical
        case cloudflareOrder
        
        var label: String {
            switch self {
            case .alphabetical: "Alphabetical"
            case .cloudflareOrder: "Most Recent"
            }
        }
        
        var systemImage: String {
            switch self {
            case .alphabetical: "textformat.abc"
            case .cloudflareOrder: "clock"
            }
        }
    }
    
    init(searchText: Binding<String>, needsRefresh: Binding<Bool>) {
        self._searchText = searchText
        self._needsRefresh = needsRefresh
        // Filter out logged out aliases
        self._emailAliases = Query(filter: #Predicate<EmailAlias> { alias in
            alias.isLoggedOut == false
        })

        // Load persisted sort order
        if let rawSort = UserDefaults.standard.string(forKey: "EmailListView.sortOrder"),
           let loadedSort = SortOrder(rawValue: rawSort) {
            _sortOrder = State(initialValue: loadedSort)
        }

        // Load persisted destination filter
        if let filterType = UserDefaults.standard.string(forKey: "EmailListView.destinationFilterType") {
            if filterType == "all" {
                _destinationFilter = State(initialValue: .all)
            } else if filterType == "address",
                      let addr = UserDefaults.standard.string(forKey: "EmailListView.destinationFilterAddress") {
                _destinationFilter = State(initialValue: .address(addr))
            }
        }
    }
    // Persist sortOrder and destinationFilter when changed
    private func persistSortOrder(_ newValue: SortOrder) {
        UserDefaults.standard.set(newValue.rawValue, forKey: "EmailListView.sortOrder")
    }

    private func persistDestinationFilter(_ newValue: DestinationFilter) {
        switch newValue {
        case .all:
            UserDefaults.standard.set("all", forKey: "EmailListView.destinationFilterType")
            UserDefaults.standard.removeObject(forKey: "EmailListView.destinationFilterAddress")
        case .address(let addr):
            UserDefaults.standard.set("address", forKey: "EmailListView.destinationFilterType")
            UserDefaults.standard.set(addr, forKey: "EmailListView.destinationFilterAddress")
        }
    }
    

    var sortedEmails: [EmailAlias] {
        let filtered = filteredEmails
        switch sortOrder {
        case .alphabetical:
            return filtered.sorted { $0.emailAddress < $1.emailAddress }
        case .cloudflareOrder:
            return filtered.sorted { $0.sortIndex < $1.sortIndex }
        }
    }

    var filteredEmails: [EmailAlias] {
        let base: [EmailAlias]
        if searchText.isEmpty {
            base = emailAliases
        } else {
            base = emailAliases.filter { email in
                email.emailAddress.localizedCaseInsensitiveContains(searchText) ||
                email.website.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch destinationFilter {
        case .all:
            return base
        case .address(let addr):
            return base.filter { $0.forwardTo == addr }
        }
    }

    var allDestinationAddresses: [String] {
        let addresses = emailAliases.map { $0.forwardTo }.filter { !$0.isEmpty }
        return Array(Set(addresses)).sorted()
    }
    
    private func refreshEmailRules() async {
        guard !isLoading else { return }
        isLoading = true
        
        do {
            var cloudflareRules = try await cloudflareClient.getEmailRules()
            
            // Handle potential duplicates in Cloudflare rules
            // Keep track of seen email addresses and only include the first occurrence
            var seenEmails = Set<String>()
            cloudflareRules = cloudflareRules.filter { rule in
                guard !seenEmails.contains(rule.emailAddress) else {
                    print("⚠️ Skipping duplicate email rule for: \(rule.emailAddress)")
                    return false
                }
                seenEmails.insert(rule.emailAddress)
                return true
            }
            
            // Create dictionaries for lookup (now safe because we've removed duplicates)
            let cloudflareRulesByEmail = Dictionary(
                uniqueKeysWithValues: cloudflareRules.map { ($0.emailAddress, $0) }
            )
            
            // Create dictionary for existing aliases, handling potential duplicates
            var existingAliasesMap: [String: EmailAlias] = [:]
            for alias in emailAliases {
                if existingAliasesMap[alias.emailAddress] == nil {
                    existingAliasesMap[alias.emailAddress] = alias
                } else {
                    // Handle duplicate in local database - keep the one with the most recent created date
                    print("⚠️ Found duplicate local alias for: \(alias.emailAddress)")
                    let existing = existingAliasesMap[alias.emailAddress]!
                    if (alias.created ?? Date.distantPast) > (existing.created ?? Date.distantPast) {
                        existingAliasesMap[alias.emailAddress] = alias
                    }
                    // If we want to clean up, we could delete the older duplicate here
                }
            }
            
            // Remove deleted aliases
            for alias in emailAliases {
                if cloudflareRulesByEmail[alias.emailAddress] == nil {
                    print("Deleting alias: \(alias.emailAddress)")
                    modelContext.delete(alias)
                }
            }
            
            // Update or create aliases
            for (index, rule) in cloudflareRules.enumerated() {
                let emailAddress = rule.emailAddress
                let forwardTo = rule.forwardTo
                
                if let existing = existingAliasesMap[emailAddress] {
                    // Only update if there are actual changes
                    let needsUpdate = existing.cloudflareTag != rule.cloudflareTag ||
                                    existing.isEnabled != rule.isEnabled ||
                                    existing.forwardTo != forwardTo ||
                                    existing.sortIndex != index + 1
                    
                    if needsUpdate {
                        withAnimation {
                            existing.cloudflareTag = rule.cloudflareTag
                            existing.isEnabled = rule.isEnabled
                            existing.forwardTo = forwardTo
                            existing.sortIndex = index + 1
                        }
                    }
                } else {
                    // Create new alias with proper properties
                    let newAlias = EmailAlias(
                        emailAddress: emailAddress,
                        forwardTo: forwardTo
                    )
                    newAlias.cloudflareTag = rule.cloudflareTag
                    newAlias.isEnabled = rule.isEnabled
                    newAlias.sortIndex = index + 1
                    
                    // Set the user identifier to ensure cross-device ownership
                    newAlias.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                    
                    modelContext.insert(newAlias)
                }
            }
            
            // Save once after all updates
            try modelContext.save()
            
        } catch {
            print("Error during refresh: \(error)")
            self.error = error
            self.showError = true
        }
        isLoading = false
        isInitialLoad = false
    }
    
    private func showToastWithTimer(_ email: String) {
        // Cancel any existing timer
        toastWorkItem?.cancel()
        
        // Show the new toast
        copiedEmail = email
        showCopyToast = true
        
        // Create and save new timer
        let workItem = DispatchWorkItem {
            withAnimation {
                showCopyToast = false
            }
        }
        toastWorkItem = workItem
        
        // Schedule the new timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
    
    var body: some View {
    ZStack {
            Group {
                if isLoading && isInitialLoad {
                    ProgressView()
                } else if sortedEmails.isEmpty {
                    ContentUnavailableView(
                        "No Email Aliases",
                        systemImage: "envelope.badge.shield.half.filled",
                        description: Text("Create your first email alias using the + button")
                    )
                } else {
                    List {
                        ForEach(sortedEmails, id: \.id) { email in
                            NavigationLink(value: email) {
                                EmailRowView(email: email) {
                                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                                    generator.impactOccurred()
                                    UIPasteboard.general.string = email.emailAddress
                                    showToastWithTimer(email.emailAddress)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                // Prepare the generator before the gesture is triggered
                                let generator = UIImpactFeedbackGenerator(style: .heavy)
                                generator.prepare()
                                // Trigger haptic immediately when gesture threshold is met
                                generator.impactOccurred()
                                // Then handle the clipboard and toast
                                UIPasteboard.general.string = email.emailAddress
                                showToastWithTimer(email.emailAddress)
                            })
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .listRowBackground(Color.black)
                    .navigationDestination(for: EmailAlias.self) { email in
                        EmailDetailView(email: email, needsRefresh: $needsRefresh)
                    }
                    .refreshable {
                        do {
                            let deleted = try EmailAlias.deduplicate(in: modelContext)
                            if deleted > 0 { print("Deduplicated \(deleted) aliases during refresh") }
                        } catch {
                            print("Error during refresh deduplication: \(error)")
                        }
                        await refreshEmailRules()
                    }
                }
            }
            // Floating Action Button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                    .padding()
                }
            }
            // Toast overlay
            if showCopyToast {
                VStack {
                    Spacer()
                    Text("\(copiedEmail) copied!")
                        .padding()
                        .background(.black.opacity(0.7))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom))
                }
            }
        }
    .background(Color.black.ignoresSafeArea())
    .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    // Sort option
                    Picker("Sort Order", selection: $sortOrder) {
                        ForEach([SortOrder.cloudflareOrder, .alphabetical], id: \.self) { order in
                            Label(order.label, systemImage: order.systemImage)
                        }
                    }
                    // Filter option
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label("Filter", systemImage: destinationFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .accessibilityLabel("Menu")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .navigationTitle("Email Aliases")
        .searchable(text: $searchText, prompt: "Search emails or websites")
        .onChange(of: sortOrder) { _, newValue in
            persistSortOrder(newValue)
        }
        .onChange(of: destinationFilter) { _, newValue in
            persistDestinationFilter(newValue)
        }
    // ...existing code...
        .sheet(isPresented: $showFilterSheet) {
            NavigationView {
                List {
                    Section(header: Text("Destination Address")) {
                        Button(action: {
                            destinationFilter = .all
                            showFilterSheet = false
                            persistDestinationFilter(.all)
                        }) {
                            HStack {
                                Text("All")
                                if destinationFilter == .all {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        ForEach(allDestinationAddresses, id: \.self) { addr in
                            Button(action: {
                                destinationFilter = .address(addr)
                                showFilterSheet = false
                                persistDestinationFilter(.address(addr))
                            }) {
                                HStack {
                                    Text(addr)
                                    if destinationFilter == .address(addr) {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showFilterSheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingCreateSheet) {
            EmailCreateView()
        }
        .alert("Error", isPresented: $showError, presenting: error) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .task {
            // Only load if we haven't loaded yet and there are no existing aliases
            if isInitialLoad && emailAliases.isEmpty {
                await refreshEmailRules()
            } else {
                // If we have existing data, just mark as loaded
                isInitialLoad = false
            }
        }
        .onChange(of: needsRefresh) { _, needsRefresh in
            if needsRefresh {
                Task {
                    await refreshEmailRules()
                    self.needsRefresh = false
                }
            }
        }
    }
}

struct EmailRowView: View {
    let email: EmailAlias
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    let onCopy: () -> Void
    @State private var websiteUIImage: UIImage?
    @State private var isLoadingIcon = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon area: website icon (if available), globe when website exists but no icon, envelope when no website
            ZStack {
                // Decide icon based on settings
                if cloudflareClient.shouldShowWebsiteLogos && !email.website.isEmpty {
                    // Show website icon if loaded
                    if let uiImage = websiteUIImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if isLoadingIcon {
                        ProgressView()
                            .frame(width: 40, height: 40)
                    } else {
                        // Globe fallback when website is specified but icon not found yet/failed
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor,
                                        Color.accentColor.opacity(0.7)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                    }
                } else {
                    // If logos disabled or no website: show globe if website present, else envelope
                    if !email.website.isEmpty {
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor,
                                        Color.accentColor.opacity(0.7)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor,
                                        Color.accentColor.opacity(0.7)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                    }
                }

                // Status indicator
                if !email.isEnabled {
                    Circle()
                        .fill(.gray)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(Color.background, lineWidth: 2)
                        )
                        .offset(x: 12, y: 12)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(email.emailAddress)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .strikethrough(!email.isEnabled)
                
                if !email.website.isEmpty && cloudflareClient.shouldShowWebsitesInList {
                    Text(email.website)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            
            Spacer()
        }
        .contentShape(Rectangle())
        .opacity(email.isEnabled ? 1.0 : 0.6)
        .task(id: email.website) {
            websiteUIImage = nil
            // Only load actual logo images when the setting is enabled
            guard !email.website.isEmpty, cloudflareClient.shouldShowWebsiteLogos else { return }
            isLoadingIcon = true
            if let img = await IconCache.shared.image(for: email.website) {
                websiteUIImage = img
            } else {
                websiteUIImage = nil
            }
            isLoadingIcon = false
        }
    }
}

// Add this extension to get the background color
extension Color {
    static let background = Color(uiColor: .systemBackground)
} 
