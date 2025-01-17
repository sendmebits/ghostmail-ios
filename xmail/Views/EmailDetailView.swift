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
    
    @Environment(\.displayScale) private var displayScale
    
    init(email: EmailAlias) {
        self.email = email
        // Initialize temporary values with existing values
        _tempWebsite = State(initialValue: email.website)
        _tempNotes = State(initialValue: email.notes)
        _tempIsEnabled = State(initialValue: email.isEnabled)
        _tempForwardTo = State(initialValue: email.forwardTo)
    }
    
    private var formattedCreatedDate: String {
        guard let created = email.created else {
            return "N/A"
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: created)
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        // In a production app, you might want to show a brief toast/notification here
    }
    
    var body: some View {
        Form {
            Section("Email Address") {
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
                    if !email.forwardTo.isEmpty {
                        Text(email.forwardTo)
                    } else {
                        Text("Not specified")
                            .foregroundStyle(.secondary)
                    }
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
            
            Section("Website") {
                if isEditing {
                    TextField("Website", text: $tempWebsite)
                } else {
                    HStack {
                        Text(email.website.isEmpty ? "Not specified" : email.website)
                        if !email.website.isEmpty {
                            Spacer()
                            Button {
                                copyToClipboard(email.website)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            
            Section("Notes") {
                if isEditing {
                    TextField("Notes", text: $tempNotes, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    HStack {
                        Text(email.notes.isEmpty ? "No notes" : email.notes)
                        if !email.notes.isEmpty {
                            Spacer()
                            Button {
                                copyToClipboard(email.notes)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            
            Section("Created") {
                Text(formattedCreatedDate)
            }
        }
        .navigationTitle("Email Details")
        .opacity(email.isEnabled ? 1.0 : 0.8)
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
                            print("Starting edit with notes: \(email.notes)")  // Debug print
                            // Reset temp values when starting to edit
                            tempWebsite = email.website
                            tempNotes = email.notes
                            tempIsEnabled = email.isEnabled
                        }
                        isEditing.toggle()
                    }
                }
            }
        }
        .onAppear {
            print("View appeared with notes: \(email.notes)")  // Debug print
        }
        .disabled(isLoading)
        .alert("Error Saving Changes", isPresented: $showError, presenting: error) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
    }
    
    private func saveChanges() async {
        isLoading = true
        print("Saving changes. Current notes: \(tempNotes)")  // Debug print
        
        do {
            // Update the model with temporary values
            email.website = tempWebsite
            email.notes = tempNotes
            email.isEnabled = tempIsEnabled
            email.forwardTo = tempForwardTo
            
            // Save to SwiftData
            try modelContext.save()
            print("Saved to SwiftData")  // Debug print
            
            // Update Cloudflare with email-related changes and enabled state
            if let tag = email.cloudflareTag {
                try await cloudflareClient.updateEmailRule(
                    tag: tag,
                    emailAddress: email.emailAddress,
                    isEnabled: tempIsEnabled,
                    forwardTo: tempForwardTo
                )
            }
        } catch {
            self.error = error
            self.showError = true
            
            // Reset temp values on error
            tempWebsite = email.website
            tempNotes = email.notes
            tempIsEnabled = email.isEnabled
        }
        
        isLoading = false
    }
} 
