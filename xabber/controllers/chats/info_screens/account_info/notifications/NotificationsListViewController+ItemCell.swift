//
//  NotificationsListViewController+ItemCell.swift
//  xabber
//
//  Created by Игорь Болдин on 02.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

extension NotificationsListViewController {
    class DeviceItemCell: UITableViewCell {
        static let cellName = "DeviceItemCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill
            
            return stack
        }()
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 72, right: 4)
            
            return stack
        }()
                
        let topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.spacing = 4
            stack.distribution = .fill
            stack.alignment = .center
            
            return stack
        }()
        
        let bottomStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .top
            stack.spacing = 8
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 8)

            return stack
        }()
        
        let avatarContainer: UIView = {
            let view = UIView(frame: CGRect(square: 60))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 60))
            
            view.backgroundColor = .clear//MDCPalette.grey.tint200
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image.upscale(dimension: 60))
            } else {
                view.mask = nil
            }
            
            return view
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 56))
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            view.backgroundColor = MDCPalette.grey.tint200
            
            return view
        }()
        

        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)

            label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
            
    //            label.backgroundColor = .white
            
            label.lineBreakMode = .byWordWrapping
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)
            label.numberOfLines = 0
            
            return label
        }()
        
        let dateLabel: UILabel = {
            let label = UILabel()
            
    //            label.backgroundColor = .white
            label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
            label.font = UIFont.systemFont(ofSize: 14)
            label.textAlignment = .left
            
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            
            return label
        }()
        
        
        let badgeIndicator: UIImageView = {
            let view = UIImageView(frame: CGRect(x: 40, y: 40, width: 18, height: 18))
            
            view.layer.cornerRadius = 9
            view.layer.masksToBounds = true
            
            return view
        }()
        
        let badgeIcon: UIImageView = {
            let view = UIImageView(frame: CGRect(1, 1, 16, 16))
            
            view.backgroundColor = .clear
            view.tintColor = .systemGreen
            view.image = UIImage(systemName: "info.circle.fill")
            
            return view
        }()
        
        let itsNotMeButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.setTitle("Revoke device", for: .normal)
            button.setTitleColor(.systemRed, for: .normal)
            
            return button
        }()
        
        
        public func configure(_ jid: String, owner: String, username: String, title: String, message: String, date: Date) {

//            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { image in
//                if let image = image {
//                    self.avatarView.image = image
//                } else {
//                    self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
//                }
//            }
            self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
            self.badgeIndicator.backgroundColor = .systemBackground
            self.badgeIndicator.tintColor = .systemOrange
            
            self.titleLabel.text = title
//            self.messageLabel.text = message
            let mutableAttributedString = NSMutableAttributedString()
            let newLoginString = NSAttributedString(string: "New login.", attributes: [NSAttributedString.Key.font : UIFont.systemFont(ofSize: 20, weight: .medium),NSAttributedString.Key.foregroundColor: UIColor.black.cgColor ])
            let modifiedMessage = message.replacingOccurrences(of: "New login.", with: "")
            let otherString = NSAttributedString(string: modifiedMessage, attributes: [NSAttributedString.Key.font : UIFont.systemFont(ofSize: 16, weight: .regular),NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint600.cgColor ])
            mutableAttributedString.append(newLoginString)
            mutableAttributedString.append(otherString)
            self.messageLabel.attributedText = mutableAttributedString
            let dateFormatter = DateFormatter()
            let today = Date()
//            if NSCalendar.current.isDateInToday(date) {
//                dateFormatter.dateFormat = "HH:mm"
//            } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
//                dateFormatter.dateFormat = "HH:mm"
//            } else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
//                dateFormatter.dateFormat = "E"
//            } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
//                dateFormatter.dateFormat = "MMM dd"
//            } else {
                dateFormatter.dateFormat = "d MMM yyyy HH:mm"
//            }
            dateLabel.text = dateFormatter.string(from: date)
            
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
                userImageView.mask = UIImageView(image: image.upscale(dimension: 60))
            } else {
                avatarView.mask = nil
                userImageView.mask = nil
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()

        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

    //        self.layer.shouldRasterize = true
    //        self.layer.rasterizationScale = UIScreen.main.scale
            
            contentView.addSubview(infoStack)
            infoStack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 2, right: 0)
            badgeIndicator.addSubview(badgeIcon)
            backgroundColor = .systemBackground
            
//            accountIndicator.frame = CGRect(x: 0.5, y: 1, width: 2, height: 74)
            
            avatarContainer.frame = CGRect(x: 8, y: 8, width: 60, height: 60)
            avatarContainer.addSubview(userImageView)
            avatarView.frame = CGRect(x: 2, y: 2, width: 56, height: 56)
//            addSubview(accountIndicator)
            addSubview(avatarContainer)
            
//            infoStack.addArrangedSubview(topStack)
            infoStack.addArrangedSubview(bottomStack)
//            infoStack.addArrangedSubview(itsNotMeButton)
            
//            topStack.addArrangedSubview(titleLabel)
            infoStack.addArrangedSubview(messageLabel)
            infoStack.addArrangedSubview(dateLabel)
            infoStack.setCustomSpacing(8, after: messageLabel)
            
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
            self.selectionStyle = .none
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
            activateConstraints()
            layoutIfNeeded()
        }
        
        override open func layoutSubviews() {
            super.layoutSubviews()
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                itsNotMeButton.heightAnchor.constraint(equalToConstant: 32)
            ])
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
            print("awaked from nib")
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}

extension NotificationsListViewController {
    class VerificationSessionItemCell: UITableViewCell {
        static let cellName = "VerificationSessionItemCell"
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 6, bottom: 6, left: 72, right: 4)
            
            return stack
        }()
        
        let avatarContainer: UIView = {
            let view = UIView(frame: CGRect(square: 60))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 60))
            
            view.backgroundColor = .clear//MDCPalette.grey.tint200
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image.upscale(dimension: 60))
            } else {
                view.mask = nil
            }
            
            return view
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 56))
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            view.backgroundColor = MDCPalette.grey.tint200
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)

            label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
            
    //            label.backgroundColor = .white
            
            label.lineBreakMode = .byWordWrapping
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)
            label.numberOfLines = 0
            
            return label
        }()
        
        let dateLabel: UILabel = {
            let label = UILabel()
            
    //            label.backgroundColor = .white
            label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
            label.font = UIFont.systemFont(ofSize: 14)
            label.textAlignment = .left
            
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            
            return label
        }()
        
        let badgeIndicator: UIImageView = {
            let view = UIImageView(frame: CGRect(x: 40, y: 40, width: 18, height: 18))
            
            view.layer.cornerRadius = 9
            view.layer.masksToBounds = true
            
            return view
        }()
        
        let badgeIcon: UIImageView = {
            let view = UIImageView(frame: CGRect(1, 1, 16, 16))
            
            view.backgroundColor = .clear
            view.tintColor = .systemGreen
            view.image = UIImage(systemName: "lock.circle.fill")
            
            return view
        }()
        
        func configure(_ jid: String, owner: String, username: String, date: Date, verificationState: VerificationSessionStorageItem.VerififcationState) {
            self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
            self.badgeIndicator.backgroundColor = .systemBackground
            self.badgeIndicator.tintColor = .systemOrange
            
            let mutableAttributedString = NSMutableAttributedString()
            let message: String
            
            if verificationState == VerificationSessionStorageItem.VerififcationState.receivedRequest || verificationState == VerificationSessionStorageItem.VerififcationState.acceptedRequest {
                titleLabel.text = "Incoming verification request"
                if verificationState == VerificationSessionStorageItem.VerififcationState.receivedRequest {
                    message = "User \(jid) wants to establish a trusted connection with you."
                } else {
                    message = "Tell \(jid) the code to continue verification."
                }
            } else if verificationState == VerificationSessionStorageItem.VerififcationState.failed {
                titleLabel.text = "Verification failed"
                message = "Verification session with \(jid)."
            } else if verificationState == VerificationSessionStorageItem.VerififcationState.rejected {
                titleLabel.text = "Verification rejected"
                message = "Verification session with \(jid)."
            } else if verificationState == VerificationSessionStorageItem.VerififcationState.trusted {
                titleLabel.text = "Verification successful"
                message = "Verification session with \(jid)."
            } else {
                titleLabel.text = "Outcoming verification request"
                if verificationState == VerificationSessionStorageItem.VerififcationState.sentRequest {
                    message = "Verification request has been sent to the user \(jid)."
                } else {
                    message = "Enter the code from user \(jid)."
                }
            }

            
            
//            let modifiedMessage = message.replacingOccurrences(of: "New login.", with: "")
            let otherString = NSAttributedString(string: message, attributes: [NSAttributedString.Key.font : UIFont.systemFont(ofSize: 16, weight: .regular),NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint600.cgColor ])
//            mutableAttributedString.append(verificationSessionString)
            mutableAttributedString.append(otherString)
            self.messageLabel.attributedText = mutableAttributedString
            let dateFormatter = DateFormatter()
//            let today = Date()
            dateFormatter.dateFormat = "d MMM yyyy HH:mm"
            dateLabel.text = dateFormatter.string(from: date)
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
                userImageView.mask = UIImageView(image: image.upscale(dimension: 60))
            } else {
                avatarView.mask = nil
                userImageView.mask = nil
            }
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()

        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            
            contentView.addSubview(infoStack)
            infoStack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 2, right: 0)
            badgeIndicator.addSubview(badgeIcon)
            backgroundColor = .systemBackground
                        
            avatarContainer.frame = CGRect(x: 8, y: 8, width: 60, height: 60)
            avatarContainer.addSubview(userImageView)
            avatarView.frame = CGRect(x: 2, y: 2, width: 56, height: 56)
            addSubview(avatarContainer)
            
//            infoStack.addArrangedSubview(topStack)
//            infoStack.addArrangedSubview(bottomStack)
//            infoStack.addArrangedSubview(itsNotMeButton)
            
//            topStack.addArrangedSubview(titleLabel)
            infoStack.addArrangedSubview(titleLabel)
            infoStack.addArrangedSubview(messageLabel)
            infoStack.addArrangedSubview(dateLabel)
            infoStack.setCustomSpacing(8, after: messageLabel)
            
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
            self.selectionStyle = .none
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
//            activateConstraints()
            layoutIfNeeded()
        }
        
        override open func layoutSubviews() {
            super.layoutSubviews()
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
