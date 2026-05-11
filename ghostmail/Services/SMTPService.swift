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
            #if DEBUG
            print("Error saving SMTP settings: \(error)")
            #endif
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
            #if DEBUG
            print("Error loading SMTP settings: \(error)")
            #endif
            return nil
        }
    }

    func hasSettings() -> Bool {
        return loadSettings() != nil
    }

    func deleteSettings() {
        KeychainHelper.shared.delete(service: keychainService, account: keychainAccount)
    }

    // MARK: - Public send / test entry points

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

        let message = createEmailMessage(from: from, to: to, subject: subject, body: body)
        try await runSession(
            settings: settings,
            mode: .send(message: message, from: from, to: to),
            tlsAlreadyUpgraded: false
        )
    }

    func testConnection(settings: SMTPSettings) async throws {
        guard settings.isValid else {
            throw SMTPError.invalidSettings
        }
        try await runSession(settings: settings, mode: .test, tlsAlreadyUpgraded: false)
    }

    // MARK: - Session driver

    private enum SessionMode {
        case send(message: String, from: String, to: String)
        case test
    }

    /// Runs one SMTP session over a single `NWConnection`.
    ///
    /// If the encryption mode is `.starttls` and the connection has not yet been
    /// upgraded, the session may complete the STARTTLS handshake and return,
    /// signalling that this method should be invoked again with TLS established.
    /// In all other cases the session runs to completion (or aborts with an error).
    ///
    /// Critical guarantee: this code never silently downgrades. STARTTLS that is
    /// not advertised by the server is a hard error, never a fallback to plaintext.
    private func runSession(
        settings: SMTPSettings,
        mode: SessionMode,
        tlsAlreadyUpgraded: Bool
    ) async throws {
        let parameters: NWParameters
        let isTLSConnection: Bool

        if tlsAlreadyUpgraded {
            // Second pass after a STARTTLS upgrade: connect with TLS this time.
            parameters = NWParameters(tls: NWProtocolTLS.Options())
            isTLSConnection = true
        } else {
            switch settings.encryption {
            case .implicit:
                parameters = NWParameters(tls: NWProtocolTLS.Options())
                isTLSConnection = true
            case .starttls, .none:
                parameters = .tcp
                isTLSConnection = false
            }
        }

        let host = NWEndpoint.Host(settings.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(settings.port))
        let connection = NWConnection(host: host, port: port, using: parameters)

        // The session may either complete normally or finish at the STARTTLS
        // handshake, in which case it returns `.upgradedToTLS` and the caller
        // re-runs the session with TLS established.
        let outcome = try await runConnection(
            connection: connection,
            settings: settings,
            mode: mode,
            tlsAlreadyEstablished: isTLSConnection
        )

        switch outcome {
        case .completed:
            return
        case .upgradedToTLS:
            try await runSession(settings: settings, mode: mode, tlsAlreadyUpgraded: true)
        }
    }

    private enum SessionOutcome {
        case completed
        case upgradedToTLS
    }

    private enum SMTPState {
        case initial
        case ehloSent
        case starttlsSent
        case authLoginSent
        case authUsernameSent
        case authPasswordSent
        case mailFromSent
        case rcptToSent
        case dataStarted
        case messageSent
        case quitSent
    }

    private func runConnection(
        connection: NWConnection,
        settings: SMTPSettings,
        mode: SessionMode,
        tlsAlreadyEstablished: Bool
    ) async throws -> SessionOutcome {
        return try await withCheckedThrowingContinuation { continuation in
            var responseBuffer = Data()
            var state: SMTPState = .initial
            var ehloAdvertisesSTARTTLS = false
            let resumptionGuard = ResumptionGuard()

            // Whether THIS connection still needs to perform a STARTTLS upgrade.
            // True only for `.starttls` mode on a connection that is not yet TLS.
            let needsSTARTTLSUpgrade = settings.encryption == .starttls && !tlsAlreadyEstablished

            func finish(_ outcome: SessionOutcome) {
                if resumptionGuard.tryResume() {
                    connection.cancel()
                    continuation.resume(returning: outcome)
                }
            }

            func fail(_ error: Error) {
                if resumptionGuard.tryResume() {
                    connection.cancel()
                    continuation.resume(throwing: error)
                }
            }

            func receiveData() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if error != nil {
                        fail(SMTPError.connectionFailed)
                        return
                    }

                    if let data = data {
                        responseBuffer.append(data)
                        let response = String(data: responseBuffer, encoding: .utf8) ?? ""

                        do {
                            let outcome = try self.processResponse(
                                response: response,
                                state: &state,
                                advertisesSTARTTLS: &ehloAdvertisesSTARTTLS,
                                needsSTARTTLSUpgrade: needsSTARTTLSUpgrade,
                                connection: connection,
                                settings: settings,
                                mode: mode,
                                hostName: settings.host,
                                port: settings.port,
                                bufferConsumed: { responseBuffer = Data() }
                            )

                            switch outcome {
                            case .stayOpen:
                                break
                            case .completedSession:
                                finish(.completed)
                                return
                            case .upgradedToTLS:
                                finish(.upgradedToTLS)
                                return
                            }
                        } catch {
                            fail(error)
                            return
                        }
                    }

                    if !isComplete {
                        receiveData()
                    }
                }
            }

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    receiveData()
                case .failed(_):
                    fail(SMTPError.connectionFailed)
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: .global())
        }
    }

    private enum ResponseOutcome {
        case stayOpen
        case completedSession
        case upgradedToTLS
    }

    /// Processes the next complete SMTP response (one or more `XYZ-…` continuation
    /// lines followed by a `XYZ ` final line) and advances the state machine.
    private func processResponse(
        response: String,
        state: inout SMTPState,
        advertisesSTARTTLS: inout Bool,
        needsSTARTTLSUpgrade: Bool,
        connection: NWConnection,
        settings: SMTPSettings,
        mode: SessionMode,
        hostName: String,
        port: Int,
        bufferConsumed: () -> Void
    ) throws -> ResponseOutcome {
        let allLines = response.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let lastLine = allLines.last else { return .stayOpen }

        // Each SMTP response line begins with a 3-digit status code. The final
        // line of a multi-line response uses a space after the code; intermediate
        // lines use a hyphen. We must wait for the final line before reacting.
        let code = String(lastLine.prefix(3))
        guard let statusCode = Int(code), (200...599).contains(statusCode) else {
            return .stayOpen
        }
        let isFinalLine = lastLine.count == 3 ||
            (lastLine.count > 3 && lastLine[lastLine.index(lastLine.startIndex, offsetBy: 3)] == " ")
        guard isFinalLine else { return .stayOpen }

        defer { bufferConsumed() }

        switch state {
        case .initial:
            guard statusCode == 220 else { throw SMTPError.connectionFailed }
            sendCommand("EHLO localhost\r\n", connection: connection)
            state = .ehloSent
            return .stayOpen

        case .ehloSent:
            guard statusCode == 250 else { throw SMTPError.connectionFailed }

            // Scan EHLO capabilities for STARTTLS. RFC 5321 capability lines
            // come in as "250-CAPABILITY" with the final one as "250 CAPABILITY".
            advertisesSTARTTLS = allLines.contains { line in
                guard line.hasPrefix("250") else { return false }
                let body = line.dropFirst(3).drop { $0 == " " || $0 == "-" }
                return body.uppercased().hasPrefix("STARTTLS")
            }

            if needsSTARTTLSUpgrade {
                guard advertisesSTARTTLS else {
                    throw SMTPError.starttlsUnsupported(host: hostName, port: port)
                }
                sendCommand("STARTTLS\r\n", connection: connection)
                state = .starttlsSent
                return .stayOpen
            }

            // Already secure (implicit TLS, post-STARTTLS upgrade) or `.none`.
            sendCommand("AUTH LOGIN\r\n", connection: connection)
            state = .authLoginSent
            return .stayOpen

        case .starttlsSent:
            guard statusCode == 220 else { throw SMTPError.starttlsFailed }
            // The current connection's protocol is finished. Signal the outer
            // driver to reconnect with TLS and run a fresh EHLO + AUTH session.
            return .upgradedToTLS

        case .authLoginSent:
            guard statusCode == 334 else { throw SMTPError.authenticationFailed }
            let usernameB64 = Data(settings.username.utf8).base64EncodedString()
            sendCommand("\(usernameB64)\r\n", connection: connection)
            state = .authUsernameSent
            return .stayOpen

        case .authUsernameSent:
            guard statusCode == 334 else { throw SMTPError.authenticationFailed }
            let passwordB64 = Data(settings.password.utf8).base64EncodedString()
            sendCommand("\(passwordB64)\r\n", connection: connection)
            state = .authPasswordSent
            return .stayOpen

        case .authPasswordSent:
            guard statusCode == 235 else { throw SMTPError.authenticationFailed }
            switch mode {
            case .test:
                sendCommand("QUIT\r\n", connection: connection)
                state = .quitSent
                return .completedSession
            case .send(_, let from, _):
                sendCommand("MAIL FROM:<\(from)>\r\n", connection: connection)
                state = .mailFromSent
                return .stayOpen
            }

        case .mailFromSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            switch mode {
            case .send(_, _, let to):
                sendCommand("RCPT TO:<\(to)>\r\n", connection: connection)
                state = .rcptToSent
                return .stayOpen
            case .test:
                throw SMTPError.sendFailed
            }

        case .rcptToSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            sendCommand("DATA\r\n", connection: connection)
            state = .dataStarted
            return .stayOpen

        case .dataStarted:
            guard statusCode == 354 else { throw SMTPError.sendFailed }
            switch mode {
            case .send(let message, _, _):
                sendCommand("\(message)\r\n.\r\n", connection: connection)
                state = .messageSent
                return .stayOpen
            case .test:
                throw SMTPError.sendFailed
            }

        case .messageSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            sendCommand("QUIT\r\n", connection: connection)
            state = .quitSent
            return .completedSession

        case .quitSent:
            return .completedSession
        }
    }

    private func sendCommand(_ command: String, connection: NWConnection) {
        let data = command.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { error in
            #if DEBUG
            if let error = error {
                print("Error sending SMTP command: \(error)")
            }
            #endif
        })
    }

    private func createEmailMessage(from: String, to: String, subject: String, body: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let dateString = dateFormatter.string(from: Date())

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
        if header.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{00}"..."\u{7F}").inverted) != nil {
            return "=?UTF-8?B?\(Data(header.utf8).base64EncodedString())?="
        }
        return header
    }
}

enum SMTPError: LocalizedError {
    case invalidSettings
    case connectionFailed
    case authenticationFailed
    case sendFailed
    case starttlsUnsupported(host: String, port: Int)
    case starttlsFailed
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
        case .starttlsUnsupported(let host, let port):
            return "Server \(host) does not advertise STARTTLS on port \(port). Sending was cancelled to protect your password. Open SMTP Settings and switch encryption to Implicit TLS or None (insecure)."
        case .starttlsFailed:
            return "STARTTLS upgrade failed. Sending was cancelled to protect your password."
        case .notImplemented(let message):
            return message
        }
    }
}
