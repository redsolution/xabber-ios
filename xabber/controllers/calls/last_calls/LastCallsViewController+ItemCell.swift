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
import Kingfisher
import MaterialComponents.MDCPalettes

extension LastCallsViewController {
    class ItemCell: CellWithBadge {
        static let cellName = "ItemCell"
        
        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()
        
        private static let weekdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter
        }()
        
        private static let monthDayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return formatter
        }()
        
        private static let fullDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
            return formatter
        }()
        
        internal var jid: String = ""
        internal var owner: String = ""
        internal var avatarUrl: String? = "-1"
        
        var stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .top
            stack.spacing = 12
            stack.distribution = .fill
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 12, bottom: 8, left: 16, right: 16)
            
            return stack
        }()
        
        let middleStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.distribution = .fill
            stack.alignment = .fill
            stack.spacing = 2
            
            return stack
        }()
        
        let titleRow: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .firstBaseline
            stack.spacing = 8
            stack.distribution = .fill
            
            return stack
        }()
        
        let subtitleRow: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 6
            
            return stack
        }()
        
        let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
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
            
            label.font = UIFont.systemFont(ofSize: 17, weight: .regular)
            label.numberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            return label
        }()
        
        let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
            }
            label.numberOfLines = 1
            
            return label
        }()
        
        let dateLabel: UILabel = {
            let label = UILabel()
            
            label.textColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textAlignment = .right
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
            
            return label
        }()
        
        let stateIndicator: UIImageView = {
            let view = UIImageView()
            
            view.isHidden = true
            view.contentMode = .scaleAspectFit
            
            return view
        }()
        
        
        private func activateConstraints() {
            let constraints: [NSLayoutConstraint] = [
                dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
                avatarView.widthAnchor.constraint(equalToConstant: 48),
                avatarView.heightAnchor.constraint(equalToConstant: 48),
                stateIndicator.widthAnchor.constraint(equalToConstant: 12),
                stateIndicator.heightAnchor.constraint(equalToConstant: 12)]
            NSLayoutConstraint.activate(constraints)
            
        }
        
        private static func formattedDate(from date: Date) -> String {
            let today = Date()
            if NSCalendar.current.isDateInToday(date) {
                return Self.timeFormatter.string(from: date)
            } else if abs(today.timeIntervalSince(date)) < 12 * 60 * 60 {
                return Self.timeFormatter.string(from: date)
            } else if (NSCalendar.current.dateComponents([.day], from: date, to: today).day ?? 0) <= 7 {
                return Self.weekdayFormatter.string(from: date)
            } else if (NSCalendar.current.dateComponents([.year], from: date, to: today).year ?? 0) < 1 {
                return Self.monthDayFormatter.string(from: date)
            } else {
                return Self.fullDateFormatter.string(from: date)
            }
        }
        
        func configure(owner: String, jid: String, avatarUrl: String?, username: String, date: Date, direction: LastCallsViewController.DisplayCallDirection, outgoing: Bool) {
            self.jid = jid
            self.owner = owner
            self.avatarUrl = avatarUrl
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 48) { image in
                guard self.avatarUrl == avatarUrl else { return }
                self.avatarView.image = image ?? UIImageView.getDefaultAvatar(for: username, owner: owner, size: 48)
            }
            titleLabel.text = JidManager.shared.prepareJid(jid: username)
            dateLabel.text = Self.formattedDate(from: date)
            titleLabel.textColor = direction.titleColor
            subtitleLabel.text = direction.title
            subtitleLabel.textColor = direction.subtitleTintColor
            let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            stateIndicator.image = UIImage(systemName: direction.iconName(outgoing: outgoing), withConfiguration: config)
            stateIndicator.tintColor = direction.subtitleTintColor
            stateIndicator.isHidden = false
                       
        }
        
        func setMask() {
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                avatarView.mask = UIImageView(image: image)
            } else {
                avatarView.mask = nil
            }
        }
        
        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            contentView.addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(middleStack)
            stack.addArrangedSubview(dateLabel)
            
            middleStack.addArrangedSubview(titleRow)
            middleStack.addArrangedSubview(subtitleRow)
            
            titleRow.addArrangedSubview(titleLabel)
            titleRow.addArrangedSubview(UIView())
            subtitleRow.addArrangedSubview(stateIndicator)
            subtitleRow.addArrangedSubview(subtitleLabel)
            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 76, right: 16)
            preservesSuperviewLayoutMargins = true
            contentView.preservesSuperviewLayoutMargins = true
            activateConstraints()
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        override func awakeFromNib() {
            super.awakeFromNib()
        }
        
        override func prepareForReuse() {
            super.prepareForReuse()
            avatarUrl = "-1"
            avatarView.image = nil
            avatarView.backgroundColor = MDCPalette.grey.tint200
            titleLabel.text = nil
            subtitleLabel.text = nil
            dateLabel.text = nil
            stateIndicator.image = nil
            stateIndicator.isHidden = true
            titleLabel.textColor = {
                if #available(iOS 13.0, *) {
                    return .label
                } else {
                    return .darkText
                }
            }()
        }
        
        override func setSelected(_ selected: Bool, animated: Bool) {
            super.setSelected(selected, animated: animated)
        }
    }
}
