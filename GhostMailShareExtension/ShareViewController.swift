import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {
    private var websiteDomain: String?
    
    override func isContentValid() -> Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Extract and display the website domain
        extractWebsiteDomain()
    }

    override func didSelectPost() {
        print("[GhostMailShareExt] didSelectPost")
        handleInputAndOpenHostApp()
    }

    override func configurationItems() -> [Any]! { return [] }

    private func extractWebsiteDomain() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else { return }
        let providers = extensionItem.attachments ?? []
        
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL) as URL?
                if let host = url?.host {
                    var domain = host.lowercased()
                    if domain.hasPrefix("www.") { domain.removeFirst(4) }
                    DispatchQueue.main.async {
                        self.websiteDomain = domain
                        self.textView.text = "Creating email alias for: \(domain)"
                        self.placeholder = "Creating alias for \(domain)"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.textView.text = "Creating new email alias"
                        self.placeholder = "Creating new email alias"
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.textView.text = "Creating new email alias"
                self.placeholder = "Creating new email alias"
            }
        }
    }

    private func handleInputAndOpenHostApp() {
        print("[GhostMailShareExt] handleInputAndOpenHostApp start")
        guard let extensionItem = self.extensionContext?.inputItems.first as? NSExtensionItem else { print("[GhostMailShareExt] No extension item"); completeRequest(); return }
        let providers = extensionItem.attachments ?? []
        print("[GhostMailShareExt] attachments count=\(providers.count)")
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            print("[GhostMailShareExt] Found URL provider")
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL) as URL?
                print("[GhostMailShareExt] Loaded URL=\(url?.absoluteString ?? "nil")")
                self.openHostApp(with: url)
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            print("[GhostMailShareExt] Found plain text provider")
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = item as? String
                let url = text.flatMap { URL(string: $0) }
                print("[GhostMailShareExt] Loaded text=\(text ?? "nil") url=\(url?.absoluteString ?? "nil")")
                self.openHostApp(with: url)
            }
        } else {
            print("[GhostMailShareExt] No suitable provider, opening without URL")
            self.openHostApp(with: nil)
        }
    }

    private func openHostApp(with url: URL?) {
        var components = URLComponents()
        components.scheme = "ghostmail"
        components.host = "create"
        if let u = url?.absoluteString, !u.isEmpty {
            components.queryItems = [URLQueryItem(name: "url", value: u)]
        }
        guard let openURL = components.url else { print("[GhostMailShareExt] Failed to build deep link"); completeRequest(); return }
        print("[GhostMailShareExt] Opening URL=\(openURL.absoluteString)")
        DispatchQueue.main.async {
            self.extensionContext?.open(openURL, completionHandler: { success in
                print("[GhostMailShareExt] extensionContext open success=\(success)")
                if !success {
                    // Try direct UIApplication.open as fallback
                    print("[GhostMailShareExt] Falling back to UIApplication.open")
                    if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication {
                        app.open(openURL, options: [:], completionHandler: nil)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    print("[GhostMailShareExt] Completing request")
                    self.completeRequest()
                }
            })
        }
    }

    private func completeRequest() {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
