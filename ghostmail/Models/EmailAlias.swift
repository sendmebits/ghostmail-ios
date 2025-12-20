import Foundation
import SwiftData
import CloudKit

/// The action type for an email routing rule
enum EmailRuleActionType: String, Codable {
    case forward = "forward"
    case drop = "drop"
    case reject = "reject"
    
    var displayName: String {
        switch self {
        case .forward: return "Forward"
        case .drop: return "Drop"
        case .reject: return "Reject"
        }
    }
}

@Model
final class EmailAlias {
    var id: String = UUID().uuidString
    var emailAddress: String = ""
    var website: String = ""
    var notes: String = ""
    var created: Date?
    var cloudflareTag: String?
    var isEnabled: Bool = true
    var sortIndex: Int = 0
    var forwardTo: String = ""
    // The Cloudflare Zone ID this alias belongs to (optional). Used to avoid deleting
    // aliases that belong to a different Cloudflare zone/account.
    var zoneId: String = ""
    var isLoggedOut: Bool = false
    var userIdentifier: String = ""
    /// The action type: forward, drop, or reject. Defaults to "forward" for backward compatibility.
    var actionTypeRaw: String = "forward"
    
    /// Computed property to get/set the action type as an enum
    var actionType: EmailRuleActionType {
        get { EmailRuleActionType(rawValue: actionTypeRaw) ?? .forward }
        set { actionTypeRaw = newValue.rawValue }
    }
    
    init(emailAddress: String, forwardTo: String = "", isManuallyCreated: Bool = false, zoneId: String = "", actionType: EmailRuleActionType = .forward) {
        self.id = UUID().uuidString
        self.emailAddress = emailAddress
        self.website = ""
        self.notes = ""
        self.created = isManuallyCreated ? Date() : nil
        self.isEnabled = true
        self.sortIndex = 0
        self.forwardTo = forwardTo
        self.isLoggedOut = false
        self.userIdentifier = ""
        self.zoneId = zoneId
        self.actionTypeRaw = actionType.rawValue
        
        print("EmailAlias initialized - address: \(emailAddress), action: \(actionType.rawValue), forward to: \(forwardTo)")
    }

    // Remove duplicate aliases by emailAddress while merging useful fields.
    // Returns number of records deleted.
    static func deduplicate(in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<EmailAlias>()
        let all = try context.fetch(descriptor)

        // Group by normalized email address
        let grouped = Dictionary(grouping: all) { $0.emailAddress.lowercased() }

        var deletedCount = 0
        for (_, group) in grouped where group.count > 1 {
            // Choose survivor:
            // 1) Prefer a record with a Cloudflare tag (ties broken by most recent created)
            // 2) Else prefer the one with a created date (most recent)
            // 3) Else fall back to first
            let survivor: EmailAlias =
                group.sorted { a, b in
                    // Prefer entries that look manually created or enriched with metadata
                    let aHasManualOrMetadata = (a.created != nil) || !a.notes.isEmpty || !a.website.isEmpty
                    let bHasManualOrMetadata = (b.created != nil) || !b.notes.isEmpty || !b.website.isEmpty
                    if aHasManualOrMetadata != bHasManualOrMetadata {
                        return aHasManualOrMetadata
                    }

                    // Prefer the one with more metadata fields populated
                    let aMetaCount = (a.notes.isEmpty ? 0 : 1) + (a.website.isEmpty ? 0 : 1)
                    let bMetaCount = (b.notes.isEmpty ? 0 : 1) + (b.website.isEmpty ? 0 : 1)
                    if aMetaCount != bMetaCount { return aMetaCount > bMetaCount }

                    // Then prefer Cloudflare tag presence
                    if (a.cloudflareTag != nil) != (b.cloudflareTag != nil) {
                        return a.cloudflareTag != nil
                    }

                    // Then most recent created date
                    let aDate = a.created ?? Date.distantPast
                    let bDate = b.created ?? Date.distantPast
                    if aDate != bDate { return aDate > bDate }

                    // Stable fallback
                    return a.id < b.id
                }.first!

            // Merge fields from others into survivor where survivor lacks data
            for duplicate in group where duplicate !== survivor {
                if survivor.website.isEmpty && !duplicate.website.isEmpty {
                    survivor.website = duplicate.website
                }
                if survivor.notes.isEmpty && !duplicate.notes.isEmpty {
                    survivor.notes = duplicate.notes
                }
                if survivor.forwardTo.isEmpty && !duplicate.forwardTo.isEmpty {
                    survivor.forwardTo = duplicate.forwardTo
                }
                if survivor.cloudflareTag == nil, let tag = duplicate.cloudflareTag {
                    survivor.cloudflareTag = tag
                }
                if survivor.created == nil, let created = duplicate.created {
                    survivor.created = created
                }
                // Prefer enabled if any duplicate was enabled
                survivor.isEnabled = survivor.isEnabled || duplicate.isEnabled

                // Ensure user identifier is set
                if survivor.userIdentifier.isEmpty && !duplicate.userIdentifier.isEmpty {
                    survivor.userIdentifier = duplicate.userIdentifier
                }

                // If survivor lacks a zoneId but the duplicate has one, prefer that
                if survivor.zoneId.isEmpty && !duplicate.zoneId.isEmpty {
                    survivor.zoneId = duplicate.zoneId
                }

                context.delete(duplicate)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            try context.save()
        }
        return deletedCount
    }
} 
