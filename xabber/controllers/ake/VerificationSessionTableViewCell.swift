//
//  VerificationSessionTableViewCell.swift
//  xabber
//
//  Created by Admin on 08.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import XMPPFramework

class VerificationSessionTableViewCell: UITableViewCell {
    static let cellName = "VerificationSessionTableViewCell"

    var owner = ""
    var jid = ""
    var sid = ""
    
    let titleLabel = UILabel()
    
    let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        
        return stack
    }()
    
    let labelsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        
        return stack
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        label.textColor = MDCPalette.grey.tint800
        label.font = UIFont.systemFont(ofSize: 14)
        label.numberOfLines = 0
        
        return label
    }()
    
    let closeButton: UIButton = {
        let button = UIButton(frame: CGRect(width: 20, height: 20))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .lightGray
        
        return button
    }()
    
    let customImageView: UIImageView = {
        let imageView = UIImageView(frame: CGRect(square: 40))
        let image = UIImage(systemName: "lock.circle.fill")?.upscale(dimension: 40).withTintColor(.systemBlue)
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        return imageView
    }()
    
    func configure(owner: String, jid: String, sid: String, title: String, subtitle: String?) {
        self.owner = owner
        self.jid = jid
        self.sid = sid
        
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 11, bottom: 11, left: 11, right: 11)
        
        titleLabel.text = title
        
        if subtitle != nil {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 3
            let attributedText = NSMutableAttributedString(string: subtitle!, attributes: [NSAttributedString.Key.paragraphStyle: paragraphStyle])
            subtitleLabel.attributedText = attributedText
        }
        
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)
        
        stack.addArrangedSubview(customImageView)
        stack.addArrangedSubview(labelsStack)
        stack.addArrangedSubview(closeButton)
        
        closeButton.addTarget(self, action: #selector(onCloseButtonPressed), for: .touchUpInside)
    }
    
    @objc
    func onCloseButtonPressed() {
        guard let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager,
              let fullJid = XMPPJID(string: self.jid) else {
            fatalError()
        }
        do {
            let realm = try WRealm.safe()
            let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: self.sid))
            try realm.write {
                realm.delete(instance!)
            }
        } catch {
            fatalError()
        }
        akeManager.sendErrorMessage(fullJID: fullJid, sid: self.sid, reason: "Сontact canceled verification session")
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            customImageView.widthAnchor.constraint(equalToConstant: 40),
            closeButton.imageView!.rightAnchor.constraint(equalTo: closeButton.rightAnchor),
        ])
    }
}
