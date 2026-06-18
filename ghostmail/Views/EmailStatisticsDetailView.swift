import SwiftUI
import SwiftData

struct EmailStatisticsDetailView: View {
    let statistic: EmailStatistic
    // Plain @Query (no predicate). A predicate-based @Query constructed at
    // navigation time can stall against an actively-mirroring CloudKit store;
    // logged-out aliases are filtered in-memory where the lookup is built.
    @Query private var emailAliases: [EmailAlias]
    
    // Filter state for action type
    @State private var selectedActionFilter: EmailRoutingAction? = nil
    
    // Group emails by date
    private var emailsByDate: [(date: Date, emails: [EmailStatistic.EmailDetail])] {
        let calendar = Calendar.current
        var grouped: [Date: [EmailStatistic.EmailDetail]] = [:]
        
        for detail in statistic.emailDetails {
            let dayStart = calendar.startOfDay(for: detail.date)
            grouped[dayStart, default: []].append(detail)
        }
        
        return grouped.map { (date: $0.key, emails: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }
    
    // Filtered emails by date, applying action filter
    private func filteredEmailsByDate(from groupedEmails: [(date: Date, emails: [EmailStatistic.EmailDetail])]) -> [(date: Date, emails: [EmailStatistic.EmailDetail])] {
        guard let filter = selectedActionFilter else { return groupedEmails }
        return groupedEmails.map { group in
            (date: group.date, emails: group.emails.filter { $0.action == filter })
        }.filter { !$0.emails.isEmpty }
    }
    
    // Total filtered count
    private func filteredEmailCount(in groupedEmails: [(date: Date, emails: [EmailStatistic.EmailDetail])]) -> Int {
        groupedEmails.reduce(0) { $0 + $1.emails.count }
    }
    
    // Overall summary counts
    private var actionSummary: (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for detail in statistic.emailDetails {
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
        let lookup = EmailAliasLookup(emailAliases.filter { !$0.isLoggedOut })
        let isDropAlias = lookup.isDropAlias(for: statistic.emailAddress)
        let isCatchAll = lookup.isCatchAllAddress(statistic.emailAddress)
        let detailGroups = emailsByDate
        let filteredEmailsByDate = filteredEmailsByDate(from: detailGroups)
        let filteredEmailCount = filteredEmailCount(in: filteredEmailsByDate)
        
        List {
            // Chart Section
            Section {
                EmailTrendChartView(statistics: [statistic])
                    .frame(height: 160)
                    .padding(.vertical, 4)
            } header: {
                Text("7-Day Trend")
            }
            
            // Summary Section
            if !statistic.emailDetails.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        ActionSummaryBadge(
                            action: .forwarded,
                            count: actionSummary.forwarded,
                            isSelected: selectedActionFilter == .forwarded,
                            hasActiveFilter: selectedActionFilter != nil
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedActionFilter = selectedActionFilter == .forwarded ? nil : .forwarded
                            }
                        }
                        ActionSummaryBadge(
                            action: .dropped,
                            count: actionSummary.dropped,
                            isSelected: selectedActionFilter == .dropped,
                            hasActiveFilter: selectedActionFilter != nil
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedActionFilter = selectedActionFilter == .dropped ? nil : .dropped
                            }
                        }
                        ActionSummaryBadge(
                            action: .rejected,
                            count: actionSummary.rejected,
                            isSelected: selectedActionFilter == .rejected,
                            hasActiveFilter: selectedActionFilter != nil
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedActionFilter = selectedActionFilter == .rejected ? nil : .rejected
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    HStack {
                        Text("Status Summary")
                        Spacer()
                        if selectedActionFilter != nil {
                            Text("\(filteredEmailCount)/\(statistic.emailDetails.count)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            
            if statistic.emailDetails.isEmpty {
                Section {
                    Text("No detailed logs available.")
                        .foregroundStyle(.secondary)
                }
            } else if filteredEmailsByDate.isEmpty && selectedActionFilter != nil {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                            Text("No \(selectedActionFilter!.label.lowercased()) emails")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            } else {
                ForEach(filteredEmailsByDate, id: \.date) { group in
                    Section {
                        ForEach(group.emails, id: \.self) { detail in
                            HStack(spacing: 12) {
                                // Status icon with background
                                ZStack {
                                    Circle()
                                        .fill(detail.action.color.opacity(0.15))
                                        .frame(width: 30, height: 30)
                                    
                                    Image(systemName: detail.action.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(detail.action.color)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(detail.from)
                                        .font(.body)
                                    
                                    HStack(spacing: 8) {
                                        Text(detail.date.formatted(date: .omitted, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        
                                        // Plus-address tag badge
                                        if let plusTag = detail.plusTag {
                                            Text("+\(plusTag)")
                                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                                .foregroundStyle(.blue)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    Capsule()
                                                        .fill(Color.blue.opacity(0.15))
                                                )
                                        }
                                        
                                        // Status badge
                                        Text(detail.action.label)
                                            .font(.system(.caption2, design: .rounded, weight: .medium))
                                            .foregroundStyle(detail.action.color)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule()
                                                    .fill(detail.action.color.opacity(0.15))
                                            )
                                    }
                                }
                                
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    Pasteboard.copySensitive(detail.from)
                                    let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                                } label: {
                                    Text("Copy Email Address")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                            .onLongPressGesture {
                                Pasteboard.copySensitive(detail.from)
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                            }
                        }
                    } header: {
                        HStack {
                            Text(formatDateHeader(group.date))
                            Spacer()
                            Text("\(group.emails.count)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(statistic.emailAddress)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    Text(statistic.emailAddress)
                        .font(.headline)
                        .foregroundStyle(isDropAlias ? .red : (isCatchAll ? .purple : .primary))
                    
                    // Catch-all indicator badge in toolbar
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
            }
        }
    }
    
    private func formatDateHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }
}
