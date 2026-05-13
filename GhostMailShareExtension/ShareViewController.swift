import UIKit
import UniformTypeIdentifiers

/// Logs only in DEBUG builds. Release ship-builds do not write share-extension
/// diagnostics (which previously included full shared URLs) to the unified
/// system log.
@inline(__always)
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

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
        
        // Navigation bar with extra padding for iOS 26
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.prefersLargeTitles = false
        
        // Add extra padding to the navigation bar
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        
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
        
        // Constraints with extra padding for iOS 26
        NSLayoutConstraint.activate([
            // Add more top padding to the navigation bar
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
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
        debugLog("[GhostMailShareExt] createTapped")
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
        debugLog("[GhostMailShareExt] handleInputAndOpenHostApp start")
        guard let extensionItem = self.extensionContext?.inputItems.first as? NSExtensionItem else {
            debugLog("[GhostMailShareExt] No extension item")
            completeRequest()
            return
        }
        let providers = extensionItem.attachments ?? []
        debugLog("[GhostMailShareExt] attachments count=\(providers.count)")
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            debugLog("[GhostMailShareExt] Found URL provider")
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? NSURL) as URL?
                self.openHostApp(with: url)
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            debugLog("[GhostMailShareExt] Found plain text provider")
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = item as? String
                let url = text.flatMap { URL(string: $0) }
                self.openHostApp(with: url)
            }
        } else {
            debugLog("[GhostMailShareExt] No suitable provider, opening without URL")
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
            debugLog("[GhostMailShareExt] Failed to build deep link")
            completeRequest()
            return
        }
        DispatchQueue.main.async {
            self.extensionContext?.open(openURL, completionHandler: { success in
                debugLog("[GhostMailShareExt] extensionContext open success=\(success)")
                if !success {
                    self.openViaResponderChain(openURL)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.completeRequest()
                }
            })
        }
    }

    // Fallback when `extensionContext.open(_:completionHandler:)` reports
    // `success: false` (a long-standing behavior for Share Extensions when the
    // host app isn't already running). Walk the responder chain to find the
    // `UIApplication` instance and invoke its non-deprecated
    // `openURL:options:completionHandler:` IMP directly via the Obj-C runtime.
    //
    // The class check is load-bearing: `UIScene` exposes a same-named selector
    // whose second argument is a `UISceneOpenExternalURLOptions` *object*
    // rather than an `NSDictionary`. Hitting UIScene first and feeding it a
    // dictionary crashes inside UIKit with
    // `-[__NSDictionary universalLinksOnly]` unrecognized selector. The
    // legacy single-arg `openURL:` selector is also no longer usable — iOS
    // logs "BUG IN CLIENT OF UIKIT" and force-returns NO for it.
    private func openViaResponderChain(_ url: URL) {
        guard let appClass = NSClassFromString("UIApplication") else {
            debugLog("[GhostMailShareExt] responder fallback: UIApplication class missing")
            return
        }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenURLFn = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: appClass), current.responds(to: selector) {
                debugLog("[GhostMailShareExt] responder fallback: invoking UIApplication.openURL:options:completionHandler:")
                let target = current as NSObject
                let imp = target.method(for: selector)
                let fn = unsafeBitCast(imp, to: OpenURLFn.self)
                fn(target, selector, url as NSURL, [:] as NSDictionary, nil)
                return
            }
            responder = current.next
        }
        debugLog("[GhostMailShareExt] responder fallback: UIApplication not found in responder chain")
    }

    private func completeRequest() {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
