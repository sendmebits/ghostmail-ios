import SwiftUI
import SwiftData

struct EmailStatisticsDetailView: View {
    let statistic: EmailStatistic
    @Query private var emailAliases: [EmailAlias]
    
    private var isDropAlias: Bool {
        emailAliases.first { $0.emailAddress == statistic.emailAddress }?.actionType != .forward
    }
    
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
        List {
            // Chart Section
            Section {
                EmailTrendChartView(statistics: [statistic])
                    .frame(height: 200)
                    .padding(.vertical, 8)
            } header: {
                Text("7-Day Trend")
            }
            
            // Summary Section
            if !statistic.emailDetails.isEmpty {
                Section {
                    HStack(spacing: 16) {
                        ActionSummaryBadge(action: .forwarded, count: actionSummary.forwarded)
                        ActionSummaryBadge(action: .dropped, count: actionSummary.dropped)
                        ActionSummaryBadge(action: .rejected, count: actionSummary.rejected)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text("Status Summary")
                }
            }
            
            if statistic.emailDetails.isEmpty {
                Section {
                    Text("No detailed logs available.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(emailsByDate, id: \.date) { group in
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
                                    UIPasteboard.general.string = detail.from
                                } label: {
                                    Text("Copy Email Address")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                            .onLongPressGesture {
                                UIPasteboard.general.string = detail.from
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                            }
                        }
                    } header: {
                        Text(formatDateHeader(group.date))
                    }
                }
            }
        }
        .navigationTitle(statistic.emailAddress)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(statistic.emailAddress)
                    .font(.headline)
                    .foregroundStyle(isDropAlias ? .red : .primary)
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
    
    // Summary badge for action counts - enhanced visual design
    private struct ActionSummaryBadge: View {
        let action: EmailRoutingAction
        let count: Int
        
        var body: some View {
            VStack(spacing: 8) {
                // Icon with colored background circle
                ZStack {
                    Circle()
                        .fill(count > 0 ? action.color.opacity(0.15) : Color.gray.opacity(0.1))
                        .frame(width: 52, height: 52)
                    
                    Image(systemName: action.iconName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(count > 0 ? action.color : .gray.opacity(0.4))
                }
                
                // Count
                Text("\(count)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(count > 0 ? .primary : .secondary)
                
                // Label
                Text(action.label)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
