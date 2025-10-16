import UIKit
import SwiftUI

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard shortcutItem.type == "com.sendmebits.ghostmail.create" else {
            completionHandler(false)
            return
        }
        
        NotificationCenter.default.post(name: .ghostmailOpenCreate, object: nil)
        completionHandler(true)
    }
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem,
           shortcutItem.type == "com.sendmebits.ghostmail.create" {
            // Post with a small delay to ensure view hierarchy is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .ghostmailOpenCreate, object: nil)
            }
        }
    }
}
