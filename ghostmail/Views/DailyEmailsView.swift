import SwiftUI

struct DailyEmailsView: View {
    let date: Date
    let statistics: [EmailStatistic]
    
    // Structure to hold individual email information
    private struct EmailItem: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let date: Date
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
                    date: detail.date
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
                Section {
                    ForEach(emailsForDay) { email in
                        EmailRowView(email: email)
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
    
    // Individual email row view
    private struct EmailRowView: View {
        let email: EmailItem
        @State private var showCopyToast = false
        
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                // Single envelope icon for the email
                Image(systemName: "envelope.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 20)
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
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Date/Time line
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(formatTime(email.date))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
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
