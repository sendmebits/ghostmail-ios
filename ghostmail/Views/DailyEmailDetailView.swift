import SwiftUI
import SwiftData

struct DailyEmailDetailView: View {
    let date: Date
    let statistic: EmailStatistic
    @Query private var emailAliases: [EmailAlias]
    
    private var isDropAlias: Bool {
        emailAliases.first { $0.emailAddress == statistic.emailAddress }?.actionType != .forward
    }
    
    // Filter email details for the selected day
    private var emailsForDay: [EmailStatistic.EmailDetail] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        
        return statistic.emailDetails.filter { detail in
            calendar.isDate(detail.date, inSameDayAs: dayStart)
        }
        .sorted { $0.date > $1.date }
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }
    
    // Summary counts by action
    private var actionSummary: (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for detail in emailsForDay {
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
            if emailsForDay.isEmpty {
                Section {
                    Text("No detailed logs available for this day")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Summary section
                Section {
                    HStack(spacing: 16) {
                        ActionSummaryBadge(action: .forwarded, count: actionSummary.forwarded)
                        ActionSummaryBadge(action: .dropped, count: actionSummary.dropped)
                        ActionSummaryBadge(action: .rejected, count: actionSummary.rejected)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text("Summary")
                }
                
                Section {
                    ForEach(emailsForDay, id: \.self) { detail in
                        HStack(spacing: 12) {
                            // Status icon
                            Image(systemName: detail.action.iconName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(detail.action.color)
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text(detail.from)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                
                                HStack(spacing: 8) {
                                    Text(detail.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    
                                    // Status badge
                                    Text(detail.action.label)
                                        .font(.system(.caption2, design: .rounded, weight: .medium))
                                        .foregroundStyle(detail.action.color)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(detail.action.color.opacity(0.15))
                                        )
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
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
                    Text("Received Emails")
                } footer: {
                    Text("Total: \(emailsForDay.count) emails on \(formattedDate)")
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
    
    // Summary badge for action counts
    private struct ActionSummaryBadge: View {
        let action: EmailRoutingAction
        let count: Int
        
        var body: some View {
            VStack(spacing: 4) {
                Image(systemName: action.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(count > 0 ? action.color : .gray.opacity(0.5))
                Text("\(count)")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(count > 0 ? .primary : .secondary)
                Text(action.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
