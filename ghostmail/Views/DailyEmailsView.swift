import SwiftUI
import SwiftData

struct DailyEmailsView: View {
    let date: Date
    let statistics: [EmailStatistic]
    @Query private var emailAliases: [EmailAlias]
    
    private func isDropAlias(for emailAddress: String) -> Bool {
        emailAliases.first { $0.emailAddress == emailAddress }?.actionType != .forward
    }
    
    // Structure to hold individual email information
    private struct EmailItem: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let date: Date
        let action: EmailRoutingAction
    }
    
    // Get all individual emails for the selected day
    private var emailsForDay: [EmailItem] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        
        var allEmails: [EmailItem] = []
        
        for stat in statistics {
            let emailsOnDay = stat.emailDetails.filter { detail in
                calendar.isDate(detail.date, inSameDayAs: dayStart)
            }
            
            for detail in emailsOnDay {
                allEmails.append(EmailItem(
                    from: detail.from,
                    to: stat.emailAddress,
                    date: detail.date,
                    action: detail.action
                ))
            }
        }
        
        // Sort by date/time, most recent first
        return allEmails.sorted { $0.date > $1.date }
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
        for email in emailsForDay {
            switch email.action {
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
                    ContentUnavailableView(
                        "No Emails",
                        systemImage: "envelope",
                        description: Text("No emails were received on this day")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
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
                    ForEach(emailsForDay) { email in
                        EmailRowView(email: email, isDropAlias: isDropAlias(for: email.to))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack {
                        Text("Emails Received")
                        Spacer()
                        Text("\(emailsForDay.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(formattedDate)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // Summary badge for action counts
    private struct ActionSummaryBadge: View {
        let action: EmailRoutingAction
        let count: Int
        
        var body: some View {
            VStack(spacing: 4) {
                Image(systemName: action.iconName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(count > 0 ? action.color : .gray.opacity(0.5))
                Text("\(count)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(count > 0 ? .primary : .secondary)
                Text(action.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: EmailItem
        let isDropAlias: Bool
        @State private var showCopyToast = false
        
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                // Status icon with color
                Image(systemName: email.action.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(email.action.color)
                    .frame(width: 24)
                    .padding(.top, 2)
                
                // All email info in a compact vertical stack
                VStack(alignment: .leading, spacing: 6) {
                    // From line with horizontal scroll
                    HStack(alignment: .top, spacing: 6) {
                        Text("From:")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(email.from)
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // To line with horizontal scroll
                    HStack(alignment: .top, spacing: 6) {
                        Text("To:")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(email.to)
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(isDropAlias ? .red : .primary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Date/Time and Status line
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(formatTime(email.date))
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        
                        // Status badge
                        Text(email.action.label)
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(email.action.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(email.action.color.opacity(0.15))
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
            )
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = email.from
                    showCopyToast = true
                } label: {
                    Label("Copy Sender", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = email.to
                    showCopyToast = true
                } label: {
                    Label("Copy Recipient", systemImage: "doc.on.doc")
                }
            }
            .onLongPressGesture {
                UIPasteboard.general.string = email.from
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                showCopyToast = true
            }
            .overlay(
                Group {
                    if showCopyToast {
                        Text("Copied!")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showCopyToast)
                , alignment: .topTrailing
            )
            .onChange(of: showCopyToast) { _, newValue in
                if newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            showCopyToast = false
                        }
                    }
                }
            }
        }
        
        private func formatTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
}
