import UIKit
import UniformTypeIdentifiers

class ActionViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Immediately process the shared content and open Ghost Mail
        handleActionAndOpenHostApp()
    }

    private func handleActionAndOpenHostApp() {
        print("[GhostMailActionExt] Processing action")
        
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            print("[GhostMailActionExt] No extension item")
            completeRequest()
            return
        }
        
        let providers = extensionItem.attachments ?? []
        print("[GhostMailActionExt] attachments count=\(providers.count)")
        
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            print("[GhostMailActionExt] Found URL provider")
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL) as URL?
                print("[GhostMailActionExt] Loaded URL=\(url?.absoluteString ?? "nil")")
                self.openHostApp(with: url)
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            print("[GhostMailActionExt] Found plain text provider")
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = item as? String
                let url = text.flatMap { URL(string: $0) }
                print("[GhostMailActionExt] Loaded text=\(text ?? "nil") url=\(url?.absoluteString ?? "nil")")
                self.openHostApp(with: url)
            }
        } else {
            print("[GhostMailActionExt] No suitable provider, opening without URL")
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
        
        guard let openURL = components.url else {
            print("[GhostMailActionExt] Failed to build deep link")
            completeRequest()
            return
        }
        
        print("[GhostMailActionExt] Opening URL=\(openURL.absoluteString)")
        
        DispatchQueue.main.async {
            self.extensionContext?.open(openURL, completionHandler: { success in
                print("[GhostMailActionExt] extensionContext open success=\(success)")
                if !success {
                    print("[GhostMailActionExt] Falling back to UIApplication.open")
                    if let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication {
                        app.open(openURL, options: [:], completionHandler: nil)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    print("[GhostMailActionExt] Completing request")
                    self.completeRequest()
                }
            })
        }
    }

    private func completeRequest() {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}