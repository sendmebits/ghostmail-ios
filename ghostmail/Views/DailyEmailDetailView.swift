import SwiftUI

struct DailyEmailDetailView: View {
    let date: Date
    let statistic: EmailStatistic
    
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
    
    var body: some View {
        List {
            if emailsForDay.isEmpty {
                Section {
                    Text("No detailed logs available for this day")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(emailsForDay, id: \.self) { detail in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail.from)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(detail.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
    }
}
