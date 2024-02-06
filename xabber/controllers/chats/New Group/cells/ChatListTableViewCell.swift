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

class ChatListTableViewCell: UITableViewCell {
    static let cellName = "ChatListTableViewCell"
    
    public var badgeColor : UIColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1.0)
    public var badgeColorHighlighted : UIColor = .darkGray
    public var badgeFontSize : Float = 13.0
    public var badgeTextStyle: UIFont.TextStyle?
    public var badgeTextColor: UIColor?
    public var badgeRadius : Float = 20
    public var badgeOffset = CGPoint(x:12, y:10)
    public var subBadgeOffset: CGFloat = 30
    
    
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
    
    var badgeStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.distribution = .fill
        
        return stack
    }()
    
    let labelsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        
        return stack
    }()
    
    let userImageView: UIView = {
        let view = UIView(frame: CGRect(square: 56))
        
        view.backgroundColor = .clear
        
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
    
    let statusIndicator: RoundedStatusView = {
        let view = RoundedStatusView()
        
        view.frame = CGRect(x: 41,
                            y: 41,
                            width: 12,
                            height: 12)

        view.border(1)
        view.setStatus(status: .offline, entity: .contact)
        
        return view
    }()
    
    let usernameLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)

        label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.textColor = MDCPalette.grey.tint800
        label.font = UIFont.systemFont(ofSize: 14)
        
        return label
    }()
    
    let messageLabel: UILabel = {
        let label = UILabel()
        
//            label.backgroundColor = .white
        
        label.lineBreakMode = .byWordWrapping
        label.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha:1)
        
        return label
    }()
    
    let dateLabel: UILabel = {
        let label = UILabel()
        
//            label.backgroundColor = .white
        label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
        label.font = UIFont.systemFont(ofSize: 14)
        label.textAlignment = .right
        
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        
        return label
    }()
    
    let unreadLabel: UILabel = {
        let label = UILabel()
        
        label.backgroundColor = UIColor(red:0.11, green:0.37, blue:0.13, alpha:1)
        
        return label
    }()
    
    let syncedIndicator: UIImageView = {
        let view = UIImageView()
        
        view.image = #imageLiteral(resourceName: "circle4").withRenderingMode(.alwaysTemplate)
        view.tintColor = MDCPalette.grey.tint300
        
        return view
    }()
    
    let muteIndicator: UIImageView = {
        let view = UIImageView()
        
        view.image = #imageLiteral(resourceName: "bell-off").withRenderingMode(.alwaysTemplate)
        view.tintColor = MDCPalette.grey.tint400
        
        return view
    }()
    
    let encryptedIndicator: UIImageView = {
        let view = UIImageView()
        
//        view.image = #imageLiteral(resourceName: "lock").withRenderingMode(.alwaysTemplate)
        view.image = UIImage(systemName: "lock.fill")?.withRenderingMode(.alwaysTemplate)
        view.tintColor = MDCPalette.green.tint500
        view.isHidden = true
        
        return view
    }()
    
    let deliveryIndicator: UIImageView = {
        let view = UIImageView()
        
        return view
    }()
    
    let pinnedIndicator: UIImageView = {
        let view = UIImageView()
        
        view.image = #imageLiteral(resourceName: "pinned").withRenderingMode(.alwaysTemplate)
        view.tintColor = MDCPalette.grey.tint500
        
        return view
    }()
    
    let errorIndicator: UIImageView = {
        let view = UIImageView()
        
        view.image = #imageLiteral(resourceName: "alert-circle").withRenderingMode(.alwaysTemplate)
        view.tintColor = MDCPalette.red.tint500
        
        return view
    }()
    
    let accountIndicator: UIView = {
        let view = UIView()
        
        view.backgroundColor = .clear
        
        return view
    }()
    
    let badgeView: UIButton = {
        let view = UIButton()
        
        view.contentEdgeInsets = UIEdgeInsets(square: 4)
        view.layer.cornerRadius = 10
        view.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        view.layer.masksToBounds = true
        view.setTitleColor(.white, for: .normal)
        view.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        
        return view
    }()
    
    let subBadgeView: UIButton = {
        let view = UIButton()
        
        view.layer.cornerRadius = 10
        view.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        view.layer.masksToBounds = true
        view.setTitleColor(.white, for: .normal)
        view.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        
        return view
    }()
    
    public var badgeString: String = ""
    
    public final func configure(_ jid: String,
                                owner: String,
                                username: String,
                                message: String,
                                date: Date?,
                                deliveryState: MessageStorageItem.MessageSendingState?,
                                isMute: Bool,
                                isSynced: Bool,
                                isGroupchat: Bool,
                                status: ResourceStatus,
                                entity: RosterItemEntity,
                                conversationType: ClientSynchronizationManager.ConversationType,
                                unread: Int,
                                unreadString: String?,
                                indicator color: UIColor,
                                isDraft: Bool,
                                isAttachment: Bool,
                                groupchatNickname: String?,
                                isSystem: Bool,
                                isPinned: Bool = false,
                                subRequest: Bool,
                                avatarUrl: String?,
                                hasErrorInChat: Bool) {

        DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 56) { image in
            if let image = image {
                self.avatarView.image = image
            } else {
                self.avatarView.setDefaultAvatar(for: username, owner: owner)
            }
        }
        
        messageLabel.layoutFor(
            JidManager.shared.prepareJid(jid: message),
            isDraft: isDraft,
            groupchatNickname: groupchatNickname,
            color: isAttachment ? AccountColorManager.shared.palette(for: owner).tint600 : nil,
            isSystem: isSystem
        )
        
        usernameLabel.text = username
        
        subtitleLabel.text = groupchatNickname
        
        switch conversationType {
            case .omemo, .omemo1, .axolotl:
                self.encryptedIndicator.isHidden = false
                self.usernameLabel.textColor = MDCPalette.green.tint500
            default:
                self.encryptedIndicator.isHidden = true
            break
        }
        
        if isPinned {
            self.contentView.backgroundColor = MDCPalette.grey.tint100
            self.pinnedIndicator.isHidden = false
        } else {
            self.pinnedIndicator.isHidden = true
        }
        
        if isGroupchat {
            messageLabel.numberOfLines = 1
        } else {
            messageLabel.numberOfLines = 2
        }
        if let date = date {
            let dateFormatter = DateFormatter()
            let today = Date()
            if NSCalendar.current.isDateInToday(date) {
                dateFormatter.dateFormat = "HH:mm"
            } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                dateFormatter.dateFormat = "HH:mm"
            } else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                dateFormatter.dateFormat = "E"
            } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                dateFormatter.dateFormat = "MMM dd"
            } else {
                dateFormatter.dateFormat = "d MMM yyyy"
            }
            dateLabel.text = dateFormatter.string(from: date)
        }
        muteIndicator.isHidden = !isMute
        syncedIndicator.alpha = isSynced ? 0.0 : 0.87
        
        accountIndicator.backgroundColor = color
                    
        if [.incognitoChat, .groupchat, .server, .privateChat, .issue].contains(entity) {
            statusIndicator.frame = CGRect(x: 39,
                                           y: 39,
                                           width: 16,
                                           height: 16)
            statusIndicator.border(1)
        }
        
        statusIndicator.setStatus(status: status, entity: entity)
        
        badgeColor = isMute ? UIColor(red: 189/255, green: 189/255, blue: 189/255, alpha: 1.0) : UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        
        if let deliveryState = deliveryState {
            deliveryIndicator.isHidden = false
            switch deliveryState {
            case .sending, .notSended, .uploading:
                deliveryIndicator.image = #imageLiteral(resourceName: "clock").withRenderingMode(.alwaysTemplate)
                deliveryIndicator.tintColor = MDCPalette.lightBlue.tint500
            case .sended:
                deliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(.alwaysTemplate)
                deliveryIndicator.tintColor = MDCPalette.grey.tint500
            case .deliver:
                deliveryIndicator.image = #imageLiteral(resourceName: "check").withRenderingMode(.alwaysTemplate)
                deliveryIndicator.tintColor = MDCPalette.green.tint500
            case .read:
                deliveryIndicator.image = #imageLiteral(resourceName: "check-all").withRenderingMode(.alwaysTemplate)
                deliveryIndicator.tintColor = MDCPalette.green.tint500
            case .error:
                deliveryIndicator.image = #imageLiteral(resourceName: "close").withRenderingMode(.alwaysTemplate)
                deliveryIndicator.tintColor = MDCPalette.red.tint500
            case .none:
                deliveryIndicator.isHidden = true
                break
            }
        } else {
            deliveryIndicator.isHidden = true
            if unread > 0 {
                badgeView.setTitle("\(unread)", for: .normal)
                if let size = badgeView.titleLabel?.frame.size {
                    badgeView.sizeThatFits(size) //sizeToFit() -  некорректно работает на старом iPad
                }
                badgeView.isHidden = false
            } else {
                badgeView.isHidden = true
            }
        }
        
        if hasErrorInChat {
            self.contentView.backgroundColor = UIColor(red: 255/255, green: 235/255, blue: 238/255, alpha: 1.0)
            self.errorIndicator.isHidden = false
        } else {
            self.errorIndicator.isHidden = true
            self.contentView.backgroundColor = .systemBackground
        }
        
        if subRequest {
//            subBadgeView.setTitle("􀅼", for: .normal)
//            if #available(iOS 13.0, *) {
//                subBadgeView.imageEdgeInsets = UIEdgeInsets(square: 5)
//                subBadgeView.setImage(UIImage(systemName: "plus")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            } else {
                subBadgeView.setTitle("＋", for: .normal)
            subBadgeView.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
//            }
            subBadgeView.isHidden = false
            subBadgeView.tintColor = .white
        } else {
            subBadgeView.isHidden = true
        }
        
        badgeView.backgroundColor = badgeColor
        subBadgeView.backgroundColor = badgeColor
    }
    
    func setMask() {
        if let image = UIImage(named: AccountMasksManager.shared.mask56pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        deliveryIndicator.image = nil
        usernameLabel.textColor = UIColor(red:0.13, green:0.13, blue:0.13, alpha:1)
        usernameLabel.text = nil
        usernameLabel.attributedText = nil
        muteIndicator.isHidden = true
        messageLabel.attributedText = nil
        messageLabel.text = nil
        dateLabel.text = nil
        dateLabel.attributedText = nil
        deliveryIndicator.isHidden = true
        pinnedIndicator.isHidden = true
        encryptedIndicator.isHidden = true
        badgeView.isHidden = true
        subBadgeView.isHidden = true
        avatarView.image = nil
        errorIndicator.isHidden = true
        
        self.contentView.backgroundColor = .systemBackground

        badgeString = ""
        badgeView.setTitle(nil, for: .normal)
        if bottomStack.layoutMargins.right > 8 {
            bottomStack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 8)
        }
        if statusIndicator.frame.width > 14 {
            statusIndicator.frame = CGRect(x: 41,
                                           y: 41,
                                           width: 12,
                                           height: 12)
            statusIndicator.border(1)
        }
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

//        self.layer.shouldRasterize = true
//        self.layer.rasterizationScale = UIScreen.main.scale
        
        contentView.addSubview(infoStack)
        infoStack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 2, right: 0)
        
        backgroundColor = .systemBackground
        
        accountIndicator.frame = CGRect(x: 0.5, y: 1, width: 2, height: 74)
        userImageView.frame = CGRect(x: 10, y: 10, width: 56, height: 56)
        addSubview(accountIndicator)
        addSubview(userImageView)
        
        infoStack.addArrangedSubview(topStack)
        infoStack.addArrangedSubview(bottomStack)
        
        topStack.addArrangedSubview(encryptedIndicator)
        topStack.addArrangedSubview(usernameLabel)
        topStack.addArrangedSubview(muteIndicator)
        topStack.addArrangedSubview(UIStackView())
        topStack.addArrangedSubview(deliveryIndicator)
        topStack.addArrangedSubview(dateLabel)
        topStack.addArrangedSubview(syncedIndicator)
        
        topStack.setCustomSpacing(4, after: encryptedIndicator)
        
        labelsStack.addArrangedSubview(subtitleLabel)
        labelsStack.addArrangedSubview(messageLabel)
        bottomStack.addArrangedSubview(labelsStack)
        bottomStack.addArrangedSubview(badgeStack)
        
        badgeStack.addArrangedSubview(subBadgeView)
        badgeStack.addArrangedSubview(badgeView)
        badgeStack.addArrangedSubview(pinnedIndicator)
        badgeStack.addArrangedSubview(errorIndicator)
        
        userImageView.addSubview(avatarView)
        userImageView.addSubview(statusIndicator)
        
        deliveryIndicator.isHidden = true
        pinnedIndicator.isHidden = true
        encryptedIndicator.isHidden = true
        badgeView.isHidden = true
        subBadgeView.isHidden = true
        errorIndicator.isHidden = true
        
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
            bottomStack.heightAnchor.constraint(equalToConstant: 36),
            deliveryIndicator.widthAnchor.constraint(equalToConstant: 16),
            deliveryIndicator.heightAnchor.constraint(equalToConstant: 16),
            pinnedIndicator.widthAnchor.constraint(equalToConstant: 24),
            pinnedIndicator.heightAnchor.constraint(equalToConstant: 24),
            muteIndicator.widthAnchor.constraint(equalToConstant: 16),
            muteIndicator.heightAnchor.constraint(equalToConstant: 16),
            syncedIndicator.heightAnchor.constraint(equalToConstant: 4),
            syncedIndicator.widthAnchor.constraint(equalToConstant: 4),
            encryptedIndicator.widthAnchor.constraint(equalToConstant:  16),
            encryptedIndicator.heightAnchor.constraint(equalToConstant: 16),
            
            badgeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            badgeView.heightAnchor.constraint(equalToConstant: 20),
            
            subBadgeView.widthAnchor.constraint(equalToConstant:  20),
            subBadgeView.heightAnchor.constraint(equalToConstant: 20),
            
            errorIndicator.widthAnchor.constraint(equalToConstant: 24),
            errorIndicator.heightAnchor.constraint(equalToConstant: 24),
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

fileprivate extension UILabel {

    func layoutFor(_ text: String, isDraft: Bool, groupchatNickname: String?, color: UIColor?, isSystem: Bool) {
        if #available(iOS 13.0, *) {
            self.textColor = .secondaryLabel
        } else {
            self.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
        }
        var textString: NSMutableAttributedString
        if isSystem {
            textString = NSMutableAttributedString(string: text, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14).italic()
            ])
        } else {
            textString = NSMutableAttributedString(string: text, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)
            ])
        }
        if isDraft {
            textString = NSMutableAttributedString(string: ["Draft".localizeString(id: "draft", arguments: []), text].joined(separator: "\n"), attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)
            ])
        }
        let textRange = NSRange(location: 0, length: textString.length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.43
        textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
        textString.addAttribute(NSAttributedString.Key.kern, value: -0.22, range: textRange)
        if isDraft {
            let draftRange = NSRange(location: 0, length: NSString(string: "Draft".localizeString(id: "draft", arguments: [])).length)
            textString.addAttribute(.foregroundColor, value: MDCPalette.red.tint700, range: draftRange)
        }
        if let color = color, !isDraft {
            let fullRange = NSRange(location: 0, length: textString.length)
            textString.addAttribute(.foregroundColor, value: color, range: fullRange)
        }
        
        self.attributedText = textString
    }
}
