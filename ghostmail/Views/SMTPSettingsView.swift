import SwiftUI

struct SMTPSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var encryption: SMTPEncryption = .starttls
    @State private var showPassword: Bool = false
    @State private var isLoading: Bool = false
    @State private var error: Error?
    @State private var showError: Bool = false
    @State private var showSuccess: Bool = false
    @State private var isTesting: Bool = false
    @State private var showTestSuccess: Bool = false
    @State private var showPlaintextConfirm: Bool = false
    @State private var pendingAction: PendingAction = .none

    private enum PendingAction {
        case none
        case save
        case test
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("SMTP Server", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)

                    Picker("Encryption", selection: $encryption) {
                        Text("Implicit TLS").tag(SMTPEncryption.implicit)
                        Text("STARTTLS").tag(SMTPEncryption.starttls)
                        Text("None (insecure)").tag(SMTPEncryption.none)
                    }
                } header: {
                    Text("Server Settings")
                } footer: {
                    Text("Port 465 is typically Implicit TLS. Port 587 is typically STARTTLS. \"None\" sends your credentials in cleartext and should only be used with a trusted local relay.")
                }

                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    HStack {
                        if showPassword {
                            TextField("Password", text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.password)
                        } else {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                        }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Authentication")
                }

                Section {
                    Button {
                        beginAction(.test)
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || isLoading || !isFormValid)
                } footer: {
                    Text("Test your SMTP credentials before saving")
                }

                if SMTPService.shared.hasSettings() {
                    Section {
                        Button(role: .destructive) {
                            deleteSettings()
                        } label: {
                            Text("Delete Settings")
                        }
                    }
                }
            }
            .navigationTitle("SMTP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        beginAction(.save)
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isLoading || !isFormValid)
                }
            }
            .onChange(of: encryption) { _, newValue in
                // Suggest the conventional port when the user picks an encryption mode,
                // but only if they're currently on one of the well-known defaults.
                guard port == "587" || port == "465" else { return }
                switch newValue {
                case .implicit:
                    port = "465"
                case .starttls:
                    port = "587"
                case .none:
                    break
                }
            }
            .onAppear {
                loadExistingSettings()
            }
            .alert("Error", isPresented: $showError, presenting: error) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
            .alert("Settings Saved", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("SMTP settings have been saved successfully.")
            }
            .alert("Connection Successful", isPresented: $showTestSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Successfully connected and authenticated with the SMTP server.")
            }
            .alert("Send password in cleartext?", isPresented: $showPlaintextConfirm) {
                Button("Cancel", role: .cancel) {
                    pendingAction = .none
                }
                Button("Use Plaintext", role: .destructive) {
                    let action = pendingAction
                    pendingAction = .none
                    switch action {
                    case .save: performSave()
                    case .test: performTest()
                    case .none: break
                    }
                }
            } message: {
                Text("Encryption is set to None. Your username and password will be transmitted to \(host) in cleartext, where any party between this device and the server can read them. Only continue if you trust the network path to this server (for example, a relay on your own machine).")
            }
        }
    }

    private var isFormValid: Bool {
        !host.isEmpty && !username.isEmpty && !password.isEmpty && Int(port) != nil
    }

    private func loadExistingSettings() {
        if let settings = SMTPService.shared.loadSettings() {
            host = settings.host
            port = String(settings.port)
            username = settings.username
            password = settings.password
            encryption = settings.encryption
        }
    }

    private func beginAction(_ action: PendingAction) {
        // For plaintext + password, require a second explicit confirmation each time
        // we'd actually send credentials over the wire (save or test).
        if encryption == .none && !password.isEmpty {
            pendingAction = action
            showPlaintextConfirm = true
            return
        }
        switch action {
        case .save: performSave()
        case .test: performTest()
        case .none: break
        }
    }

    private func performSave() {
        guard let portInt = Int(port) else {
            error = SMTPError.invalidSettings
            showError = true
            return
        }

        let settings = SMTPSettings(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            encryption: encryption
        )

        SMTPService.shared.saveSettings(settings)
        showSuccess = true
    }

    private func deleteSettings() {
        SMTPService.shared.deleteSettings()
        host = ""
        port = "587"
        username = ""
        password = ""
        encryption = .starttls
    }

    private func performTest() {
        guard let portInt = Int(port) else {
            error = SMTPError.invalidSettings
            showError = true
            return
        }

        let settings = SMTPSettings(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portInt,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            encryption: encryption
        )

        isTesting = true

        Task {
            do {
                try await SMTPService.shared.testConnection(settings: settings)
                await MainActor.run {
                    isTesting = false
                    showTestSuccess = true
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    self.error = error
                    showError = true
                }
            }
        }
    }
}
