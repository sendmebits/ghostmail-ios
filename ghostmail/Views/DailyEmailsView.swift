import SwiftUI

struct DailyEmailsView: View {
    let date: Date
    let statistics: [EmailStatistic]
    @State private var selectedEmailAddress: String?
    @State private var showEmailDetail = false
    
    private var emailsForDay: [(email: String, count: Int)] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        
        var emailCounts: [String: Int] = [:]
        
        for stat in statistics {
            let datesOnDay = stat.receivedDates.filter { receivedDate in
                calendar.isDate(receivedDate, inSameDayAs: dayStart)
            }
            if !datesOnDay.isEmpty {
                emailCounts[stat.emailAddress] = datesOnDay.count
            }
        }
        
        return emailCounts.map { (email: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
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
                    Text("No emails received on this day")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(emailsForDay, id: \.email) { item in
                        Button {
                            selectedEmailAddress = item.email
                            showEmailDetail = true
                        } label: {
                            HStack {
                                Text(item.email)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(item.count)")
                                    .font(.monospacedDigit(.body)())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Emails Received")
                } footer: {
                    Text("Total: \(emailsForDay.reduce(0) { $0 + $1.count }) emails")
                }
            }
        }
        .navigationTitle(formattedDate)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showEmailDetail) {
            if let emailAddress = selectedEmailAddress,
               let statistic = statistics.first(where: { $0.emailAddress == emailAddress }) {
                DailyEmailDetailView(date: date, statistic: statistic)
            }
        }
    }
}
