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

class StatusInfoCell: UITableViewCell {
    static let cellName: String = "StatusCell"
            
    internal let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 8
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 10, bottom: 10, left: 20, right: 16)
        
        return stack
    }()
    
    internal let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body)
        
        return label
    }()

    internal let leadingIconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    internal let leadingIconSpacer: UIView = {
        let view = UIView()
        view.isHidden = true
        return view
    }()

    private lazy var leadingIconSpacerWidthConstraint =
        leadingIconSpacer.widthAnchor.constraint(equalToConstant: 0)

    private lazy var leadingIconLeadingConstraint =
        leadingIconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)

    internal let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body)
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
    
    internal let statusIndicator: RoundedStatusView = {
        let view = RoundedStatusView()
        
        view.frame = CGRect(square: 18)
        
        return view
    }()
    
    internal let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        
        view.isHidden = true
        
        return view
    }()
    
    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            activityIndicator.heightAnchor.constraint(equalToConstant: 24),
            activityIndicator.widthAnchor.constraint(equalToConstant: 24),
            statusIndicator.heightAnchor.constraint(equalToConstant: 18),
            statusIndicator.widthAnchor.constraint(equalToConstant: 18),
            leadingIconSpacerWidthConstraint,
            leadingIconLeadingConstraint,
            leadingIconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            //titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.5),
            //titleLabel.widthAnchor.constraint(equalToConstant: 100),
            //subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.25)
        ])
    }
    
    open func configure(title: String, status: ResourceStatus, entity: RosterItemEntity, isTemporary: Bool) {
        titleLabel.text = "Status".localizeString(id: "groupchat_status", arguments: [])
        subtitleLabel.text = title
        
       
        
        switch entity {
        case .groupchat, .incognitoChat, .bot, .server, .issue:
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: entity)
        default:
            statusIndicator.border(4)
            statusIndicator.setStatus(status: status, entity: entity)
        }
        if isTemporary {
            statusIndicator.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
            statusIndicator.isHidden = false
            activityIndicator.isHidden = true
        }
        
        if status == .offline {
            statusIndicator.isHidden = true
        } else {
            statusIndicator.isHidden = false
        }
        
        self.statusIndicator.layoutIfNeeded()
    }

    internal func configureLeadingIcon(
        image: UIImage?,
        tintColor: UIColor,
        leadingInset: CGFloat
    ) {
        leadingIconView.image = image
        leadingIconView.tintColor = tintColor
        leadingIconView.isHidden = image == nil
        leadingIconSpacerWidthConstraint.constant = image?.size.width ?? 0
        leadingIconLeadingConstraint.constant = leadingInset
        leadingIconSpacer.isHidden = image == nil
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.statusIndicator.isHidden = false
        leadingIconView.image = nil
        leadingIconView.isHidden = true
        leadingIconSpacerWidthConstraint.constant = 0
        leadingIconLeadingConstraint.constant = 0
        leadingIconSpacer.isHidden = true
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(stack)
        contentView.addSubview(leadingIconView)
        stack.fillSuperview()
        stack.addArrangedSubview(leadingIconSpacer)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(activityIndicator)
        stack.addArrangedSubview(statusIndicator)
        activateConstraints()
//            separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: 66, right: 0)
        selectionStyle = .none
        accessoryType = .disclosureIndicator
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
