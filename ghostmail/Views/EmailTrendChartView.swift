import SwiftUI

// Beautiful chart component for email trend visualization
struct EmailTrendChartView: View {
    let statistics: [EmailStatistic]
    var showTotalBadge: Bool = true
    var onDayTapped: ((Date) -> Void)? = nil
    
    private var dailyCounts: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        var countsByDay: [Date: Int] = [:]
        
        // Aggregate all received dates across all email addresses
        for stat in statistics {
            for date in stat.receivedDates {
                let dayStart = calendar.startOfDay(for: date)
                countsByDay[dayStart, default: 0] += 1
            }
        }
        
        // Create array for last 7 days, filling in zeros for days with no emails
        let today = calendar.startOfDay(for: Date())
        var result: [(date: Date, count: Int)] = []
        
        for i in (0..<7).reversed() {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                result.append((date: date, count: countsByDay[date] ?? 0))
            }
        }
        
        return result
    }
    
    private var maxCount: Int {
        dailyCounts.map { $0.count }.max() ?? 1
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Total count badge (optional)
            if showTotalBadge {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Emails")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(dailyCounts.reduce(0) { $0 + $1.count })")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            
            // Chart
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(dailyCounts.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 4) {
                        // Bar
                        Button {
                            if item.count > 0, let onDayTapped = onDayTapped {
                                onDayTapped(item.date)
                            }
                        } label: {
                            ZStack(alignment: .bottom) {
                                // Background bar
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.1))
                                    .frame(height: 120)
                                
                                // Actual value bar with gradient
                                if item.count > 0 {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.accentColor,
                                                    Color.accentColor.opacity(0.7)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(height: max(20, CGFloat(item.count) / CGFloat(maxCount) * 120))
                                        .overlay(
                                            // Count label on bar
                                            Text("\(item.count)")
                                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.bottom, 4)
                                            , alignment: .bottom
                                        )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(item.count == 0 || onDayTapped == nil)
                        
                        // Day label
                        Text(dayLabel(for: item.date))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
        }
        .padding(.vertical, 8)
    }
    
    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
    }
}
