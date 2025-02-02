import SwiftUI
import SwiftData

// Import CloudflareClient from the Services directory
@MainActor
struct AuthenticationView: View {
    @EnvironmentObject private var cloudflareClient: CloudflareClient
    @AppStorage("accountId") private var accountId = ""
    @AppStorage("zoneId") private var zoneId = ""
    @AppStorage("apiToken") private var apiToken = ""
    @State private var useQuickAuth = false
    @State private var quickAuthString = ""
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 32) {
            // Header
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
                
                Text("Welcome to Ghost Mail")
                    .font(.system(.title, design: .rounded, weight: .bold))
                
                Text("Please sign in with your Cloudflare credentials")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            
            // Auth Form
            VStack(spacing: 24) {
                Toggle("Quick Auth", isOn: $useQuickAuth)
                    .tint(.accentColor)
                    .padding(.horizontal)
                
                if useQuickAuth {
                    AuthTextField(
                        text: $quickAuthString,
                        placeholder: "Account ID:Zone ID:Token",
                        systemImage: "key.fill"
                    )
                } else {
                    VStack(spacing: 16) {
                        AuthTextField(
                            text: $accountId,
                            placeholder: "Account ID",
                            systemImage: "person.fill"
                        )
                        
                        AuthTextField(
                            text: $zoneId,
                            placeholder: "Zone ID",
                            systemImage: "globe"
                        )
                        
                        AuthTextField(
                            text: $apiToken,
                            placeholder: "API Token",
                            systemImage: "key.fill"
                        )
                    }
                }
                
                // Login Button
                Button(action: authenticate) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Sign In")
                                .font(.system(.body, design: .rounded, weight: .medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)
                .padding(.top, 8)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .alert("Authentication Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage.isEmpty ? "Please check your credentials and try again." : errorMessage)
        }
    }
    
    private func authenticate() {
        if useQuickAuth {
            let components = quickAuthString.split(separator: ":")
            guard components.count == 3 else {
                errorMessage = "Invalid quick auth format. Please use 'Account ID:Zone ID:Token'"
                showError = true
                return
            }
            accountId = String(components[0])
            zoneId = String(components[1])
            apiToken = String(components[2])
        }
        
        isLoading = true
        
        Task {
            do {
                // First update the credentials
                cloudflareClient.updateCredentials(
                    accountId: accountId,
                    zoneId: zoneId,
                    apiToken: apiToken
                )
                
                // Verify the token
                let isValid = try await cloudflareClient.verifyToken()
                
                await MainActor.run {
                    if isValid {
                        // Set authenticated state
                        UserDefaults.standard.set(true, forKey: "isAuthenticated")
                        cloudflareClient.isAuthenticated = true
                    } else {
                        errorMessage = "Invalid credentials. Please check and try again."
                        showError = true
                        cloudflareClient.logout()
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    cloudflareClient.logout()
                    isLoading = false
                }
            }
        }
    }
}

// Helper view for consistent text field styling
struct AuthTextField: View {
    @Binding var text: String
    let placeholder: String
    let systemImage: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            TextField(placeholder, text: $text)
                .submitLabel(.next)
                .autocorrectionDisabled()
        }
        .padding()
        .background(.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
} 
