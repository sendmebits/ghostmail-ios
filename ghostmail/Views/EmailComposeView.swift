import SwiftUI

struct EmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let fromEmail: String
    @State private var to: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var isLoading: Bool = false
    @State private var error: Error?
    @State private var showError: Bool = false
    @State private var showSuccess: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fromEmail)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("From")
                }
                
                Section {
                    TextField("To", text: $to)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                } header: {
                    Text("To")
                }
                
                Section {
                    TextField("Subject", text: $subject)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Subject")
                }
                
                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 200)
                } header: {
                    Text("Body")
                }
            }
            .navigationTitle("Send Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        sendEmail()
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(isLoading || !isFormValid)
                }
            }
            .alert("Error", isPresented: $showError, presenting: error) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
            .alert("Email Sent", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your email has been sent successfully.")
            }
        }
    }
    
    private var isFormValid: Bool {
        !to.isEmpty && !subject.isEmpty && !bodyText.isEmpty
    }
    
    private func sendEmail() {
        guard let settings = SMTPService.shared.loadSettings() else {
            error = SMTPError.invalidSettings
            showError = true
            return
        }
        
        guard settings.isValid else {
            error = SMTPError.invalidSettings
            showError = true
            return
        }
        
        isLoading = true
        
        Task {
            do {
                try await SMTPService.shared.sendEmail(
                    from: fromEmail,
                    to: to.trimmingCharacters(in: .whitespacesAndNewlines),
                    subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                    settings: settings
                )
                
                await MainActor.run {
                    isLoading = false
                    showSuccess = true
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    self.error = error
                    self.showError = true
                }
            }
        }
    }
}


