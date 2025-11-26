import SwiftUI
import UIKit
import SwiftData
import Combine

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
    @State private var showingComposeSheet = false
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
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @AppStorage("themePreference") private var themePreferenceRaw: String = "Auto"

    // Filter state
    @State private var showFilterSheet = false
    @State private var destinationFilter: DestinationFilter = .all
    // Domain filter (by domain name - includes main domains and subdomains)
    enum DomainFilter: Equatable { case all, domain(String) }
    @State private var domainFilter: DomainFilter = .all
    // Pending (staged) filters used inside the filter sheet
    @State private var pendingDestinationFilter: DestinationFilter = .all
    @State private var pendingDomainFilter: DomainFilter = .all
    
    // Statistics state
    @State private var emailStatistics: [EmailStatistic] = []
    @State private var isLoadingStatistics = false
    @State private var isUsingCachedStatistics = false
    @AppStorage("showAnalytics") private var showAnalytics: Bool = false
    @State private var selectedDate: Date?
    @State private var showDailyEmails = false
    @State private var lastCacheCheckTime: Date = .distantPast

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

    // Only show aliases whose zoneId is in this device's configured zones
    private var allAliases: [EmailAlias] {
        let allowedZoneIds = Set(cloudflareClient.zones.map { $0.zoneId.trimmingCharacters(in: .whitespacesAndNewlines) })
        return emailAliases.filter { allowedZoneIds.contains($0.zoneId.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    
    private var themeColorScheme: ColorScheme? {
        switch themePreferenceRaw {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }
    
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
            } else if domainType == "domain",
                      let domainName = UserDefaults.standard.string(forKey: "EmailListView.domainFilterDomain"),
                      !domainName.isEmpty {
                _domainFilter = State(initialValue: .domain(domainName))
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
            UserDefaults.standard.removeObject(forKey: "EmailListView.domainFilterDomain")
        case .domain(let domainName):
            UserDefaults.standard.set("domain", forKey: "EmailListView.domainFilterType")
            UserDefaults.standard.set(domainName, forKey: "EmailListView.domainFilterDomain")
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

        // Apply domain filter (by domain name)
        let domainFiltered: [EmailAlias]
        switch domainFilter {
        case .all:
            domainFiltered = destinationFiltered
        case .domain(let domainName):
            domainFiltered = destinationFiltered.filter { alias in
                // Extract domain from email address
                let parts = alias.emailAddress.split(separator: "@")
                if parts.count == 2 {
                    return String(parts[1]).lowercased() == domainName.lowercased()
                }
                return false
            }
        }

        return domainFiltered
    }

    var allDestinationAddresses: [String] {
        // Use the same source as SettingsView so the filter list is consistent
        Array(cloudflareClient.forwardingAddresses).sorted()
    }
    
    // Get all available domains (main domains + subdomains with subdomain feature enabled)
    var allAvailableDomains: [String] {
        var domains: [String] = []
        
        for zone in cloudflareClient.zones {
            // Add main domain
            if !zone.domainName.isEmpty {
                domains.append(zone.domainName)
            }
            
            // Add subdomains only if enabled for this zone
            if zone.subdomainsEnabled {
                domains.append(contentsOf: zone.subdomains)
            }
        }
        
        return domains.sorted()
    }
    
    // Computed property for empty state view to avoid complex expressions
    private var emptyStateView: some View {
        if allAliases.isEmpty {
            // No aliases exist at all - show first-time user message
            return ContentUnavailableView(
                "No Email Aliases",
                systemImage: "envelope.badge.shield.half.filled",
                description: Text("Create your first email alias using the + button")
            )
        } else {
            // Aliases exist but search/filter returned no results
            return ContentUnavailableView(
                "No Email Aliases",
                systemImage: "magnifyingglass",
                description: Text("No aliases match your current search or filters")
            )
        }
    }
    
    private func refreshEmailRules(showLoading: Bool = false) async {
        // Coalesce concurrent refreshes regardless of UI loading state
        guard !isNetworking else { return }
        isNetworking = true
        if showLoading { isLoading = true }
        
        do {
            try await cloudflareClient.syncEmailRules(modelContext: modelContext)
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
        // Bypass cache on manual refresh to get fresh data
        await loadStatistics(useCache: false)
    }
    
    // Store unfiltered statistics for efficient re-filtering
    @State private var unfilteredStatistics: [EmailStatistic] = []
    
    private func loadStatistics(useCache: Bool = true) async {
        guard showAnalytics else {
            emailStatistics = []
            unfilteredStatistics = []
            return
        }
        
        // Try to load from cache first for instant display
        if useCache, let cached = StatisticsCache.shared.load() {
            // Update last check time
            if let cacheTimestamp = UserDefaults.standard.object(forKey: "EmailStatisticsCacheTimestamp") as? Date {
                lastCacheCheckTime = cacheTimestamp
            }
            
            await MainActor.run {
                self.unfilteredStatistics = cached.statistics
                self.emailStatistics = filterStatistics(cached.statistics)
                self.isUsingCachedStatistics = true
            }
            
            // If cache is fresh (< 24 hours), we're done
            if !cached.isStale {
                return
            }
            // If stale, continue to fetch fresh data in background
        }
        
        isLoadingStatistics = true
        
        // Fetch statistics for all zones
        var allStats: [EmailStatistic] = []
        for zone in cloudflareClient.zones {
            do {
                let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                allStats.append(contentsOf: stats)
            } catch {
                print("Error fetching statistics for zone \(zone.zoneId): \(error)")
            }
        }
        
        // Cache the raw statistics before filtering
        if !allStats.isEmpty {
            StatisticsCache.shared.save(allStats)
        }
        
        // Filter statistics based on current filters
        let filteredStats = filterStatistics(allStats)
        
        await MainActor.run {
            self.unfilteredStatistics = allStats
            self.emailStatistics = filteredStats
            self.isLoadingStatistics = false
            self.isUsingCachedStatistics = false
        }
    }
    
    /// Re-filter existing statistics without reloading from network
    private func refilterStatistics() {
        guard showAnalytics else {
            emailStatistics = []
            return
        }
        emailStatistics = filterStatistics(unfilteredStatistics)
    }
    
    private func filterStatistics(_ stats: [EmailStatistic]) -> [EmailStatistic] {
        var filtered = stats
        
        // Get the email addresses from filteredEmails
        let filteredEmailAddresses = Set(filteredEmails.map { $0.emailAddress })
        
        // Only include statistics for emails that pass the current filters
        filtered = filtered.filter { stat in
            filteredEmailAddresses.contains(stat.emailAddress)
        }
        
        return filtered
    }
    
    /// Check if cache has been updated since we last loaded and reload if so
    private func checkAndReloadIfCacheUpdated() {
        guard showAnalytics else { return }
        
        // Get cache timestamp
        guard let cacheTimestamp = UserDefaults.standard.object(forKey: "EmailStatisticsCacheTimestamp") as? Date else {
            return
        }
        
        // If cache has been updated since we last checked, reload from cache
        if cacheTimestamp > lastCacheCheckTime {
            print("Statistics cache updated, reloading data...")
            lastCacheCheckTime = cacheTimestamp
            
            Task {
                await loadStatisticsFromCache()
            }
        }
    }
    
    /// Load statistics from cache only (used when cache is updated by background sync)
    private func loadStatisticsFromCache() async {
        guard showAnalytics else { return }
        
        guard let cached = StatisticsCache.shared.load() else {
            return
        }
        
        await MainActor.run {
            self.unfilteredStatistics = cached.statistics
            self.emailStatistics = filterStatistics(cached.statistics)
            print("Statistics refreshed from updated cache (\(cached.statistics.count) addresses)")
        }
    }
    
    private var content: some View {
        ZStack {
            if isLoading && isInitialLoad {
                ProgressView()
            } else if sortedEmails.isEmpty {
                // Wrap empty state in a ScrollView so pull-to-refresh works even when empty
                ScrollView {
                    VStack {
                        emptyStateView
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .refreshable {
                    await refreshAction()
                }
            } else {
                List {
                    // Chart Section
                    if showAnalytics {
                        if !emailStatistics.isEmpty {
                            Section {
                                EmailTrendChartView(
                                    statistics: emailStatistics,
                                    showTotalBadge: false,
                                    onDayTapped: { date in
                                        selectedDate = date
                                        showDailyEmails = true
                                    }
                                )
                                .frame(height: 180)
                                .padding(.top, -28)
                                .padding(.bottom, -8)
                                .opacity(isLoadingStatistics && isUsingCachedStatistics ? 0.7 : 1.0)
                            } header: {
                                HStack {
                                    Text("7-Day Trend")
                                    if isLoadingStatistics && isUsingCachedStatistics {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Total Emails")
                                            .font(.caption2)
                                        Text("\(emailStatistics.reduce(0) { $0 + $1.count })")
                                            .font(.system(.body, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                        } else if isLoadingStatistics {
                            // Placeholder skeleton while loading (only shown if no cache available)
                            Section {
                                VStack(spacing: 0) {
                                    // Skeleton chart placeholder
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.1))
                                        .frame(height: 180)
                                        .overlay(
                                            ProgressView()
                                        )
                                }
                                .padding(.top, -28)
                            } header: {
                                HStack {
                                    Text("7-Day Trend")
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Spacer()
                                }
                            }
                        }
                    }
                    
                    ForEach(sortedEmails, id: \.id) { email in
                        EmailListRowLink(email: email) { copied in
                            showToastWithTimer(copied)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .navigationDestination(for: EmailAlias.self) { email in
                    EmailDetailView(email: email, needsRefresh: $needsRefresh)
                }
                .navigationDestination(isPresented: $showDailyEmails) {
                    if let date = selectedDate {
                        DailyEmailsView(date: date, statistics: emailStatistics)
                    }
                }
                .refreshable {
                    await refreshAction()
                }
            }
            // Floating Action Button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Menu {
                        Button {
                            showingComposeSheet = true
                        } label: {
                            Label("Send Mail", systemImage: "paperplane")
                        }
                        
                        Button {
                            showingCreateSheet = true
                        } label: {
                            Label("Create Alias", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 60, height: 60)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    } primaryAction: {
                        showingCreateSheet = true
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
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom))
                }
            }
        }
    }

    var body: some View {
        content
    .background(Color(.systemBackground).ignoresSafeArea())
    .preferredColorScheme(themeColorScheme)
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
            refilterStatistics()
        }
        .onChange(of: domainFilter) { _, newValue in
            persistDomainFilter(newValue)
            refilterStatistics()
        }
        .onChange(of: searchText) { _, _ in
            refilterStatistics()
        }
        .onChange(of: showAnalytics) { _, _ in
            Task {
                await loadStatistics()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheetView(
                pendingDestinationFilter: $pendingDestinationFilter,
                pendingDomainFilter: $pendingDomainFilter,
                destinationFilter: $destinationFilter,
                domainFilter: $domainFilter,
                showFilterSheet: $showFilterSheet,
                allDestinationAddresses: allDestinationAddresses,
                allAvailableDomains: allAvailableDomains
            )
        }
        .sheet(isPresented: $showingComposeSheet) {
            let enabledAliases = emailAliases.filter { $0.isEnabled }.map { $0.emailAddress }.sorted()
            let lastUsedEmail = UserDefaults.standard.string(forKey: "lastUsedFromEmail")
            let defaultEmail = lastUsedEmail != nil && enabledAliases.contains(lastUsedEmail!) 
                ? lastUsedEmail! 
                : (enabledAliases.first ?? "")
            
            EmailComposeView(
                fromEmail: defaultEmail,
                availableEmails: enabledAliases
            )
        }
        .sheet(isPresented: $showingCreateSheet) {
            EmailCreateView { createdEmail in
                showToastWithTimer(createdEmail)
            }
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
            // Load statistics on initial appear
            await loadStatistics()
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
        .onAppear {
            // Check if cache has been updated since we last loaded
            checkAndReloadIfCacheUpdated()
        }
        .onReceive(NotificationCenter.default.publisher(for: .statisticsCacheUpdated)) { _ in
            // Cache was updated by background sync, reload it immediately
            checkAndReloadIfCacheUpdated()
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

// Extracted filter sheet view to reduce type-check complexity in main view
private struct FilterSheetView: View {
    @Binding var pendingDestinationFilter: DestinationFilter
    @Binding var pendingDomainFilter: EmailListView.DomainFilter
    @Binding var destinationFilter: DestinationFilter
    @Binding var domainFilter: EmailListView.DomainFilter
    @Binding var showFilterSheet: Bool
    let allDestinationAddresses: [String]
    let allAvailableDomains: [String]

    @EnvironmentObject private var cloudflareClient: CloudflareClient

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Destination Address")) {
                    Button(action: { pendingDestinationFilter = .all }) {
                        HStack {
                            Text("All")
                            if pendingDestinationFilter == .all {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach(allDestinationAddresses, id: \.self) { addr in
                        Button(action: { pendingDestinationFilter = .address(addr) }) {
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
                Section(header: Text("Domain")) {
                    Button(action: { pendingDomainFilter = .all }) {
                        HStack {
                            Text("All")
                            if pendingDomainFilter == .all {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach(allAvailableDomains, id: \.self) { domainName in
                        Button(action: { pendingDomainFilter = .domain(domainName) }) {
                            HStack {
                                Text(domainName)
                                if pendingDomainFilter == .domain(domainName) {
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") {
                        // Reset filters to defaults and apply immediately
                        destinationFilter = .all
                        domainFilter = .all
                        pendingDestinationFilter = .all
                        pendingDomainFilter = .all
                        showFilterSheet = false
                    }
                    .disabled(destinationFilter == .all && domainFilter == .all)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    VStack {
                        Button {
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
}
