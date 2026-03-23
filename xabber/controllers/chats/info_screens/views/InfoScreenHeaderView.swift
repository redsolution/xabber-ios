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

    // MARK: - Configuration

    /// Push all elements down (e.g. to avoid nav bar overlap on specific screens).
    open var additionalTopOffset: CGFloat = 0
    open var bottomPadding: CGFloat = 16

    // The avatar's center.y = avatarBaseCenter + additionalTopOffset.
    // avatarBaseCenter = 36 keeps the top 28pt of the avatar above the header
    // frame so it overlaps the transparent navigation bar.
    private let avatarBaseCenter: CGFloat = 36
    private let avatarSize: CGFloat = 128

    // Maximum width for the action buttons row (prevents huge gaps on iPad).
    private let maxButtonsWidth: CGFloat = 420
    private let avatarToTitleSpacing: CGFloat = 8
    private let titleToSubtitleSpacing: CGFloat = 8
    private let subtitleToThirdLineSpacing: CGFloat = 8
    private let textToButtonsSpacing: CGFloat = 8
    private let buttonsRowHeight: CGFloat = 56
    private let buttonWidth: CGFloat = 76
    private let buttonHeight: CGFloat = 56

    // MARK: - Avatar

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

    // MARK: - Text labels

    let titleButton: UIButton = {
        let button = UIButton()
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .title2)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        return button
    }()

    let subtitleLabel: XCopyableLabel = {
        let label = XCopyableLabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    let thirdLineLabel: UILabel = {
        let label = UILabel()
        label.isHidden = true
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        return label
    }()

    // MARK: - Action buttons

    /// Horizontal stack containing the action buttons (InfoHeaderButton instances).
    let supportButtonsStack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.axis = .horizontal
        stack.spacing = 8
        return stack
    }()

    /// Outer vertical stack (kept for API compatibility with callers that access buttonsStack directly).
    let buttonsStack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.distribution = .fill
        stack.axis = .vertical
        return stack
    }()

    var showButtons: Bool {
        didSet {
            buttonsStack.isHidden = !showButtons
        }
    }

    internal var buttons: [UIButton] = []

    open var delegate: InfoScreenHeaderDelegate? = nil

    // MARK: - Setup

    internal func setup() {
        backgroundColor = .systemGroupedBackground

        addSubview(imageButton)
        addSubview(titleButton)
        addSubview(subtitleLabel)
        addSubview(thirdLineLabel)
        addSubview(buttonsStack)

        buttonsStack.addArrangedSubview(supportButtonsStack)

        imageButton.addTarget(self, action: #selector(onAvatarButtonTouchUpInside), for: .touchUpInside)
    }

    // MARK: - Layout

    /// Lays out all subviews. Called from viewWillAppear after setting the frame.
    internal func updateSubviews() {
        let w = bounds.width
        let horizontalInset: CGFloat = 20

        // ── Avatar ──────────────────────────────────────────────────────────
        let avatarCenterY = avatarBaseCenter + additionalTopOffset
        imageButton.frame = CGRect(square: avatarSize)
        imageButton.center = CGPoint(x: w / 2, y: avatarCenterY)

        // ── Text block ──────────────────────────────────────────────────────
        var y = avatarCenterY + avatarSize / 2 + avatarToTitleSpacing

        let textWidth = w - horizontalInset * 2

        // Title – allow up to 2 lines
        let titleFont = UIFont.preferredFont(forTextStyle: .title2)
        let titleHeight = max(ceil(titleFont.lineHeight) * 2 + 4, 28)
        titleButton.frame = CGRect(x: horizontalInset, y: y, width: textWidth, height: titleHeight)
        y = titleButton.frame.maxY + titleToSubtitleSpacing

        // Subtitle
        let bodyFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let subtitleHeight = max(ceil(bodyFont.lineHeight), 20)
        if let subtitle = subtitleLabel.text, !subtitle.isEmpty {
            subtitleLabel.frame = CGRect(x: horizontalInset, y: y, width: textWidth, height: subtitleHeight)
            y = subtitleLabel.frame.maxY
        } else {
            subtitleLabel.frame = .zero
        }

        // Third line (only when visible)
        if !thirdLineLabel.isHidden {
            if subtitleLabel.frame != .zero {
                y += subtitleToThirdLineSpacing
            }
            thirdLineLabel.frame = CGRect(x: horizontalInset, y: y, width: textWidth, height: subtitleHeight)
            y = thirdLineLabel.frame.maxY
        } else {
            thirdLineLabel.frame = .zero
        }

        // ── Action buttons ──────────────────────────────────────────────────
        if !buttonsStack.isHidden {
            y += textToButtonsSpacing
            let buttonsWidth = min(w - horizontalInset * 2, maxButtonsWidth)
            let buttonsX = (w - buttonsWidth) / 2
            buttonsStack.frame = CGRect(x: buttonsX, y: y, width: buttonsWidth, height: buttonsRowHeight)
            y = buttonsStack.frame.maxY
        } else {
            buttonsStack.frame = .zero
        }
    }

    /// The height this header view prefers given its current content.
    /// Set `headerView.frame.size.height = headerView.preferredHeight` then
    /// reassign `tableView.tableHeaderView = headerView` to apply.
    var preferredHeight: CGFloat {
        let avatarCenterY = avatarBaseCenter + additionalTopOffset
        var h = avatarCenterY + avatarSize / 2 + 10   // below avatar

        // Title (up to 2 lines)
        let titleFont = UIFont.preferredFont(forTextStyle: .title2)
        h += max(ceil(titleFont.lineHeight) * 2 + 4, 28) + 4

        let bodyFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let subtitleHeight = max(ceil(bodyFont.lineHeight), 20)
        if let subtitle = subtitleLabel.text, !subtitle.isEmpty {
            h += subtitleHeight
        }

        // Third line
        if !thirdLineLabel.isHidden {
            if let subtitle = subtitleLabel.text, !subtitle.isEmpty {
                h += subtitleToThirdLineSpacing
            }
            h += subtitleHeight
        }

        // Buttons
        if !buttonsStack.isHidden { h += textToButtonsSpacing + buttonsRowHeight }

        h += bottomPadding
        return h
    }

    // MARK: - Button configuration

    public final func configureButtons(_ block: () -> [UIButton]) {
        self.buttons = block()
        NSLayoutConstraint.activate(self.buttons.flatMap { btn -> [NSLayoutConstraint] in [
            btn.widthAnchor.constraint(equalToConstant: buttonWidth),
            btn.heightAnchor.constraint(equalToConstant: buttonHeight)
        ] })
        self.buttons.forEach { self.supportButtonsStack.addArrangedSubview($0) }
        self.showButtons = true
    }

    // MARK: - Content configuration

    var currentUrl: String? = ""

    public final func configure(avatarUrl: String?, owner: String, jid: String,
                                titleColor: UIColor, title: String,
                                subtitle: String?, thirdLine: String?) {
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
        titleButton.setTitleColor(titleColor, for: .normal)
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        if let thirdLine = thirdLine, !thirdLine.isEmpty {
            thirdLineLabel.text = thirdLine
            thirdLineLabel.isHidden = false
        } else {
            thirdLineLabel.isHidden = true
        }
    }

    // MARK: - Avatar mask

    internal func setMask() {
        if AccountMasksManager.shared.load() != "square" {
            imageButton.mask = UIImageView(image: imageLiteral(AccountMasksManager.shared.mask128pt))
        } else {
            imageButton.mask = nil
        }
    }

    // MARK: - Xabber Account button (special case)

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

    @objc private func onXabberAccountButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onXabberAccount()
    }

    // MARK: - Init

    override init(frame: CGRect) {
        self.showButtons = false
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func onAvatarButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onImageButtonPressed()
    }

    // MARK: - Deprecated / unused stubs (kept for API compatibility)

    internal func activateConstraints() {}
    public final func update() {}
}

// MARK: - Gradient Border Button

internal class GradientBorderButton: UIButton {

    private let gradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.colors = [
            UIColor(red: 224/255, green: 32/255, blue: 32/255, alpha: 1).cgColor,
            UIColor(red: 250/255, green: 100/255, blue: 0, alpha: 1).cgColor,
            UIColor(red: 247/255, green: 181/255, blue: 0, alpha: 1).cgColor,
            UIColor(red: 109/255, green: 212/255, blue: 0, alpha: 1).cgColor,
            UIColor(red: 0, green: 145/255, blue: 1, alpha: 1).cgColor,
            UIColor(red: 98/255, green: 54/255, blue: 1, alpha: 1).cgColor,
            UIColor(red: 182/255, green: 32/255, blue: 224/255, alpha: 1).cgColor,
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
