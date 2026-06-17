//
//  FloatingBottomBarView.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit
import ObjectiveC

enum NativeGlassBarStyle {
    enum CornerStyle {
        case fixed(CGFloat)
        case capsule
    }

    enum GlassEffectStyle {
        case regular
        case clear
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
    private static let detachedIconButtonGlassViewTag = 26051801
    private static var iconButtonCachedImageKey: UInt8 = 0

    static func makeEffect(
        interactive: Bool = true,
        prefersNativeGlass: Bool = true,
        nativeGlassStyle: GlassEffectStyle = .regular
    ) -> UIVisualEffect {
        if prefersNativeGlass, #available(iOS 26.0, *) {
            let style: UIGlassEffect.Style = nativeGlassStyle == .clear ? .clear : .regular
            let effect = UIGlassEffect(style: style)
            effect.tintColor = nativeGlassTintColor
            effect.isInteractive = interactive
            return effect
        }

        return UIBlurEffect(style: fallbackBlurStyle)
    }

    static func applySurface(
        to view: UIVisualEffectView,
        cornerStyle: CornerStyle = .fixed(cornerRadius),
        interactive: Bool = true,
        nativeGlassStyle: GlassEffectStyle = .regular
    ) {
        view.effect = makeEffect(interactive: interactive, nativeGlassStyle: nativeGlassStyle)
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
            effectView.effect = makeEffect(interactive: true)
        } else {
            effectView = UIVisualEffectView(effect: makeEffect(interactive: true))
            effectView.tag = detachedIconButtonGlassViewTag
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.isUserInteractionEnabled = false
            effectView.backgroundColor = .clear
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

final class BottomSearchHostView: UIView, UITextFieldDelegate {
    enum Metrics {
        static let height: CGFloat = NativeGlassBarStyle.minimumHeight
        static let bottomOffset: CGFloat = NativeGlassBarStyle.bottomOffset
        static let horizontalInset: CGFloat = NativeGlassBarStyle.horizontalInset
        static let contentInset: CGFloat = NativeGlassBarStyle.contentInset
        static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
        static let iconSize: CGFloat = NativeGlassBarStyle.iconSize
        static let interItemSpacing: CGFloat = NativeGlassBarStyle.interItemSpacing
        static let tableInsetPadding: CGFloat = 12
        static let reservedBottomInset = height + bottomOffset + tableInsetPadding
    }

    let collapsedButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(systemName: "magnifyingglass")?
                .upscale(dimension: Metrics.iconSize)
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.accessibilityIdentifier = "bottom_search_button"
        button.accessibilityLabel = "Search"
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor
        )

        return button
    }()

    let surfaceView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))

        view.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)

        return view
    }()

    let searchTextField: UISearchTextField = {
        let textField = UISearchTextField(frame: .zero)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholder = ChatSearchResultsController.placeholderText
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = false
        textField.clearButtonMode = .whileEditing
        textField.accessibilityIdentifier = "bottom_search_text_field"

        return textField
    }()

    let cancelButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(systemName: "xmark")?
                .upscale(dimension: Metrics.iconSize)
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.accessibilityIdentifier = "bottom_search_cancel_button"
        button.accessibilityLabel = "Cancel search"
        NativeGlassBarStyle.applyIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            prefersNativeGlass: false
        )

        return button
    }()

    private(set) var isExpanded: Bool = false
    var onBegin: (() -> Void)?
    var onQueryChanged: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    var query: String {
        searchTextField.text ?? ""
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else {
            updateVisibility(animated: animated)
            return
        }

        isExpanded = expanded
        updateVisibility(animated: animated)
        if expanded {
            searchTextField.becomeFirstResponder()
        } else {
            searchTextField.resignFirstResponder()
        }
    }

    func setQuery(_ query: String?, notify: Bool) {
        searchTextField.text = query ?? ""
        if notify {
            onQueryChanged?(searchTextField.text)
        }
    }

    @discardableResult
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false

        addSubview(surfaceView)
        addSubview(collapsedButton)
        applyTransparentSearchTextFieldChrome()

        let contentView = surfaceView.contentView
        contentView.addSubview(searchTextField)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            collapsedButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            collapsedButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            collapsedButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            collapsedButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            surfaceView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Metrics.horizontalInset
            ),
            surfaceView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
            surfaceView.heightAnchor.constraint(equalToConstant: Metrics.height),

            searchTextField.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: Metrics.contentInset
            ),
            searchTextField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            searchTextField.heightAnchor.constraint(equalToConstant: Metrics.height - 8),

            cancelButton.leadingAnchor.constraint(
                equalTo: searchTextField.trailingAnchor,
                constant: Metrics.interItemSpacing
            ),
            cancelButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -Metrics.contentInset
            ),
            cancelButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            cancelButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize)
        ])

        collapsedButton.addTarget(self, action: #selector(onCollapsedButtonTouchUp), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(onCancelButtonTouchUp), for: .touchUpInside)
        searchTextField.addTarget(self, action: #selector(onTextFieldEditingChanged), for: .editingChanged)
        searchTextField.delegate = self
        updateVisibility(animated: false)
    }

    private func applyTransparentSearchTextFieldChrome() {
        searchTextField.backgroundColor = .clear
        searchTextField.layer.backgroundColor = UIColor.clear.cgColor
        searchTextField.borderStyle = .none
        searchTextField.background = UIImage()
        searchTextField.disabledBackground = UIImage()
        searchTextField.layer.borderWidth = 0
        searchTextField.layer.borderColor = nil
        searchTextField.layer.shadowColor = nil
        searchTextField.layer.shadowOpacity = 0
        searchTextField.layer.shadowRadius = 0
        searchTextField.layer.shadowOffset = .zero
        searchTextField.layer.shadowPath = nil
    }

    private func updateVisibility(animated: Bool) {
        let updates = {
            self.collapsedButton.isHidden = self.isExpanded
            self.collapsedButton.alpha = self.isExpanded ? 0 : 1
            self.surfaceView.isHidden = !self.isExpanded
            self.surfaceView.alpha = self.isExpanded ? 1 : 0
        }

        guard animated else {
            updates()
            return
        }

        if isExpanded {
            surfaceView.isHidden = false
        } else {
            collapsedButton.isHidden = false
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut],
            animations: updates
        )
    }

    @objc
    private func onCollapsedButtonTouchUp(_ sender: UIButton) {
        setExpanded(true, animated: true)
        onBegin?()
    }

    @objc
    private func onCancelButtonTouchUp(_ sender: UIButton) {
        setQuery("", notify: true)
        setExpanded(false, animated: true)
        onCancel?()
    }

    @objc
    private func onTextFieldEditingChanged(_ sender: UISearchTextField) {
        onQueryChanged?(sender.text)
    }
}
