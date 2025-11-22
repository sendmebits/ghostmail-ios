import SwiftUI

struct EmailStatisticsDetailView: View {
    let statistic: EmailStatistic
    
    var body: some View {
        List {
            Section {
                if statistic.receivedDates.isEmpty {
                    Text("No detailed logs available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(statistic.receivedDates, id: \.self) { date in
                        HStack {
                            Text("Received")
                            Spacer()
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recent Activity")
            } footer: {
                Text("Showing received timestamps for the last 7 days.")
            }
        }
        .navigationTitle(statistic.emailAddress)
        .navigationBarTitleDisplayMode(.inline)
    }
}
