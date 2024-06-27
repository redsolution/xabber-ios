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

/*
 import UIKit
 import MaterialComponents.MDCPalettes

 class VerificationSessionTableViewCell: UITableViewCell {
     static let cellName = "VerificationSessionTableViewCell"
     
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
         stack.spacing = 10
         stack.alignment = .leading
         
         return stack
     }()
     
     let titleLabel: UILabel = {
         let label = UILabel()
         label.numberOfLines = 0
         label.setContentHuggingPriority(.defaultLow, for: .horizontal)
         label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
         
         return label
     }()
     
     let subtitleLabel: UILabel = {
         let label = UILabel()
         label.textColor = MDCPalette.grey.tint800
         label.font = UIFont.systemFont(ofSize: 14)
         label.numberOfLines = 0
         label.setContentHuggingPriority(.defaultLow, for: .horizontal)
         label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
         
         return label
     }()
     
     let closeButton: UIButton = {
         let button = UIButton(frame: CGRect(square: 44))
         button.setImage(UIImage(systemName: "xmark"), for: .normal)
         button.imageEdgeInsets = UIEdgeInsets(top: 11, right: 11)
         button.tintColor = .lightGray
         button.contentHorizontalAlignment = .right
         button.contentVerticalAlignment = .top
         
         return button
     }()
     
     let verifyButton: UIButton = {
         let button = UIButton()
         button.setTitle("Verify", for: .normal)
         button.setTitleColor(.white, for: .normal)
         button.configuration = UIButton.Configuration.filled()
         button.configuration!.baseBackgroundColor = .systemBlue
         button.translatesAutoresizingMaskIntoConstraints = false
         button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
         
         return button
     }()
     
     let customImageView: UIImageView = {
         let imageView = UIImageView(frame: CGRect(square: 40))
         let image = UIImage(systemName: "exclamationmark.triangle.fill")?.upscale(dimension: 40).withTintColor(.systemOrange)
         imageView.image = image
         imageView.translatesAutoresizingMaskIntoConstraints = false
         imageView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
         
         return imageView
     }()
     
     func configure(title: String, subtitle: String?) {
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
 //        stack.addArrangedSubview(closeButton)
         
         activateConstraints()
         
         accessoryType = .none
     }
     
     func activateConstraints() {
         NSLayoutConstraint.activate([
 //            closeButton.widthAnchor.constraint(equalToConstant: 44),
 //            closeButton.heightAnchor.constraint(equalToConstant: 44),
 //            closeButton.rightAnchor.constraint(equalTo: self.contentView.rightAnchor),
         ])
     }
 }

 */

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
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill

            return stack
        }()
        
        let avatarContainer: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 64))
            
            view.backgroundColor = .clear//MDCPalette.grey.tint200
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
            let view = UIImageView(frame: CGRect(x: 47, y: 47, width: 16, height: 16))
            
            view.layer.cornerRadius = 9
            view.layer.masksToBounds = true
            
            return view
        }()
        
        let badgeIcon: UIImageView = {
            let view = UIImageView(frame: CGRect(1, 1, 16, 16))
            
            view.backgroundColor = .clear
            view.tintColor = MDCPalette.green.tint700
            view.image = UIImage(systemName: "info.circle.fill")
            
            return view
        }()
        
        let itsNotMeButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.setTitle("Revoke device", for: .normal)
            button.setTitleColor(.systemRed, for: .normal)
            
            return button
        }()
        
        let positiveButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(.white, for: .normal)
            button.configuration = UIButton.Configuration.filled()
            button.configuration!.baseBackgroundColor = .systemBlue
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return button
        }()
        
        let negativeButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(.white, for: .normal)
            var configuration = UIButton.Configuration.bordered()
            configuration.baseBackgroundColor = .systemRed
            button.configuration = configuration
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return button
        }()
        
        var currentUrl: String? = nil
        public func configure(_ jid: String, owner: String, avatarUrl: String?, customImage: UIImage? = nil, username: String, title: String?, message: String, date: Date?, positiveButtonTitle: String?, negativeButtonTitle: String?) {

            if currentUrl != avatarUrl {
                currentUrl = avatarUrl
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { image in
                    if let image = image {
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
                    }
                }
            }
            
            
            
            let dateFormatter = DateFormatter()
            
            dateFormatter.dateFormat = "d MMM yyyy HH:mm"
            dateLabel.isHidden = date == nil
            if let date = date {
                dateLabel.text = dateFormatter.string(from: date)
            }
            titleLabel.isHidden = title == nil
            if let title = title {
                titleLabel.text = title
            }
            messageLabel.text = message
            negativeButton.isHidden = negativeButtonTitle == nil
            if let negativeButtonTitle = negativeButtonTitle {
                negativeButton.setTitle(negativeButtonTitle, for: .normal)
            }
            positiveButton.isHidden = positiveButtonTitle == nil
            if let positiveButtonTitle = positiveButtonTitle {
                positiveButton.setTitle(positiveButtonTitle, for: .normal)
            }
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
            infoStack.fillSuperviewWithOffset(top: 8, bottom: 8, left: 96, right: 18)
            
            backgroundColor = .systemBackground
            
//            accountIndicator.frame = CGRect(x: 0.5, y: 1, width: 2, height: 74)
            badgeIndicator.addSubview(badgeIcon)
            avatarContainer.frame = CGRect(x: 16, y: 10, width: 64, height: 64)
            avatarContainer.addSubview(userImageView)
            avatarView.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            addSubview(avatarContainer)
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
            infoStack.addArrangedSubview(topStack)
//            infoStack.addArrangedSubview(itsNotMeButton)
            
            topStack.addArrangedSubview(titleLabel)
            topStack.addArrangedSubview(dateLabel)
            infoStack.addArrangedSubview(messageLabel)
            infoStack.addArrangedSubview(bottomStack)
            bottomStack.addArrangedSubview(positiveButton)
            bottomStack.addArrangedSubview(negativeButton)
            bottomStack.addArrangedSubview(UIStackView())
//            infoStack.addArrangedSubview(dateLabel)
            infoStack.setCustomSpacing(8, after: messageLabel)
            
            
            
//            self.selectionStyle = .none
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
        
//        override func setSelected(_ selected: Bool, animated: Bool) {
//            super.setSelected(selected, animated: animated)
//        }
    }
    
    class ContactOldItemCell: UITableViewCell {
        
        class ScrollCell: UICollectionViewCell {
            static let cellName = "ContactItemCell.ScrollCell"
            
            let containerView: UIView = {
                let view = UIView()
                
                view.layer.cornerRadius = 12
                view.layer.masksToBounds = true
                view.backgroundColor = .white
                
                return view
            }()
            
            let badgeIndicator: UIImageView = {
                let view = UIImageView(frame: CGRect(x: 40, y: 40, width: 18, height: 18))
                
                view.layer.cornerRadius = 9
                view.layer.masksToBounds = true
                view.backgroundColor = AccountColorManager.shared.accounts.first!.color.palette.tint50
                
                return view
            }()
            
            let badgeIcon: UIImageView = {
                let view = UIImageView(frame: CGRect(1, 1, 16, 16))
                
                view.backgroundColor = .clear
                view.tintColor = MDCPalette.green.tint700
                view.image = UIImage(systemName: "plus.circle.fill")
                
                return view
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
                let label = UILabel(frame: CGRect(
                    origin: CGPoint(x: 76, y: 12),
                    size: CGSize(width: 240, height: 48)
                ))
                
                label.textColor = .label
                label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
                label.numberOfLines = 0
                
                return label
            }()
            
            let acceptButton: UIButton = {
                let button = UIButton(frame: CGRect(
                    origin: CGPoint(x: 76, y: 70),
                    size: CGSize(width: 80, height: 24)
                ))
                
                button.backgroundColor = .systemBlue
                button.setTitle("Accept", for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .regular)
                button.setTitleColor(.white, for: .normal)
                button.layer.cornerRadius = 8
                button.layer.masksToBounds = true
                
                
                return button
            }()
            
            let declineButton: UIButton = {
                let button = UIButton(frame: CGRect(
                    origin: CGPoint(x: 160, y: 70),
                    size: CGSize(width: 80, height: 24)
                ))
                
                button.backgroundColor = .systemBackground
                button.setTitle("Decline", for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .regular)
                button.setTitleColor(.systemRed, for: .normal)
                button.layer.cornerRadius = 8
                button.layer.masksToBounds = true
                
                
                return button
            }()
            
            func configure(owner: String, username: String) {
                addSubview(containerView)
                containerView.fillSuperview()
                badgeIndicator.addSubview(badgeIcon)
                avatarContainer.frame = CGRect(x: 8, y: 8, width: 60, height: 60)
                avatarContainer.addSubview(userImageView)
                avatarView.frame = CGRect(x: 2, y: 2, width: 56, height: 56)
                containerView.addSubview(avatarContainer)
                userImageView.addSubview(avatarView)
                avatarContainer.addSubview(badgeIndicator)
                avatarContainer.bringSubviewToFront(badgeIndicator)
//                titleLabel.text = "Natalia Barabanchikova"
                
                let mutableAttributedString = NSMutableAttributedString()
                let newLoginString = NSAttributedString(string: "\(username) ", attributes: [NSAttributedString.Key.font : UIFont.systemFont(ofSize: 18, weight: .medium),NSAttributedString.Key.foregroundColor: UIColor.black.cgColor ])
                let modifiedMessage = " sent you a subscription request"
                let otherString = NSAttributedString(string: modifiedMessage, attributes: [NSAttributedString.Key.font : UIFont.systemFont(ofSize: 16, weight: .regular),NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint600.cgColor ])
                mutableAttributedString.append(newLoginString)
                mutableAttributedString.append(otherString)
                self.titleLabel.attributedText = mutableAttributedString
                
                containerView.addSubview(titleLabel)
                containerView.addSubview(acceptButton)
                containerView.addSubview(declineButton)
                self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
                
                containerView.backgroundColor = AccountColorManager.shared.accounts.first!.color.palette.tint50
            }
        }
        
        static let cellName = "ContactItemCell"
        
        let collectionView: UICollectionView = {
            let flowLayout = UICollectionViewFlowLayout()
            flowLayout.scrollDirection = .horizontal
            flowLayout.itemSize = CGSize(width: 324, height: 104)
            flowLayout.minimumInteritemSpacing = 16
            flowLayout.minimumLineSpacing = 16
            flowLayout.sectionInset = UIEdgeInsets(square: 4)
            let view = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
            
            view.register(ScrollCell.self, forCellWithReuseIdentifier: ScrollCell.cellName)
            view.showsHorizontalScrollIndicator = false
            view.backgroundColor = .systemBackground//.systemGroupedBackground
            
            return view
        }()
        
        
        
        override func prepareForReuse() {
            super.prepareForReuse()

        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.contentView.addSubview(collectionView)
            collectionView.fillSuperview()
//            self.separ
        }
        
        override open func layoutSubviews() {
            super.layoutSubviews()
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                
            ])
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
            print("awaked from nib")
        }
        
//        override func setSelected(_ selected: Bool, animated: Bool) {
//            super.setSelected(selected, animated: animated)
//        }
    }
    
    class ContactItemCell: UITableViewCell {
        static let cellName = "ContactItemCell"
        
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
            stack.layoutMargins = UIEdgeInsets(top: 10, bottom: 10, left: 72, right: 4)
            
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
            
            label.lineBreakMode = .byTruncatingTail
            label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel//UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)
            label.numberOfLines = 1
            
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
            view.tintColor = MDCPalette.green.tint700
            view.image = UIImage(systemName: "info.circle.fill")
            
            return view
        }()
        
        let itsNotMeButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.setTitle("Revoke device", for: .normal)
            button.setTitleColor(.systemRed, for: .normal)
            
            return button
        }()
        
        
        public final func configure(owner: String, username: String, title: String, message: String) {
            self.avatarView.image = UIImageView.getDefaultAvatar(for: username, owner: owner, size: 56)
            self.badgeIndicator.backgroundColor = .systemBackground
            self.badgeIndicator.tintColor = .systemOrange
            
            self.titleLabel.text = title
            self.messageLabel.text = message
            
            self.accessoryType = .disclosureIndicator
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
            
            backgroundColor = .systemBackground
            
//            accountIndicator.frame = CGRect(x: 0.5, y: 1, width: 2, height: 74)
            badgeIndicator.addSubview(badgeIcon)
            avatarContainer.frame = CGRect(x: 8, y: 8, width: 60, height: 60)
            avatarContainer.addSubview(userImageView)
            avatarView.frame = CGRect(x: 2, y: 2, width: 56, height: 56)
            addSubview(avatarContainer)
            userImageView.addSubview(avatarView)
            avatarContainer.addSubview(badgeIndicator)
            avatarContainer.bringSubviewToFront(badgeIndicator)
            
//            infoStack.addArrangedSubview(topStack)
//            infoStack.addArrangedSubview(bottomStack)
//            infoStack.addArrangedSubview(itsNotMeButton)
            
            infoStack.addArrangedSubview(titleLabel)
            infoStack.addArrangedSubview(messageLabel)
//            infoStack.addArrangedSubview(dateLabel)
//            infoStack.setCustomSpacing(8, after: messageLabel)
            
            
            
//            self.selectionStyle = .none
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
            activateConstraints()
            layoutIfNeeded()
        }
        
        override open func layoutSubviews() {
            super.layoutSubviews()
        }
        
        private func activateConstraints() {
            NSLayoutConstraint.activate([
                itsNotMeButton.heightAnchor.constraint(equalToConstant: 32),
                titleLabel.heightAnchor.constraint(equalToConstant: 24),
                messageLabel.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
            print("awaked from nib")
        }
//        
//        override func setSelected(_ selected: Bool, animated: Bool) {
//            super.setSelected(selected, animated: animated)
//        }
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
            
//            self.selectionStyle = .none
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
