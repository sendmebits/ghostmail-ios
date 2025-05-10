import Foundation
import SwiftData
import CloudKit

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
    var isLoggedOut: Bool = false
    var iCloudSyncDisabled: Bool = false
    var userIdentifier: String = ""
    
    init(emailAddress: String, forwardTo: String = "", isManuallyCreated: Bool = false) {
        self.id = UUID().uuidString
        self.emailAddress = emailAddress
        self.website = ""
        self.notes = ""
        self.created = isManuallyCreated ? Date() : nil
        self.isEnabled = true
        self.sortIndex = 0
        self.forwardTo = forwardTo
        self.isLoggedOut = false
        self.iCloudSyncDisabled = false
        self.userIdentifier = ""
        
        print("EmailAlias initialized - address: \(emailAddress), forward to: \(forwardTo)")
    }
    
    static func isEmailAddressUnique(_ emailAddress: String, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<EmailAlias>(
            predicate: #Predicate<EmailAlias> { alias in
                alias.emailAddress == emailAddress
            }
        )
        
        do {
            let matches = try context.fetch(descriptor)
            return matches.isEmpty
        } catch {
            print("Error checking email uniqueness: \(error)")
            return false
        }
    }
    
    // Helper method to get stable identifier for CloudKit
    static func stableIdentifier(for emailAddress: String) -> String {
        return "alias_\(emailAddress.lowercased())"
    }
    
    // Helper method to mark aliases as not syncing to iCloud
    static func disableSyncForAll(in context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<EmailAlias>()
            let allAliases = try context.fetch(descriptor)
            
            var changesMade = false
            for alias in allAliases {
                if !alias.iCloudSyncDisabled {
                    alias.iCloudSyncDisabled = true
                    changesMade = true
                }
            }
            
            if changesMade {
                try context.save()
                print("Successfully marked \(allAliases.count) aliases as not syncing to iCloud")
            } else {
                print("No changes needed: all \(allAliases.count) aliases already marked as not syncing")
            }
        } catch {
            print("Error marking aliases as not syncing: \(error)")
            
            // Try to fetch and update in smaller batches if the main approach failed
            do {
                let descriptor = FetchDescriptor<EmailAlias>(predicate: #Predicate<EmailAlias> { alias in
                    !alias.iCloudSyncDisabled
                })
                let aliasesToUpdate = try context.fetch(descriptor)
                
                if aliasesToUpdate.isEmpty {
                    print("No aliases need updating")
                    return
                }
                
                // Update in smaller batches
                let batchSize = 10
                for i in stride(from: 0, to: aliasesToUpdate.count, by: batchSize) {
                    let endIndex = min(i + batchSize, aliasesToUpdate.count)
                    let batch = aliasesToUpdate[i..<endIndex]
                    
                    for alias in batch {
                        alias.iCloudSyncDisabled = true
                    }
                    
                    try context.save()
                    print("Updated batch \(i/batchSize + 1): marked \(batch.count) aliases as not syncing")
                }
            } catch {
                print("Failed to update aliases in batches: \(error)")
            }
        }
    }
    
    // Helper method to enable sync for all aliases
    static func enableSyncForAll(in context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<EmailAlias>()
            let allAliases = try context.fetch(descriptor)
            
            for alias in allAliases {
                alias.iCloudSyncDisabled = false
            }
            
            try context.save()
        } catch {
            print("Error enabling sync for aliases: \(error)")
        }
    }
    
    // Helper method to set user identifier for all aliases
    static func setUserIdentifier(_ identifier: String, in context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<EmailAlias>()
            let allAliases = try context.fetch(descriptor)
            
            for alias in allAliases {
                if alias.userIdentifier.isEmpty {
                    alias.userIdentifier = identifier
                }
            }
            
            try context.save()
        } catch {
            print("Error setting user identifier for aliases: \(error)")
        }
    }
} 
