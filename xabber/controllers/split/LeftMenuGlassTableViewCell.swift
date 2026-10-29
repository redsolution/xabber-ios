import UIKit

enum LeftMenuPremiumContent {
    static let key = "premium"
    static let title = "Xabber Premium"
    static let iconName = "star.fill"

    static var description: String {
        L10n.text(
            "left_menu__premium__description",
            fallback: "More cloud storage and customisation. Support Xabber development."
        )
    }

    static var menuItem: LeftMenuViewController.Datasource {
        .init(title: title, icon: iconName, key: key, category: "", subtitle: description, showTriangle: false)
    }
}

/// Sidebar-only cells keep their content inside the native glass surface.
final class LeftMenuGlassTableViewCell: UITableViewCell {
    static let cellName = "LeftMenuGlassTableViewCell"
    static let premiumCellName = "LeftMenuPremiumTableViewCell"

    private enum Metrics {
        static let horizontalInset: CGFloat = 16
        static let iconSize: CGFloat = 24
        static let spacing: CGFloat = 12
    }

    let glassSurfaceView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: nil)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    let iconView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    private final class BadgeLabel: UILabel {
        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: max(24, size.width + 12), height: max(20, size.height + 4))
        }
    }
    let badgeLabel: UILabel = BadgeLabel()
    private let contentStack = UIStackView()
    private let labelsStack = UIStackView()
    private var representsPremium = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // Keep separate reuse pools: changing native glass to nil replaces its
        // content host on iOS 26. Plain rows never create a native glass surface.
        if reuseIdentifier == Self.premiumCellName {
            XabberGlassStyle.applySurface(
                to: glassSurfaceView, role: .leftMenuSurface,
                cornerStyle: .fixed(16), interactive: false
            )
            glassSurfaceView.backgroundColor = LeftMenuSurfaceEffectFactory.surfaceBackgroundColor()
        }
        backgroundConfiguration = .clear()
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isOpaque = false
        selectionStyle = .none
        contentView.isAccessibilityElement = false
        contentView.addSubview(glassSurfaceView)
        glassSurfaceView.contentView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = Metrics.spacing
        labelsStack.axis = .vertical
        labelsStack.spacing = 4
        labelsStack.alignment = .fill
        labelsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(labelsStack)
        contentStack.addArrangedSubview(badgeLabel)
        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(subtitleLabel)
        iconView.contentMode = .scaleAspectFit
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .label
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byWordWrapping
        badgeLabel.font = .preferredFont(forTextStyle: .caption1)
        badgeLabel.textAlignment = .center
        badgeLabel.textColor = .white
        badgeLabel.layer.cornerRadius = 10
        badgeLabel.clipsToBounds = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.init(751), for: .horizontal)
        [titleLabel, subtitleLabel, badgeLabel].forEach {
            $0.adjustsFontForContentSizeCategory = true
            $0.isAccessibilityElement = false
        }
        iconView.isAccessibilityElement = false
        let minimumBadgeWidth = badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24)
        minimumBadgeWidth.priority = .init(999)
        NSLayoutConstraint.activate([
            glassSurfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glassSurfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            glassSurfaceView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            glassSurfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            glassSurfaceView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            contentStack.leadingAnchor.constraint(equalTo: glassSurfaceView.leadingAnchor, constant: Metrics.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: glassSurfaceView.trailingAnchor, constant: -Metrics.horizontalInset),
            contentStack.topAnchor.constraint(equalTo: glassSurfaceView.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: glassSurfaceView.bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            badgeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            minimumBadgeWidth
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: LeftMenuViewController.Datasource) {
        representsPremium = item.key == LeftMenuPremiumContent.key
        titleLabel.text = item.title
        titleLabel.font = .preferredFont(forTextStyle: representsPremium ? .headline : .body)
        subtitleLabel.text = representsPremium ? item.subtitle : nil
        subtitleLabel.isHidden = !representsPremium
        subtitleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 3
        iconView.image = (UIImage(named: item.icon) ?? UIImage(systemName: item.icon))?
            .withRenderingMode(.alwaysTemplate)
        iconView.tintColor = representsPremium ? .systemYellow : .label
        contentStack.alignment = representsPremium ? .top : .center
        badgeLabel.text = item.subtitle
        badgeLabel.isHidden = representsPremium || item.subtitle.isEmpty || item.subtitle == "0"
        badgeLabel.backgroundColor = item.key == "archive" ? .systemGray
            : UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1)
        isAccessibilityElement = true
        accessibilityIdentifier = "left_menu_\(item.key)_row"
        accessibilityLabel = representsPremium ? [item.title, item.subtitle].joined(separator: ". ") : item.title
        accessibilityValue = representsPremium || badgeLabel.isHidden ? nil : item.subtitle
        accessibilityTraits = .button
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        if representsPremium {
            // Establish the wrapping width before UITableView asks for the row's
            // height; the effect's contentView otherwise retains its last frame.
            let textWidth = targetSize.width - Metrics.horizontalInset * 2
                - Metrics.iconSize - Metrics.spacing
            if textWidth > 0 { subtitleLabel.preferredMaxLayoutWidth = textWidth }
        }
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = subtitleLabel.bounds.width
        if representsPremium, textWidth > 0,
           abs(subtitleLabel.preferredMaxLayoutWidth - textWidth) > 0.5 {
            subtitleLabel.preferredMaxLayoutWidth = textWidth
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        subtitleLabel.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 3
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        iconView.image = nil
        iconView.tintColor = .label
        badgeLabel.text = nil
        badgeLabel.isHidden = true
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = []
    }
}

/// One shared glass plate follows the ordinary sidebar section in scroll coordinates.
final class LeftMenuTableView: UITableView {
    private let mainSectionSurface: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: nil)
        XabberGlassStyle.applySurface(
            to: view, role: .leftMenuSurface, cornerStyle: .fixed(16), interactive: false
        )
        view.backgroundColor = LeftMenuSurfaceEffectFactory.surfaceBackgroundColor()
        view.accessibilityIdentifier = "left_menu_main_section_surface"
        view.isAccessibilityElement = false
        view.isUserInteractionEnabled = false
        return view
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        guard numberOfSections > 0, numberOfRows(inSection: 0) > 0 else {
            mainSectionSurface.isHidden = true
            return
        }
        if let backgroundView, backgroundView.superview === self,
           let backgroundIndex = subviews.firstIndex(where: { $0 === backgroundView }) {
            let surfaceIndex = subviews.firstIndex(where: { $0 === mainSectionSurface })
            if surfaceIndex != backgroundIndex + 1 {
                insertSubview(mainSectionSurface, aboveSubview: backgroundView)
            }
        } else if subviews.first !== mainSectionSurface {
            insertSubview(mainSectionSurface, at: 0)
        }
        let first = rectForRow(at: IndexPath(row: 0, section: 0))
        let last = rectForRow(at: IndexPath(row: numberOfRows(inSection: 0) - 1, section: 0))
        let rowFrame = visibleCells.first { indexPath(for: $0)?.section == 0 }
            .map { $0.contentView.convert($0.contentView.bounds, to: self) } ?? first
        let frame = CGRect(
            x: rowFrame.minX,
            y: first.minY + 4,
            width: rowFrame.width,
            height: max(0, last.maxY - first.minY - 8)
        )
        if mainSectionSurface.frame != frame { mainSectionSurface.frame = frame }
        mainSectionSurface.isHidden = false
    }
}
