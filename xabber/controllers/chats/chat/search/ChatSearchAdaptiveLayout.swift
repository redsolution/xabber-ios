//
//  ChatSearchAdaptiveLayout.swift
//  xabber
//
//  Created by Codex on 14.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

struct ChatSearchAdaptiveEnvironment: Equatable {
    let contentSizeCategory: UIContentSizeCategory
    let layoutDirection: UIUserInterfaceLayoutDirection
    let accessibilityContrast: UIAccessibilityContrast
    let differentiateWithoutColor: Bool
    let reduceTransparency: Bool
    let reduceMotion: Bool
    let userInterfaceStyle: UIUserInterfaceStyle

    static let standard = ChatSearchAdaptiveEnvironment(
        contentSizeCategory: .large,
        layoutDirection: .leftToRight,
        accessibilityContrast: .normal,
        differentiateWithoutColor: false,
        reduceTransparency: false,
        reduceMotion: false,
        userInterfaceStyle: .light
    )

    var animationPreferences: ChatSearchAnimationSpec.AccessibilityPreferences {
        .init(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    static func current(for view: UIView) -> ChatSearchAdaptiveEnvironment {
        ChatSearchAdaptiveEnvironment(
            contentSizeCategory: view.traitCollection.preferredContentSizeCategory,
            layoutDirection: view.effectiveUserInterfaceLayoutDirection,
            accessibilityContrast: view.traitCollection.accessibilityContrast,
            differentiateWithoutColor: UIAccessibility.shouldDifferentiateWithoutColor,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            userInterfaceStyle: view.traitCollection.userInterfaceStyle
        )
    }

    func replacing(
        contentSizeCategory: UIContentSizeCategory? = nil,
        layoutDirection: UIUserInterfaceLayoutDirection? = nil,
        accessibilityContrast: UIAccessibilityContrast? = nil,
        differentiateWithoutColor: Bool? = nil,
        reduceTransparency: Bool? = nil,
        reduceMotion: Bool? = nil,
        userInterfaceStyle: UIUserInterfaceStyle? = nil
    ) -> ChatSearchAdaptiveEnvironment {
        ChatSearchAdaptiveEnvironment(
            contentSizeCategory: contentSizeCategory ?? self.contentSizeCategory,
            layoutDirection: layoutDirection ?? self.layoutDirection,
            accessibilityContrast: accessibilityContrast ?? self.accessibilityContrast,
            differentiateWithoutColor: differentiateWithoutColor ?? self.differentiateWithoutColor,
            reduceTransparency: reduceTransparency ?? self.reduceTransparency,
            reduceMotion: reduceMotion ?? self.reduceMotion,
            userInterfaceStyle: userInterfaceStyle ?? self.userInterfaceStyle
        )
    }
}

enum ChatSearchAdaptiveLayoutPolicy {
    static let minimumAccessibilityHitDimension: CGFloat = 44
    static let calendarDayIndicatorDiameter: CGFloat = 40

    struct CalendarMetrics: Equatable {
        let headerHeight: CGFloat
        let monthNavigationHeight: CGFloat
        let weekdayHeight: CGFloat
        let dayHeight: CGFloat
        let pickerHeight: CGFloat
        let doneHeight: CGFloat
    }

    static func accessibilityHitFrame(for frame: CGRect) -> CGRect {
        guard !frame.isNull, !frame.isInfinite else { return frame }
        let width = max(minimumAccessibilityHitDimension, frame.width)
        let height = max(minimumAccessibilityHitDimension, frame.height)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func areUsableAndDisjoint(_ frames: [CGRect]) -> Bool {
        guard frames.allSatisfy({
            !$0.isNull &&
            !$0.isInfinite &&
            $0.width > 0 &&
            $0.height > 0
        }) else {
            return false
        }
        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                if frames[firstIndex].intersects(frames[secondIndex]) {
                    return false
                }
            }
        }
        return true
    }

    static func calendarMetrics(
        for contentSizeCategory: UIContentSizeCategory
    ) -> CalendarMetrics {
        let traits = UITraitCollection(
            preferredContentSizeCategory: contentSizeCategory
        )
        let headline = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont.systemFont(ofSize: 17, weight: .semibold),
            compatibleWith: traits
        )
        let body = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 17),
            compatibleWith: traits
        )
        let caption = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: UIFont.systemFont(ofSize: 12),
            compatibleWith: traits
        )
        return CalendarMetrics(
            headerHeight: max(60, ceil(headline.lineHeight) + 20),
            monthNavigationHeight: max(52, ceil(headline.lineHeight) + 12),
            weekdayHeight: max(28, ceil(caption.lineHeight) + 8),
            dayHeight: max(44, ceil(body.lineHeight) + 8),
            pickerHeight: max(220, ceil(body.lineHeight) * 5),
            doneHeight: max(52, ceil(headline.lineHeight) + 20)
        )
    }

    static func scaledFont(
        baseSize: CGFloat,
        weight: UIFont.Weight,
        textStyle: UIFont.TextStyle,
        contentSizeCategory: UIContentSizeCategory,
        maximumPointSize: CGFloat? = nil
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: baseSize, weight: weight)
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let traits = UITraitCollection(
            preferredContentSizeCategory: contentSizeCategory
        )
        if let maximumPointSize {
            return metrics.scaledFont(
                for: base,
                maximumPointSize: maximumPointSize,
                compatibleWith: traits
            )
        }
        return metrics.scaledFont(for: base, compatibleWith: traits)
    }
}

enum ChatSearchAdaptiveAppearance {
    struct SurfaceStyle: Equatable {
        let usesVisualEffect: Bool
        let usesOpaqueBackground: Bool
        let borderWidth: CGFloat
    }

    static func surfaceStyle(
        for environment: ChatSearchAdaptiveEnvironment
    ) -> SurfaceStyle {
        SurfaceStyle(
            usesVisualEffect: !environment.reduceTransparency,
            usesOpaqueBackground: environment.reduceTransparency,
            borderWidth: environment.accessibilityContrast == .high ? 1 : 0
        )
    }

    @discardableResult
    static func applySurface(
        to view: UIVisualEffectView,
        role: XabberGlassStyle.SurfaceRole,
        cornerStyle: XabberGlassStyle.CornerStyle,
        interactive: Bool,
        prefersNativeGlass: Bool,
        environment: ChatSearchAdaptiveEnvironment,
        maskedCorners: CACornerMask? = nil
    ) -> SurfaceStyle {
        let style = surfaceStyle(for: environment)
        if style.usesVisualEffect {
            NativeGlassBarStyle.applySurface(
                to: view,
                role: role,
                cornerStyle: cornerStyle,
                interactive: interactive,
                prefersNativeGlass: prefersNativeGlass,
                maskedCorners: maskedCorners
            )
            if role == .sheet {
                view.contentView.backgroundColor = .systemBackground
            }
        } else {
            if #available(iOS 26.0, *), view.effect is UIGlassEffect {
                // UIKit keeps an interactive glass effect attached when it is
                // changed directly to nil. Transition through a non-glass
                // effect so Reduce Transparency can deterministically remove it.
                view.effect = UIBlurEffect(style: .systemMaterial)
            }
            view.effect = nil
            view.backgroundColor = .secondarySystemBackground
            view.contentView.backgroundColor = .secondarySystemBackground
            view.isOpaque = true
            view.clipsToBounds = true
            if let maskedCorners {
                view.layer.maskedCorners = maskedCorners
            }
            switch cornerStyle {
            case .fixed(let radius):
                view.layer.cornerRadius = radius
            case .capsule:
                view.layer.cornerRadius = NativeGlassBarStyle.cornerRadius
            }
            view.layer.cornerCurve = .continuous
        }
        view.layer.borderWidth = style.borderWidth
        view.layer.borderColor = style.borderWidth > 0
            ? UIColor.secondaryLabel.cgColor
            : nil
        return style
    }

    static func applyDetachedButton(
        _ button: UIButton,
        environment: ChatSearchAdaptiveEnvironment,
        tintColor: UIColor = NativeGlassBarStyle.iconTintColor
    ) {
        let style = surfaceStyle(for: environment)
        if style.usesVisualEffect {
            NativeGlassBarStyle.applyDetachedIconButtonStyle(
                to: button,
                tintColor: tintColor
            )
        } else {
            button.subviews.compactMap { $0 as? UIVisualEffectView }.forEach {
                $0.effect = nil
                $0.removeFromSuperview()
            }
            if #available(iOS 26.0, *) {
                var configuration = UIButton.Configuration.plain()
                configuration.image = button.image(for: .normal) ?? button.configuration?.image
                configuration.baseForegroundColor = tintColor
                configuration.contentInsets = .zero
                button.configuration = configuration
            }
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = min(button.bounds.width, button.bounds.height) / 2
            button.layer.cornerCurve = .continuous
        }
        button.layer.borderWidth = style.borderWidth
        button.layer.borderColor = style.borderWidth > 0
            ? UIColor.secondaryLabel.cgColor
            : nil
    }
}

enum ChatSearchContrastPolicy {
    static let bodyTextMinimumRatio = 4.5
    static let largeOrControlTextMinimumRatio = 3.0
    static let nonTextBoundaryMinimumRatio = 3.0

    static func passesBodyText(
        foreground: UIColor,
        background: UIColor,
        compatibleWith traits: UITraitCollection
    ) -> Bool {
        contrastRatio(
            foreground: foreground,
            background: background,
            compatibleWith: traits
        ) >= bodyTextMinimumRatio
    }

    static func passesLargeOrControlText(
        foreground: UIColor,
        background: UIColor,
        compatibleWith traits: UITraitCollection
    ) -> Bool {
        contrastRatio(
            foreground: foreground,
            background: background,
            compatibleWith: traits
        ) >= largeOrControlTextMinimumRatio
    }

    static func passesNonTextBoundary(
        foreground: UIColor,
        background: UIColor,
        compatibleWith traits: UITraitCollection
    ) -> Bool {
        contrastRatio(
            foreground: foreground,
            background: background,
            compatibleWith: traits
        ) >= nonTextBoundaryMinimumRatio
    }

    static func contrastRatio(
        foreground: UIColor,
        background: UIColor,
        compatibleWith traits: UITraitCollection
    ) -> Double {
        let backgroundComponents = rgba(
            background.resolvedColor(with: traits)
        )
        let foregroundComponents = rgba(
            foreground.resolvedColor(with: traits)
        )
        let compositedForeground = composite(
            foreground: foregroundComponents,
            background: backgroundComponents
        )
        let foregroundLuminance = relativeLuminance(compositedForeground)
        let backgroundLuminance = relativeLuminance(backgroundComponents)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func rgba(_ color: UIColor) -> (r: Double, g: Double, b: Double, a: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            return (Double(white), Double(white), Double(white), Double(alpha))
        }
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    private static func composite(
        foreground: (r: Double, g: Double, b: Double, a: Double),
        background: (r: Double, g: Double, b: Double, a: Double)
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        let alpha = foreground.a + background.a * (1 - foreground.a)
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return (
            (foreground.r * foreground.a + background.r * background.a * (1 - foreground.a)) / alpha,
            (foreground.g * foreground.a + background.g * background.a * (1 - foreground.a)) / alpha,
            (foreground.b * foreground.a + background.b * background.a * (1 - foreground.a)) / alpha,
            alpha
        )
    }

    private static func relativeLuminance(
        _ components: (r: Double, g: Double, b: Double, a: Double)
    ) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(components.r) +
            0.7152 * channel(components.g) +
            0.0722 * channel(components.b)
    }
}

extension UIView {
    var chatSearchAccessibilityFrame: CGRect {
        ChatSearchAdaptiveLayoutPolicy.accessibilityHitFrame(for: frame)
    }

    func updateChatSearchAccessibilityFrame() {
        guard window != nil, let superview else { return }
        accessibilityFrame = superview.convert(chatSearchAccessibilityFrame, to: nil)
    }
}

extension ChatSearchAnimationSpec {
    var requiresFinalStateApplication: Bool {
        let transitions = [
            chromeControls,
            floatingButtons,
            list.presentation,
            list.dismissal,
            calendar.dimPresentation,
            calendar.sheetPresentation,
            calendar.dimDismissal,
            calendar.sheetDismissal
        ]
        return transitions.allSatisfy { $0.completionPolicy == .applyFinalState }
    }
}
