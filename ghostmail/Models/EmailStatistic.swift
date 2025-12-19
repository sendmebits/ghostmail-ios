import Foundation
import SwiftUI

/// Represents the action/status of an email in Cloudflare Email Routing
enum EmailRoutingAction: String, Codable, Hashable {
    case forwarded = "forward"
    case dropped = "drop"
    case rejected = "reject"
    case unknown = "unknown"
    
    /// Human-readable label for the action
    var label: String {
        switch self {
        case .forwarded: return "Forwarded"
        case .dropped: return "Dropped"
        case .rejected: return "Rejected"
        case .unknown: return "Unknown"
        }
    }
    
    /// SF Symbol icon name for the action
    var iconName: String {
        switch self {
        case .forwarded: return "checkmark.circle.fill"
        case .dropped: return "minus.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    
    /// Color for the action indicator
    var color: Color {
        switch self {
        case .forwarded: return .green
        case .dropped: return .orange
        case .rejected: return .red
        case .unknown: return .gray
        }
    }
    
    /// Initialize from Cloudflare API action string (case-insensitive)
    init(from apiValue: String) {
        let normalized = apiValue.lowercased()
        if normalized.contains("forward") {
            self = .forwarded
        } else if normalized.contains("drop") {
            self = .dropped
        } else if normalized.contains("reject") {
            self = .rejected
        } else {
            self = .unknown
        }
    }
}

struct EmailStatistic: Identifiable, Hashable {
    let id = UUID()
    let emailAddress: String
    let count: Int
    let receivedDates: [Date]
    let emailDetails: [EmailDetail]
    
    struct EmailDetail: Hashable {
        let from: String
        let date: Date
        let action: EmailRoutingAction
        
        init(from: String, date: Date, action: EmailRoutingAction = .forwarded) {
            self.from = from
            self.date = date
            self.action = action
        }
    }
}
