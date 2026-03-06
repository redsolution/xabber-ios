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
        button.backgroundColor = MDCPalette.grey.tint50
        
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
    
    let subtitleLabel: XCopyableLabel = {
        let label = XCopyableLabel()
        
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
    
    let supportButtonsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.axis = .horizontal
        stack.spacing = 8
        
        return stack
    }()
    
    let buttonsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.axis = .vertical
        
        return stack
    }()
    
    var showButtons: Bool {
        didSet {
            self.buttonsStack.isHidden = !self.showButtons
        }
    }
    
    internal var buttons: [UIButton] = []
    
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
        
        self.addSubview(self.imageButton)
        self.addSubview(self.titleButton)
        self.addSubview(self.subtitleLabel)
        self.addSubview(self.buttonsStack)
        
        self.buttonsStack.addArrangedSubview(self.supportButtonsStack)
        
        
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
        self.buttonsStack.frame = CGRect(width: self.frame.width, height: 44)
        self.buttonsStack.center = CGPoint(x: self.frame.width / 2, y: 278 - offset)
    }
    
    internal func setMask() {
        if AccountMasksManager.shared.load() != "square" {
            imageButton.mask = UIImageView(image: imageLiteral( AccountMasksManager.shared.mask128pt))
        } else {
            imageButton.mask = nil
        }
    }
    
    internal let xabberAccountButton: GradientBorderButton = {
        let button = GradientBorderButton()

        var conf = UIButton.Configuration.plain()
        conf.title = "Xabber account"
        conf.baseForegroundColor = .label
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            return outgoing
        }
        button.configuration = conf

        return button
    }()

    public final func setupXabberAccountButton() {
        self.showButtons = true
        self.buttonsStack.subviews.forEach { $0.removeFromSuperview() }
        self.buttonsStack.addArrangedSubview(xabberAccountButton)
        NSLayoutConstraint.activate([
            xabberAccountButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 224),
            xabberAccountButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        
        self.xabberAccountButton.addTarget(self, action: #selector(self.onXabberAccountButtonTouchUpInside), for: .touchUpInside)
    }
    
    @objc
    private func onXabberAccountButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onXabberAccount()
    }

    override init(frame: CGRect) {
        self.showButtons = false
        super.init(frame: frame)
        setup()
        activateConstraints()
    }
    
    public final func configureButtons(_ block: (() -> [UIButton])) {
        self.buttons = block()
        NSLayoutConstraint.activate(self.buttons.compactMap { return [
            $0.widthAnchor.constraint(equalToConstant: 80),
            $0.heightAnchor.constraint(equalToConstant: 72)
        ] }.flatMap({ $0 }))
        self.buttons.forEach { self.supportButtonsStack.addArrangedSubview($0) }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc
    private func onAvatarButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onImageButtonPressed()
    }
}

// MARK: - Gradient Border Button

internal class GradientBorderButton: UIButton {

    private let gradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.colors = [
            UIColor(red: 224/255, green: 32/255, blue: 32/255, alpha: 1).cgColor,   // #E02020
            UIColor(red: 250/255, green: 100/255, blue: 0, alpha: 1).cgColor,       // #FA6400
            UIColor(red: 247/255, green: 181/255, blue: 0, alpha: 1).cgColor,       // #F7B500
            UIColor(red: 109/255, green: 212/255, blue: 0, alpha: 1).cgColor,       // #6DD400
            UIColor(red: 0, green: 145/255, blue: 1, alpha: 1).cgColor,             // #0091FF
            UIColor(red: 98/255, green: 54/255, blue: 1, alpha: 1).cgColor,         // #6236FF
            UIColor(red: 182/255, green: 32/255, blue: 224/255, alpha: 1).cgColor   // #B620E0
        ]
        layer.locations = [0, 0.17, 0.33, 0.50, 0.67, 0.83, 1.0]
        layer.startPoint = CGPoint(x: 0, y: 0)
        layer.endPoint = CGPoint(x: 1, y: 1)
        return layer
    }()

    private let borderMask = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        layer.cornerRadius = 16
        clipsToBounds = true

        borderMask.fillRule = .evenOdd
        gradientLayer.mask = borderMask
        layer.insertSublayer(gradientLayer, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let borderWidth: CGFloat = 3
        let cornerRadius: CGFloat = 16

        gradientLayer.frame = bounds

        let outer = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius)
        let inner = UIBezierPath(roundedRect: bounds.insetBy(dx: borderWidth, dy: borderWidth),
                                 cornerRadius: cornerRadius - borderWidth)
        outer.append(inner)
        outer.usesEvenOddFillRule = true
        borderMask.path = outer.cgPath
    }
}
