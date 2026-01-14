import Foundation
import Network

// Thread-safe wrapper for tracking continuation resumption state
private final class ResumptionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasResumed = false
    
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _hasResumed {
            return false
        }
        _hasResumed = true
        return true
    }
}

class SMTPService: @unchecked Sendable {
    static let shared = SMTPService()
    private let keychainService = "com.sendmebits.ghostmail.smtp"
    private let keychainAccount = "smtp_settings"
    
    private init() {}
    
    func saveSettings(_ settings: SMTPSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            KeychainHelper.shared.save(data, service: keychainService, account: keychainAccount)
        } catch {
            print("Error saving SMTP settings: \(error)")
        }
    }
    
    func loadSettings() -> SMTPSettings? {
        guard let data = KeychainHelper.shared.read(service: keychainService, account: keychainAccount) else {
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(SMTPSettings.self, from: data)
        } catch {
            print("Error loading SMTP settings: \(error)")
            return nil
        }
    }
    
    func hasSettings() -> Bool {
        return loadSettings() != nil
    }
    
    func deleteSettings() {
        KeychainHelper.shared.delete(service: keychainService, account: keychainAccount)
    }
    
    func sendEmail(
        from: String,
        to: String,
        subject: String,
        body: String,
        settings: SMTPSettings
    ) async throws {
        guard settings.isValid else {
            throw SMTPError.invalidSettings
        }
        
        // Validate email addresses to prevent injection
        guard isValidEmailAddress(from) else {
            throw SMTPError.invalidSettings
        }
        guard isValidEmailAddress(to) else {
            throw SMTPError.invalidSettings
        }
        
        // Create the email message in RFC 2822 format
        let message = createEmailMessage(from: from, to: to, subject: subject, body: body)
        
        // Use Network framework to connect and send via SMTP
        try await sendViaSMTP(settings: settings, message: message, from: from, to: to)
    }
    
    private func sendViaSMTP(settings: SMTPSettings, message: String, from: String, to: String) async throws {
        let host = NWEndpoint.Host(settings.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(settings.port))
        
        // Configure TLS parameters if enabled
        let parameters: NWParameters
        if settings.useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            // Enable certificate verification for security
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) {
                    sec_protocol_verify_complete(true)
                } else {
                    print("SMTP TLS certificate verification failed: \(error?.localizedDescription ?? "unknown error")")
                    sec_protocol_verify_complete(false)
                }
            }, DispatchQueue.global())
            
            // Set minimum TLS version to 1.2 for security
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = .tcp
        }
        
        let connection = NWConnection(host: host, port: port, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            var responseBuffer = Data()
            var state: SMTPState = .initial
            let resumptionGuard = ResumptionGuard()
            
            func receiveData() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                    guard let self = self else { return }
                    
                    if error != nil {
                        if resumptionGuard.tryResume() {
                            continuation.resume(throwing: SMTPError.connectionFailed)
                        }
                        return
                    }
                    
                    if let data = data {
                        responseBuffer.append(data)
                        let response = String(data: responseBuffer, encoding: .utf8) ?? ""
                        
                        // Process SMTP response
                        do {
                            if let newState = try self.processSMTPResponse(response: response, currentState: state, connection: connection, settings: settings, message: message, from: from, to: to) {
                                state = newState
                                responseBuffer = Data()
                                
                                if state == .completed {
                                    connection.cancel()
                                    if resumptionGuard.tryResume() {
                                        continuation.resume()
                                    }
                                    return
                                } else if state == .error {
                                    connection.cancel()
                                    if resumptionGuard.tryResume() {
                                        continuation.resume(throwing: SMTPError.sendFailed)
                                    }
                                    return
                                }
                            }
                        } catch {
                            connection.cancel()
                            if resumptionGuard.tryResume() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                    }
                    
                    if !isComplete {
                        receiveData() // Continue receiving
                    }
                }
            }
            
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    // Connection established, start receiving
                    receiveData()
                case .failed(_):
                    if resumptionGuard.tryResume() {
                        continuation.resume(throwing: SMTPError.connectionFailed)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
    
    // Test SMTP connection and authentication
    func testConnection(settings: SMTPSettings) async throws {
        guard settings.isValid else {
            throw SMTPError.invalidSettings
        }
        
        let host = NWEndpoint.Host(settings.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(settings.port))
        
        // Configure TLS parameters if enabled
        let parameters: NWParameters
        if settings.useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            // Enable certificate verification for security
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                var error: CFError?
                if SecTrustEvaluateWithError(trust, &error) {
                    sec_protocol_verify_complete(true)
                } else {
                    print("SMTP TLS certificate verification failed: \(error?.localizedDescription ?? "unknown error")")
                    sec_protocol_verify_complete(false)
                }
            }, DispatchQueue.global())
            
            // Set minimum TLS version to 1.2 for security
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = .tcp
        }
        
        let connection = NWConnection(host: host, port: port, using: parameters)
        
        return try await withCheckedThrowingContinuation { continuation in
            var responseBuffer = Data()
            var state: SMTPState = .initial
            let resumptionGuard = ResumptionGuard()
            
            func receiveData() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                    guard let self = self else { return }
                    
                    if error != nil {
                        if resumptionGuard.tryResume() {
                            continuation.resume(throwing: SMTPError.connectionFailed)
                        }
                        return
                    }
                    
                    if let data = data {
                        responseBuffer.append(data)
                        let response = String(data: responseBuffer, encoding: .utf8) ?? ""
                        
                        // Process SMTP response for authentication test
                        do {
                            if let newState = try self.processTestResponse(response: response, currentState: state, connection: connection, settings: settings) {
                                state = newState
                                responseBuffer = Data()
                                
                                // Test is complete after successful authentication
                                if state == .authPasswordSent {
                                    connection.cancel()
                                    if resumptionGuard.tryResume() {
                                        continuation.resume()
                                    }
                                    return
                                } else if state == .error {
                                    connection.cancel()
                                    if resumptionGuard.tryResume() {
                                        continuation.resume(throwing: SMTPError.authenticationFailed)
                                    }
                                    return
                                }
                            }
                        } catch {
                            connection.cancel()
                            if resumptionGuard.tryResume() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                    }
                    
                    if !isComplete {
                        receiveData() // Continue receiving
                    }
                }
            }
            
            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    // Connection established, start receiving
                    receiveData()
                case .failed(_):
                    if resumptionGuard.tryResume() {
                        continuation.resume(throwing: SMTPError.connectionFailed)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
        }
    }
    
    private func processTestResponse(
        response: String,
        currentState: SMTPState,
        connection: NWConnection,
        settings: SMTPSettings
    ) throws -> SMTPState? {
        let lines = response.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        
        guard let lastLine = lines.last else { return nil }
        
        let code = String(lastLine.prefix(3))
        guard let statusCode = Int(code), (200...599).contains(statusCode) else { return nil }
        
        let isComplete = lastLine.count == 3 || (lastLine.count > 3 && lastLine[lastLine.index(lastLine.startIndex, offsetBy: 3)] == " ")
        
        guard isComplete else { return nil }
        
        switch currentState {
        case .initial:
            if statusCode == 220 {
                sendCommand("EHLO localhost\r\n", connection: connection)
                return .ehloSent
            } else {
                throw SMTPError.connectionFailed
            }
            
        case .ehloSent:
            if statusCode == 250 {
                // Proceed directly to authentication
                sendCommand("AUTH LOGIN\r\n", connection: connection)
                return .authenticated
            } else {
                throw SMTPError.connectionFailed
            }
            
        case .authenticated:
            if statusCode == 334 {
                let usernameB64 = Data(settings.username.utf8).base64EncodedString()
                sendCommand("\(usernameB64)\r\n", connection: connection)
                return .authUsernameSent
            } else {
                return .error
            }
            
        case .authUsernameSent:
            if statusCode == 334 {
                let passwordB64 = Data(settings.password.utf8).base64EncodedString()
                sendCommand("\(passwordB64)\r\n", connection: connection)
                return .authPasswordSent
            } else {
                throw SMTPError.authenticationFailed
            }
            
        case .authPasswordSent:
            if statusCode == 235 {
                // Authentication successful - test complete
                sendCommand("QUIT\r\n", connection: connection)
                return .authPasswordSent
            } else {
                throw SMTPError.authenticationFailed
            }
            
        default:
            break
        }
        
        if statusCode >= 400 {
            throw SMTPError.authenticationFailed
        }
        
        return nil
    }
    
    private enum SMTPState {
        case initial
        case ehloSent
        case authenticated
        case authUsernameSent
        case authPasswordSent
        case mailFromSent
        case rcptToSent
        case dataStarted
        case messageSent
        case completed
        case error
    }
    
    private func processSMTPResponse(
        response: String,
        currentState: SMTPState,
        connection: NWConnection,
        settings: SMTPSettings,
        message: String,
        from: String,
        to: String
    ) throws -> SMTPState? {
        let lines = response.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        
        guard let lastLine = lines.last else { return nil }
        
        // Check if response is complete (starts with 3-digit code and may have continuation)
        let code = String(lastLine.prefix(3))
        guard let statusCode = Int(code), (200...599).contains(statusCode) else { return nil }
        
        let isComplete = lastLine.count == 3 || (lastLine.count > 3 && lastLine[lastLine.index(lastLine.startIndex, offsetBy: 3)] == " ")
        
        guard isComplete else { return nil } // Wait for more data
        
        switch currentState {
        case .initial:
            if statusCode == 220 {
                // Server ready, send EHLO
                sendCommand("EHLO localhost\r\n", connection: connection)
                return .ehloSent
            } else {
                throw SMTPError.connectionFailed
            }
            
        case .ehloSent:
            if statusCode == 250 {
                // Proceed directly to authentication
                sendCommand("AUTH LOGIN\r\n", connection: connection)
                return .authenticated
            } else {
                throw SMTPError.connectionFailed
            }
            
        case .authenticated:
            if statusCode == 334 {
                // Server asking for username
                let usernameB64 = Data(settings.username.utf8).base64EncodedString()
                sendCommand("\(usernameB64)\r\n", connection: connection)
                return .authUsernameSent
            } else {
                return .error
            }
            
        case .authUsernameSent:
            if statusCode == 334 {
                // Server asking for password
                let passwordB64 = Data(settings.password.utf8).base64EncodedString()
                sendCommand("\(passwordB64)\r\n", connection: connection)
                return .authPasswordSent
            } else {
                throw SMTPError.authenticationFailed
            }
            
        case .authPasswordSent:
            if statusCode == 235 {
                // Authentication successful, send MAIL FROM
                sendCommand("MAIL FROM:<\(from)>\r\n", connection: connection)
                return .mailFromSent
            } else {
                throw SMTPError.authenticationFailed
            }
            
        case .mailFromSent:
            if statusCode == 250 {
                // MAIL FROM accepted, send RCPT TO
                sendCommand("RCPT TO:<\(to)>\r\n", connection: connection)
                return .rcptToSent
            } else {
                throw SMTPError.sendFailed
            }
            
        case .rcptToSent:
            if statusCode == 250 {
                // RCPT TO accepted, send DATA
                sendCommand("DATA\r\n", connection: connection)
                return .dataStarted
            } else {
                throw SMTPError.sendFailed
            }
            
        case .dataStarted:
            if statusCode == 354 {
                // Ready to receive message - end message with \r\n.\r\n
                sendCommand("\(message)\r\n.\r\n", connection: connection)
                return .messageSent
            } else {
                throw SMTPError.sendFailed
            }
            
        case .messageSent:
            if statusCode == 250 {
                // Message accepted, quit
                sendCommand("QUIT\r\n", connection: connection)
                return .completed
            } else {
                throw SMTPError.sendFailed
            }
            
        default:
            break
        }
        
        // If we get an error code, throw
        if statusCode >= 400 {
            throw SMTPError.sendFailed
        }
        
        return nil
    }
    
    private func sendCommand(_ command: String, connection: NWConnection) {
        let data = command.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Error sending SMTP command: \(error)")
            }
        })
    }
    
    private func createEmailMessage(from: String, to: String, subject: String, body: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let dateString = dateFormatter.string(from: Date())
        
        // Encode subject if it contains non-ASCII characters
        let encodedSubject = encodeHeader(subject)
        
        var message = "Date: \(dateString)\r\n"
        message += "From: \(from)\r\n"
        message += "To: \(to)\r\n"
        message += "Subject: \(encodedSubject)\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: 8bit\r\n"
        message += "\r\n"
        message += body
        message += "\r\n"
        
        return message
    }
    
    private func encodeHeader(_ header: String) -> String {
        // Simple encoding - if contains non-ASCII, use base64
        if header.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{00}"..."\u{7F}").inverted) != nil {
            return "=?UTF-8?B?\(Data(header.utf8).base64EncodedString())?="
        }
        return header
    }
    
    /// Validates email address format to prevent injection attacks
    private func isValidEmailAddress(_ email: String) -> Bool {
        let emailPattern = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailPattern)
        return emailPredicate.evaluate(with: email)
    }
}

enum SMTPError: LocalizedError {
    case invalidSettings
    case connectionFailed
    case authenticationFailed
    case sendFailed
    case notImplemented(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "SMTP settings are invalid or incomplete"
        case .connectionFailed:
            return "Failed to connect to SMTP server"
        case .authenticationFailed:
            return "SMTP authentication failed"
        case .sendFailed:
            return "Failed to send email"
        case .notImplemented(let message):
            return message
        }
    }
}

