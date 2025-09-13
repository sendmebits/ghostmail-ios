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
    @State private var isNetworking = false
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
    // Domain filter (by Cloudflare zone)
    enum DomainFilter: Equatable { case all, zone(String) }
    @State private var domainFilter: DomainFilter = .all
    // Pending (staged) filters used inside the filter sheet
    @State private var pendingDestinationFilter: DestinationFilter = .all
    @State private var pendingDomainFilter: DomainFilter = .all

    // Derived UI state
    private var isFilterActive: Bool {
        let destActive = destinationFilter != .all
        let domainActive: Bool
        switch domainFilter {
        case .all: domainActive = false
        default: domainActive = true
        }
        return destActive || domainActive
    }

    // Display all aliases from all configured zones; keep legacy entries too
    private var allAliases: [EmailAlias] { emailAliases }
    
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
        // Load persisted domain filter
        if let domainType = UserDefaults.standard.string(forKey: "EmailListView.domainFilterType") {
            if domainType == "all" {
                _domainFilter = State(initialValue: .all)
            } else if domainType == "zone",
                      let zid = UserDefaults.standard.string(forKey: "EmailListView.domainFilterZoneId"),
                      !zid.isEmpty {
                _domainFilter = State(initialValue: .zone(zid))
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
    private func persistDomainFilter(_ newValue: DomainFilter) {
        switch newValue {
        case .all:
            UserDefaults.standard.set("all", forKey: "EmailListView.domainFilterType")
            UserDefaults.standard.removeObject(forKey: "EmailListView.domainFilterZoneId")
        case .zone(let zid):
            UserDefaults.standard.set("zone", forKey: "EmailListView.domainFilterType")
            UserDefaults.standard.set(zid, forKey: "EmailListView.domainFilterZoneId")
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
        let source = allAliases
        let base: [EmailAlias]
        if searchText.isEmpty {
            base = source
        } else {
            base = source.filter { email in
                email.emailAddress.localizedCaseInsensitiveContains(searchText) ||
                email.website.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Apply destination filter
        let destinationFiltered: [EmailAlias]
        switch destinationFilter {
        case .all:
            destinationFiltered = base
        case .address(let addr):
            destinationFiltered = base.filter { $0.forwardTo == addr }
        }

        // Apply domain filter (zone)
        let domainFiltered: [EmailAlias]
        switch domainFilter {
        case .all:
            domainFiltered = destinationFiltered
        case .zone(let zid):
            domainFiltered = destinationFiltered.filter { $0.zoneId == zid }
        }

        return domainFiltered
    }

    var allDestinationAddresses: [String] {
        // Use the same source as SettingsView so the filter list is consistent
        Array(cloudflareClient.forwardingAddresses).sorted()
    }
    
    private func refreshEmailRules(showLoading: Bool = false) async {
        // Coalesce concurrent refreshes regardless of UI loading state
        guard !isNetworking else { return }
        isNetworking = true
        if showLoading { isLoading = true }
        
        do {
            var cloudflareRules = try await cloudflareClient.getEmailRulesAllZones()
            
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
            
            // Build dictionary for existing aliases across zones, including logged-out ones
            // so we can reactivate instead of creating duplicates
            var existingAliasesMap: [String: EmailAlias] = [:]
            do {
                let descriptor = FetchDescriptor<EmailAlias>()
                let allExisting = try modelContext.fetch(descriptor)
                for alias in allExisting {
                    if let current = existingAliasesMap[alias.emailAddress] {
                        // Prefer non-logged-out entries; otherwise prefer the one with richer metadata
                        if current.isLoggedOut && !alias.isLoggedOut {
                            existingAliasesMap[alias.emailAddress] = alias
                        } else if current.isLoggedOut == alias.isLoggedOut {
                            // Tie-breaker: prefer the one with more metadata
                            let currentMeta = (current.notes.isEmpty ? 0 : 1) + (current.website.isEmpty ? 0 : 1)
                            let aliasMeta = (alias.notes.isEmpty ? 0 : 1) + (alias.website.isEmpty ? 0 : 1)
                            if aliasMeta > currentMeta {
                                existingAliasesMap[alias.emailAddress] = alias
                            }
                        }
                    } else {
                        existingAliasesMap[alias.emailAddress] = alias
                    }
                }
            } catch {
                print("Error fetching existing aliases for refresh: \(error)")
            }
            
            // Remove deleted aliases, but only those that belong to configured zones and are missing there
            let configuredZoneIds = Set(cloudflareClient.zones.map { $0.zoneId })
            for alias in emailAliases {
                // Only consider deleting if alias has a zoneId and belongs to a configured zone
                guard !alias.zoneId.isEmpty, configuredZoneIds.contains(alias.zoneId) else { continue }
                // If no matching rule exists for that email in the aggregated set AND the email does not exist under any zone, delete
                if cloudflareRulesByEmail[alias.emailAddress] == nil {
                    print("Deleting alias not found in any configured zones: \(alias.emailAddress) [zone: \(alias.zoneId)]")
                    modelContext.delete(alias)
                }
            }
            
            // Update or create aliases
            for (index, rule) in cloudflareRules.enumerated() {
                let emailAddress = rule.emailAddress
                let forwardTo = rule.forwardTo
                
                if let existing = existingAliasesMap[emailAddress] {
                    // Reactivate if it was logged out and update fields
                    let newZoneId = rule.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)
                    withAnimation {
                        existing.isLoggedOut = false
                        existing.cloudflareTag = rule.cloudflareTag
                        existing.isEnabled = rule.isEnabled
                        existing.forwardTo = forwardTo
                        existing.sortIndex = index + 1
                        existing.zoneId = newZoneId
                    }
                } else {
                    // Create new alias with proper properties
                    let newAlias = EmailAlias(
                        emailAddress: emailAddress,
                        forwardTo: forwardTo,
                        zoneId: rule.zoneId
                    )
                    newAlias.cloudflareTag = rule.cloudflareTag
                    newAlias.isEnabled = rule.isEnabled
                    newAlias.sortIndex = index + 1
                    
                    // Set the user identifier to ensure cross-device ownership
                    newAlias.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                    
                    modelContext.insert(newAlias)
                }
            }
            
            // Save once after all updates and run a quick dedup pass to merge any stragglers
            try modelContext.save()
            do {
                let removed = try EmailAlias.deduplicate(in: modelContext)
                if removed > 0 { print("Deduplicated \(removed) aliases during refresh (post-reactivation)") }
            } catch {
                print("Deduplication error: \(error)")
            }
            
    } catch {
            // Treat user-initiated cancellations (URLError.cancelled / -999) as non-fatal
            if isCancellationError(error) {
                print("Refresh cancelled (ignored)")
            } else {
                print("Error during refresh: \(error)")
                self.error = error
                self.showError = true
            }
        }
    if showLoading { isLoading = false }
    isNetworking = false
        isInitialLoad = false
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
    
    // Unified refresh action used by both list and empty-state scroll view
    private func refreshAction() async {
        do {
            let deleted = try EmailAlias.deduplicate(in: modelContext)
            if deleted > 0 { print("Deduplicated \(deleted) aliases during refresh") }
        } catch {
            print("Error during refresh deduplication: \(error)")
        }
        await refreshEmailRules()
    }
    
    var body: some View {
    ZStack {
            Group {
                if isLoading && isInitialLoad {
                    ProgressView()
                } else if sortedEmails.isEmpty {
                    // Wrap empty state in a ScrollView so pull-to-refresh works even when empty
                    ScrollView {
                        VStack {
                            ContentUnavailableView(
                                "No Email Aliases",
                                systemImage: "envelope.badge.shield.half.filled",
                                description: Text("Create your first email alias using the + button")
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .refreshable {
                        await refreshAction()
                    }
                } else {
                    List {
                        ForEach(sortedEmails, id: \.id) { email in
                            EmailListRowLink(email: email) { copied in
                                showToastWithTimer(copied)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .listRowBackground(Color.black)
                    .navigationDestination(for: EmailAlias.self) { email in
                        EmailDetailView(email: email, needsRefresh: $needsRefresh)
                    }
                    .refreshable {
                        await refreshAction()
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
                        // Stage current filters before presenting the sheet
                        pendingDestinationFilter = destinationFilter
                        pendingDomainFilter = domainFilter
                        showFilterSheet = true
                    } label: {
                        Label("Filter", systemImage: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                } label: {
                    Image(systemName: isFilterActive ? "ellipsis.circle.fill" : "ellipsis.circle")
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
        .onChange(of: domainFilter) { _, newValue in
            persistDomainFilter(newValue)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationView {
                List {
                    Section(header: Text("Destination Address")) {
                        Button(action: {
                            pendingDestinationFilter = .all
                        }) {
                            HStack {
                                Text("All")
                                if pendingDestinationFilter == .all {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        ForEach(allDestinationAddresses, id: \.self) { addr in
                            Button(action: {
                                pendingDestinationFilter = .address(addr)
                            }) {
                                HStack {
                                    Text(addr)
                                    if pendingDestinationFilter == .address(addr) {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    // Domain filter only when more than one zone exists
                    if cloudflareClient.zones.count > 1 {
                        Section(header: Text("Domain")) {
                            Button(action: {
                                pendingDomainFilter = .all
                            }) {
                                HStack {
                                    Text("All")
                                    if pendingDomainFilter == .all {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            ForEach(cloudflareClient.zones, id: \.zoneId) { z in
                                Button(action: {
                                    pendingDomainFilter = .zone(z.zoneId)
                                }) {
                                    HStack {
                                        Text(z.domainName.isEmpty ? z.zoneId : z.domainName)
                                        if pendingDomainFilter == .zone(z.zoneId) {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
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
                // Bottom Apply button so selections don't auto-apply until confirmed
                .safeAreaInset(edge: .bottom) {
                    ZStack {
                        // subtle background to separate from list content
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                            .ignoresSafeArea()
                            .frame(height: 0)
                        VStack {
                            Button {
                                // Apply staged filters and close
                                destinationFilter = pendingDestinationFilter
                                domainFilter = pendingDomainFilter
                                showFilterSheet = false
                            } label: {
                                Text("Apply Filters")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(pendingDestinationFilter == destinationFilter && pendingDomainFilter == domainFilter)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom)
                        }
                        .background(.ultraThinMaterial)
                    }
                }
            }
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
            // Ensure we have forwarding addresses ready for the filter picker
            do {
                if cloudflareClient.zones.count > 1 {
                    try await cloudflareClient.refreshForwardingAddressesAllZones()
                } else {
                    try await cloudflareClient.ensureForwardingAddressesLoaded()
                }
            } catch {
                print("Error loading forwarding addresses for list view: \(error)")
            }
            // Only load if we haven't loaded yet and there are no existing aliases
            if isInitialLoad && emailAliases.isEmpty {
                await refreshEmailRules(showLoading: true)
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
        // Auto-refresh when zones change (e.g., adding/removing a zone)
        .onChange(of: cloudflareClient.zones) { _, _ in
            Task {
                // Keep forwarding addresses in sync when zones change
                do {
                    if cloudflareClient.zones.count > 1 {
                        try await cloudflareClient.refreshForwardingAddressesAllZones()
                    } else {
                        try await cloudflareClient.refreshForwardingAddresses()
                    }
                } catch {
                    print("Error refreshing addresses after zone change: \(error)")
                }
                await refreshEmailRules()
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
                            .font(.system(size: 22, weight: .medium))
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
                            .font(.system(size: 20, weight: .medium))
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

            // If we already know this host has no icon, avoid showing a spinner or fetching again
            if IconCache.shared.hasMissingIcon(for: email.website) {
                isLoadingIcon = false
                websiteUIImage = nil
                return
            }

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
// Compact wrapper for a list row + NavigationLink + copy gestures
private struct EmailListRowLink: View {
    let email: EmailAlias
    let onCopied: (String) -> Void

    var body: some View {
        NavigationLink(value: email) {
            EmailRowView(email: email) {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
                UIPasteboard.general.string = email.emailAddress
                onCopied(email.emailAddress)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred()
            UIPasteboard.general.string = email.emailAddress
            onCopied(email.emailAddress)
        })
    }
}

// Add this extension to get the background color
extension Color {
    static let background = Color(uiColor: .systemBackground)
} 
