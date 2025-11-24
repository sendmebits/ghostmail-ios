import Foundation

struct SMTPSettings: Codable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var useTLS: Bool
    
    init(host: String = "", port: Int = 587, username: String = "", password: String = "", useTLS: Bool = true) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useTLS = useTLS
    }
    
    var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty && port > 0
    }
}


