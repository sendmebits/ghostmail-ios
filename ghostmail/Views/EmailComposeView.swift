import SwiftUI

struct EmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFromEmail: String
    let availableEmails: [String]
    
    @State private var to: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var isLoading: Bool = false
    @State private var error: Error?
    @State private var showError: Bool = false
    @State private var showSuccess: Bool = false
    @State private var searchText = ""
    
    init(fromEmail: String, availableEmails: [String] = []) {
        _selectedFromEmail = State(initialValue: fromEmail)
        self.availableEmails = availableEmails
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !availableEmails.isEmpty {
                        FromAddressSelector(
                            selectedFromEmail: $selectedFromEmail,
                            availableEmails: availableEmails
                        )
                    } else {
                        Text(selectedFromEmail)
                            .foregroundStyle(.secondary)
                    }
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
    
    private var filteredFromEmails: [String] {
        if searchText.isEmpty {
            return availableEmails
        } else {
            return availableEmails.filter { $0.localizedCaseInsensitiveContains(searchText) }
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
                    from: selectedFromEmail,
                    to: to.trimmingCharacters(in: .whitespacesAndNewlines),
                    subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                    settings: settings
                )
                
                // Save the used email as the last used one
                UserDefaults.standard.set(selectedFromEmail, forKey: "lastUsedFromEmail")
                
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

struct FromAddressSelector: View {
    @Binding var selectedFromEmail: String
    let availableEmails: [String]
    
    var body: some View {
        NavigationLink {
            FromAddressSelectionList(selectedFromEmail: $selectedFromEmail, availableEmails: availableEmails)
        } label: {
            HStack {
                Text(selectedFromEmail)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct FromAddressSelectionList: View {
    @Binding var selectedFromEmail: String
    let availableEmails: [String]
    @State private var localSearchText: String = ""
    @State private var isSearching = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let filtered: [String] = localSearchText.isEmpty 
            ? availableEmails
            : availableEmails.filter { email in
                email.localizedCaseInsensitiveContains(localSearchText)
            }
        
        List {
            ForEach(Array(filtered.enumerated()), id: \.element) { index, email in
                Button(action: {
                    selectedFromEmail = email
                    dismiss()
                }) {
                    HStack {
                        Text(email)
                            .foregroundStyle(.primary)
                        if email == selectedFromEmail {
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .searchable(text: $localSearchText, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Select From Address")
        .onAppear {
            isSearching = true
        }
    }
}


