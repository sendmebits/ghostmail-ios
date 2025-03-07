import Foundation
import SwiftData

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
} 
