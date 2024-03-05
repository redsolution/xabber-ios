//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import Kingfisher

extension SearchResultsViewController {
    class MessageCell: UITableViewCell {
        static let cellName = "MessageCell"
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0.5, right: 0)
            
            return stack
        }()
        
        let infoStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.spacing = 0
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 4)
            
            return stack
        }()
        
        let usernameStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .trailing
            stack.spacing = 8
            
            return stack
        }()
        
        let topStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.spacing = 4
            stack.distribution = .fill
            stack.alignment = .center
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 8)
            
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
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 56))
            
            view.backgroundColor = .clear
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
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
            
            return view
        }()
        
        let statusIndicator: UIView = {
            let view = UIView()
            
            view.frame = CGRect(square: 18)
            view.backgroundColor = .white
            view.layer.cornerRadius = 8
            view.layer.masksToBounds = true
            
            return view
        }()
        
        let usernameLabel: UILabel = {
            let label = UILabel()
            
            label.backgroundColor = .white
            label.textColor = UIColor(red:0.13, green:0.13, blue:0.13, alpha:1)
            label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            
            return label
        }()
        
        let fromLabel: UILabel = {
            let label = UILabel()
            
            label.backgroundColor = .white
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
            
            label.backgroundColor = .white
            
            return label
        }()
        
        let dateLabel: UILabel = {
            let label = UILabel()
            
            label.backgroundColor = .white
            label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
            label.font = UIFont.systemFont(ofSize: 14)
            label.textAlignment = .right
            
            return label
        }()
        
        let accountIndicator: UIView = {
            let view = UIView()
            
            view.backgroundColor = .clear
            
            return view
        }()
                
        private func activateConstraints() {
            let constraints: [NSLayoutConstraint] = [
                userImageView.widthAnchor.constraint(equalToConstant: 56),
                userImageView.heightAnchor.constraint(equalToConstant: 56),
                accountIndicator.widthAnchor.constraint(equalToConstant: 2),
                topStack.heightAnchor.constraint(equalToConstant: 20),
                bottomStack.heightAnchor.constraint(equalToConstant: 36),
                accountIndicator.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 1)]
            NSLayoutConstraint.activate(constraints)
            
        }
        
        func configure(jid: String, owner: String, username: String, message text: String, status: ResourceStatus, isGroupchat: Bool, isIncome: Bool, date: Date, accountColor: UIColor) {
            
            DefaultAvatarManager.shared.getAvatar(url: nil, jid: jid, owner: owner, size: 56) { image in
                if let image = image {
                    self.avatarView.image = image
                } else {
                    self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: owner, size: 56)
                }
            }
            
            messageLabel.layoutFor(text, fromLabel: !isIncome)
            fromLabel.isHidden = !isIncome
            
            usernameLabel.text = username
            
            
            accountIndicator.backgroundColor = accountColor
            
            statusIndicator.isHidden = !isGroupchat
            
            let dateFormatter = DateFormatter()
            
            if NSCalendar.current.isDateInToday(date) {
                dateFormatter.dateFormat = "HH:mm"
            } else {
                dateFormatter.dateFormat = "dd MMM"
            }
            dateLabel.text = dateFormatter.string(from: date)
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
                userImageView.mask = UIImageView(image: image)
                avatarView.mask = UIImageView(image: image)
            } else {
                userImageView.mask = nil
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            backgroundColor = .white
            stack.addArrangedSubview(accountIndicator)
            stack.addArrangedSubview(userImageView)
            stack.addArrangedSubview(infoStack)
            
            infoStack.addArrangedSubview(topStack)
            infoStack.addArrangedSubview(bottomStack)
            
            topStack.addArrangedSubview(usernameLabel)
            topStack.addArrangedSubview(dateLabel)
            //
            //            membersStack.addArrangedSubview(membersIcon)
            //            membersStack.addArrangedSubview(membersLabel)
            
//            bottomStack.addArrangedSubview(from)
            bottomStack.addArrangedSubview(messageLabel)
            fromLabel.layoutFor("You:".localizeString(id: "you", arguments: []) + " ", fromLabel: true)
            
            statusIndicator.frame = CGRect(x: 38,
                                           y: 38,
                                           width: 18,
                                           height: 18)
            
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            
            
            let iconView = UIImageView(image: #imageLiteral(resourceName: "group-public").withRenderingMode(.alwaysTemplate))
            iconView.frame = CGRect(x: 2,
                                    y: 2,
                                    width: 14,
                                    height: 14)
            statusIndicator.addSubview(iconView)
            
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 74, right: 0)
            //            self.
            
            activateConstraints()
            //            let customSeparator = UIView(frame: CGRect(x: 74, y: self.frame.height - 1, width: frame.width - 74, height: 0.5))
            //            customSeparator.backgroundColor = .gray
            //            addSubview(customSeparator)
            
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}

fileprivate extension UILabel {
    
    func layoutFor(_ text: String, fromLabel: Bool) {
        self.lineBreakMode = .byWordWrapping
        self.numberOfLines = 0
        self.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
        let textString = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)
            ])
        let textRange = NSRange(location: 0, length: textString.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.4
        textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
        textString.addAttribute(NSAttributedString.Key.kern, value: -0.22, range: textRange)
        if fromLabel {
            textString.addAttribute(NSAttributedString.Key.foregroundColor,
                                    value: UIColor(red:0.13, green:0.13, blue:0.13, alpha:1),
                                    range: NSRange(location: 0, length: "You:".localizeString(id: "you", arguments: []).count))
        }
        self.attributedText = textString
    }
    
}
