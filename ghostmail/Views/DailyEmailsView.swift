import SwiftUI
import SwiftData

struct DailyEmailsView: View {
    let date: Date
    let statistics: [EmailStatistic]
    @Query private var emailAliases: [EmailAlias]
    
    private func isDropAlias(for emailAddress: String) -> Bool {
        guard let alias = emailAliases.first(where: { $0.emailAddress == emailAddress }) else {
            return false  // Not an alias at all (catch-all) - not a drop alias
        }
        return alias.actionType != .forward
    }
    
    /// Check if an email address is a catch-all (not defined as any alias)
    private func isCatchAllAddress(_ emailAddress: String) -> Bool {
        !emailAliases.contains { $0.emailAddress == emailAddress }
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
    
    // Filter state for action type
    @State private var selectedActionFilter: EmailRoutingAction? = nil
    
    // Filtered emails based on selected action
    private var filteredEmails: [EmailItem] {
        guard let filter = selectedActionFilter else { return emailsForDay }
        return emailsForDay.filter { $0.action == filter }
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
                                Text("\(filteredEmails.count)/\(emailsForDay.count)")
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text("\(emailsForDay.count)")
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
                        ForEach(filteredEmails) { email in
                            EmailRowView(
                                email: email,
                                isDropAlias: isDropAlias(for: email.to),
                                isCatchAll: isCatchAllAddress(email.to)
                            )
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
    }
    
    // Summary badge for action counts - tappable filter
    private struct ActionSummaryBadge: View {
        let action: EmailRoutingAction
        let count: Int
        let isSelected: Bool
        let hasActiveFilter: Bool
        let onTap: () -> Void
        
        var body: some View {
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                onTap()
            }) {
                VStack(spacing: 8) {
                    // Icon with colored background circle
                    ZStack {
                        Circle()
                            .fill(count > 0 ? action.color.opacity(isSelected ? 0.3 : 0.15) : Color.gray.opacity(0.1))
                            .frame(width: 52, height: 52)
                        
                        // Selection ring
                        if isSelected {
                            Circle()
                                .strokeBorder(action.color, lineWidth: 2.5)
                                .frame(width: 52, height: 52)
                        }
                        
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
                .opacity(hasActiveFilter && !isSelected ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
        }
    }
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: EmailItem
        let isDropAlias: Bool
        let isCatchAll: Bool
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
                            HStack(spacing: 4) {
                                Text(email.to)
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(isDropAlias ? .red : (isCatchAll ? .purple : .primary))
                                    .fixedSize(horizontal: true, vertical: false)
                                
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
                                }
                            }
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
