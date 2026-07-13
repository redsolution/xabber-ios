//
//  XabberGlassStyle.swift
//  xabber
//
//  Created by Codex on 25.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit
import ObjectiveC

enum XabberGlassStyle {
    enum CornerStyle {
        case fixed(CGFloat)
        case capsule
    }

    enum GlassEffectStyle {
        case regular
        case clear
    }

    enum SurfaceRole {
        case bar
        case clearInputSurface
        case sheet
        case leftMenuSurface
        case splitCellNormal
        case splitCellHighlighted
        case audioPlayer
        case detachedIconButton
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
    static let nativeGlassTintColor: UIColor? = nil
    static let iconTintColor: UIColor = .label
    static let leftMenuFallbackSurfaceBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.28)
    static let splitCellNormalBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.24)

    private static let detachedIconButtonGlassViewTag = 26051801
    private static var iconButtonCachedImageKey: UInt8 = 0

    static func fallbackBlurStyle(for role: SurfaceRole) -> UIBlurEffect.Style {
        switch role {
        case .leftMenuSurface, .splitCellNormal:
            return .systemThinMaterial
        case .bar, .clearInputSurface, .sheet, .splitCellHighlighted, .audioPlayer, .detachedIconButton:
            return .systemMaterial
        }
    }

    static func surfaceBackgroundColor(
        role: SurfaceRole,
        prefersNativeGlass: Bool = true
    ) -> UIColor {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            return .clear
        }

        switch role {
        case .leftMenuSurface:
            return leftMenuFallbackSurfaceBackgroundColor
        case .splitCellNormal:
            return splitCellNormalBackgroundColor
        default:
            return .clear
        }
    }

    static func splitCellBackgroundColor(
        isHighlighted: Bool,
        selectedColor: UIColor
    ) -> UIColor {
        isHighlighted
            ? selectedColor.withAlphaComponent(0.35)
            : splitCellNormalBackgroundColor
    }

    static func splitCellTintColor(
        isHighlighted _: Bool,
        selectedColor _: UIColor
    ) -> UIColor? {
        nil
    }

    static func makeEffect(
        role: SurfaceRole,
        interactive: Bool = true,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: GlassEffectStyle? = nil,
        tintColor: UIColor? = nil
    ) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let style: UIGlassEffect.Style = (nativeGlassStyle ?? defaultGlassEffectStyle(for: role)) == .clear ? .clear : .regular
            let effect = UIGlassEffect(style: style)
            if let resolvedTintColor = tintColor ?? nativeGlassTintColor {
                effect.tintColor = resolvedTintColor
            }
            effect.isInteractive = interactive
            return effect
        }

        return UIBlurEffect(style: fallbackBlurStyle(for: role))
    }

    static func makeEffect(
        interactive: Bool = true,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: GlassEffectStyle = .regular
    ) -> UIVisualEffect {
        makeEffect(
            role: .bar,
            interactive: interactive,
            prefersNativeGlass: prefersNativeGlass,
            nativeGlassStyle: nativeGlassStyle
        )
    }

    static func applySurface(
        to view: UIVisualEffectView,
        role: SurfaceRole = .bar,
        cornerStyle: CornerStyle = .fixed(cornerRadius),
        interactive: Bool = true,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: GlassEffectStyle? = nil,
        maskedCorners: CACornerMask? = nil,
        tintColor: UIColor? = nil
    ) {
        view.effect = makeEffect(
            role: role,
            interactive: interactive,
            prefersNativeGlass: prefersNativeGlass,
            nativeGlassStyle: nativeGlassStyle,
            tintColor: tintColor
        )
        view.backgroundColor = .clear
        view.contentView.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true
        view.layer.borderWidth = 0
        view.layer.borderColor = nil
        view.layer.shadowColor = nil
        view.layer.shadowOpacity = 0
        view.layer.shadowRadius = 0
        view.layer.shadowOffset = .zero
        view.layer.shadowPath = nil

        if let maskedCorners {
            view.layer.maskedCorners = maskedCorners
        } else {
            view.layer.maskedCorners = allCornerMask
        }

        switch cornerStyle {
        case .fixed(let radius):
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *), view.layer.maskedCorners == allCornerMask {
                view.cornerConfiguration = .uniformCorners(radius: .fixed(Double(radius)))
            }
        case .capsule:
            view.layer.cornerRadius = cornerRadius
            view.layer.cornerCurve = .continuous
            if #available(iOS 26.0, *), view.layer.maskedCorners == allCornerMask {
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
        let cachedImage = cachedIconButtonImage(for: button)
        let resolvedImage = (image ?? button.image(for: .normal) ?? configuredImage ?? cachedImage)?
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

        if let resolvedImage {
            cacheIconButtonImage(resolvedImage, for: button)
            button.setImage(resolvedImage, for: .normal)
        }

        if prefersNativeGlass, #available(iOS 26.0, *) {
            if forceConfigurationUpdate || button.configuration == nil || configuredImage == nil {
                var configuration = UIButton.Configuration.glass()
                configuration.image = resolvedImage
                configuration.baseForegroundColor = resolvedTintColor
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
                button.configuration = configuration
            }
        } else {
            button.configuration = nil
        }
    }

    static func applyDetachedIconButtonStyle(
        to button: UIButton,
        tintColor: UIColor? = nil,
        image: UIImage? = nil,
        forceConfigurationUpdate: Bool = true
    ) {
        applyIconButtonStyle(
            to: button,
            tintColor: tintColor ?? button.tintColor,
            image: image,
            forceConfigurationUpdate: forceConfigurationUpdate
        )
        button.layer.cornerRadius = 0
        button.clipsToBounds = false

        if #available(iOS 26.0, *) {
            detachedIconButtonGlassEffectView(in: button)?.removeFromSuperview()
            return
        }

        let effectView: UIVisualEffectView
        if let existing = detachedIconButtonGlassEffectView(in: button) {
            effectView = existing
            effectView.effect = makeEffect(role: .detachedIconButton, interactive: true)
        } else {
            effectView = UIVisualEffectView(effect: makeEffect(role: .detachedIconButton, interactive: true))
            effectView.tag = detachedIconButtonGlassViewTag
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.isUserInteractionEnabled = false
            effectView.backgroundColor = .clear
            effectView.contentView.backgroundColor = .clear
            effectView.isOpaque = false
            button.insertSubview(effectView, at: 0)
            NSLayoutConstraint.activate([
                effectView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                effectView.topAnchor.constraint(equalTo: button.topAnchor),
                effectView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = buttonSize / 2
        effectView.layer.cornerCurve = .continuous
        effectView.layer.borderWidth = 0
        effectView.layer.borderColor = nil
        button.sendSubviewToBack(effectView)
    }

    static func setDetachedIconButtonChromeHidden(
        _ hidden: Bool,
        on button: UIButton
    ) {
        if #available(iOS 26.0, *) {
            if hidden {
                button.configuration = nil
                button.backgroundColor = .clear
            } else {
                applyDetachedIconButtonStyle(to: button)
            }
        } else if let effectView = detachedIconButtonGlassEffectView(in: button) {
            effectView.isHidden = hidden
        } else if !hidden {
            applyDetachedIconButtonStyle(to: button)
        }
    }

    private static func defaultGlassEffectStyle(for role: SurfaceRole) -> GlassEffectStyle {
        switch role {
        case .bar, .clearInputSurface, .sheet, .leftMenuSurface, .splitCellNormal, .splitCellHighlighted, .audioPlayer, .detachedIconButton:
            return .regular
        }
    }

    private static func detachedIconButtonGlassEffectView(in button: UIButton) -> UIVisualEffectView? {
        button.subviews
            .compactMap { $0 as? UIVisualEffectView }
            .first { $0.tag == detachedIconButtonGlassViewTag }
    }

    private static func cachedIconButtonImage(for button: UIButton) -> UIImage? {
        objc_getAssociatedObject(button, &iconButtonCachedImageKey) as? UIImage
    }

    private static func cacheIconButtonImage(_ image: UIImage, for button: UIButton) {
        objc_setAssociatedObject(
            button,
            &iconButtonCachedImageKey,
            image.withRenderingMode(.alwaysTemplate),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static var allCornerMask: CACornerMask {
        [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
    }
}

typealias NativeGlassBarStyle = XabberGlassStyle
