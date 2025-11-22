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
