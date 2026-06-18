import SwiftUI
import SwiftData

// File-scoped types so section building can run off the main actor (nested types
// inside a @MainActor View inherit main-actor isolation and can't be built in Task.detached).
private struct WeeklyEmailItem: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let date: Date
    let action: EmailRoutingAction
    let originalTo: String?

    var plusTag: String? {
        guard let original = originalTo,
              let atIndex = original.firstIndex(of: "@"),
              let plusIndex = original.firstIndex(of: "+"),
              plusIndex < atIndex else {
            return nil
        }
        return String(original[original.index(after: plusIndex)..<atIndex])
    }
}

private struct WeeklyDaySection: Identifiable {
    let date: Date
    let emails: [WeeklyEmailItem]

    var id: Date { date }
}

private func buildWeeklyDaySections(from statistics: [EmailStatistic]) -> [WeeklyDaySection] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    var emailsByDay: [Date: [WeeklyEmailItem]] = [:]

    for stat in statistics {
        for detail in stat.emailDetails {
            let dayStart = calendar.startOfDay(for: detail.date)

            if let daysAgo = calendar.dateComponents([.day], from: dayStart, to: today).day,
               daysAgo >= 0 && daysAgo < 7 {
                let email = WeeklyEmailItem(
                    from: detail.from,
                    to: stat.emailAddress,
                    date: detail.date,
                    action: detail.action,
                    originalTo: detail.originalTo
                )
                emailsByDay[dayStart, default: []].append(email)
            }
        }
    }

    var sections: [WeeklyDaySection] = []
    for i in 0..<7 {
        if let date = calendar.date(byAdding: .day, value: -i, to: today) {
            let emails = (emailsByDay[date] ?? []).sorted { $0.date > $1.date }
            sections.append(WeeklyDaySection(date: date, emails: emails))
        }
    }
    return sections
}

/// Aggregated view showing all emails from the last 7 days in a single scrollable list
struct WeeklyEmailsView: View {
    let statistics: [EmailStatistic]
    // Plain @Query (no predicate). A predicate-based @Query constructed at
    // navigation time can stall against an actively-mirroring CloudKit store;
    // logged-out aliases are filtered in-memory where the lookup is built.
    @Query private var emailAliases: [EmailAlias]
    
    // Sections are built once (off the main thread) and stored here so that the
    // generated item ids stay stable across re-renders.
    @State private var loadedSections: [WeeklyDaySection] = []
    @State private var didLoad = false

    // Bound the number of rows rendered per day so a heavy (e.g. catch-all) day
    // can't generate tens of thousands of List rows and stall the main thread.
    private let perDayRowLimit = 300
    
    // Aggregate summary counts
    private func summaryStats(for sections: [WeeklyDaySection]) -> (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for section in sections {
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
    
    private func totalEmails(in sections: [WeeklyDaySection]) -> Int {
        sections.reduce(0) { $0 + $1.emails.count }
    }
    
    // Filter state for action type
    @State private var selectedActionFilter: EmailRoutingAction? = nil
    
    // Navigation state for email detail (moved from row to parent)
    @State private var selectedAlias: EmailAlias? = nil
    @State private var navigateToDetail = false
    
    // Filtered sections based on selected action
    private func filteredSections(from sections: [WeeklyDaySection]) -> [WeeklyDaySection] {
        guard let filter = selectedActionFilter else { return sections }
        return sections.map { section in
            WeeklyDaySection(
                date: section.date,
                emails: section.emails.filter { $0.action == filter }
            )
        }
    }
    
    // Filtered total count
    private func filteredTotalEmails(in sections: [WeeklyDaySection]) -> Int {
        sections.reduce(0) { $0 + $1.emails.count }
    }
    
    @State private var showCopyToast = false
    
    var body: some View {
        let sections = loadedSections
        let filteredSections = filteredSections(from: sections)
        let totalEmails = totalEmails(in: sections)
        let filteredTotalEmails = filteredTotalEmails(in: filteredSections)
        let summaryStats = summaryStats(for: sections)
        let aliasLookup = EmailAliasLookup(emailAliases.filter { !$0.isLoggedOut })
        
        List {
            // Summary section - aggregated totals
            Section {
                HStack(spacing: 0) {
                    ActionSummaryBadge(
                        action: .forwarded,
                        count: summaryStats.forwarded,
                        isSelected: selectedActionFilter == .forwarded,
                        hasActiveFilter: selectedActionFilter != nil
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedActionFilter = selectedActionFilter == .forwarded ? nil : .forwarded
                        }
                    }
                    ActionSummaryBadge(
                        action: .dropped,
                        count: summaryStats.dropped,
                        isSelected: selectedActionFilter == .dropped,
                        hasActiveFilter: selectedActionFilter != nil
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedActionFilter = selectedActionFilter == .dropped ? nil : .dropped
                        }
                    }
                    ActionSummaryBadge(
                        action: .rejected,
                        count: summaryStats.rejected,
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
                        // Show filtered count when filter is active
                        if selectedActionFilter != nil {
                            Text("\(filteredTotalEmails)/\(totalEmails)")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("\(totalEmails)")
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            
            // Email list sectioned by day
            ForEach(filteredSections) { section in
                Section {
                    if section.emails.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "envelope.open")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(Color.secondary.opacity(0.5))
                                Text(selectedActionFilter != nil ? "No \(selectedActionFilter!.label.lowercased()) emails" : "No emails")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    } else {
                        ForEach(section.emails.prefix(perDayRowLimit)) { email in
                            let alias = aliasLookup.alias(for: email.to)
                            let isCatchAll = aliasLookup.isCatchAllAddress(email.to)
                            
                            EmailRowView(
                                email: email,
                                isDropAlias: aliasLookup.isDropAlias(for: email.to),
                                isCatchAll: isCatchAll,
                                alias: !isCatchAll ? alias : nil,
                                onTapAlias: { tappedAlias in
                                    selectedAlias = tappedAlias
                                    navigateToDetail = true
                                }
                            )
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                        }
                        if section.emails.count > perDayRowLimit {
                            Text("+ \(section.emails.count - perDayRowLimit) more on this day")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.secondary)
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
        .overlay {
            if !didLoad {
                ProgressView()
            }
        }
        .navigationDestination(isPresented: $navigateToDetail) {
            if let alias = selectedAlias {
                EmailDetailView(email: alias, needsRefresh: .constant(false))
            }
        }
        .task {
            guard !didLoad else { return }
            let stats = statistics
            let built = await Task.detached(priority: .userInitiated) {
                buildWeeklyDaySections(from: stats)
            }.value
            loadedSections = built
            didLoad = true
        }
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
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: WeeklyEmailItem
        let isDropAlias: Bool
        let isCatchAll: Bool
        let alias: EmailAlias?
        let onTapAlias: (EmailAlias) -> Void  // Callback for navigation
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
                    // From line
                    HStack(alignment: .top, spacing: 6) {
                        Text("From:")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(email.from)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // To line
                    HStack(alignment: .top, spacing: 6) {
                        Text("To:")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(email.to)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(isDropAlias ? .red : (isCatchAll ? .purple : .primary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
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
                                .fixedSize()
                        }
                    }
                    
                    // Date/Time, Plus-tag, and Status line
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                            Text(formatTime(email.date))
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        
                        // Plus-address tag badge (moved to metadata row for better visibility)
                        if let plusTag = email.plusTag {
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
                    Pasteboard.copySensitive(email.from)
                    let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                    showCopyToast = true
                } label: {
                    Label("Copy Sender", systemImage: "doc.on.doc")
                }
                Button {
                    Pasteboard.copySensitive(email.to)
                    let g = UIImpactFeedbackGenerator(style: .light); g.impactOccurred()
                    showCopyToast = true
                } label: {
                    Label("Copy Recipient", systemImage: "doc.on.doc")
                }
            }
            .onLongPressGesture {
                Pasteboard.copySensitive(email.from)
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
            .onTapGesture {
                if let alias = alias {
                    onTapAlias(alias)
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

