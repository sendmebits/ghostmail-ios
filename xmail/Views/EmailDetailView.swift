import SwiftUI
import SwiftData

struct EmailDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @Bindable private var email: EmailAlias
    
    // Use @State for temporary edits
    @State private var tempWebsite: String
    @State private var tempNotes: String
    @State private var tempIsEnabled: Bool
    @State private var tempForwardTo: String
    @State private var tempUsername: String = ""
    
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var showDeleteConfirmation = false
    
    init(email: EmailAlias) {
        print("Initializing DetailView with email: \(email.emailAddress), forward to: \(email.forwardTo)")
        self.email = email
        _tempWebsite = State(initialValue: email.website)
        _tempNotes = State(initialValue: email.notes)
        _tempIsEnabled = State(initialValue: email.isEnabled)
        _tempForwardTo = State(initialValue: email.forwardTo)
        
        print("DetailView initialized with tempForwardTo: \(email.forwardTo)")
        
        // Extract username from email address
        if let username = email.emailAddress.split(separator: "@").first {
            _tempUsername = State(initialValue: String(username))
        } else {
            _tempUsername = State(initialValue: "")
        }
    }
    
    private var formattedCreatedDate: String {
        guard let created = email.created else {
            return "Created by Cloudflare"
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: created)
    }
    
    private func copyToClipboard(_ text: String) {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
        UIPasteboard.general.string = text
        toastMessage = "Copied to clipboard"
        withAnimation {
            showToast = true
        }
    }
    
    private var fullEmailAddress: String {
        "\(tempUsername)@\(cloudflareClient.emailDomain)"
    }
    
    var body: some View {
        Form {
            Section("Email Address") {
                if isEditing {
                    HStack {
                        TextField("username", text: $tempUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                        Text("@\(cloudflareClient.emailDomain)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(email.emailAddress)
                            .strikethrough(!email.isEnabled)
                        Spacer()
                        Button {
                            copyToClipboard(email.emailAddress)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            Section("Destination") {
                if isEditing {
                    if !cloudflareClient.forwardingAddresses.isEmpty {
                        Picker("Forward to", selection: $tempForwardTo) {
                            ForEach(Array(cloudflareClient.forwardingAddresses), id: \.self) { address in
                                Text(address).tag(address)
                            }
                        }
                    } else {
                        Text("No forwarding addresses available")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(email.forwardTo.isEmpty ? "Not specified" : email.forwardTo)
                }
            }
            
            Section("Status") {
                if isEditing {
                    Toggle("Enabled", isOn: $tempIsEnabled)
                } else {
                    HStack {
                        Text("Enabled")
                        Spacer()
                        Toggle("", isOn: .constant(email.isEnabled))
                            .disabled(true)
                    }
                }
            }
            
            if isEditing || !email.website.isEmpty {
                Section("Website") {
                    if isEditing {
                        TextField("Website", text: $tempWebsite)
                    } else {
                        Text(email.website)
                    }
                }
            }
            
            if isEditing || !email.notes.isEmpty {
                Section("Notes") {
                    if isEditing {
                        TextField("Notes", text: $tempNotes, axis: .vertical)
                            .lineLimit(3...6)
                    } else {
                        Text(email.notes)
                    }
                }
            }
            
            Section("Created") {
                Text(formattedCreatedDate)
            }
            
            if isEditing {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete Email Alias")
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("Email Details")
        .opacity(email.isEnabled ? 1.0 : 0.8)
        .onAppear {
            print("View appeared with forward to: \(email.forwardTo)")  // Debug print
            let parts = email.emailAddress.split(separator: "@")
            tempUsername = String(parts[0])
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Save" : "Edit") {
                    if isEditing {
                        Task {
                            await saveChanges()
                        }
                    }
                    withAnimation {
                        if !isEditing {
                            let parts = email.emailAddress.split(separator: "@")
                            tempUsername = String(parts[0])
                            tempWebsite = email.website
                            tempNotes = email.notes
                            tempIsEnabled = email.isEnabled
                            tempForwardTo = email.forwardTo
                        }
                        isEditing.toggle()
                    }
                }
            }
        }
        .disabled(isLoading)
        .alert("Error Saving Changes", isPresented: $showError, presenting: error) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .toast(isShowing: $showToast, message: toastMessage)
        .alert("Delete Email Alias", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteEmailAlias()
                }
            }
        } message: {
            Text("Are you sure you want to delete this email alias? This action cannot be undone.")
        }
    }
    
    private func deleteEmailAlias() async {
        isLoading = true
        
        do {
            if let tag = email.cloudflareTag {
                try await cloudflareClient.deleteEmailRule(tag: tag)
                modelContext.delete(email)
                try modelContext.save()
                dismiss()
            }
        } catch {
            self.error = error
            self.showError = true
        }
        
        isLoading = false
    }
    
    private func saveChanges() async {
        isLoading = true
        
        do {
            // Update the model with temporary values
            email.emailAddress = fullEmailAddress
            email.website = tempWebsite
            email.notes = tempNotes
            email.isEnabled = tempIsEnabled
            email.forwardTo = tempForwardTo
            
            // Save to SwiftData
            try modelContext.save()
            
            // Update Cloudflare with email-related changes and enabled state
            if let tag = email.cloudflareTag {
                try await cloudflareClient.updateEmailRule(
                    tag: tag,
                    emailAddress: fullEmailAddress,
                    isEnabled: tempIsEnabled,
                    forwardTo: tempForwardTo
                )
            }
        } catch {
            self.error = error
            self.showError = true
            
            // Reset temp values on error
            let parts = email.emailAddress.split(separator: "@")
            tempUsername = String(parts[0])
            tempWebsite = email.website
            tempNotes = email.notes
            tempIsEnabled = email.isEnabled
            tempForwardTo = email.forwardTo
        }
        
        isLoading = false
    }
} 
