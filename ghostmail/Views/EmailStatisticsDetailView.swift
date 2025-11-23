import SwiftUI

struct EmailStatisticsDetailView: View {
    let statistic: EmailStatistic
    
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
            
            if statistic.emailDetails.isEmpty {
                Section {
                    Text("No detailed logs available.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(emailsByDate, id: \.date) { group in
                    Section {
                        ForEach(group.emails, id: \.self) { detail in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(detail.from)
                                    .font(.body)
                                Text(detail.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
