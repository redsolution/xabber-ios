//
//  EmptyChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 16.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class EmptyChatViewController: UIViewController {
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        
        return stack
    }()
    
    let centerStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .title2)
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
            label.textColor = MDCPalette.grey.tint500//.systemGray
//            }//MDCPalette.grey.tint900
        
        return label
    }()
    
    let newChatButton: UIButton = {
        let button = UIButton()
        
        button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
        
        return button
    }()
    
    internal func activaateConstraints() {
//            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
    }
    
    open func configure() {
        self.view.backgroundColor = .systemBackground
        self.view.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(UIStackView())
        stack.addArrangedSubview(centerStack)
        stack.addArrangedSubview(UIStackView())
        centerStack.addArrangedSubview(titleLabel)
//            centerStack.addArrangedSubview(newChatButton)
        titleLabel.text = "Select chat to start conversation"
        newChatButton.titleLabel?.numberOfLines = 0
        newChatButton.titleLabel?.textAlignment = .center
        activaateConstraints()
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
    }
    
    @objc
    internal func onButtonPressed(_ sender: UIButton) {
//        callback?()
    }
}

extension EmptyChatViewController: SplitViewControllerDelegate {
    func onOpenChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        let vc = ChatViewController()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
//        splitv
//        self.navigationController?.setViewControllers([vc], animated: true)
    }
}
