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
import XMPPFramework.XMPPJID

class InfoScreenHeaderView: UIView {
    
    open var additionalTopOffset: CGFloat = 0
    
    let imageButton: RoundedAvatarButton = {
        let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                         avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
        button.layer.masksToBounds = true
        button.contentVerticalAlignment = .fill
        button.contentHorizontalAlignment = .fill
        button.imageView?.contentMode = .scaleAspectFill
        button.contentMode = .scaleAspectFill
        
        return button
    }()
    
    let titleButton: UIButton = {
        let button = UIButton()
        
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title1)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.5
        button.titleLabel?.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        
        return button
    }()
    
    let imageActivityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView()
        
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.stopAnimating()
        indicator.style = .medium
        
        return indicator
    }()
    
    let darkenedView: UIView = {
        let view = UIView()
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black.withAlphaComponent(0.27)
        view.alpha = 0
        
        return view
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        
        return label
    }()
    
    let thirdLineLabel: UILabel = {
        let label = UILabel()
    
        label.isHidden = true
        
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
    
        return label
    }()
    
    open var delegate: InfoScreenHeaderDelegate? = nil
    
    
    internal func activateConstraints() {

    }
    
    public final func update() {
    }
    
    var currentUrl: String? = ""
    
    public final func configure(avatarUrl: String?, owner: String, jid: String, titleColor: UIColor, title: String, subtitle: String?, thirdLine: String?) {
        if currentUrl != avatarUrl {
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                if let image = image {
                    self.imageButton.setImage(image, for: .normal)
                    self.currentUrl = avatarUrl
                } else {
                    self.imageButton.setImage(UIImageView.getDefaultAvatar(for: title, owner: owner, size: 128), for: .normal)
                }
            }
        }
        
        titleButton.setTitle(title, for: .normal)
        subtitleLabel.text = subtitle
        
        if let thirdLine = thirdLine {
            thirdLineLabel.text = thirdLine
            thirdLineLabel.isHidden = false
        } else {
            thirdLineLabel.isHidden = true
        }
        titleButton.setTitleColor(titleColor, for: .normal)
    }
    
    internal func setup() {
        backgroundColor = .systemGroupedBackground
        
        self.addSubview(imageButton)
        self.addSubview(titleButton)
        self.addSubview(subtitleLabel)
        
        imageButton.imageView?.addSubview(darkenedView)
        imageButton.imageView?.addSubview(imageActivityIndicator)
        
        imageButton.addTarget(self, action: #selector(onAvatarButtonTouchUpInside), for: .touchUpInside)
    }
    
    internal func updateSubviews() {
        let offset: CGFloat = 76 - self.additionalTopOffset
        self.imageButton.frame = CGRect(square: 128)
        self.imageButton.center = CGPoint(x: self.frame.width / 2, y: 112 - offset)
        self.titleButton.frame = CGRect(width: self.frame.width, height: 24)
        self.titleButton.center = CGPoint(x: self.frame.width / 2, y: 204 - offset)
        self.subtitleLabel.frame = CGRect(width: self.frame.width, height: 18)
        self.subtitleLabel.center = CGPoint(x: self.frame.width / 2, y: 232 - offset)
    }
    
    internal func setMask() {
        if AccountMasksManager.shared.load() != "square" {
            imageButton.mask = UIImageView(image: #imageLiteral(resourceName: AccountMasksManager.shared.mask128pt))
        } else {
            imageButton.mask = nil
        }
    }
    
    internal func showDarkenedView() {
        UIView.animate(withDuration: 0.2) {
            self.darkenedView.alpha = 1
        }
    }
    
    internal func hideDarkenedView() {
        self.darkenedView.alpha = 0
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        activateConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc
    private func onAvatarButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onImageButtonPressed()
    }
}
