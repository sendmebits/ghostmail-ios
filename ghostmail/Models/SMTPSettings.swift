import Foundation

/// Encryption mode for the SMTP connection.
///
/// - `implicit`: TLS is negotiated immediately on connect (SMTPS, typically port 465).
/// - `starttls`: Plain TCP connect, then upgrade to TLS via STARTTLS (typically port 587).
///   The send is aborted (never silently downgraded) if the server does not advertise STARTTLS.
/// - `none`: Plaintext SMTP. Insecure: AUTH credentials are sent in cleartext.
///   Only valid for trusted local relays. Requires explicit user confirmation before saving.
enum SMTPEncryption: String, Codable {
    case implicit
    case starttls
    case none
}

struct SMTPSettings: Codable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var encryption: SMTPEncryption

    init(
        host: String = "",
        port: Int = 587,
        username: String = "",
        password: String = "",
        encryption: SMTPEncryption = .starttls
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encryption = encryption
    }

    var isValid: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty && port > 0
    }

    // MARK: - Codable migration from legacy `useTLS: Bool`
    //
    // Old persisted settings only had `useTLS: Bool`. The mapping is chosen so that
    // the migration NEVER weakens security:
    //   - useTLS == true  -> .implicit (port 465 users keep working unchanged)
    //   - useTLS == false -> .starttls (silently UPGRADES plaintext-on-587 users
    //                                   to STARTTLS; they are not auto-set to .none)
    // The only path to `.none` is an explicit user choice in the settings UI.

    enum CodingKeys: String, CodingKey {
        case host, port, username, password, encryption
        case useTLS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)

        if let stored = try container.decodeIfPresent(SMTPEncryption.self, forKey: .encryption) {
            encryption = stored
        } else if let useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) {
            encryption = useTLS ? .implicit : .starttls
        } else {
            encryption = .starttls
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encode(encryption, forKey: .encryption)
    }
}
