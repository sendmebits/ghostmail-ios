import SwiftUI
import SwiftData
import UIKit

struct EmailDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @State private var showCopyToast = false
    @State private var copiedText = ""
    @State private var websiteUIImage: UIImage?
    @State private var isLoadingIcon = false
    @Bindable private var email: EmailAlias
    @Binding var needsRefresh: Bool
    
    // Use @State for temporary edits
    @State private var tempWebsite: String
    @State private var tempNotes: String
    @State private var tempIsEnabled: Bool
    @State private var tempForwardTo: String
    @State private var tempUsername: String = ""
    
    @State private var showDeleteConfirmation = false
    @State private var toastWorkItem: DispatchWorkItem?
    
    init(email: EmailAlias, needsRefresh: Binding<Bool>) {
        print("Initializing DetailView with email: \(email.emailAddress), forward to: \(email.forwardTo)")
        self.email = email
        self._needsRefresh = needsRefresh
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
    
    private func showToastWithTimer(_ text: String) {
        // Cancel any existing timer
        toastWorkItem?.cancel()
        
        // Show the new toast
        copiedText = text
        showCopyToast = true
        
        // Create and save new timer
        let workItem = DispatchWorkItem {
            withAnimation {
                showCopyToast = false
            }
        }
        toastWorkItem = workItem
        
        // Schedule the new timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
    
    private func copyToClipboard(_ text: String) {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        UIPasteboard.general.string = text
        showToastWithTimer(text)
    }
    
    private var fullEmailAddress: String {
        "\(tempUsername)@\(cloudflareClient.emailDomain)"
    }
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header with email icon
                    VStack(spacing: 16) {
                        // Icon area: mirror the logic used in EmailRowView
                        ZStack {
                            if cloudflareClient.shouldShowWebsiteLogos && !email.website.isEmpty {
                                if let uiImage = websiteUIImage {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else if isLoadingIcon {
                                    ProgressView()
                                        .frame(width: 64, height: 64)
                                } else {
                                    Image(systemName: "globe")
                                        .font(.system(size: 48, weight: .medium))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 64, height: 64)
                                }
                            } else {
                                if !email.website.isEmpty {
                                    Image(systemName: "globe")
                                        .font(.system(size: 48, weight: .medium))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 64, height: 64)
                                } else {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 48, weight: .medium))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 64, height: 64)
                                }
                            }
                        }
                        .padding(.top, 20)
                        .task(id: email.website) {
                            websiteUIImage = nil
                            guard !email.website.isEmpty, cloudflareClient.shouldShowWebsiteLogos else { return }
                            isLoadingIcon = true
                            if let img = await IconCache.shared.image(for: email.website) {
                                websiteUIImage = img
                            } else {
                                websiteUIImage = nil
                            }
                            isLoadingIcon = false
                        }
                        
                        VStack(spacing: 8) {
                            if isEditing {
                                VStack(spacing: 4) {
                                    TextField("username", text: $tempUsername)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .keyboardType(.emailAddress)
                                        .textContentType(.username)
                                        .multilineTextAlignment(.center)
                                        .font(.system(.title2, design: .rounded, weight: .medium))
                                        .padding(8)
                                        .background(Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .padding(.horizontal)
                                    
                                    Text("@\(cloudflareClient.emailDomain)")
                                        .foregroundStyle(.primary)
                                        .font(.system(.title2, design: .rounded, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            } else {
                                Text(email.emailAddress)
                                    .font(.system(.title2, design: .rounded, weight: .medium))
                                    .multilineTextAlignment(.center)
                                    .strikethrough(!email.isEnabled)
                            }
                            
                            Button {
                                copyToClipboard(email.emailAddress)
                            } label: {
                                Label("Copy Address", systemImage: "doc.on.doc")
                                    .font(.system(.subheadline, design: .rounded))
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(.accentColor)
                            .opacity(isEditing ? 0 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                    
                    // Content sections
                    VStack(spacing: 16) {
                        // Destination section
                        DetailSection(title: "Destination") {
                            if isEditing {
                                if !cloudflareClient.forwardingAddresses.isEmpty {
                                    Picker("Forward to", selection: $tempForwardTo) {
                                        ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                            Text(address).tag(address)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onAppear {
                                        // Ensure we have a valid selection
                                        if tempForwardTo.isEmpty && !cloudflareClient.forwardingAddresses.isEmpty {
                                            tempForwardTo = cloudflareClient.forwardingAddresses.first ?? ""
                                        }
                                    }
                                } else {
                                    Text("No forwarding addresses available")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(email.forwardTo.isEmpty ? "Not specified" : email.forwardTo)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // Status section
                        DetailSection(title: "Status") {
                            if isEditing {
                                Toggle("Enabled", isOn: $tempIsEnabled)
                                    .tint(.accentColor)
                            } else {
                                HStack {
                                    Text("Enabled")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Toggle("", isOn: .constant(email.isEnabled))
                                        .disabled(true)
                                        .tint(.accentColor)
                                }
                            }
                        }
                        
                        // Website section
                        if isEditing || !email.website.isEmpty {
                            DetailSection(title: "Website") {
                                if isEditing {
                                    TextField("Website", text: $tempWebsite)
                                        .textInputAutocapitalization(.never)
                                        .keyboardType(.URL)
                                } else {
                                    Text(email.website)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Notes section
                        if isEditing || !email.notes.isEmpty {
                            DetailSection(title: "Notes") {
                                if isEditing {
                                    TextField("Notes", text: $tempNotes, axis: .vertical)
                                        .lineLimit(3...6)
                                } else {
                                    Text(email.notes)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        // Created section
                        DetailSection(title: "Created") {
                            Text(formattedCreatedDate)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Delete button
                        if isEditing {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Text("Delete Email Alias")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 20)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Email Details")
            .navigationBarTitleDisplayMode(.inline)
            .opacity(email.isEnabled ? 1.0 : 0.8)
            .onAppear {
                let parts = email.emailAddress.split(separator: "@")
                tempUsername = String(parts[0])
                
                // Load forwarding addresses immediately on appear
                Task {
                    do {
                        try await cloudflareClient.refreshForwardingAddresses()
                    } catch {
                        self.error = error
                        self.showError = true
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "Save" : "Edit") {
                        if isEditing {
                            Task {
                                await saveChanges()
                            }
                        } else {
                            // Before entering edit mode, make sure we have forwarding addresses
                            if cloudflareClient.forwardingAddresses.isEmpty {
                                Task {
                                    isLoading = true
                                    do {
                                        try await cloudflareClient.refreshForwardingAddresses()
                                        withAnimation {
                                            enterEditMode()
                                        }
                                    } catch {
                                        self.error = error
                                        self.showError = true
                                    }
                                    isLoading = false
                                }
                            } else {
                                withAnimation {
                                    enterEditMode()
                                }
                            }
                        }
                    }
                }
            }
            .disabled(isLoading)
            
            // Toast overlay
            if showCopyToast {
                VStack {
                    Spacer()
                    Text("\(copiedText) copied!")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .alert("Error Saving Changes", isPresented: $showError, presenting: error) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .alert("Delete Email Alias", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteEmailAlias()
                }
            }
        } message: {
            Text("Are you sure you want to delete this email alias?")
        }
    }
    
    private func deleteEmailAlias() async {
        isLoading = true
        
        do {
            if let tag = email.cloudflareTag {
                try await cloudflareClient.deleteEmailRule(tag: tag)
                modelContext.delete(email)
                try modelContext.save()
                needsRefresh = true
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
            print("Saving changes for email: \(email.emailAddress)")
            print("Website: '\(tempWebsite)' -> '\(email.website)'")
            print("Notes: '\(tempNotes)' -> '\(email.notes)'")
            
            // Update the model with temporary values
            email.emailAddress = fullEmailAddress
            email.website = tempWebsite
            email.notes = tempNotes
            email.isEnabled = tempIsEnabled
            email.forwardTo = tempForwardTo
            
            // Ensure user identifier is set for CloudKit sync
            if email.userIdentifier.isEmpty {
                email.userIdentifier = UserDefaults.standard.string(forKey: "userIdentifier") ?? UUID().uuidString
                print("Set user identifier for email: \(email.userIdentifier)")
            }
            
            // Save to SwiftData
            try modelContext.save()
            print("Successfully saved to SwiftData, triggering CloudKit sync")
            
            // Update Cloudflare with email-related changes and enabled state
            if let tag = email.cloudflareTag {
                try await cloudflareClient.updateEmailRule(
                    tag: tag,
                    emailAddress: fullEmailAddress,
                    isEnabled: tempIsEnabled,
                    forwardTo: tempForwardTo
                )
            }
            needsRefresh = true
            
            // Dismiss the view after successful save
            dismiss()
        } catch {
            print("Error saving changes: \(error)")
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
    
    private func enterEditMode() {
        let parts = email.emailAddress.split(separator: "@")
        tempUsername = String(parts[0])
        tempWebsite = email.website
        tempNotes = email.notes
        tempIsEnabled = email.isEnabled
        tempForwardTo = email.forwardTo
        isEditing = true
    }
}

// Helper view for consistent section styling
struct DetailSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }
} 
