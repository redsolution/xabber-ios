import UIKit

enum LeftMenuPremiumContent {
    static let key = "premium"
    static let iconName = "star.fill"

    static var title: String {
        L10n.format(
            "premium__brand__title",
            fallback: "%1$@ Premium",
            arguments: [CommonConfigManager.shared.config.app_name]
        )
    }

    static var description: String {
        L10n.format(
            "left_menu__premium__description",
            fallback: "More cloud storage and customisation. Support %1$@ development.",
            arguments: [CommonConfigManager.shared.config.app_name]
        )
    }

    static var menuItem: LeftMenuViewController.Datasource {
        .init(title: title, icon: iconName, key: key, category: "", subtitle: description, showTriangle: false)
    }
}

/// UIKit draws the backgrounds for both inset-grouped sidebar sections.
final class LeftMenuGlassTableViewCell: UITableViewCell {
    static let cellName = "LeftMenuGlassTableViewCell"
    static let premiumCellName = "LeftMenuPremiumTableViewCell"

    private enum Metrics {
        static let horizontalInset: CGFloat = 16
        static let iconSize: CGFloat = 24
        static let spacing: CGFloat = 12
    }

    private let rowSurfaceView: UIView = {
        let view = UIView()
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
        automaticallyUpdatesBackgroundConfiguration = false
        contentView.backgroundColor = .clear
        isOpaque = false
        selectionStyle = .none
        contentView.isAccessibilityElement = false
        contentView.addSubview(rowSurfaceView)
        rowSurfaceView.addSubview(contentStack)
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
            rowSurfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowSurfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowSurfaceView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            rowSurfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            rowSurfaceView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            contentStack.leadingAnchor.constraint(equalTo: rowSurfaceView.leadingAnchor, constant: Metrics.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: rowSurfaceView.trailingAnchor, constant: -Metrics.horizontalInset),
            contentStack.topAnchor.constraint(equalTo: rowSurfaceView.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: rowSurfaceView.bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
            badgeLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            minimumBadgeWidth
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var background: UIBackgroundConfiguration
        if #available(iOS 18.0, *) {
            background = .listCell().updated(for: state)
        } else {
            background = .listGroupedCell().updated(for: state)
        }
        background.backgroundColor = .systemBackground
        background.backgroundColorTransformer = nil
        background.visualEffect = nil
        backgroundConfiguration = background
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
            // Use the proposed width to measure wrapping before the row is laid out.
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
