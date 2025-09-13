import SwiftUI
import SwiftData

struct AddZoneView: View {
    var onSuccess: () -> Void = {}
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @Environment(\.modelContext) private var modelContext
    @AppStorage("addZone.accountId") private var accountId = ""
    @AppStorage("addZone.zoneId") private var zoneId = ""
    @AppStorage("addZone.apiToken") private var apiToken = ""
    @State private var useQuickAuth = false
    @State private var quickAuthString = ""
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var successMessage = ""
    @State private var showSuccess = false

    var body: some View {
        ZStack(alignment: .top) {
            // Icon pinned at top
            HStack {
                Spacer()
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundColor(.accentColor)
                    .padding(12)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                    )
                Spacer()
            }
            .padding(.top, 16)

            // Form centered vertically across full screen
            VStack {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Quick Auth", isOn: $useQuickAuth)
                        .tint(.accentColor)

                    if useQuickAuth {
                        AuthTextField(
                            text: $quickAuthString,
                            placeholder: "Account ID:Zone ID:Token",
                            systemImage: "key.fill"
                        )
                    } else {
                        VStack(spacing: 10) {
                            AuthTextField(
                                text: $accountId,
                                placeholder: "Account ID",
                                systemImage: "person.fill",
                                helpTitle: "Account ID",
                                helpMessage: """
                                Log in to your Cloudflare dashboard, choose a zone/domain, on the bottom right of the screen in the API section: copy "Account ID" and "Zone ID"
                                """,
                                helpURL: "https://dash.cloudflare.com/"
                            )

                            AuthTextField(
                                text: $zoneId,
                                placeholder: "Zone ID",
                                systemImage: "globe",
                                helpTitle: "Zone ID",
                                helpMessage: """
                                Log in to your Cloudflare dashboard, choose a zone/domain, on the bottom right of the screen in the API section: copy "Account ID" and "Zone ID"
                                """,
                                helpURL: "https://dash.cloudflare.com/"
                            )

                            AuthTextField(
                                text: $apiToken,
                                placeholder: "API Token",
                                systemImage: "key.fill",
                                helpTitle: "API Token",
                                helpMessage: """
                                In Cloudflare, create new token (choose Custom token)
                                Permissions:
                                1) Account > Email Routing Addresses > Read
                                2) Zone > Email Routing Rules > Edit
                                3) Zone > Zone Settings > Read
                                """,
                                helpURL: "https://dash.cloudflare.com/profile/api-tokens"
                            )
                        }
                    }

                    Button(action: addZone) {
                        HStack {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Add Zone")
                                    .font(.system(.body, design: .rounded, weight: .medium))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isLoading)

                    if showSuccess {
                        Text(successMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: 500)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Add Zone Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage.isEmpty ? "Please check your values and try again." : errorMessage)
        }
    }

    private func addZone() {
        if useQuickAuth {
            let components = quickAuthString.split(separator: ":")
            guard components.count == 3 else {
                errorMessage = "Invalid quick auth format. Use Account ID:Zone ID:Token"
                showError = true
                return
            }
            accountId = String(components[0])
            zoneId = String(components[1])
            apiToken = String(components[2])
        }
        guard !accountId.isEmpty, !zoneId.isEmpty, !apiToken.isEmpty else {
            errorMessage = "All fields are required"
            showError = true
            return
        }
        isLoading = true
        Task {
            do {
                try await cloudflareClient.addZone(accountId: accountId, zoneId: zoneId, apiToken: apiToken)
                // Refresh forwarding addresses across all zones and pull rules to populate DB
                try await cloudflareClient.refreshForwardingAddressesAllZones()
                let allRules = try await cloudflareClient.getEmailRulesAllZones()
                await MainActor.run {
                    // Merge basic rules into local DB; duplicate handling done elsewhere
                    var existingByEmail: [String: EmailAlias] = [:]
                    for alias in ((try? modelContext.fetch(FetchDescriptor<EmailAlias>())) ?? []) {
                        if existingByEmail[alias.emailAddress] == nil { existingByEmail[alias.emailAddress] = alias }
                    }
                    for (idx, rule) in allRules.enumerated() {
                        if let ex = existingByEmail[rule.emailAddress] {
                            ex.cloudflareTag = rule.cloudflareTag
                            ex.isEnabled = rule.isEnabled
                            ex.forwardTo = rule.forwardTo
                            if ex.zoneId.isEmpty { ex.zoneId = rule.zoneId }
                            ex.sortIndex = idx + 1
                        } else {
                            let newAlias = EmailAlias(emailAddress: rule.emailAddress, forwardTo: rule.forwardTo, zoneId: rule.zoneId)
                            newAlias.cloudflareTag = rule.cloudflareTag
                            newAlias.isEnabled = rule.isEnabled
                            newAlias.sortIndex = idx + 1
                            modelContext.insert(newAlias)
                        }
                    }
                    try? modelContext.save()
                    successMessage = "Zone added and entries loaded."
                    showSuccess = true
                    // Notify parent to dismiss
                    onSuccess()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            await MainActor.run { isLoading = false }
        }
    }
}
