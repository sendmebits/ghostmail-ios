import SwiftUI
import SwiftData

struct EmailListView: View {
    @Binding var searchText: String
    @State private var sortOrder: SortOrder = .cloudflareOrder
    @Query private var emailAliases: [EmailAlias]
    @State private var showingCreateSheet = false
    @State private var showingSettings = false
    @State private var isLoading = false
    @State private var error: Error?
    @State private var showError = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    
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
    
    init(searchText: Binding<String>) {
        self._searchText = searchText
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
            let rules = try await cloudflareClient.getEmailRules()
            
            // Create a dictionary of existing aliases by email address
            let existingAliases = Dictionary(
                uniqueKeysWithValues: emailAliases.map { ($0.emailAddress, $0) }
            )
            
            // Get email addresses from Cloudflare rules
            let cloudflareEmails = rules.map { $0.emailAddress }
            let newEmailAddresses = Set(cloudflareEmails)
            
            // Remove aliases that no longer exist in Cloudflare
            emailAliases.forEach { alias in
                if !newEmailAddresses.contains(alias.emailAddress) {
                    modelContext.delete(alias)
                }
            }
            
            // Update or create aliases while preserving order
            for (index, rule) in rules.enumerated() {
                if let existingAlias = existingAliases[rule.emailAddress] {
                    // Update existing alias's Cloudflare properties
                    existingAlias.cloudflareTag = rule.cloudflareTag
                    existingAlias.isEnabled = rule.isEnabled
                    existingAlias.sortIndex = index + 1
                } else {
                    // Create new alias
                    let newAlias = EmailAlias(emailAddress: rule.emailAddress)
                    newAlias.cloudflareTag = rule.cloudflareTag
                    newAlias.isEnabled = rule.isEnabled
                    newAlias.sortIndex = index + 1
                    modelContext.insert(newAlias)
                }
            }
            
            try modelContext.save()
        } catch {
            self.error = error
            self.showError = true
        }
        isLoading = false
    }
    
    var body: some View {
        ZStack {
            Group {
                if isLoading && emailAliases.isEmpty {
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
                            NavigationLink(destination: EmailDetailView(email: email)) {
                                EmailRowView(email: email)
                            }
                        }
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
    }
}

struct EmailRowView: View {
    let email: EmailAlias
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    
    var body: some View {
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