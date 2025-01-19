import Foundation
import SwiftData

@Model
final class EmailAlias {
    @Attribute(.unique) var id: String
    var emailAddress: String
    var website: String
    var notes: String
    var created: Date?
    var cloudflareTag: String?
    var isEnabled: Bool
    var sortIndex: Int
    var forwardTo: String
    
    init(emailAddress: String, forwardTo: String = "") {
        self.id = UUID().uuidString
        self.emailAddress = emailAddress
        self.website = ""
        self.notes = ""
        self.created = Date()
        self.isEnabled = true
        self.sortIndex = 0
        self.forwardTo = forwardTo
        
        print("EmailAlias initialized - address: \(emailAddress), forward to: \(self.forwardTo)")
    }
} 
