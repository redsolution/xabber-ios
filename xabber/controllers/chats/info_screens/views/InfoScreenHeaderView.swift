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
    open var additionalTopOffset: CGFloat = 0 {
        didSet {
            updateLayoutInsets()
            refreshAppliedHeaderLayout()
        }
    }

    open var bottomPadding: CGFloat = 16 {
        didSet {
            updateLayoutInsets()
            refreshAppliedHeaderLayout()
        }
    }

    private let horizontalInset: CGFloat = 20
    private let topPadding: CGFloat = 16
    private let avatarSize: CGFloat = 112

    // Maximum width for the action buttons row (prevents huge gaps on iPad).
    private let maxButtonsWidth: CGFloat = 420
    private let avatarToTitleSpacing: CGFloat = 14
    private let titleToSubtitleSpacing: CGFloat = 4
    private let subtitleToThirdLineSpacing: CGFloat = 8
    private let textToButtonsSpacing: CGFloat = 16
    private let buttonsRowHeight: CGFloat = 56
    private let buttonWidth: CGFloat = 76
    private let buttonHeight: CGFloat = 56

    private weak var appliedTableView: UITableView?
    private var appliedHeaderWidth: CGFloat = 0
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var titleHeightConstraint: NSLayoutConstraint?
    private var supportButtonsWidthConstraint: NSLayoutConstraint?
    private var measuredTitleHeight: CGFloat = 0

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let avatarContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.12
        view.layer.shadowRadius = 10
        view.layer.shadowOffset = CGSize(width: 0, height: 3)
        return view
    }()

    private let textStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let buttonsScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.delaysContentTouches = false
        return scrollView
    }()

    // MARK: - Avatar

    let imageButton: RoundedAvatarButton = {
        let button = RoundedAvatarButton(frame: CGRect(square: 112),
                                         avatarMaskResourceName: AccountMasksManager.shared.mask128pt)
        button.translatesAutoresizingMaskIntoConstraints = false
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
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .title1)
            .scaledFont(for: UIFont.systemFont(ofSize: 34, weight: .bold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        return button
    }()

    let subtitleLabel: XCopyableLabel = {
        let label = XCopyableLabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let thirdLineLabel: UILabel = {
        let label = UILabel()
        label.isHidden = true
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Action buttons

    /// Horizontal stack containing the action buttons (InfoHeaderButton instances).
    let supportButtonsStack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.distribution = .fillEqually
        stack.axis = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    /// Outer vertical stack (kept for API compatibility with callers that access buttonsStack directly).
    let buttonsStack: UIStackView = {
        let stack = UIStackView()
        stack.alignment = .center
        stack.distribution = .fill
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    var showButtons: Bool {
        didSet {
            buttonsStack.isHidden = !showButtons
            updateVisibilityAwareSpacing()
            refreshAppliedHeaderLayout()
        }
    }

    internal var buttons: [UIButton] = []

    open var delegate: InfoScreenHeaderDelegate? = nil

    // MARK: - Setup

    internal func setup() {
        backgroundColor = .systemGroupedBackground

        addSubview(contentStack)
        avatarContainer.addSubview(imageButton)
        textStack.addArrangedSubview(titleButton)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.addArrangedSubview(thirdLineLabel)
        buttonsStack.addArrangedSubview(supportButtonsStack)

        contentStack.addArrangedSubview(avatarContainer)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(buttonsStack)

        let topConstraint = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: topPadding + additionalTopOffset)
        let bottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding)
        self.topConstraint = topConstraint
        self.bottomConstraint = bottomConstraint

        let buttonsWidthConstraint = buttonsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        buttonsWidthConstraint.priority = .defaultHigh
        let supportButtonsWidthConstraint = supportButtonsStack.widthAnchor.constraint(lessThanOrEqualTo: buttonsStack.widthAnchor)
        self.supportButtonsWidthConstraint = supportButtonsWidthConstraint

        titleHeightConstraint = titleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        titleHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            topConstraint,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            bottomConstraint,

            avatarContainer.widthAnchor.constraint(equalToConstant: avatarSize),
            avatarContainer.heightAnchor.constraint(equalToConstant: avatarSize),

            imageButton.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            imageButton.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            imageButton.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            imageButton.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),

            textStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            buttonsWidthConstraint,
            buttonsStack.widthAnchor.constraint(lessThanOrEqualToConstant: maxButtonsWidth),
            supportButtonsStack.heightAnchor.constraint(equalToConstant: buttonsRowHeight),
            supportButtonsWidthConstraint,
        ])

        buttonsStack.isHidden = !showButtons
        updateVisibilityAwareSpacing()
        imageButton.addTarget(self, action: #selector(onAvatarButtonTouchUpInside), for: .touchUpInside)
        titleButton.addTarget(self, action: #selector(onTitleButtonTouchUpInside), for: .touchUpInside)
        titleButton.isAccessibilityElement = true
    }

    // MARK: - Layout

    /// Lays out all subviews. Kept for callers that still ask the header to refresh after setting its frame.
    internal func updateSubviews() {
        let width = effectiveWidth(from: bounds.width)
        updateDynamicTextSizing(for: width)
        updateLayoutInsets()
        updateVisibilityAwareSpacing()
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The height this header view prefers given its current content.
    /// Set `headerView.frame.size.height = headerView.preferredHeight` then reassign `tableView.tableHeaderView = headerView` to apply.
    var preferredHeight: CGFloat {
        return preferredHeight(for: effectiveWidth(from: bounds.width))
    }

    internal func preferredHeight(for width: CGFloat) -> CGFloat {
        let width = effectiveWidth(from: width)
        updateDynamicTextSizing(for: width)
        updateLayoutInsets()
        updateVisibilityAwareSpacing()

        return ceil(visibleContentHeight(for: width))
    }

    @discardableResult
    internal func applyLayout(width: CGFloat) -> CGFloat {
        let width = effectiveWidth(from: width)
        let height = preferredHeight(for: width)
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        updateSubviews()
        return height
    }

    @discardableResult
    internal func applyHeaderLayout(to tableView: UITableView, width: CGFloat) -> CGFloat {
        let width = effectiveWidth(from: width > 0 ? width : tableView.bounds.width)
        appliedTableView = tableView
        appliedHeaderWidth = width
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        let height = applyLayout(width: width)
        tableView.tableHeaderView = self
        return height
    }

    private func refreshAppliedHeaderLayout() {
        guard let tableView = appliedTableView else { return }
        applyHeaderLayout(to: tableView, width: appliedHeaderWidth)
    }

    private func updateLayoutInsets() {
        topConstraint?.constant = topPadding + additionalTopOffset
        bottomConstraint?.constant = -bottomPadding
    }

    private func updateVisibilityAwareSpacing() {
        buttonsStack.isHidden = !showButtons || !buttonRowHasContent

        let textStackHidden = titleButton.isHidden && subtitleLabel.isHidden && thirdLineLabel.isHidden
        textStack.isHidden = textStackHidden

        textStack.setCustomSpacing(subtitleLabel.isHidden ? 0 : titleToSubtitleSpacing, after: titleButton)
        textStack.setCustomSpacing(thirdLineLabel.isHidden ? 0 : subtitleToThirdLineSpacing, after: subtitleLabel)

        contentStack.setCustomSpacing(textStackHidden ? 0 : avatarToTitleSpacing, after: avatarContainer)
        contentStack.setCustomSpacing(hasVisibleButtonRow ? textToButtonsSpacing : 0, after: textStack)
    }

    private func effectiveWidth(from width: CGFloat) -> CGFloat {
        if width > 0 {
            return width
        }
        if appliedHeaderWidth > 0 {
            return appliedHeaderWidth
        }
        if let tableView = appliedTableView, tableView.bounds.width > 0 {
            return tableView.bounds.width
        }
        return UIScreen.main.bounds.width
    }

    private func updateDynamicTextSizing(for width: CGFloat) {
        let textWidth = max(width - horizontalInset * 2, 1)
        titleButton.titleLabel?.preferredMaxLayoutWidth = textWidth
        subtitleLabel.preferredMaxLayoutWidth = textWidth
        thirdLineLabel.preferredMaxLayoutWidth = textWidth

        let title = titleButton.title(for: .normal) ?? ""
        let titleFont = titleButton.titleLabel?.font ?? UIFont.preferredFont(forTextStyle: .title1)
        let oneLineHeight = ceil(titleFont.lineHeight)
        let maxTitleHeight = oneLineHeight * 2 + 4
        if titleButton.isHidden {
            measuredTitleHeight = 0
        } else if title.isEmpty {
            measuredTitleHeight = oneLineHeight + 4
        } else {
            let rect = (title as NSString).boundingRect(
                with: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: titleFont],
                context: nil
            )
            measuredTitleHeight = min(max(ceil(rect.height) + 4, oneLineHeight + 4), maxTitleHeight)
        }
        titleHeightConstraint?.constant = measuredTitleHeight
    }

    private func visibleContentHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(width - horizontalInset * 2, 1)
        var height = topPadding + additionalTopOffset + avatarSize

        let textHeight = visibleTextHeight(for: textWidth)
        if textHeight > 0 {
            height += avatarToTitleSpacing + textHeight
        }

        if hasVisibleButtonRow {
            height += textToButtonsSpacing + buttonsRowHeight
        }

        return height + bottomPadding
    }

    private func visibleTextHeight(for width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        var hasVisibleLabel = false

        if !titleButton.isHidden {
            height += measuredTitleHeight
            hasVisibleLabel = true
        }

        if !subtitleLabel.isHidden {
            if hasVisibleLabel {
                height += titleToSubtitleSpacing
            }
            height += measuredLabelHeight(subtitleLabel, width: width)
            hasVisibleLabel = true
        }

        if !thirdLineLabel.isHidden {
            if hasVisibleLabel {
                height += subtitleToThirdLineSpacing
            }
            height += measuredLabelHeight(thirdLineLabel, width: width)
        }

        return height
    }

    private func measuredLabelHeight(_ label: UILabel, width: CGFloat) -> CGFloat {
        guard let text = label.text, !text.isEmpty else { return 0 }
        let font = label.font ?? UIFont.preferredFont(forTextStyle: .subheadline)
        let maxLines = label.numberOfLines > 0 ? label.numberOfLines : Int.max
        let maxHeight = CGFloat(maxLines) * ceil(font.lineHeight)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(max(ceil(rect.height), ceil(font.lineHeight)), maxHeight)
    }

    private var hasVisibleButtonRow: Bool {
        guard showButtons, !buttonsStack.isHidden else { return false }
        return buttonRowHasContent
    }

    private var buttonRowHasContent: Bool {
        return buttonsStack.arrangedSubviews.contains { arrangedSubview in
            if arrangedSubview === supportButtonsStack {
                return supportButtonsStack.arrangedSubviews.contains { !$0.isHidden }
            }
            return !arrangedSubview.isHidden
        }
    }

    // MARK: - Button configuration

    public final func configureButtons(_ block: () -> [UIButton]) {
        self.supportButtonsStack.arrangedSubviews.forEach { button in
            self.supportButtonsStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        self.buttons = block()
        NSLayoutConstraint.activate(self.buttons.flatMap { btn -> [NSLayoutConstraint] in [
            btn.widthAnchor.constraint(equalToConstant: buttonWidth),
            btn.heightAnchor.constraint(equalToConstant: buttonHeight)
        ] })
        self.buttons.forEach { self.supportButtonsStack.addArrangedSubview($0) }
        self.showButtons = true
        refreshAppliedHeaderLayout()
    }

    // MARK: - Content configuration

    var currentUrl: String? = ""

    public final func configure(avatarUrl: String?, owner: String, jid: String,
                                titleColor: UIColor, title: String,
                                subtitle: String?, thirdLine: String?) {
        if currentUrl != avatarUrl {
            DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: owner, size: 112) { image in
                if let image = image {
                    self.imageButton.setImage(image, for: .normal)
                    self.currentUrl = avatarUrl
                } else {
                    self.imageButton.setImage(UIImageView.getDefaultAvatar(for: title, owner: owner, size: 112), for: .normal)
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
            thirdLineLabel.text = nil
            thirdLineLabel.isHidden = true
        }
        updateVisibilityAwareSpacing()
        refreshAppliedHeaderLayout()
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
        supportButtonsWidthConstraint?.isActive = false
        self.buttonsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        self.buttonsStack.addArrangedSubview(xabberAccountButton)
        NSLayoutConstraint.activate([
            xabberAccountButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 224),
            xabberAccountButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        self.xabberAccountButton.addTarget(self, action: #selector(self.onXabberAccountButtonTouchUpInside), for: .touchUpInside)
        refreshAppliedHeaderLayout()
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

    override func layoutSubviews() {
        super.layoutSubviews()
        avatarContainer.layer.cornerRadius = avatarContainer.bounds.width / 2
        avatarContainer.layer.shadowPath = UIBezierPath(ovalIn: avatarContainer.bounds).cgPath
    }

    @objc private func onAvatarButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onImageButtonPressed()
    }

    @objc private func onTitleButtonTouchUpInside(_ sender: UIButton) {
        self.delegate?.onTitleButtonPressed()
    }

    // MARK: - Deprecated / unused stubs (kept for API compatibility)

    internal func activateConstraints() {}
    public final func update() {}
}

internal enum InfoScreenSectionMetrics {
    static func headerHeight(for title: String?, section: Int) -> CGFloat {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return .leastNonzeroMagnitude
        }

        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let verticalPadding: CGFloat = section == 0 ? 8 : 14
        return ceil(font.lineHeight + verticalPadding)
    }
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
