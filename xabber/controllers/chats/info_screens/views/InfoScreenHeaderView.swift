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
    
    class HeaderButton: UIView {
        
        enum Style {
            case active
            case inactive
            case danger
        }
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 2

            stack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 4, bottom: 4, left: 0, right: 0)
            
            return stack
        }()
        
        let button: UIButton = {
            let button = UIButton(frame: CGRect(square: 40))
            
//            button.layer.cornerRadius = 20
//            button.layer.borderWidth = 1
            
            button.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
            
            
            return button
        }()
        
        let label: UILabel = {
            let label = UILabel()
            
//            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            let font = UIFont.systemFont(ofSize: 8, weight: .light)
            label.font = font
            if #available(iOS 13.0, *) {
                label.textColor = .secondaryLabel
            } else {
                label.textColor = .gray
            }
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            
            return label
        }()
        
        public func configure(_ image: UIImage, title: String, style: Style, enabled: Bool = true) {
            button.setImage(image.withRenderingMode(.alwaysTemplate), for: .normal)
            button.isEnabled = enabled
            label.text = title.uppercased()
            UIView.performWithoutAnimation {
                switch style {
                    
                case .active:
//                    self.button.backgroundColor = .systemBlue
//                    self.button.layer.borderColor = UIColor.systemBlue.cgColor
                    self.button.tintColor = .systemBlue
                    self.label.textColor = .systemBlue
                case .inactive:
//                    self.button.layer.borderColor = MDCPalette.grey.tint400.cgColor
//                    self.button.backgroundColor = MDCPalette.grey.tint400
                    self.button.tintColor = .gray
                    self.label.textColor = .gray
                case .danger:
//                    self.button.backgroundColor = .systemRed
//                    self.button.layer.borderColor = UIColor.systemRed.cgColor
                    self.button.tintColor = .systemRed
                    self.button.isEnabled = true
                    self.label.textColor = .systemRed
                }
            }
        }
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 36),
                button.widthAnchor.constraint(equalTo: button.heightAnchor, multiplier: 1)
            ])
        }
        
        internal func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(button)
            stack.addArrangedSubview(label)
//            self.layer.cornerRadius = 14
//            self.backgroundColor = .white
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
            activateConstraints()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalCentering
        
        stack.spacing = 6
//        stack.isLayoutMarginsRelativeArrangement = true
//        stack.layoutMargins = UIEdgeInsets(square: 8)
        
        return stack
    }()
    
    let imageButton: RoundedAvatarButton = {
        let button = RoundedAvatarButton(frame: CGRect(square: 128),
                                         avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
        
//        button.setContentHuggingPriority(.defaultLow, for: .vertical)
//        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
//        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
//        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
        
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .gray
        }
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
    
    let buttonsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.spacing = 12
        
        stack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 6, left: 4, right: 4)
        
        return stack
    }()
    
    let firstButton: HeaderButton = {
        let button = HeaderButton()
        
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        return button
    }()
    
    let secondButton: HeaderButton = {
        let button = HeaderButton()
        
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        return button
    }()
    
    let thirdButton: HeaderButton = {
        let button = HeaderButton()
        
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        return button
    }()
    
    let fourthButton: HeaderButton = {
        let button = HeaderButton()
        
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        return button
    }()
    
    let separatorLine: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.21)
        
        return view
    }()
    
    let coloredView: UIView = {
        let view = UIView()
        
        view.backgroundColor = .systemGroupedBackground
        
        return view
    }()
    
    let blurredEffectView: UIVisualEffectView = {
        let effect = UIBlurEffect(style: .regular)
        let view = UIVisualEffectView(effect: effect)
        
        return view
    }()
    
    open var delegate: InfoScreenHeaderButtonDelegate? = nil
    
    @objc
    private func onFirstButtonPressed() {
        self.delegate?.onFirstButtonPressed()
    }
    
    @objc
    private func onSecondButtonPressed() {
        self.delegate?.onSecondButtonPressed()
    }
    
    @objc
    private func onThirdButtonPressed() {
        self.delegate?.onThirdButtonPressed()
    }
    
    @objc
    private func onFourthButtonPressed() {
        self.delegate?.onFourthButtonPressed()
    }
    
    @objc
    private func onImageButtonPressed() {
        self.delegate?.onImageButtonPressed()
    }
    
    @objc
    private func onTitleButtonPressed() {
        self.delegate?.onTitleButtonPressed()
    }
    
    internal func activateConstraints() {
        let offsetHeight: CGFloat = 0
//        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
//            offsetHeight += bottomInset
//        }
        NSLayoutConstraint.activate([
            imageButton.topAnchor.constraint(equalTo: stack.topAnchor, constant: offsetHeight),//20
            imageButton.heightAnchor.constraint(equalToConstant: 128),
            imageButton.heightAnchor.constraint(equalToConstant: 128),
            imageButton.widthAnchor.constraint(equalToConstant: 128),//: imageButton.heightAnchor, multiplier: 1),
//            titleButton.heightAnchor.constraint(lessThanOrEqualToConstant: 32),
            titleButton.heightAnchor.constraint(equalToConstant: 32),
            subtitleLabel.heightAnchor.constraint(equalToConstant: 18),
            thirdLineLabel.heightAnchor.constraint(equalToConstant: 18),
            buttonsStack.heightAnchor.constraint(equalToConstant: 64),
            buttonsStack.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 20),
            buttonsStack.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: -20),
        ])
        if let imgView = imageButton.imageView {
            NSLayoutConstraint.activate([
                darkenedView.leftAnchor.constraint(equalTo: imgView.leftAnchor),
                darkenedView.topAnchor.constraint(equalTo: imgView.topAnchor),
                darkenedView.rightAnchor.constraint(equalTo: imgView.rightAnchor),
                darkenedView.bottomAnchor.constraint(equalTo: imgView.bottomAnchor),
                imageActivityIndicator.centerXAnchor.constraint(equalTo: imgView.centerXAnchor),
                imageActivityIndicator.centerYAnchor.constraint(equalTo: imgView.centerYAnchor)
            ])
        }
    }
    
    public final func update() {
        coloredView.frame = bounds
        blurredEffectView.frame = bounds
        
        separatorLine.frame = CGRect(x: 0, y: frame.height - 0.5, width: frame.width, height: 0.5)
        imageButton.setNeedsDisplay()
        //titleButton.setNeedsDisplay()
        print(self.imageButton.frame)
    }
    
    var currentUrl: String? = ""
    
    public final func configure(avatarUrl: String?, jid: String, owner: String, userId: String?, title: String?, subtitle: String?, thirdLine: String? = nil, titleColor: UIColor? = nil) {
        if currentUrl != avatarUrl {
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 128) { image in
                if let image = image {
                    self.imageButton.setImage(image, for: .normal)
                    self.currentUrl = avatarUrl
                } else {
                    self.imageButton.setImage(UIImageView.getDefaultAvatar(for: jid, owner: owner, size: 128), for: .normal)
                }
            }
        }
        
        titleButton.setTitle(title, for: .normal)
        
        if CommonConfigManager.shared.config.supports_multiaccounts {
            self.subtitleLabel.text = jid
        } else {
            self.subtitleLabel.text = XMPPJID(string: jid)?.user ?? jid
        }
//        subtitleLabel.text = jid //JidManager.shared.prepareJid(jid: subtitle ?? "")
        if let thirdLine = thirdLine {
            thirdLineLabel.text = thirdLine
            thirdLineLabel.isHidden = false
        } else {
            thirdLineLabel.isHidden = true
        }
        if let titleColor = titleColor {
            titleButton.setTitleColor(titleColor, for: .normal)
        }
        
        update()
    }
    
    internal func setup() {
        
        coloredView.frame = bounds
        blurredEffectView.frame = bounds
        
        addSubview(coloredView)
        
        backgroundColor = .clear
        addSubview(stack)
        if let topOffset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            stack.fillSuperviewWithOffset(top: topOffset, bottom: 4, left: 0, right: 0)
        } else {
            stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 0, right: 0)
        }
        stack.addArrangedSubview(imageButton)
        stack.addArrangedSubview(titleButton)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(thirdLineLabel)
        stack.addArrangedSubview(buttonsStack)
        
        stack.setCustomSpacing(16, after: imageButton)
        
        imageButton.imageView?.addSubview(darkenedView)
        imageButton.imageView?.addSubview(imageActivityIndicator)
        
        [firstButton, secondButton, thirdButton, fourthButton].forEach {
            $0.layer.backgroundColor = UIColor.white.cgColor
            $0.layer.cornerRadius = 8
            $0.layer.masksToBounds = true
        }
//        buttonsStack.layer.backgroundColor = UIColor.white.cgColor
//        buttonsStack.layer.cornerRadius = 14
        
        buttonsStack.addArrangedSubview(firstButton)
        buttonsStack.addArrangedSubview(secondButton)
        buttonsStack.addArrangedSubview(thirdButton)
        buttonsStack.addArrangedSubview(fourthButton)
        imageButton.addTarget(self, action: #selector(onImageButtonPressed), for: .touchUpInside)
        titleButton.addTarget(self, action: #selector(onTitleButtonPressed), for: .touchUpInside)
        firstButton.button.addTarget(self, action: #selector(onFirstButtonPressed), for: .touchUpInside)
        secondButton.button.addTarget(self, action: #selector(onSecondButtonPressed), for: .touchUpInside)
        thirdButton.button.addTarget(self, action: #selector(onThirdButtonPressed), for: .touchUpInside)
        fourthButton.button.addTarget(self, action: #selector(onFourthButtonPressed), for: .touchUpInside)
        update()
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
}
