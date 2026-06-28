//
//  FloatingBottomBarView.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

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

    let leftButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor
        )

        return button
    }()

    let centerEffectView: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: NativeGlassBarStyle.makeEffect(interactive: true))

        view.translatesAutoresizingMaskIntoConstraints = false
        NativeGlassBarStyle.applySurface(to: view, cornerStyle: .capsule, interactive: true)

        return view
    }()

    let centerButton: UIButton = {
        let button = UIButton(type: .system)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitleColor(.label, for: .normal)
        button.setTitleColor(.secondaryLabel, for: .disabled)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.backgroundColor = .clear
        button.layer.borderWidth = 0
        button.layer.borderColor = nil
        button.layer.shadowColor = nil
        button.layer.shadowOpacity = 0
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = .zero
        button.layer.shadowPath = nil

        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLeftButton(imageName: String, isActive: Bool) {
        configure(button: leftButton, imageName: imageName)
        leftButton.accessibilityValue = isActive ? "On" : "Off"
    }

    func setCenterButtonEnabled(_ isEnabled: Bool) {
        centerButton.isEnabled = isEnabled
        centerEffectView.alpha = isEnabled ? 1.0 : 0.55
        centerButton.accessibilityValue = isEnabled ? nil : "Disabled"
    }

    func setCenterButtonTitle(
        _ title: String,
        accessibilityIdentifier: String,
        accessibilityLabel: String? = nil
    ) {
        centerButton.setTitle(title, for: .normal)
        centerButton.accessibilityIdentifier = accessibilityIdentifier
        centerButton.accessibilityLabel = accessibilityLabel ?? title
    }

    func refreshAppearance() {
        NativeGlassBarStyle.applySurface(to: centerEffectView, cornerStyle: .capsule, interactive: true)
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: leftButton,
            tintColor: NativeGlassBarStyle.iconTintColor
        )
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false

        addSubview(leftButton)
        addSubview(centerEffectView)
        centerEffectView.contentView.addSubview(centerButton)

        NSLayoutConstraint.activate([
            leftButton.leadingAnchor.constraint(
                equalTo: leadingAnchor
            ),
            leftButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftButton.widthAnchor.constraint(equalToConstant: Metrics.buttonSize),
            leftButton.heightAnchor.constraint(equalToConstant: Metrics.buttonSize),

            centerEffectView.leadingAnchor.constraint(
                equalTo: leftButton.trailingAnchor,
                constant: NativeGlassBarStyle.interItemSpacing
            ),
            centerEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            centerEffectView.topAnchor.constraint(equalTo: topAnchor),
            centerEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            centerEffectView.heightAnchor.constraint(equalToConstant: Metrics.height),

            centerButton.leadingAnchor.constraint(
                equalTo: centerEffectView.contentView.leadingAnchor
            ),
            centerButton.trailingAnchor.constraint(
                equalTo: centerEffectView.contentView.trailingAnchor
            ),
            centerButton.topAnchor.constraint(equalTo: centerEffectView.contentView.topAnchor),
            centerButton.bottomAnchor.constraint(equalTo: centerEffectView.contentView.bottomAnchor)
        ])

        configure(button: leftButton, imageName: "line.3.horizontal.decrease.circle")
        setCenterButtonEnabled(true)
    }

    private func configure(button: UIButton, imageName: String) {
        let image = imageLiteral(imageName, dimension: Metrics.iconSize)

        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: image
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
        textField.placeholder = "Search".localizeString(id: "search", arguments: [])
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else {
            return nil
        }

        if isExpanded {
            let surfacePoint = convert(point, to: surfaceView)
            guard !surfaceView.isHidden,
                  surfaceView.alpha > 0.01,
                  surfaceView.point(inside: surfacePoint, with: event) else {
                return nil
            }
            return surfaceView.hitTest(surfacePoint, with: event)
        }

        let buttonPoint = convert(point, to: collapsedButton)
        guard !collapsedButton.isHidden,
              collapsedButton.alpha > 0.01,
              collapsedButton.point(inside: buttonPoint, with: event) else {
            return nil
        }
        return collapsedButton.hitTest(buttonPoint, with: event)
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
