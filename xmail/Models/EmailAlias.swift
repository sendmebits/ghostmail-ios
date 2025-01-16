import Foundation
import SwiftData

@Model
final class EmailAlias {
    @Attribute(.unique) var id: String
    var emailAddress: String
    var website: String = ""
    var notes: String = ""
    var created: Date?
    var cloudflareTag: String?
    var isEnabled: Bool = true
    var sortIndex: Int = 0
    var forwardTo: String = ""
    
    init(emailAddress: String) {
        self.id = UUID().uuidString
        self.emailAddress = emailAddress
        self.website = ""
        self.notes = ""
        self.created = Date()
        self.isEnabled = true
        self.sortIndex = 0
        self.forwardTo = ""
    }
} 
