import SwiftUI

struct EmailStatisticsView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @State private var statistics: [EmailStatistic] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedZoneId: String
    @State private var statisticsCache: [String: [EmailStatistic]] = [:]
    
    init(initialZoneId: String) {
        _selectedZoneId = State(initialValue: initialZoneId)
    }
    
    var body: some View {
        List {
            if cloudflareClient.zones.count > 1 {
                Section {
                    Picker("Zone", selection: $selectedZoneId) {
                        ForEach(cloudflareClient.zones, id: \.zoneId) { zone in
                            Text(zone.domainName.isEmpty ? zone.zoneId : zone.domainName)
                                .tag(zone.zoneId)
                        }
                    }
                    .onChange(of: selectedZoneId) { _, newValue in
                        loadStatistics(zoneId: newValue, forceRefresh: false)
                    }
                }
            }
            
            // Chart Section
            if !isLoading && errorMessage == nil && !statistics.isEmpty {
                Section {
                    EmailTrendChartView(statistics: statistics)
                        .frame(height: 200)
                        .padding(.vertical, 8)
                } header: {
                    Text("7-Day Trend")
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
                            HStack {
                                Text(stat.emailAddress)
                                    .font(.body)
                                Spacer()
                                Text("\(stat.count)")
                                    .font(.monospacedDigit(.body)())
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = "\(stat.count)"
                                        } label: {
                                            Text("Copy Count")
                                            Image(systemName: "doc.on.doc")
                                        }
                                    }
                                    .onLongPressGesture {
                                        UIPasteboard.general.string = "\(stat.count)"
                                        let generator = UIImpactFeedbackGenerator(style: .light)
                                        generator.impactOccurred()
                                    }
                                    .padding(-8)
                            }
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
            loadStatistics(zoneId: selectedZoneId, forceRefresh: false)
        }
    }
    
    private func refreshStatistics() async {
        loadStatistics(zoneId: selectedZoneId, forceRefresh: true)
        // Wait for the loading to complete
        while isLoading {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }
    
    private func loadStatistics(zoneId: String, forceRefresh: Bool) {
        guard let zone = cloudflareClient.zones.first(where: { $0.zoneId == zoneId }) else { return }
        
        // Check cache first if not forcing refresh
        if !forceRefresh, let cachedStats = statisticsCache[zoneId] {
            statistics = cachedStats
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let stats = try await cloudflareClient.fetchEmailStatistics(for: zone)
                await MainActor.run {
                    self.statistics = stats
                    self.statisticsCache[zoneId] = stats
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

// Beautiful chart component for email trend visualization
private struct EmailTrendChartView: View {
    let statistics: [EmailStatistic]
    
    private var dailyCounts: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        var countsByDay: [Date: Int] = [:]
        
        // Aggregate all received dates across all email addresses
        for stat in statistics {
            for date in stat.receivedDates {
                let dayStart = calendar.startOfDay(for: date)
                countsByDay[dayStart, default: 0] += 1
            }
        }
        
        // Create array for last 7 days, filling in zeros for days with no emails
        let today = calendar.startOfDay(for: Date())
        var result: [(date: Date, count: Int)] = []
        
        for i in (0..<7).reversed() {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                result.append((date: date, count: countsByDay[date] ?? 0))
            }
        }
        
        return result
    }
    
    private var maxCount: Int {
        dailyCounts.map { $0.count }.max() ?? 1
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Total count badge
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Emails")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(dailyCounts.reduce(0) { $0 + $1.count })")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            
            // Chart
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(dailyCounts.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 4) {
                        // Bar
                        ZStack(alignment: .bottom) {
                            // Background bar
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.1))
                                .frame(height: 120)
                            
                            // Actual value bar with gradient
                            if item.count > 0 {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.accentColor,
                                                Color.accentColor.opacity(0.7)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(height: max(20, CGFloat(item.count) / CGFloat(maxCount) * 120))
                                    .overlay(
                                        // Count label on bar
                                        Text("\(item.count)")
                                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.bottom, 4)
                                        , alignment: .bottom
                                    )
                            }
                        }
                        
                        // Day label
                        Text(dayLabel(for: item.date))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
        }
        .padding(.vertical, 8)
    }
    
    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
    }
}
