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

class TableHeaderWithAvatarCell: UITableViewCell {
    enum Target {
        case button
        case title
    }
    
    public static let cellName: String = "topCell"
    
    private let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        
        return stack
    }()
    
    private let avatarView: UIButton = {
        let button = UIButton(frame: CGRect(square: 128))
        
        if AccountMasksManager.shared.load() != "square" {
            button.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask128pt))
        } else {
            button.mask = nil
        }
        button.layer.masksToBounds = true
        button.contentMode = .scaleAspectFill
        button.imageView?.contentMode = .scaleAspectFill
        
        return button
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.isUserInteractionEnabled = true
        
        return label
    }()
    
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15, weight: .light)
        label.isUserInteractionEnabled = true
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
                
        return label
    }()
    
    public var actionCallback: ((Target) -> Void)? = nil
    
    public final func configure(avatar avatarImage: UIImage?, owner: String, jid: String, displayName: String, thinLabel: Bool = false) {
        self.titleLabel.text = displayName
        self.subtitleLabel.text = JidManager.shared.prepareJid(jid: jid)
        if thinLabel {
            titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .light)
            titleLabel.textColor = .systemBlue
            subtitleLabel.isHidden = true
        }
        guard let url = URL(string: jid) else {
            return
        }
        if let image = avatarImage {
            self.avatarView.setImage(image.upscale(dimension: 128), for: .normal)
            self.avatarView.contentMode = .scaleAspectFill
        } else {
            self.avatarView.contentMode = .scaleAspectFill
            self.avatarView.kf.setImage(with: ImageResource(downloadURL: url, cacheKey: jid), for: .normal, placeholder: nil, options: [.onlyFromCache], progressBlock: nil) { result in
                self.avatarView.contentMode = .scaleAspectFill
                
                switch result {
                case .success(let data):
                    self.avatarView.setImage(data.image.upscale(dimension: 128), for: .normal)
                    self.avatarView.contentMode = .scaleAspectFill
                    self.avatarView.layoutIfNeeded()
                case .failure(_):
                    break
                }
            }
        }
    }
    
    func setMask() {
        if let image = UIImage(named: AccountMasksManager.shared.mask128pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
    
    private final func setupSubviews() {
        contentView.addSubview(stack)
        stack.fillSuperviewWithOffset(top: 8, bottom: 0, left: 16, right: 16)
        stack.addArrangedSubview(avatarView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        backgroundColor = .groupTableViewBackground
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 128),
            avatarView.heightAnchor.constraint(equalToConstant: 128),
            titleLabel.heightAnchor.constraint(equalToConstant: 32),
            subtitleLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
        selectionStyle = .none
        let gestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(onTitleTouchUp))
        gestureRecognizer.delaysTouchesBegan = true
        titleLabel.addGestureRecognizer(gestureRecognizer)
        avatarView.addTarget(self, action: #selector(onButtonTouchUpInside), for: .touchUpInside)
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .value1, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
    
    @objc
    private final func onButtonTouchUpInside(_ sender: UIButton) {
        self.actionCallback?(.button)
    }
    
    @objc
    private final func onTitleTouchUp(_ sender: UIGestureRecognizer) {
        self.actionCallback?(.title)
    }
}
