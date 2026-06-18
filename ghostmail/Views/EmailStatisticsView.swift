import SwiftUI
import SwiftData

/// Filter options for email statistics action types
enum StatisticsActionFilter: String, CaseIterable {
    case all = "All"
    case forwarded = "Forwarded"
    case dropped = "Dropped"
    case rejected = "Rejected"
}

struct EmailStatisticsView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    // Plain @Query (no predicate). A predicate-based @Query constructed at
    // navigation time can stall against an actively-mirroring CloudKit store;
    // logged-out aliases are filtered in-memory (see `activeAliases`).
    @Query private var emailAliases: [EmailAlias]
    @State private var statistics: [EmailStatistic] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedZoneId: String
    @State private var selectedActionFilter: StatisticsActionFilter = .all
    @State private var selectedDestination: String = "ALL_DESTINATIONS"
    
    private let allZonesIdentifier = "ALL_ZONES"
    private let allDestinationsIdentifier = "ALL_DESTINATIONS"
    
    /// Aliases excluding logged-out ones (from removed zones). Filtered in-memory
    /// instead of via a predicate @Query to avoid navigation-time CloudKit stalls.
    private var activeAliases: [EmailAlias] {
        emailAliases.filter { !$0.isLoggedOut }
    }
    
    /// Get unique destination addresses (forwardTo) from aliases for the filter picker
    private var availableDestinations: [String] {
        let destinations = Set(activeAliases.compactMap { alias -> String? in
            guard !alias.forwardTo.isEmpty else { return nil }
            return alias.forwardTo
        })
        return Array(destinations).sorted()
    }
    
    /// Get all zone options including subdomains
    private var zoneOptions: [(id: String, name: String)] {
        var options: [(id: String, name: String)] = []
        
        for zone in cloudflareClient.zones {
            let displayName = zone.domainName.isEmpty ? zone.zoneId : zone.domainName
            options.append((id: zone.zoneId, name: displayName))
            
            // Add subdomains if enabled for this zone.
            // Entries in zone.subdomains are already fully-qualified names
            // (e.g. "mail.example.com"), so use them directly for display.
            if zone.subdomainsEnabled {
                for subdomain in zone.subdomains {
                    // Use a composite ID for subdomains: "zoneId:subdomain"
                    options.append((id: "\(zone.zoneId):\(subdomain)", name: subdomain))
                }
            }
        }
        
        return options
    }
    
    /// Filtered statistics based on the selected destination and action filters
    private func filteredStatistics(using lookup: EmailAliasLookup) -> [EmailStatistic] {
        var filtered = statistics
        
        // Apply destination address filter
        if selectedDestination != allDestinationsIdentifier {
            filtered = filtered.filter { stat in
                lookup.destinationAddress(for: stat.emailAddress) == selectedDestination
            }
        }
        
        // Apply action type filter
        switch selectedActionFilter {
        case .all:
            break
        case .forwarded:
            filtered = filtered.filter { stat in
                lookup.actionType(for: stat.emailAddress) == .forward
            }
        case .dropped:
            filtered = filtered.filter { stat in
                lookup.actionType(for: stat.emailAddress) == .drop
            }
        case .rejected:
            filtered = filtered.filter { stat in
                lookup.actionType(for: stat.emailAddress) == .reject
            }
        }
        
        return filtered
    }
    
    init(initialZoneId: String? = nil) {
        // Default to "All" if no zone specified or if multiple zones exist
        _selectedZoneId = State(initialValue: initialZoneId ?? "ALL_ZONES")
    }
    
    var body: some View {
        let lookup = EmailAliasLookup(activeAliases)
        let filteredStats = filteredStatistics(using: lookup)
        // Catch-all traffic can produce thousands of distinct recipient addresses.
        // Rendering one row per address can stall the main thread, so cap the list
        // (statistics are sorted by count, so this keeps the busiest addresses).
        let rowDisplayLimit = 250
        let displayStats = Array(filteredStats.prefix(rowDisplayLimit))
        
        List {
            // Settings Section (Zone + Filters)
            Section {
                if cloudflareClient.zones.count > 1 || zoneOptions.count > cloudflareClient.zones.count {
                    Picker("Zone", selection: $selectedZoneId) {
                        Text("All Zones")
                            .tag(allZonesIdentifier)
                        ForEach(zoneOptions, id: \.id) { option in
                            Text(option.name)
                                .tag(option.id)
                        }
                    }
                    .onChange(of: selectedZoneId) { _, newValue in
                        // Reset destination filter when zone changes
                        selectedDestination = allDestinationsIdentifier
                        Task {
                            await loadStatistics(zoneId: newValue, useCache: true)
                        }
                    }
                }
                
                Picker("Destination", selection: $selectedDestination) {
                    Text("All Destinations")
                        .tag(allDestinationsIdentifier)
                    ForEach(availableDestinations, id: \.self) { destination in
                        Text(destination)
                            .tag(destination)
                    }
                }
                
                Picker("Status", selection: $selectedActionFilter) {
                    ForEach(StatisticsActionFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue)
                            .tag(filter)
                    }
                }
            }
            
            // Chart Section
            if !filteredStats.isEmpty && errorMessage == nil {
                Section {
                    EmailTrendChartView(statistics: filteredStats)
                        .frame(height: 200)
                        .padding(.vertical, 8)
                } header: {
                    HStack {
                        Text("7-Day Trend")
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
            } else if isLoading && statistics.isEmpty {
                // Placeholder skeleton while loading
                Section {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 200)
                        .overlay(
                            ProgressView()
                        )
                        .padding(.vertical, 8)
                } header: {
                    HStack {
                        Text("7-Day Trend")
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
            
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                } else if filteredStats.isEmpty {
                    if selectedActionFilter == .all {
                        Text("No email traffic found in the last 7 days.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No \(selectedActionFilter.rawValue.lowercased()) emails found in the last 7 days.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(displayStats) { stat in
                        NavigationLink {
                            EmailStatisticsDetailView(statistic: stat)
                        } label: {
                            StatisticRowView(
                                stat: stat,
                                isDropAlias: lookup.actionType(for: stat.emailAddress) != .forward,
                                isCatchAll: lookup.isCatchAllAddress(stat.emailAddress)
                            )
                        }
                    }
                    if filteredStats.count > displayStats.count {
                        Text("Showing the top \(displayStats.count) of \(filteredStats.count) addresses. Use the filters above to narrow results.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Emails Received (Last 7 Days)")
            } footer: {
                Text("Statistics are provided by Cloudflare Email Routing.")
            }
        }
        .navigationTitle("Email Statistics")
        .refreshable {
            await refreshStatistics()
        }
        .task {
            await loadStatistics(zoneId: selectedZoneId, useCache: true)
        }
    }
    
    private func refreshStatistics() async {
        await loadStatistics(zoneId: selectedZoneId, useCache: false)
    }
    
    private func loadStatistics(zoneId: String, useCache: Bool) async {
        // Handle "All Zones" option
        if zoneId == allZonesIdentifier {
            await loadAllZonesStatistics(useCache: useCache)
            return
        }
        
        // Subdomain picker options use a composite ID: "zoneId:subdomain-fqdn".
        // Resolve the parent zone and remember the subdomain to filter by.
        let idParts = zoneId.split(separator: ":", maxSplits: 1).map(String.init)
        let parentZoneId = idParts[0]
        let subdomainFilter: String? = idParts.count == 2 ? idParts[1].lowercased() : nil
        
        guard let zone = cloudflareClient.zones.first(where: { $0.zoneId == parentZoneId }) else { return }
        
        // Try to load from shared cache first
        if useCache, let cached = await StatisticsCache.shared.loadAsync() {
            // Filter to this zone's (or subdomain's) statistics
            let zoneStats = cached.statistics.filter { stat in
                // Check if this statistic belongs to this zone by matching email domain
                let domain = stat.emailAddress.split(separator: "@").last.map(String.init) ?? ""
                if let subdomainFilter {
                    return domain.lowercased() == subdomainFilter
                }
                return domain == zone.domainName || zone.subdomains.contains(domain)
            }
            statistics = zoneStats
            
            // If cache is fresh, we're done
            if !cached.isStale {
                return
            }
            // If stale, continue to fetch fresh data
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
            
            // Update shared cache by merging with existing data
            if !stats.isEmpty {
                if let existingCache = await StatisticsCache.shared.loadAsync() {
                    // Remove old stats for this zone and add new ones
                    let otherZoneStats = existingCache.statistics.filter { stat in
                        let domain = stat.emailAddress.split(separator: "@").last.map(String.init) ?? ""
                        return domain != zone.domainName && !zone.subdomains.contains(domain)
                    }
                    StatisticsCache.shared.save(otherZoneStats + stats)
                } else {
                    StatisticsCache.shared.save(stats)
                }
            }
            
            if let subdomainFilter {
                // Show only the selected subdomain's statistics
                self.statistics = stats.filter { stat in
                    let domain = stat.emailAddress.split(separator: "@").last.map(String.init) ?? ""
                    return domain.lowercased() == subdomainFilter
                }
            } else {
                self.statistics = stats
            }
            self.isLoading = false
        } catch {
            // Ignore non-fatal network errors (timeouts, connection lost) that occur during background transitions
            if !isNonFatalNetworkError(error) {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }
    
    /// Determines if an error is non-fatal and shouldn't be shown to the user.
    /// Includes timeouts and connection issues which commonly occur during background/foreground transitions.
    private func isNonFatalNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return true
            default:
                break
            }
        }
        return false
    }
    
    private func loadAllZonesStatistics(useCache: Bool) async {
        // Try to load from shared cache first
        if useCache, let cached = await StatisticsCache.shared.loadAsync() {
            statistics = cached.statistics.sorted { $0.count > $1.count }
            
            // If cache is fresh, we're done
            if !cached.isStale {
                return
            }
            // If stale, continue to fetch fresh data
        }
        
        isLoading = true
        errorMessage = nil
        
        var allStats: [EmailStatistic] = []
        var firstError: Error?
        var successCount = 0
        
        // Fetch statistics per zone — one failing zone shouldn't discard
        // the results from zones that succeeded
        for zone in cloudflareClient.zones {
            do {
                let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                allStats.append(contentsOf: stats)
                successCount += 1
            } catch {
                debugLog("Failed to fetch statistics for zone \(zone.zoneId): \(error)")
                if firstError == nil { firstError = error }
            }
        }
        
        // Only overwrite the shared cache when every zone succeeded; a partial
        // save would wipe cached data for the zones that failed
        if !allStats.isEmpty && firstError == nil {
            StatisticsCache.shared.save(allStats)
        }
        
        if successCount > 0 {
            self.statistics = allStats.sorted { $0.count > $1.count }
        }
        // Only surface an error when nothing could be fetched at all
        if let error = firstError, successCount == 0, !isNonFatalNetworkError(error) {
            self.errorMessage = error.localizedDescription
        }
        self.isLoading = false
    }
}

// MARK: - Statistic Row View

private struct StatisticRowView: View {
    let stat: EmailStatistic
    let isDropAlias: Bool
    let isCatchAll: Bool
    
    // Calculate action counts
    private var actionCounts: (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for detail in stat.emailDetails {
            switch detail.action {
            case .forwarded: forwarded += 1
            case .dropped: dropped += 1
            case .rejected: rejected += 1
            case .unknown: break
            }
        }
        return (forwarded, dropped, rejected)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Text(stat.emailAddress)
                        .font(.body)
                        .foregroundStyle(isDropAlias ? .red : (isCatchAll ? .purple : .primary))
                        .lineLimit(1)
                    
                    // Catch-all indicator badge
                    if isCatchAll {
                        Text("Catch-All")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.15))
                            )
                    }
                }
                Spacer()
                Text("\(stat.count)")
                    .font(.monospacedDigit(.body)())
                    .foregroundStyle(.secondary)
            }
            
            // Mini status indicators
            HStack(spacing: 12) {
                if actionCounts.forwarded > 0 {
                    StatusBadge(action: .forwarded, count: actionCounts.forwarded)
                }
                if actionCounts.dropped > 0 {
                    StatusBadge(action: .dropped, count: actionCounts.dropped)
                }
                if actionCounts.rejected > 0 {
                    StatusBadge(action: .rejected, count: actionCounts.rejected)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = stat.emailAddress
                let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
            } label: {
                Text("Copy Email")
                Image(systemName: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = "\(stat.count)"
                let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
            } label: {
                Text("Copy Count")
                Image(systemName: "number")
            }
        }
    }
    
    // Compact status badge
    private struct StatusBadge: View {
        let action: EmailRoutingAction
        let count: Int
        
        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: action.iconName)
                    .font(.system(size: 10, weight: .medium))
                Text("\(count)")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
            }
            .foregroundStyle(action.color)
        }
    }
}
