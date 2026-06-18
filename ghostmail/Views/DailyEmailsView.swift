import SwiftUI
import SwiftData

// File-scoped builder so email aggregation can run off the main actor (static
// methods on a @MainActor View remain main-actor isolated in Swift 6).
private func buildDailyEmails(for date: Date, from statistics: [EmailStatistic]) -> [EmailLogItem] {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)

    var allEmails: [EmailLogItem] = []

    for stat in statistics {
        let emailsOnDay = stat.emailDetails.filter { detail in
            calendar.isDate(detail.date, inSameDayAs: dayStart)
        }

        for detail in emailsOnDay {
            allEmails.append(EmailLogItem(
                from: detail.from,
                to: stat.emailAddress,
                date: detail.date,
                action: detail.action,
                originalTo: detail.originalTo
            ))
        }
    }

    return allEmails.sorted { $0.date > $1.date }
}

struct DailyEmailsView: View {
    let date: Date
    let statistics: [EmailStatistic]
    // Plain @Query (no predicate). A predicate-based @Query constructed at
    // navigation time can stall against an actively-mirroring CloudKit store;
    // logged-out aliases are filtered in-memory where the lookup is built.
    @Query private var emailAliases: [EmailAlias]
    
    // Emails are built once (off the main thread) and stored here so the generated
    // EmailLogItem ids stay stable across re-renders. Recomputing them in `body`
    // regenerated UUIDs every pass, forcing SwiftUI to rebuild every row and
    // potentially hanging the main thread on large datasets.
    @State private var dayEmails: [EmailLogItem] = []
    @State private var didLoad = false

    // Bound the number of rows rendered so a heavy (e.g. catch-all) day can't
    // generate tens of thousands of List rows and stall the main thread.
    private let rowLimit = 500
    
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
    private func actionSummary(for emails: [EmailLogItem]) -> (forwarded: Int, dropped: Int, rejected: Int) {
        var forwarded = 0, dropped = 0, rejected = 0
        for email in emails {
            switch email.action {
            case .forwarded: forwarded += 1
            case .dropped: dropped += 1
            case .rejected: rejected += 1
            case .unknown: break
            }
        }
        return (forwarded, dropped, rejected)
    }
    
    // Filter state for action type
    @State private var selectedActionFilter: EmailRoutingAction? = nil
    
    // Navigation state for email detail (moved from row to parent)
    @State private var selectedAlias: EmailAlias? = nil
    @State private var navigateToDetail = false
    
    // Filtered emails based on selected action
    private func filteredEmails(from emails: [EmailLogItem]) -> [EmailLogItem] {
        guard let filter = selectedActionFilter else { return emails }
        return emails.filter { $0.action == filter }
    }
    
    var body: some View {
        let dayEmails = self.dayEmails
        let filteredEmails = filteredEmails(from: dayEmails)
        let actionSummary = actionSummary(for: dayEmails)
        let aliasLookup = EmailAliasLookup(emailAliases.filter { !$0.isLoggedOut })
        
        List {
            if dayEmails.isEmpty {
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
                        HStack(spacing: 5) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("Summary")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            // Show filtered count when filter is active
                            if selectedActionFilter != nil {
                                Text("\(filteredEmails.count)/\(dayEmails.count)")
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text("\(dayEmails.count)")
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                
                Section {
                    if filteredEmails.isEmpty && selectedActionFilter != nil {
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
                    } else {
                        ForEach(filteredEmails.prefix(rowLimit)) { email in
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
                        if filteredEmails.count > rowLimit {
                            Text("+ \(filteredEmails.count - rowLimit) more")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "tray.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(selectedActionFilter != nil ? "\(selectedActionFilter!.label) Emails" : "Emails Received")
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(filteredEmails.count)")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(formattedDate)
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
            let day = date
            let built = await Task.detached(priority: .userInitiated) {
                buildDailyEmails(for: day, from: stats)
            }.value
            self.dayEmails = built
            didLoad = true
        }
    }
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: EmailLogItem
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
