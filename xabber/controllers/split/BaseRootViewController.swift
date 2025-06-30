//
//  BaseRootViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 26.06.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

class BaseRootViewController: BaseViewController {
    
    class XabberTabBarView: UIToolbar {
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            
            return stack
        }()
        /*self.tabBar.itemPositioning = .automatic
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
         }*/
        internal let chatsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("message")
            conf.attributedTitle = AttributedString("Chats", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let contactsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("person.2")
//            conf.title = "Contacts"
            conf.attributedTitle = AttributedString("Contacts", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let notificationsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("bell")
//            conf.title = "Notifications"
            conf.attributedTitle = AttributedString("Notifications", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let archivedButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("archivebox")
//            conf.title = "Archive"
            conf.attributedTitle = AttributedString("Archive", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        internal let callsButton: UIButton = {
            var conf = UIButton.Configuration.plain()
            conf.image = imageLiteral("phone")
//            conf.title = "Calls"
            conf.attributedTitle = AttributedString("Calls", attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 12, weight: .regular)
            ]))
            conf.imagePlacement = .top
            conf.titleAlignment = .center
            let button = UIButton(configuration: conf, primaryAction: nil)
            
            return button
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupSubviews()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func setupSubviews() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(chatsButton)
            stack.addArrangedSubview(contactsButton)
            stack.addArrangedSubview(notificationsButton)
            stack.addArrangedSubview(archivedButton)
            stack.addArrangedSubview(callsButton)
        }
    }
    
    let tabBarHeight: CGFloat = 49
    
    internal let xabberTabBar: XabberTabBarView = {
        let bar = XabberTabBarView(frame: .zero)
        
        return bar
    }()
    
    
    
    func addTabBar() {
        self.view.addSubview(self.xabberTabBar)
        self.updateFrame()
    }
    
    func configureTabBar() {
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.addTabBar()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.updateFrame()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        self.updateFrame()
    }
    
    func updateFrame() {
        self.view.bringSubviewToFront(xabberTabBar)
        var barHeight = tabBarHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            barHeight += bottomInset
        }
        self.xabberTabBar.frame = CGRect(
            origin: CGPoint(x: 0, y: self.view.frame.height - barHeight),
            size: CGSize(width: self.view.frame.width, height: barHeight)
        )
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        updateFrame()
    }
    
}
