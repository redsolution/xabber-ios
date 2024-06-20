//
//  XabberTabBarViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 19.06.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

class XabberTabBarViewController: UITabBarController {
//    UINavigationController(rootViewController: chatsVc),
//    UINavigationController(rootViewController: contactsVc),
//    UINavigationController(rootViewController: notificationsVc),
//    UINavigationController(rootViewController: archivedVc),
//    UINavigationController(rootViewController: callsVc),
    private func configure() {
        self.tabBar.itemPositioning = .automatic
        self.tabBar.items?[0].image = UIImage(named: "chat-outline")
        self.tabBar.items?[0].title = "Chats"
        self.tabBar.items?[1].image = UIImage(named: "contacts")
        self.tabBar.items?[1].title = "Contacts"
        self.tabBar.items?[2].image = UIImage(named: "bell-outline")
        self.tabBar.items?[2].title = "Notifications"
        self.tabBar.items?[3].image = UIImage(named: "archive-outline-variant")
        self.tabBar.items?[3].title = "Archive"
        if CommonConfigManager.shared.config.support_calls {
            self.tabBar.items?[4].image = UIImage(named: "call-outline")
            self.tabBar.items?[4].title = "Calls"
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
//        configure()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configure()
    }
}
