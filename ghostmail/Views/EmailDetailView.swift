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
    @State private var availableForwardingAddresses: [String] = []
    
    @State private var showDeleteConfirmation = false
    @State private var toastWorkItem: DispatchWorkItem?
    
    init(email: EmailAlias, needsRefresh: Binding<Bool>) {
        self.email = email
        self._needsRefresh = needsRefresh
        _tempWebsite = State(initialValue: email.website)
        _tempNotes = State(initialValue: email.notes)
        _tempIsEnabled = State(initialValue: email.isEnabled)
        _tempForwardTo = State(initialValue: email.forwardTo)
        
        
        // Extract username from email address
        if let username = email.emailAddress.split(separator: "@").first {
            _tempUsername = State(initialValue: String(username))
        } else {
            _tempUsername = State(initialValue: "")
        }
    }
    
    // Determine domain and zone for this alias to support multi-zone editing
    private var aliasDomain: String {
        let parts = email.emailAddress.split(separator: "@")
        if parts.count == 2 { return String(parts[1]) }
        // Fallback to zone's domain name if available
        if let z = aliasZone, !z.domainName.isEmpty { return z.domainName }
        return cloudflareClient.emailDomain
    }

    private var aliasZone: CloudflareClient.CloudflareZone? {
        if !email.zoneId.isEmpty, let z = cloudflareClient.zones.first(where: { $0.zoneId == email.zoneId }) {
            return z
        }
        // Fallback: try match by domain name from the email address
        let parts = email.emailAddress.split(separator: "@")
        if parts.count == 2 {
            let domain = String(parts[1])
            if let z = cloudflareClient.zones.first(where: { $0.domainName == domain }) {
                return z
            }
        }
        return nil
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

    /// Returns a valid URL for a website string, adding https:// if the scheme is missing.
    private func urlFrom(_ website: String) -> URL? {
        var s = website.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }
    
    private var fullEmailAddress: String { "\(tempUsername)@\(aliasDomain)" }
    
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
                                    
                                    Text("@\(aliasDomain)")
                                        .foregroundStyle(.primary)
                                        .font(.system(.title2, design: .rounded, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            } else {
                                Text(email.emailAddress)
                                    .font(.system(.title2, design: .rounded, weight: .medium))
                                    .multilineTextAlignment(.center)
                                    .strikethrough(!email.isEnabled)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button {
                                            if !email.emailAddress.isEmpty {
                                                copyToClipboard(email.emailAddress)
                                            }
                                        } label: {
                                            Text("Copy Address")
                                            Image(systemName: "doc.on.doc")
                                        }
                                    }
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
                                if !availableForwardingAddresses.isEmpty {
                                    Picker("Forward to", selection: $tempForwardTo) {
                                        ForEach(availableForwardingAddresses, id: \.self) { address in
                                            Text(address).tag(address)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onAppear {
                                        // Ensure we have a valid selection for this zone
                                        if tempForwardTo.isEmpty || !availableForwardingAddresses.contains(tempForwardTo) {
                                            tempForwardTo = availableForwardingAddresses.first ?? ""
                                        }
                                    }
                                } else if !cloudflareClient.forwardingAddresses.isEmpty {
                                    // Fallback to global list if zone-specific list not loaded yet
                                    Picker("Forward to", selection: $tempForwardTo) {
                                        ForEach(Array(cloudflareClient.forwardingAddresses).sorted(), id: \.self) { address in
                                            Text(address).tag(address)
                                        }
                                    }
                                    .pickerStyle(.menu)
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
                                Group {
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
                            .contentShape(Rectangle())
                            .contextMenu {
                                // Open website in Safari when possible
                                if let url = urlFrom(email.website) {
                                    Button {
                                        let generator = UIImpactFeedbackGenerator(style: .medium)
                                        generator.impactOccurred()
                                        UIApplication.shared.open(url)
                                    } label: {
                                        Text("Open Website")
                                        Image(systemName: "safari")
                                    }
                                }

                                // Copy website to clipboard
                                Button {
                                    if !email.website.isEmpty {
                                        copyToClipboard(email.website)
                                    }
                                } label: {
                                    Text("Copy Website")
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                        }
                        
                        // Notes section
                        if isEditing || !email.notes.isEmpty {
                            DetailSection(title: "Notes") {
                                Group {
                                    if isEditing {
                                        TextField("Notes", text: $tempNotes, axis: .vertical)
                                            .lineLimit(3...6)
                                    } else {
                                        Text(email.notes)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    if !email.notes.isEmpty {
                                        copyToClipboard(email.notes)
                                    }
                                } label: {
                                    Text("Copy Notes")
                                    Image(systemName: "doc.on.doc")
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
            .refreshable {
                // Only refresh the website icon for this entry
                guard !email.website.isEmpty, cloudflareClient.shouldShowWebsiteLogos else { return }
                isLoadingIcon = true
                websiteUIImage = nil
                if let img = await IconCache.shared.refreshImage(for: email.website) {
                    websiteUIImage = img
                } else {
                    websiteUIImage = nil
                }
                isLoadingIcon = false
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
                        // Load zone-specific forwarding addresses if we can resolve the zone
                        if let z = aliasZone {
                            let set = try await cloudflareClient.fetchForwardingAddresses(accountId: z.accountId, token: z.apiToken)
                            await MainActor.run {
                                self.availableForwardingAddresses = Array(set).sorted()
                                if self.tempForwardTo.isEmpty || !self.availableForwardingAddresses.contains(self.tempForwardTo) {
                                    self.tempForwardTo = self.availableForwardingAddresses.first ?? ""
                                }
                            }
                        } else {
                            try await cloudflareClient.refreshForwardingAddresses()
                            await MainActor.run {
                                self.availableForwardingAddresses = Array(cloudflareClient.forwardingAddresses).sorted()
                                if self.tempForwardTo.isEmpty || !self.availableForwardingAddresses.contains(self.tempForwardTo) {
                                    self.tempForwardTo = self.availableForwardingAddresses.first ?? ""
                                }
                            }
                        }
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
                if let z = aliasZone {
                    try await cloudflareClient.deleteEmailRule(tag: tag, in: z)
                } else {
                    try await cloudflareClient.deleteEmailRule(tag: tag)
                }
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
            
            // Ensure we have a valid zone for this alias and a verified forwarding address within that zone
            if let z = aliasZone {
                // If zone-specific list is empty, fetch to validate
                if availableForwardingAddresses.isEmpty {
                    let set = try await cloudflareClient.fetchForwardingAddresses(accountId: z.accountId, token: z.apiToken)
                    availableForwardingAddresses = Array(set).sorted()
                }
                guard tempForwardTo.isEmpty || availableForwardingAddresses.contains(tempForwardTo) else {
                    throw CloudflareClient.CloudflareError(message: "Selected forwarding address isn't verified for this domain's account.")
                }
                // Correct legacy zoneId if needed
                if email.zoneId != z.zoneId {
                    email.zoneId = z.zoneId
                }
            }

            // Save to SwiftData
            try modelContext.save()
            print("Successfully saved to SwiftData, triggering CloudKit sync")
            
            // Update Cloudflare with email-related changes and enabled state
            if let tag = email.cloudflareTag {
                if let z = aliasZone {
                    try await cloudflareClient.updateEmailRule(
                        tag: tag,
                        emailAddress: fullEmailAddress,
                        isEnabled: tempIsEnabled,
                        forwardTo: tempForwardTo,
                        in: z
                    )
                } else {
                    try await cloudflareClient.updateEmailRule(
                        tag: tag,
                        emailAddress: fullEmailAddress,
                        isEnabled: tempIsEnabled,
                        forwardTo: tempForwardTo
                    )
                }
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

        // Load zone-specific forwarding addresses for the edit session
        Task {
            do {
                if let z = aliasZone {
                    let set = try await cloudflareClient.fetchForwardingAddresses(accountId: z.accountId, token: z.apiToken)
                    await MainActor.run {
                        self.availableForwardingAddresses = Array(set).sorted()
                        if self.tempForwardTo.isEmpty || !self.availableForwardingAddresses.contains(self.tempForwardTo) {
                            self.tempForwardTo = self.availableForwardingAddresses.first ?? ""
                        }
                    }
                } else {
                    try await cloudflareClient.refreshForwardingAddresses()
                    await MainActor.run {
                        self.availableForwardingAddresses = Array(cloudflareClient.forwardingAddresses).sorted()
                        if self.tempForwardTo.isEmpty || !self.availableForwardingAddresses.contains(self.tempForwardTo) {
                            self.tempForwardTo = self.availableForwardingAddresses.first ?? ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    self.showError = true
                }
            }
        }
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
