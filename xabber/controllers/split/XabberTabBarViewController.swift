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
        self.tabBar.items?[0].image = imageLiteral("message")
        self.tabBar.items?[0].title = "Chats"
        self.tabBar.items?[1].image = imageLiteral("person.2")
        self.tabBar.items?[1].title = "Contacts"
        self.tabBar.items?[2].image = imageLiteral("bell")
        self.tabBar.items?[2].title = "Notifications"
        self.tabBar.items?[3].image = imageLiteral("archivebox")
        self.tabBar.items?[3].title = "Archive"
        if CommonConfigManager.shared.config.support_calls {
            self.tabBar.items?[4].image = imageLiteral("phone")
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
