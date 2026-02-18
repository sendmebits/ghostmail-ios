import UIKit
import SwiftUI

extension Notification.Name {
    static let ghostmailOpenCreate = Notification.Name("GhostMailOpenCreate")
    /// Post after syncEmailRules (e.g. from list refresh) so the app runs pullMetadataFromCloudKit.
    static let requestCloudKitMetadataPull = Notification.Name("GhostMailRequestCloudKitMetadataPull")
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
        
        // Register for remote notifications so CloudKit can push
        // iCloud data changes between devices (notes, website, etc.)
        application.registerForRemoteNotifications()
        
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("Registered for remote notifications (CloudKit sync)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // CloudKit sends silent push notifications when data changes on the server.
        // SwiftData/Core Data's CloudKit integration handles the actual data merge
        // automatically — we just need to acknowledge the notification.
        print("Received remote notification (CloudKit sync)")
        completionHandler(.newData)
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
