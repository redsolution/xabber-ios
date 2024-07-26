//
//  ContactItemCell.swift
//  xabber
//
//  Created by Admin on 26.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

class ContactItemCell: UITableViewCell {
    class MessageView: UIView {
        let view: UIView = {
            let view = UIView()
            
//            let layer = CAShapeLayer()
//            layer.strokeColor = MDCPalette.deepPurple.tint700.cgColor
//            layer.lineWidth = 1
//            layer.lineDashPattern = [2, 2]
//            layer.fillColor = nil
            
            view.layer.borderColor = MDCPalette.deepPurple.tint400.cgColor
            view.layer.borderWidth = 1
            view.layer.cornerRadius = 10
            
            return view
        }()
        
        let stack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            
            return stack
        }()
        
        
        let label: UILabel = {
            let label = UILabel()
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 14)
            label.textColor =  MDCPalette.deepPurple.tint700
            
            return label
        }()
        
        
        let quoteOpening: UIImageView = {
            let imageView = UIImageView(image: UIImage(systemName: "quote.opening")?.withTintColor(MDCPalette.deepPurple.tint700))
            imageView.image = imageView.image?.resize(targetSize: CGSize(square: 15))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            
            return imageView
        }()
        
        let quoteClosing: UIImageView = {
            let imageView = UIImageView(image: UIImage(systemName: "quote.closing")?.withTintColor(MDCPalette.deepPurple.tint700))
            imageView.image = imageView.image?.resize(targetSize: CGSize(square: 15))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            
            return imageView
        }()
        
        init(text: String) {
            super.init(frame: .zero)
            
            label.text = text
            
            setupSubviews()
            activateConstraints()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func setupSubviews() {
            view.addSubview(stack)
            view.addSubview(quoteOpening)
            view.addSubview(quoteClosing)
            stack.addArrangedSubview(label)
        }
        
        func activateConstraints() {
            NSLayoutConstraint.activate([
                quoteOpening.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
                quoteOpening.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 5),
                
                quoteClosing.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
                quoteClosing.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -5),
                
                stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
                stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
                stack.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 25),
                stack.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -25),
            ])
        }
    }
    
    static let cellName = "ContactItemCell"
    
    let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        
        return stack
    }()
    
    let avatarContainer: UIView = {
        let view = UIView(frame: CGRect(square: 64))
        view.backgroundColor = .clear
        
        return view
    }()
    
    let userImageView: UIView = {
        let view = UIView(frame: CGRect(square: 64))
        
        view.backgroundColor = .clear
        if let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image.upscale(dimension: 64))
        } else {
            view.mask = nil
        }
        
        return view
    }()
    
    let avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 64))
        if let image = UIImage(named: AccountMasksManager.shared.mask56pt)?.upscale(dimension: 64), AccountMasksManager.shared.load() != "square" {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.contentMode = .scaleAspectFill
        
        view.backgroundColor = MDCPalette.grey.tint200
        
        return view
    }()
    
    let badgeIndicator: UIImageView = {
        let view = UIImageView(frame: CGRect(x: 47, y: 47, width: 16, height: 16))
        
        view.layer.cornerRadius = 9
        view.layer.masksToBounds = true
        
        return view
    }()
    
    let badgeIcon: UIImageView = {
        let view = UIImageView(frame: CGRect(1, 1, 16, 16))
        
        view.backgroundColor = .clear
        view.tintColor = MDCPalette.green.tint700
        view.image = UIImage(systemName: "plus.circle.fill")
        
        return view
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: label.font.pointSize, weight: .medium)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    var messageView: MessageView? = nil
    
//    let messageView: UIView = {
//        let view = UIView()
//        
////            let layer = CAShapeLayer()
////            layer.strokeColor = MDCPalette.deepPurple.tint700.cgColor
////            layer.lineWidth = 1
////            layer.lineDashPattern = [2, 2]
////            layer.fillColor = nil
//        
//        view.layer.borderColor = MDCPalette.deepPurple.tint400.cgColor
//        view.layer.borderWidth = 1
//        view.layer.cornerRadius = 10
//        
//        let stack = UIStackView()
//        stack.axis = .horizontal
//        stack.alignment = .center
//        stack.translatesAutoresizingMaskIntoConstraints = false
//        
//        let label = UILabel()
//        label.numberOfLines = 0
//        label.text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus ut vulputate nunc."
//        label.font = .systemFont(ofSize: 14)
//        label.textColor =  MDCPalette.deepPurple.tint700
//        
//        let quoteOpening = UIImageView(image: UIImage(systemName: "quote.opening")?.withTintColor(MDCPalette.deepPurple.tint700))
//        quoteOpening.image = quoteOpening.image?.resize(targetSize: CGSize(square: 15))
//        quoteOpening.translatesAutoresizingMaskIntoConstraints = false
//        
//        let quoteClosing = UIImageView(image: UIImage(systemName: "quote.closing")?.withTintColor(MDCPalette.deepPurple.tint700))
//        quoteClosing.image = quoteClosing.image?.resize(targetSize: CGSize(square: 15))
//        quoteClosing.translatesAutoresizingMaskIntoConstraints = false
//        
//        view.addSubview(stack)
//        view.addSubview(quoteOpening)
//        view.addSubview(quoteClosing)
//        stack.addArrangedSubview(label)
//        
//        NSLayoutConstraint.activate([
//            quoteOpening.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
//            quoteOpening.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 5),
//
//            quoteClosing.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
//            quoteClosing.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -5),
//            
//            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
//            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
//            stack.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 25),
//            stack.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -25),
//        ])
//        
//        return view
//    }()
    
    let buttonsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        
        return stack
    }()
    
    let addButton: UIButton = {
        let button = UIButton()
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .systemBlue
        button.configuration = config
        
        return button
    }()
    
    let declineButton: UIButton = {
        let button = UIButton()
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .systemBlue

        button.configuration = config
        
        return button
    }()
    
    func setupSubviews() {
        badgeIndicator.addSubview(badgeIcon)
        
        contentView.addSubview(avatarContainer)
        avatarContainer.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
        avatarContainer.addSubview(userImageView)
        
        userImageView.addSubview(avatarView)
        avatarContainer.addSubview(badgeIndicator)
        avatarContainer.bringSubviewToFront(badgeIndicator)
        
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 10, bottom: 10, left: 96, right: 16)
        
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        if messageView != nil {
            stack.addArrangedSubview(messageView!)
        }
        stack.addArrangedSubview(buttonsStack)
        
        buttonsStack.addArrangedSubview(addButton)
        buttonsStack.addArrangedSubview(declineButton)
        buttonsStack.addArrangedSubview(UIStackView())
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
//        badgeIndicator.addSubview(badgeIcon)
//        
//        contentView.addSubview(avatarContainer)
//        avatarContainer.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
//        avatarContainer.addSubview(userImageView)
//        
//        userImageView.addSubview(avatarView)
//        avatarContainer.addSubview(badgeIndicator)
//        avatarContainer.bringSubviewToFront(badgeIndicator)
//        
//        contentView.addSubview(stack)
//        stack.fillSuperviewWithOffset(top: 10, bottom: 10, left: 96, right: 16)
//        
//        stack.addArrangedSubview(titleLabel)
//        stack.addArrangedSubview(subtitleLabel)
//        stack.addArrangedSubview(messageView)
//        stack.addArrangedSubview(buttonsStack)
//        
//        buttonsStack.addArrangedSubview(addButton)
//        buttonsStack.addArrangedSubview(declineButton)
//        buttonsStack.addArrangedSubview(UIStackView())
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(owner: String, username: String, jid: String, message: String? = nil, avatarUrl: String? = nil) {
        DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { image in
            if let image = image {
                self.avatarView.image = image
            } else {
                self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
            }
        }
        
        titleLabel.text = username
        subtitleLabel.text = jid
        
        if let message = message {
            messageView = MessageView(text: message)
        }
        
        addButton.setTitle("Add contact", for: .normal)
        declineButton.setTitle("Decline", for: .normal)
        
        setupSubviews()
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        
        
    }
    
}
