import SwiftUI
import UIKit

// MARK: - Shared Data Types

/// Represents a single email log entry for display in statistics views
struct EmailLogItem: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let date: Date
    let action: EmailRoutingAction
}

// MARK: - Shared Helper Functions

extension Array where Element == EmailAlias {
    /// Check if an alias exists and is not a forward action (drop/reject)
    func isDropAlias(for emailAddress: String) -> Bool {
        guard let alias = first(where: { $0.emailAddress == emailAddress }) else {
            return false  // Not an alias at all (catch-all) - not a drop alias
        }
        return alias.actionType != .forward
    }
    
    /// Check if an email address is catch-all (not defined as any alias)
    func isCatchAllAddress(_ emailAddress: String) -> Bool {
        !contains { $0.emailAddress == emailAddress }
    }
    
    /// Get the action type for an email address (defaults to forward)
    func actionType(for emailAddress: String) -> EmailRuleActionType {
        first(where: { $0.emailAddress == emailAddress })?.actionType ?? .forward
    }
}

// MARK: - Date Formatting Helpers

extension Date {
    /// Format date for email statistics headers (Today, Yesterday, or medium date style)
    var emailStatisticsDateHeader: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return "Today"
        } else if calendar.isDateInYesterday(self) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: self)
        }
    }
    
    /// Format time only (e.g., "3:45 PM")
    var emailTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - Shared ActionSummaryBadge View

/// Tappable filter badge showing action counts (Forwarded/Dropped/Rejected)
struct ActionSummaryBadge: View {
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
