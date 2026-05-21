//
//  FloatingBottomBarView.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

enum NativeGlassBarStyle {
    enum CornerStyle {
        case fixed(CGFloat)
        case capsule
    }

    static let minimumHeight: CGFloat = 44
    static let bottomOffset: CGFloat = 4
    static let horizontalInset: CGFloat = 16
    static let contentInset: CGFloat = 10
    static let buttonSize: CGFloat = 44
    static let iconSize: CGFloat = 20
    static let interItemSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 22
    static let fallbackBlurStyle: UIBlurEffect.Style = .systemMaterial
    static let nativeGlassTintColor = UIColor.systemBackground.withAlphaComponent(0.16)
    static let iconTintColor: UIColor = .label

    static func makeEffect(
        interactive: Bool = true,
        prefersNativeGlass: Bool = true
    ) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = nativeGlassTintColor
            effect.isInteractive = interactive
            return effect
        }

        return UIBlurEffect(style: fallbackBlurStyle)
    }

    static func applySurface(
        to view: UIVisualEffectView,
        cornerStyle: CornerStyle = .fixed(cornerRadius),
        interactive: Bool = true
    ) {
        view.effect = makeEffect(interactive: interactive)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true
        view.layer.borderWidth = 0
        view.layer.borderColor = nil
        view.layer.shadowColor = nil
        view.layer.shadowOpacity = 0
        view.layer.shadowRadius = 0
        view.layer.shadowOffset = .zero
        view.layer.shadowPath = nil

        switch cornerStyle {
        case .fixed(let radius):
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *) {
                view.cornerConfiguration = .uniformCorners(radius: .fixed(Double(radius)))
            }
        case .capsule:
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *) {
                view.cornerConfiguration = .capsule()
            }
        }
    }

    static func applyIconButtonStyle(
        to button: UIButton,
        tintColor: UIColor? = nil,
        image: UIImage? = nil,
        prefersNativeGlass: Bool = true,
        forceConfigurationUpdate: Bool = true
    ) {
        let configuredImage: UIImage?
        if #available(iOS 26.0, *) {
            configuredImage = button.configuration?.image
        } else {
            configuredImage = nil
        }
        let resolvedImage = (image ?? button.image(for: .normal) ?? configuredImage)?
            .withRenderingMode(.alwaysTemplate)
        let resolvedTintColor = tintColor ?? button.tintColor ?? iconTintColor

        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = resolvedTintColor
        button.backgroundColor = .clear
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.layer.borderWidth = 0
        button.layer.borderColor = nil
        button.layer.shadowColor = nil
        button.layer.shadowOpacity = 0
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = .zero
        button.layer.shadowPath = nil

        if image != nil, let resolvedImage {
            button.setImage(resolvedImage, for: .normal)
        }

        if prefersNativeGlass, #available(iOS 26.0, *) {
            if forceConfigurationUpdate {
                var configuration = UIButton.Configuration.clearGlass()
                configuration.image = resolvedImage
                configuration.baseForegroundColor = resolvedTintColor
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
                button.configuration = configuration
            }
        } else {
            button.configuration = nil
        }
    }
}

final class FloatingBottomBarView: UIView {
    enum Metrics {
        static let height: CGFloat = NativeGlassBarStyle.minimumHeight
        static let bottomOffset: CGFloat = NativeGlassBarStyle.bottomOffset
        static let horizontalInset: CGFloat = NativeGlassBarStyle.horizontalInset
        static let contentInset: CGFloat = NativeGlassBarStyle.contentInset
        static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
        static let iconSize: CGFloat = NativeGlassBarStyle.iconSize
        static let maxWidth: CGFloat = 360
        static let tableInsetPadding: CGFloat = 12
        static let reservedBottomInset = height + bottomOffset + tableInsetPadding
    }

    let effectView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))

        view.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)

        return view
    }()

    let leftButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            prefersNativeGlass: false
        )
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
        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            prefersNativeGlass: false
        )
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
        NativeGlassBarStyle.applySurface(to: effectView, cornerStyle: .capsule, interactive: true)
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

        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: image,
            prefersNativeGlass: false
        )
    }
}
