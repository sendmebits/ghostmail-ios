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
        /// The actual recipient address (may include plus-addressing like aaa+tag@domain.com)
        /// When nil, the email was sent directly to the base address
        let originalTo: String?
        
        /// The plus-addressed tag portion (e.g., "newsletter" for aaa+newsletter@domain.com)
        /// Returns nil if no plus-addressing was used
        var plusTag: String? {
            guard let to = originalTo,
                  let atIndex = to.firstIndex(of: "@"),
                  let plusIndex = to.firstIndex(of: "+"),
                  plusIndex < atIndex else {
                return nil
            }
            return String(to[to.index(after: plusIndex)..<atIndex])
        }
        
        init(from: String, date: Date, action: EmailRoutingAction = .forwarded, originalTo: String? = nil) {
            self.from = from
            self.date = date
            self.action = action
            self.originalTo = originalTo
        }
    }
}
