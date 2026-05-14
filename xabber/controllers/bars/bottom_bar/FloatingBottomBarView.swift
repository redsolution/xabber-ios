//
//  FloatingBottomBarView.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

enum BottomBarGlassEffectFactory {
    static let fallbackBlurStyle: UIBlurEffect.Style = .systemMaterial

    static func makeEffect(prefersNativeGlass: Bool = true) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            return effect
        }

        return UIBlurEffect(style: fallbackBlurStyle)
    }
}

final class FloatingBottomBarView: UIView {
    enum Metrics {
        static let height: CGFloat = 44
        static let bottomOffset: CGFloat = 4
        static let horizontalInset: CGFloat = 16
        static let contentInset: CGFloat = 10
        static let buttonSize: CGFloat = 44
        static let iconSize: CGFloat = 20
        static let maxWidth: CGFloat = 360
        static let tableInsetPadding: CGFloat = 12
        static let reservedBottomInset = height + bottomOffset + tableInsetPadding
    }

    let effectView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: BottomBarGlassEffectFactory.makeEffect())

        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .capsule()
        } else {
            view.layer.cornerRadius = Metrics.height / 2
            view.layer.cornerCurve = .continuous
        }
        view.layer.borderWidth = 1.0 / UIScreen.main.scale
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.34).cgColor

        return view
    }()

    let leftButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .black
        button.backgroundColor = .clear
        button.accessibilityLabel = "Unread chats filter"

        return button
    }()

    let titleLabel: UILabel = {
        let label = UILabel(frame: .zero)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        return label
    }()

    let rightButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .black
        button.backgroundColor = .clear
        button.accessibilityLabel = "Add"

        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
        titleLabel.accessibilityLabel = title
    }

    func updateLeftButton(imageName: String, isActive: Bool) {
        configure(button: leftButton, imageName: imageName)
        leftButton.accessibilityValue = isActive ? "On" : "Off"
    }

    func updateRightButton(imageName: String) {
        configure(button: rightButton, imageName: imageName)
    }

    func refreshAppearance() {
        effectView.layer.borderColor = UIColor.separator.withAlphaComponent(0.34).cgColor
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false

        addSubview(effectView)

        let contentView = effectView.contentView
        contentView.addSubview(leftButton)
        contentView.addSubview(titleLabel)
        contentView.addSubview(rightButton)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            leftButton.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: Metrics.contentInset
            ),
            leftButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leftButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            leftButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            rightButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -Metrics.contentInset
            ),
            rightButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            rightButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            rightButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftButton.trailingAnchor,
                constant: 8
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: rightButton.leadingAnchor,
                constant: -8
            )
        ])

        configure(button: leftButton, imageName: "line.3.horizontal.decrease.circle")
        configure(button: rightButton, imageName: "plus")
    }

    private func configure(button: UIButton, imageName: String) {
        let image = imageLiteral(imageName, dimension: Metrics.iconSize)

        button.configuration = nil
        button.setImage(image, for: .normal)
        button.tintColor = .black
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
    }
}
