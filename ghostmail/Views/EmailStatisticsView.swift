import SwiftUI
import SwiftData

struct EmailStatisticsView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Query private var emailAliases: [EmailAlias]
    @State private var statistics: [EmailStatistic] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedZoneId: String
    
    private let allZonesIdentifier = "ALL_ZONES"
    
    /// Returns the action type for a given email address by looking up in aliases
    private func actionType(for emailAddress: String) -> EmailRuleActionType {
        if let alias = emailAliases.first(where: { $0.emailAddress == emailAddress }) {
            return alias.actionType
        }
        return .forward  // Default to forward if no alias found
    }
    
    init(initialZoneId: String? = nil) {
        // Default to "All" if no zone specified or if multiple zones exist
        _selectedZoneId = State(initialValue: initialZoneId ?? "ALL_ZONES")
    }
    
    var body: some View {
        List {
            if cloudflareClient.zones.count > 1 {
                Section {
                    Picker("Zone", selection: $selectedZoneId) {
                        Text("All Zones")
                            .tag(allZonesIdentifier)
                        ForEach(cloudflareClient.zones, id: \.zoneId) { zone in
                            Text(zone.domainName.isEmpty ? zone.zoneId : zone.domainName)
                                .tag(zone.zoneId)
                        }
                    }
                    .onChange(of: selectedZoneId) { _, newValue in
                        loadStatistics(zoneId: newValue, useCache: true)
                    }
                }
            }
            
            // Chart Section
            if !statistics.isEmpty && errorMessage == nil {
                Section {
                    EmailTrendChartView(statistics: statistics)
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
                } else if statistics.isEmpty {
                    Text("No email traffic found in the last 7 days.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(statistics) { stat in
                        NavigationLink {
                            EmailStatisticsDetailView(statistic: stat)
                        } label: {
                            StatisticRowView(stat: stat, isDropAlias: actionType(for: stat.emailAddress) != .forward)
                        }
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
            loadStatistics(zoneId: selectedZoneId, useCache: true)
        }
    }
    
    private func refreshStatistics() async {
        loadStatistics(zoneId: selectedZoneId, useCache: false)
        // Wait for the loading to complete
        while isLoading {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    private func loadStatistics(zoneId: String, useCache: Bool) {
        // Handle "All Zones" option
        if zoneId == allZonesIdentifier {
            loadAllZonesStatistics(useCache: useCache)
            return
        }
        
        guard let zone = cloudflareClient.zones.first(where: { $0.zoneId == zoneId }) else { return }
        
        // Try to load from shared cache first
        if useCache, let cached = StatisticsCache.shared.load() {
            // Filter to this zone's statistics
            let zoneStats = cached.statistics.filter { stat in
                // Check if this statistic belongs to this zone by matching email domain
                let domain = stat.emailAddress.split(separator: "@").last.map(String.init) ?? ""
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
        
        Task {
            do {
                let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                
                // Update shared cache by merging with existing data
                if !stats.isEmpty {
                    if let existingCache = StatisticsCache.shared.load() {
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
                
                await MainActor.run {
                    self.statistics = stats
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadAllZonesStatistics(useCache: Bool) {
        // Try to load from shared cache first
        if useCache, let cached = StatisticsCache.shared.load() {
            statistics = cached.statistics.sorted { $0.count > $1.count }
            
            // If cache is fresh, we're done
            if !cached.isStale {
                return
            }
            // If stale, continue to fetch fresh data
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                var allStats: [EmailStatistic] = []
                
                // Fetch statistics for all zones
                for zone in cloudflareClient.zones {
                    let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                    allStats.append(contentsOf: stats)
                }
                
                // Update shared cache with all statistics
                if !allStats.isEmpty {
                    StatisticsCache.shared.save(allStats)
                }
                
                await MainActor.run {
                    self.statistics = allStats.sorted { $0.count > $1.count }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Statistic Row View

private struct StatisticRowView: View {
    let stat: EmailStatistic
    let isDropAlias: Bool
    
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
                Text(stat.emailAddress)
                    .font(.body)
                    .foregroundStyle(isDropAlias ? .red : .primary)
                    .lineLimit(1)
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
            } label: {
                Text("Copy Email")
                Image(systemName: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = "\(stat.count)"
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
