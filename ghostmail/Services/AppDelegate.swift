import UIKit
import SwiftUI

extension Notification.Name {
    static let ghostmailOpenCreate = Notification.Name("GhostMailOpenCreate")
}

// Bridge UIApplicationDelegate to SwiftUI App to handle Home Screen Quick Actions
class AppDelegate: NSObject, UIApplicationDelegate {
    // Used to handle quick action when app is launched cold
    var pendingCreateQuickAction: Bool = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
           shortcutItem.type == "com.sendmebits.ghostmail.create" {
            pendingCreateQuickAction = true
            // Return false to prevent the system from calling performActionFor
            return false
        }
        return true
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem,
           shortcutItem.type == "com.sendmebits.ghostmail.create" {
            pendingCreateQuickAction = true
        }
        
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let handled = handle(shortcutItem: shortcutItem)
        completionHandler(handled)
    }

    private func handle(shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == "com.sendmebits.ghostmail.create" else { 
            return false 
        }
        pendingCreateQuickAction = true
        NotificationCenter.default.post(name: .ghostmailOpenCreate, object: nil)
        return true
    }
}
