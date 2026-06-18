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
    
    // Note: cold-launch quick actions are NOT posted from here. AppDelegate's
    // configurationForConnecting(_:options:) sets pendingCreateQuickAction for the
    // same connectionOptions, and ghostmailApp delivers the notification exactly
    // once. Posting here as well used to open the create sheet twice.
}
