import Foundation

struct EmailStatistic: Identifiable, Hashable {
    let id = UUID()
    let emailAddress: String
    let count: Int
    let receivedDates: [Date]
}
