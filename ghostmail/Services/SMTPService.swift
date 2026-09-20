import Foundation
import Network

// Thread-safe wrapper for tracking continuation resumption state
private final class ResumptionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasResumed = false

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasResumed
    }

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

// MARK: - Byte transports

/// Minimal SMTP I/O surface shared by Network.framework (implicit TLS / plaintext)
/// and Foundation streams (STARTTLS in-place upgrade).
private protocol SMTPTransport: AnyObject {
    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void)
    func send(_ data: Data)
    func receive(completion: @escaping (_ data: Data?, _ isComplete: Bool, _ error: Error?) -> Void)
    func startTLS(peerName: String, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}

/// TLS-on-connect and plaintext TCP via `NWConnection`.
/// Used for `.implicit` and `.none` so those working paths stay on Network.framework.
private final class NWSMTPTransport: SMTPTransport {
    private let connection: NWConnection
    private var didBecomeReady = false

    init(host: String, port: Int, useTLS: Bool) {
        let parameters: NWParameters = useTLS
            ? NWParameters(tls: NWProtocolTLS.Options())
            : .tcp
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: parameters
        )
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard self?.didBecomeReady == false else { return }
                self?.didBecomeReady = true
                onReady()
            case .failed:
                onFailure(SMTPError.connectionFailed)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            #if DEBUG
            if let error = error {
                print("Error sending SMTP command: \(error)")
            }
            #endif
        })
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func startTLS(peerName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        _ = peerName
        completion(.failure(SMTPError.starttlsFailed))
    }

    func cancel() {
        connection.cancel()
    }
}

/// Plain TCP via Foundation streams, with RFC 3207 STARTTLS as an in-place TLS upgrade
/// on the same socket (`kCFStreamPropertySSLSettings` after the server's 220 reply).
private final class StreamSMTPTransport: NSObject, SMTPTransport, StreamDelegate {
    private let host: String
    private let port: Int
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var onReady: (() -> Void)?
    private var onFailure: ((Error) -> Void)?
    private var pendingReceive: ((Data?, Bool, Error?) -> Void)?
    private var tlsCompletion: ((Result<Void, Error>) -> Void)?
    private var incomingBuffer = Data()
    private var writeBuffer = Data()
    private var didBecomeReady = false
    private var isHandshaking = false
    private var tlsCompleted = false
    private var isCancelled = false
    private var inputEOF = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        self.queue = DispatchQueue(label: "com.sendmebits.ghostmail.smtp.stream")
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        perform {
            self.onReady = onReady
            self.onFailure = onFailure

            var input: InputStream?
            var output: OutputStream?
            Stream.getStreamsToHost(
                withName: self.host,
                port: self.port,
                inputStream: &input,
                outputStream: &output
            )

            guard let input, let output else {
                onFailure(SMTPError.connectionFailed)
                return
            }

            self.inputStream = input
            self.outputStream = output

            CFReadStreamSetProperty(
                input as CFReadStream,
                CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket),
                kCFBooleanTrue
            )
            CFWriteStreamSetProperty(
                output as CFWriteStream,
                CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket),
                kCFBooleanTrue
            )

            input.delegate = self
            output.delegate = self
            CFReadStreamSetDispatchQueue(input as CFReadStream, self.queue)
            CFWriteStreamSetDispatchQueue(output as CFWriteStream, self.queue)
            input.open()
            output.open()
        }
    }

    func send(_ data: Data) {
        perform {
            self.writeBuffer.append(data)
            self.flushWriteBuffer()
        }
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        perform {
            self.pendingReceive = completion
            if self.inputStream?.hasBytesAvailable == true {
                self.readIntoBuffer()
            }
            self.deliverIfNeeded()
        }
    }

    func startTLS(peerName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        perform {
            guard let input = self.inputStream, let output = self.outputStream else {
                completion(.failure(SMTPError.starttlsFailed))
                return
            }

            self.tlsCompletion = completion
            self.isHandshaking = true
            self.tlsCompleted = false

            let settings: [CFString: Any] = [
                kCFStreamSSLPeerName: peerName as CFString,
                kCFStreamSSLValidatesCertificateChain: kCFBooleanTrue as Any,
                kCFStreamSSLLevel: kCFStreamSocketSecurityLevelNegotiatedSSL
            ]
            let cfSettings = settings as CFDictionary

            // Apply SSL settings to one stream only; CFStream applies it to the pair.
            // Setting both can prevent the in-place handshake from completing.
            let readOK = CFReadStreamSetProperty(
                input as CFReadStream,
                CFStreamPropertyKey(kCFStreamPropertySSLSettings),
                cfSettings
            )
            let writeOK = readOK ? true : CFWriteStreamSetProperty(
                output as CFWriteStream,
                CFStreamPropertyKey(kCFStreamPropertySSLSettings),
                cfSettings
            )

            if !writeOK {
                self.finishTLS(.failure(SMTPError.starttlsFailed))
                return
            }

            // Handshake may complete synchronously; only SSLPeerTrust is a valid
            // success signal here — output may still report space from plaintext.
            self.checkTLSHandshake(allowSpaceAvailable: false)
        }
    }

    func cancel() {
        perform {
            self.isCancelled = true
        }
        // Close streams on a later turn so we never tear down from inside a
        // StreamDelegate callback (CFStream can crash if closed reentrantly).
        queue.async {
            self.tearDown()
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if isCancelled { return }

        if eventCode.contains(.errorOccurred) {
            if isHandshaking {
                finishTLS(.failure(SMTPError.starttlsFailed))
            } else {
                fail(aStream.streamError ?? SMTPError.connectionFailed)
            }
            return
        }

        if eventCode.contains(.endEncountered) {
            if isHandshaking {
                finishTLS(.failure(SMTPError.starttlsFailed))
                return
            }
            inputEOF = true
            deliverIfNeeded()
            return
        }

        if eventCode.contains(.openCompleted) {
            notifyReadyIfNeeded()
        }

        if isHandshaking {
            if eventCode.contains(.hasSpaceAvailable) || eventCode.contains(.hasBytesAvailable) {
                checkTLSHandshake(allowSpaceAvailable: true)
            }
            return
        }

        if eventCode.contains(.hasSpaceAvailable) {
            flushWriteBuffer()
        }

        if eventCode.contains(.hasBytesAvailable) {
            readIntoBuffer()
            deliverIfNeeded()
        }
    }

    // MARK: Stream helpers

    private func perform(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private func notifyReadyIfNeeded() {
        guard !didBecomeReady else { return }
        guard inputStream?.streamStatus == .open, outputStream?.streamStatus == .open else { return }
        didBecomeReady = true
        onReady?()
    }

    private func checkTLSHandshake(allowSpaceAvailable: Bool) {
        guard isHandshaking, let input = inputStream else { return }

        if input.streamStatus == .error || outputStream?.streamStatus == .error {
            finishTLS(.failure(SMTPError.starttlsFailed))
            return
        }

        if CFReadStreamCopyProperty(input as CFReadStream, CFStreamPropertyKey(kCFStreamPropertySSLPeerTrust)) != nil {
            finishTLS(.success(()))
            return
        }

        // A *new* space-available event after SSL settings is the usual signal that
        // the handshake finished and application data can be written.
        if allowSpaceAvailable, outputStream?.hasSpaceAvailable == true {
            finishTLS(.success(()))
        }
    }

    private func finishTLS(_ result: Result<Void, Error>) {
        guard !tlsCompleted else { return }
        tlsCompleted = true
        isHandshaking = false
        let completion = tlsCompletion
        tlsCompletion = nil
        completion?(result)
    }

    private func readIntoBuffer() {
        guard let input = inputStream else { return }
        while input.hasBytesAvailable {
            var buf = [UInt8](repeating: 0, count: 4096)
            let bytesRead = input.read(&buf, maxLength: buf.count)
            if bytesRead > 0 {
                incomingBuffer.append(Data(buf[0..<bytesRead]))
            } else if bytesRead == 0 {
                inputEOF = true
                break
            } else {
                fail(input.streamError ?? SMTPError.connectionFailed)
                break
            }
        }
    }

    private func deliverIfNeeded() {
        guard let callback = pendingReceive else { return }
        if !incomingBuffer.isEmpty {
            let data = incomingBuffer
            incomingBuffer.removeAll(keepingCapacity: true)
            pendingReceive = nil
            callback(data, false, nil)
            return
        }
        if inputEOF {
            pendingReceive = nil
            callback(nil, true, nil)
        }
    }

    private func flushWriteBuffer() {
        guard let output = outputStream, !writeBuffer.isEmpty else { return }
        while !writeBuffer.isEmpty {
            let written: Int = writeBuffer.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: writeBuffer.count)
            }
            if written > 0 {
                writeBuffer.removeFirst(written)
            } else if written == 0 {
                break
            } else {
                fail(output.streamError ?? SMTPError.connectionFailed)
                break
            }
        }
    }

    private func fail(_ error: Error) {
        let callback = pendingReceive
        pendingReceive = nil
        callback?(nil, false, error)
        onFailure?(error)
    }

    private func tearDown() {
        if let input = inputStream {
            CFReadStreamSetDispatchQueue(input as CFReadStream, nil)
            input.delegate = nil
            input.close()
        }
        if let output = outputStream {
            CFWriteStreamSetDispatchQueue(output as CFWriteStream, nil)
            output.delegate = nil
            output.close()
        }
        inputStream = nil
        outputStream = nil
        pendingReceive = nil
        tlsCompletion = nil
        onReady = nil
        onFailure = nil
        writeBuffer.removeAll()
        incomingBuffer.removeAll()
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
            mode: .send(message: message, from: from, to: to)
        )
    }

    func testConnection(settings: SMTPSettings) async throws {
        guard settings.isValid else {
            throw SMTPError.invalidSettings
        }
        try await runSession(settings: settings, mode: .test)
    }

    // MARK: - Session driver

    private enum SessionMode {
        case send(message: String, from: String, to: String)
        case test
    }

    /// Runs one SMTP session.
    ///
    /// `.implicit` and `.none` use Network.framework. `.starttls` uses Foundation
    /// streams so TLS can be negotiated in place on the same TCP connection after
    /// the server replies 220 to STARTTLS (RFC 3207). STARTTLS that is not
    /// advertised by the server is a hard error, never a fallback to plaintext.
    private func runSession(
        settings: SMTPSettings,
        mode: SessionMode
    ) async throws {
        let transport: SMTPTransport
        switch settings.encryption {
        case .implicit:
            transport = NWSMTPTransport(host: settings.host, port: settings.port, useTLS: true)
        case .none:
            transport = NWSMTPTransport(host: settings.host, port: settings.port, useTLS: false)
        case .starttls:
            transport = StreamSMTPTransport(host: settings.host, port: settings.port)
        }

        try await runConnection(
            transport: transport,
            settings: settings,
            mode: mode
        )
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
        transport: SMTPTransport,
        settings: SMTPSettings,
        mode: SessionMode
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var responseBuffer = Data()
            var state: SMTPState = .initial
            var ehloAdvertisesSTARTTLS = false
            var needsSTARTTLSUpgrade = settings.encryption == .starttls
            let resumptionGuard = ResumptionGuard()

            func finish() {
                if resumptionGuard.tryResume() {
                    transport.cancel()
                    continuation.resume(returning: ())
                }
            }

            func fail(_ error: Error) {
                if resumptionGuard.tryResume() {
                    transport.cancel()
                    continuation.resume(throwing: error)
                }
            }

            func receiveData() {
                transport.receive { data, isComplete, error in
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
                                transport: transport,
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
                                finish()
                                return
                            case .startTLS:
                                transport.startTLS(peerName: settings.host) { result in
                                    guard !resumptionGuard.hasResumed else { return }
                                    switch result {
                                    case .success:
                                        needsSTARTTLSUpgrade = false
                                        self.sendCommand("EHLO localhost\r\n", transport: transport)
                                        state = .ehloSent
                                        receiveData()
                                    case .failure:
                                        fail(SMTPError.starttlsFailed)
                                    }
                                }
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

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                fail(SMTPError.timedOut)
            }

            transport.start(
                onReady: {
                    guard !resumptionGuard.hasResumed else { return }
                    receiveData()
                },
                onFailure: { error in
                    fail(error)
                }
            )
        }
    }

    private enum ResponseOutcome {
        case stayOpen
        case completedSession
        case startTLS
    }

    /// Processes the next complete SMTP response (one or more `XYZ-…` continuation
    /// lines followed by a `XYZ ` final line) and advances the state machine.
    private func processResponse(
        response: String,
        state: inout SMTPState,
        advertisesSTARTTLS: inout Bool,
        needsSTARTTLSUpgrade: Bool,
        transport: SMTPTransport,
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
            sendCommand("EHLO localhost\r\n", transport: transport)
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
                sendCommand("STARTTLS\r\n", transport: transport)
                state = .starttlsSent
                return .stayOpen
            }

            // Already secure (implicit TLS, post-STARTTLS upgrade) or `.none`.
            sendCommand("AUTH LOGIN\r\n", transport: transport)
            state = .authLoginSent
            return .stayOpen

        case .starttlsSent:
            guard statusCode == 220 else { throw SMTPError.starttlsFailed }
            // Upgrade TLS on this same connection, then EHLO again (RFC 3207).
            return .startTLS

        case .authLoginSent:
            guard statusCode == 334 else { throw SMTPError.authenticationFailed }
            let usernameB64 = Data(settings.username.utf8).base64EncodedString()
            sendCommand("\(usernameB64)\r\n", transport: transport)
            state = .authUsernameSent
            return .stayOpen

        case .authUsernameSent:
            guard statusCode == 334 else { throw SMTPError.authenticationFailed }
            let passwordB64 = Data(settings.password.utf8).base64EncodedString()
            sendCommand("\(passwordB64)\r\n", transport: transport)
            state = .authPasswordSent
            return .stayOpen

        case .authPasswordSent:
            guard statusCode == 235 else { throw SMTPError.authenticationFailed }
            switch mode {
            case .test:
                sendCommand("QUIT\r\n", transport: transport)
                state = .quitSent
                return .completedSession
            case .send(_, let from, _):
                sendCommand("MAIL FROM:<\(from)>\r\n", transport: transport)
                state = .mailFromSent
                return .stayOpen
            }

        case .mailFromSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            switch mode {
            case .send(_, _, let to):
                sendCommand("RCPT TO:<\(to)>\r\n", transport: transport)
                state = .rcptToSent
                return .stayOpen
            case .test:
                throw SMTPError.sendFailed
            }

        case .rcptToSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            sendCommand("DATA\r\n", transport: transport)
            state = .dataStarted
            return .stayOpen

        case .dataStarted:
            guard statusCode == 354 else { throw SMTPError.sendFailed }
            switch mode {
            case .send(let message, _, _):
                sendCommand(prepareDATAPayload(message), transport: transport)
                state = .messageSent
                return .stayOpen
            case .test:
                throw SMTPError.sendFailed
            }

        case .messageSent:
            guard statusCode == 250 else { throw SMTPError.sendFailed }
            sendCommand("QUIT\r\n", transport: transport)
            state = .quitSent
            return .completedSession

        case .quitSent:
            return .completedSession
        }
    }

    private func sendCommand(_ command: String, transport: SMTPTransport) {
        let data = command.data(using: .utf8)!
        transport.send(data)
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

    /// Prepares a message for inclusion in an SMTP DATA command. Normalizes line
    /// endings to CRLF (RFC 5321 §4.1.1.4), applies dot-stuffing so a body line
    /// beginning with "." cannot be misread as the end-of-data marker (§4.5.2),
    /// and appends the `<CRLF>.<CRLF>` terminator.
    private func prepareDATAPayload(_ message: String) -> String {
        let normalized = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")

        var stuffed = normalized.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if stuffed.hasPrefix(".") {
            stuffed = "." + stuffed
        }

        return stuffed + "\r\n.\r\n"
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
    case timedOut
    case starttlsUnsupported(host: String, port: Int)
    case starttlsFailed
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "SMTP settings are invalid or incomplete"
        case .connectionFailed:
            return "Failed to connect to SMTP server"
        case .timedOut:
            return "The SMTP server did not respond in time"
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
