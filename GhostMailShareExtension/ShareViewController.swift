import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private var websiteDomain: String?
    private var titleLabel: UILabel!
    private var descriptionLabel: UILabel!
    private var createButton: UIButton!
    private var cancelButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        extractWebsiteDomain()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground
        
        // Navigation bar
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let navItem = UINavigationItem(title: "Create Email Alias")
        
        cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        navItem.leftBarButtonItem = UIBarButtonItem(customView: cancelButton)
        
        createButton = UIButton(type: .system)
        createButton.setTitle("Create", for: .normal)
        createButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
        navItem.rightBarButtonItem = UIBarButtonItem(customView: createButton)
        
        navBar.setItems([navItem], animated: false)
        view.addSubview(navBar)
        
        // Main content
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        
        // Title label
        titleLabel = UILabel()
        titleLabel.text = "Creating email alias..."
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        stackView.addArrangedSubview(titleLabel)
        
        // Description label
        descriptionLabel = UILabel()
        descriptionLabel.text = "This will open Ghost Mail to create a new email alias."
        descriptionLabel.font = UIFont.systemFont(ofSize: 16)
        descriptionLabel.textColor = UIColor.secondaryLabel
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0
        stackView.addArrangedSubview(descriptionLabel)
        
        // Constraints
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)
        ])
    }
    
    @objc private func cancelTapped() {
        completeRequest()
    }
    
    @objc private func createTapped() {
        print("[GhostMailShareExt] createTapped")
        handleInputAndOpenHostApp()
    }

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
                        self.titleLabel.text = "Create alias for \(domain)"
                        self.descriptionLabel.text = "This will create a new email alias for \(domain) in Ghost Mail."
                    }
                } else {
                    DispatchQueue.main.async {
                        self.titleLabel.text = "Create new email alias"
                        self.descriptionLabel.text = "This will open Ghost Mail to create a new email alias."
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.titleLabel.text = "Create new email alias"
                self.descriptionLabel.text = "This will open Ghost Mail to create a new email alias."
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
