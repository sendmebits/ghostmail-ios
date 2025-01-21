import SwiftUI
import SwiftData

struct EmailListView: View {
    @Binding var searchText: String
    @State private var sortOrder: SortOrder = .cloudflareOrder
    @Query private var emailAliases: [EmailAlias]
    @State private var showingCreateSheet = false
    @State private var showingSettings = false
    @State private var isLoading = false
    @State private var isInitialLoad = true
    @State private var error: Error?
    @State private var showError = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Binding var needsRefresh: Bool
    
    enum SortOrder {
        case alphabetical
        case cloudflareOrder
        
        var label: String {
            switch self {
            case .alphabetical: "Alphabetical"
            case .cloudflareOrder: "Most Recent"
            }
        }
        
        var systemImage: String {
            switch self {
            case .alphabetical: "textformat.abc"
            case .cloudflareOrder: "clock"
            }
        }
    }
    
    init(searchText: Binding<String>, needsRefresh: Binding<Bool>) {
        self._searchText = searchText
        self._needsRefresh = needsRefresh
        // Don't set a default sort for @Query to preserve Cloudflare order
        self._emailAliases = Query()
    }
    
    var sortedEmails: [EmailAlias] {
        let filtered = filteredEmails
        switch sortOrder {
        case .alphabetical:
            return filtered.sorted { $0.emailAddress < $1.emailAddress }
        case .cloudflareOrder:
            // Use the sortIndex to preserve Cloudflare's order
            return filtered.sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    
    var filteredEmails: [EmailAlias] {
        if searchText.isEmpty {
            return emailAliases
        }
        return emailAliases.filter { email in
            email.emailAddress.localizedCaseInsensitiveContains(searchText) ||
            email.website.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func refreshEmailRules() async {
        isLoading = true
        do {
            let cloudflareRules = try await cloudflareClient.getEmailRules()
            
            // Create dictionaries for lookup
            let cloudflareRulesByEmail = Dictionary(
                uniqueKeysWithValues: cloudflareRules.map { ($0.emailAddress, $0) }
            )
            
            let existingAliases = Dictionary(
                uniqueKeysWithValues: emailAliases.map { ($0.emailAddress, $0) }
            )
            
            // Remove deleted aliases
            for alias in emailAliases {
                if cloudflareRulesByEmail[alias.emailAddress] == nil {
                    print("Deleting alias: \(alias.emailAddress)")
                    modelContext.delete(alias)
                }
            }
            
            // Update or create aliases
            for (index, rule) in cloudflareRules.enumerated() {
                let emailAddress = rule.emailAddress
                let forwardTo = rule.forwardTo
                
                if let existing = existingAliases[emailAddress] {
                    // Only update if there are actual changes
                    let needsUpdate = existing.cloudflareTag != rule.cloudflareTag ||
                                    existing.isEnabled != rule.isEnabled ||
                                    existing.forwardTo != forwardTo ||
                                    existing.sortIndex != index + 1
                    
                    if needsUpdate {
                        withAnimation {
                            existing.cloudflareTag = rule.cloudflareTag
                            existing.isEnabled = rule.isEnabled
                            existing.forwardTo = forwardTo
                            existing.sortIndex = index + 1
                        }
                    }
                } else {
                    let newAlias = EmailAlias(
                        emailAddress: emailAddress,
                        forwardTo: forwardTo
                    )
                    newAlias.cloudflareTag = rule.cloudflareTag
                    newAlias.isEnabled = rule.isEnabled
                    newAlias.sortIndex = index + 1
                    modelContext.insert(newAlias)
                }
            }
            
            // Save once after all updates
            try modelContext.save()
            
        } catch {
            print("Error during refresh: \(error)")
            self.error = error
            self.showError = true
        }
        isLoading = false
        isInitialLoad = false
    }
    
    var body: some View {
        ZStack {
            Group {
                if isLoading && isInitialLoad {
                    ProgressView()
                } else if sortedEmails.isEmpty {
                    ContentUnavailableView(
                        "No Email Aliases",
                        systemImage: "envelope.badge.shield.half.filled",
                        description: Text("Create your first email alias using the + button")
                    )
                } else {
                    List {
                        ForEach(sortedEmails, id: \.id) { email in
                            NavigationLink(value: email) {
                                EmailRowView(email: email) {
                                    toastMessage = "\(email.emailAddress) copied!"
                                    withAnimation {
                                        showToast = true
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                                let generator = UIImpactFeedbackGenerator(style: .heavy)
                                generator.prepare()
                                generator.impactOccurred()
                                UIPasteboard.general.string = email.emailAddress
                                toastMessage = "\(email.emailAddress) copied!"
                                withAnimation {
                                    showToast = true
                                }
                            })
                        }
                    }
                    .navigationDestination(for: EmailAlias.self) { email in
                        EmailDetailView(email: email, needsRefresh: $needsRefresh)
                    }
                    .refreshable {
                        await refreshEmailRules()
                    }
                }
            }
            
            // Floating Action Button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 50))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .background(Color.white.clipShape(Circle()))
                            .shadow(radius: 4, y: 2)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Email Aliases")
        .searchable(text: $searchText, prompt: "Search emails or websites")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Sort Order", selection: $sortOrder) {
                        ForEach([SortOrder.cloudflareOrder, .alphabetical], id: \.self) { order in
                            Label(order.label, systemImage: order.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingCreateSheet) {
            EmailCreateView()
        }
        .alert("Error", isPresented: $showError, presenting: error) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.localizedDescription)
        }
        .toast(isShowing: $showToast, message: toastMessage)
        .task {
            // Only load if we haven't loaded yet
            if isInitialLoad {
                await refreshEmailRules()
            }
        }
        .onChange(of: needsRefresh) { _, needsRefresh in
            if needsRefresh {
                Task {
                    await refreshEmailRules()
                    self.needsRefresh = false
                }
            }
        }
    }
}

struct EmailRowView: View {
    let email: EmailAlias
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(email.emailAddress)
                    .font(.headline)
                    .strikethrough(!email.isEnabled)
                if !email.website.isEmpty && cloudflareClient.shouldShowWebsitesInList {
                    Text(email.website)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .opacity(email.isEnabled ? 1.0 : 0.6)
        }
    }
} 
