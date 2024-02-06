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

class ContactListTableViewCell: BaseTableCell {
    public static let cellName: String = "ContactListTableViewCell"
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        
        stack.spacing = 8
        
        return stack
    }()
    
    private let avatarView: UIImageView = {
        let view = UIImageView(frame: CGRect(square: 48))
        if let image = UIImage(named: "white_mask_48pt") {
            view.mask = UIImageView(image: image)
        } else {
            view.mask = nil
        }
        view.contentMode = .scaleAspectFill
        
        return view
    }()
    
    private let labelsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .leading
        
        stack.spacing = 4
        
        return stack
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        return label
    }()
    
    private let subtitileLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        
        return label
    }()
        
    override func activateConstraints() {
        super.activateConstraints()
        let constaints: [NSLayoutConstraint] = [
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor),
        ]
        NSLayoutConstraint.activate(constaints)
    }
    
    override func setupSubviews() {
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 4, bottom: 4, left: 8, right: 20)
        stack.addArrangedSubview(avatarView)
        stack.addArrangedSubview(labelsStack)
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitileLabel)
        
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.image = nil
        titleLabel.text = nil
        subtitileLabel.text = nil
    }
    
    public final func configure(owner: String, jid: String, username: String, avatarUrl: String?) {
        self.titleLabel.text = username
        self.subtitileLabel.text = jid
        DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner) { image in
            if let image = image {
                self.avatarView.image = image
            } else {
                self.avatarView.setDefaultAvatar(for: jid, owner: owner)
            }
        }
    }
}
