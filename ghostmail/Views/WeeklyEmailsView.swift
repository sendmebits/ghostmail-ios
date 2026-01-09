import SwiftUI
import SwiftData

/// Aggregated view showing all emails from the last 7 days in a single scrollable list
struct WeeklyEmailsView: View {
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
    
    // Group emails by day
    private struct DaySection: Identifiable {
        let date: Date
        let emails: [EmailItem]
        
        var id: Date { date }
    }
    
    // Get all emails from the last 7 days grouped by day
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Collect all emails from the last 7 days
        var emailsByDay: [Date: [EmailItem]] = [:]
        
        for stat in statistics {
            for detail in stat.emailDetails {
                let dayStart = calendar.startOfDay(for: detail.date)
                
                // Only include emails from the last 7 days
                if let daysAgo = calendar.dateComponents([.day], from: dayStart, to: today).day,
                   daysAgo >= 0 && daysAgo < 7 {
                    let email = EmailItem(
                        from: detail.from,
                        to: stat.emailAddress,
                        date: detail.date,
                        action: detail.action
                    )
                    emailsByDay[dayStart, default: []].append(email)
                }
            }
        }
        
        // Build sections array for last 7 days (most recent first)
        var sections: [DaySection] = []
        for i in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                let emails = (emailsByDay[date] ?? []).sorted { $0.date > $1.date }
                sections.append(DaySection(date: date, emails: emails))
            }
        }
        return sections
    }
    
    // Aggregate summary counts
    private var summaryStats: (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for section in daySections {
            for email in section.emails {
                switch email.action {
                case .forwarded: forwarded += 1
                case .dropped: dropped += 1
                case .rejected: rejected += 1
                case .unknown: break
                }
            }
        }
        return (forwarded, dropped, rejected)
    }
    
    private var totalEmails: Int {
        daySections.reduce(0) { $0 + $1.emails.count }
    }
    
    @State private var showCopyToast = false
    
    var body: some View {
        List {
            // Summary section - aggregated totals
            Section {
                HStack(spacing: 0) {
                    ActionSummaryBadge(action: .forwarded, count: summaryStats.forwarded)
                    ActionSummaryBadge(action: .dropped, count: summaryStats.dropped)
                    ActionSummaryBadge(action: .rejected, count: summaryStats.rejected)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("7-Day Summary")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(totalEmails)")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            
            // Email list sectioned by day
            ForEach(daySections) { section in
                Section {
                    if section.emails.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "envelope.open")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(Color.secondary.opacity(0.5))
                                Text("No emails")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    } else {
                        ForEach(section.emails) { email in
                            EmailRowView(email: email, isDropAlias: isDropAlias(for: email.to))
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: isToday(section.date) ? "star.fill" : "calendar")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isToday(section.date) ? Color.accentColor : .secondary)
                            Text(dayLabel(for: section.date))
                                .font(.system(.subheadline, design: .rounded, weight: isToday(section.date) ? .semibold : .medium))
                                .foregroundStyle(isToday(section.date) ? Color.accentColor : .secondary)
                        }
                        Spacer()
                        if !section.emails.isEmpty {
                            Text("\(section.emails.count)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(isToday(section.date) ? Color.accentColor : .secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Weekly Overview")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // Format day label
    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
    
    // Check if date is today
    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }
    
    // Summary badge for action counts
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
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: EmailItem
        let isDropAlias: Bool
        @State private var showCopyToast = false
        
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                // Status icon with colored background
                ZStack {
                    Circle()
                        .fill(email.action.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: email.action.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(email.action.color)
                }
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
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                            Text(formatTime(email.date))
                                .font(.system(.caption, design: .rounded, weight: .medium))
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
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("Copied!")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                        }
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

