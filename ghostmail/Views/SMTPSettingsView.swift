import SwiftUI

struct SMTPSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useTLS: Bool = true
    @State private var showPassword: Bool = false
    @State private var isLoading: Bool = false
    @State private var error: Error?
    @State private var showError: Bool = false
    @State private var showSuccess: Bool = false
    @State private var isTesting: Bool = false
    @State private var showTestSuccess: Bool = false
    
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
                    
                    Toggle("Use TLS", isOn: $useTLS)
                        .tint(.accentColor)
                } header: {
                    Text("Server Settings")
                } footer: {
                    Text("Use port 587 without TLS, or port 465 with TLS enabled (implicit SSL/TLS)")
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
                        testConnection()
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
                        saveSettings()
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
            .onChange(of: useTLS) { _, newValue in
                // Auto-update port when TLS toggle changes (only if using default ports)
                if port == "587" || port == "465" {
                    port = newValue ? "465" : "587"
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
            useTLS = settings.useTLS
        }
    }
    
    private func saveSettings() {
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
            useTLS: useTLS
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
        useTLS = true
    }
    
    private func testConnection() {
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
            useTLS: useTLS
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


