import UIKit

/// Fills the title space that UIKit leaves between the navigation actions.
final class ListNavigationTitleView: UIView {
    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = true
        label.accessibilityTraits.insert(.header)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let surfaceView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: nil)
        NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: false)
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(accessibilityIdentifier: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        self.accessibilityIdentifier = accessibilityIdentifier
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(surfaceView)
        surfaceView.contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: surfaceView.contentView.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: surfaceView.contentView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: surfaceView.contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: surfaceView.contentView.topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: surfaceView.contentView.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        NativeGlassBarStyle.navigationTitleIntrinsicSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        NativeGlassBarStyle.navigationTitleSizeThatFits(size)
    }
}
