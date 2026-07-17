//
//  FloatingBottomBarView.swift
//  xabber
//
//  Created by Codex on 14.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

final class FloatingBottomBarView: UIView {
    struct ActionPresentation: Equatable {
        let isLeftVisible: Bool
        let isCenterVisible: Bool

        static let allVisible = ActionPresentation(
            isLeftVisible: true,
            isCenterVisible: true
        )
    }

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

    private(set) var actionPresentation: ActionPresentation = .allVisible

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

    func applyActionPresentation(_ presentation: ActionPresentation) {
        actionPresentation = presentation
        applyVisibility(presentation.isLeftVisible, to: leftButton)
        applyVisibility(presentation.isCenterVisible, to: centerButton)

        centerEffectView.isHidden = !presentation.isCenterVisible
        centerEffectView.isUserInteractionEnabled = presentation.isCenterVisible
        centerEffectView.accessibilityElementsHidden = !presentation.isCenterVisible
        centerEffectView.alpha = 1
        if presentation.isCenterVisible {
            centerButton.accessibilityValue = nil
        }
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha >= 0.01,
              self.point(inside: point, with: event) else {
            return nil
        }

        if actionPresentation.isLeftVisible {
            let leftPoint = leftButton.convert(point, from: self)
            if let hitView = leftButton.hitTest(leftPoint, with: event) {
                return hitView
            }
        }

        if actionPresentation.isCenterVisible {
            let centerPoint = centerEffectView.convert(point, from: self)
            if let hitView = centerEffectView.hitTest(centerPoint, with: event) {
                return hitView
            }
        }

        return nil
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
        applyActionPresentation(.allVisible)
    }

    private func configure(button: UIButton, imageName: String) {
        let image = imageLiteral(imageName, dimension: Metrics.iconSize)

        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: image
        )
    }

    private func applyVisibility(_ isVisible: Bool, to button: UIButton) {
        button.isHidden = !isVisible
        button.isEnabled = isVisible
        button.isUserInteractionEnabled = isVisible
        button.isAccessibilityElement = isVisible
        button.accessibilityElementsHidden = !isVisible
        button.alpha = 1
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

    enum TransitionPhase: Equatable {
        case collapsed
        case expanding
        case expanded
        case collapsing
    }

    struct TransitionGeometry: Equatable {
        let startSurfaceFrame: CGRect
        let endSurfaceFrame: CGRect
    }

    typealias AnimatorFactory = (TimeInterval, UIView.AnimationCurve) -> UIViewPropertyAnimator

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
    private(set) var transitionPhase: TransitionPhase = .collapsed
    private(set) var transitionGeometry: TransitionGeometry?
    private(set) var transitionAnimator: UIViewPropertyAnimator?
    var animatorFactory: AnimatorFactory = { duration, curve in
        UIViewPropertyAnimator(duration: duration, curve: curve)
    }
    var reduceMotionEnabledProvider: () -> Bool = {
        UIAccessibility.isReduceMotionEnabled
    }
    var onBegin: (() -> Void)?
    var onQueryChanged: ((String?) -> Void)?
    var onCancel: (() -> Void)?
    var onTransitionPhaseChanged: ((TransitionPhase) -> Void)?

    var hidesUnderlyingActions: Bool {
        transitionPhase == .expanded
    }

    var currentInteractiveSurfaceFrame: CGRect {
        switch transitionPhase {
        case .collapsed:
            return untransformedFrame(of: collapsedButton)
        case .expanded:
            return untransformedFrame(of: surfaceView)
        case .expanding, .collapsing:
            guard let geometry = transitionGeometry else {
                return isExpanded
                    ? untransformedFrame(of: surfaceView)
                    : untransformedFrame(of: collapsedButton)
            }
            let progress = min(max(transitionAnimator?.fractionComplete ?? 0, 0), 1)
            return Self.interpolate(
                from: geometry.startSurfaceFrame,
                to: geometry.endSurfaceFrame,
                progress: progress
            )
        }
    }

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
            return
        }

        isExpanded = expanded
        if !animated || reduceMotionEnabledProvider() {
            stopActiveTransition()
            settle(atExpanded: expanded, notifyPhaseChange: true)
            updateFirstResponder(forExpanded: expanded)
            return
        }

        if reverseActiveTransition(towardExpanded: expanded) {
            updateFirstResponder(forExpanded: expanded)
            return
        }

        startTransition(towardExpanded: expanded)
        updateFirstResponder(forExpanded: expanded)
    }

    private func updateFirstResponder(forExpanded expanded: Bool) {
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

        switch transitionPhase {
        case .expanded:
            let surfacePoint = convert(point, to: surfaceView)
            guard !surfaceView.isHidden,
                  surfaceView.alpha > 0.01,
                  surfaceView.point(inside: surfacePoint, with: event) else {
                return nil
            }
            return surfaceView.hitTest(surfacePoint, with: event)
        case .collapsed:
            let buttonPoint = convert(point, to: collapsedButton)
            guard !collapsedButton.isHidden,
                  collapsedButton.alpha > 0.01,
                  collapsedButton.point(inside: buttonPoint, with: event) else {
                return nil
            }
            return collapsedButton.hitTest(buttonPoint, with: event)
        case .expanding, .collapsing:
            guard currentInteractiveSurfaceFrame.contains(point),
                  !surfaceView.isHidden else {
                return nil
            }
            let surfacePoint = convert(point, to: surfaceView)
            return surfaceView.hitTest(surfacePoint, with: event) ?? surfaceView
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
        settle(atExpanded: false, notifyPhaseChange: false)
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

    private func startTransition(towardExpanded expanded: Bool) {
        layoutIfNeeded()
        surfaceView.layoutIfNeeded()

        let collapsedFrame = untransformedFrame(of: collapsedButton)
        let expandedFrame = untransformedFrame(of: surfaceView)
        guard collapsedFrame.width > 0, expandedFrame.width > 0 else {
            settle(atExpanded: expanded, notifyPhaseChange: true)
            return
        }

        let startExpanded = !expanded
        let startFrame = startExpanded ? expandedFrame : collapsedFrame
        let endFrame = expanded ? expandedFrame : collapsedFrame
        transitionGeometry = TransitionGeometry(
            startSurfaceFrame: startFrame,
            endSurfaceFrame: endFrame
        )
        transitionStartExpanded = startExpanded
        transitionEndExpanded = expanded

        prepareTransition(startExpanded: startExpanded, collapsedFrame: collapsedFrame, expandedFrame: expandedFrame)
        setTransitionPhase(expanded ? .expanding : .collapsing)

        let animator = animatorFactory(0.28, .easeInOut)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.surfaceView.transform = expanded
                ? .identity
                : self.transform(from: expandedFrame, to: collapsedFrame)
            self.collapsedButton.alpha = expanded ? 0 : 1
            self.searchTextField.alpha = expanded ? 1 : 0
            self.cancelButton.alpha = expanded ? 1 : 0
        }
        animator.addCompletion { [weak self, weak animator] position in
            guard let self,
                  let animator,
                  self.transitionAnimator === animator else {
                return
            }
            self.completeTransition(at: position)
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    private var transitionStartExpanded: Bool?
    private var transitionEndExpanded: Bool?

    private func reverseActiveTransition(towardExpanded expanded: Bool) -> Bool {
        guard let animator = transitionAnimator,
              let startExpanded = transitionStartExpanded,
              let endExpanded = transitionEndExpanded,
              expanded == startExpanded || expanded == endExpanded else {
            return false
        }

        animator.pauseAnimation()
        animator.isReversed = expanded == startExpanded
        setTransitionPhase(expanded ? .expanding : .collapsing)
        animator.continueAnimation(withTimingParameters: nil, durationFactor: 1)
        return true
    }

    private func prepareTransition(
        startExpanded: Bool,
        collapsedFrame: CGRect,
        expandedFrame: CGRect
    ) {
        collapsedButton.isHidden = false
        surfaceView.isHidden = false
        surfaceView.isUserInteractionEnabled = true
        collapsedButton.isUserInteractionEnabled = false

        collapsedButton.alpha = startExpanded ? 0 : 1
        searchTextField.alpha = startExpanded ? 1 : 0
        cancelButton.alpha = startExpanded ? 1 : 0
        surfaceView.alpha = 1
        surfaceView.transform = startExpanded
            ? .identity
            : transform(from: expandedFrame, to: collapsedFrame)

        collapsedButton.accessibilityElementsHidden = true
        surfaceView.accessibilityElementsHidden = false
    }

    private func completeTransition(at position: UIViewAnimatingPosition) {
        let completedExpanded: Bool
        switch position {
        case .start:
            completedExpanded = transitionStartExpanded ?? isExpanded
        case .end:
            completedExpanded = transitionEndExpanded ?? isExpanded
        case .current:
            completedExpanded = isExpanded
        @unknown default:
            completedExpanded = isExpanded
        }

        isExpanded = completedExpanded
        transitionAnimator = nil
        transitionGeometry = nil
        transitionStartExpanded = nil
        transitionEndExpanded = nil
        settle(atExpanded: completedExpanded, notifyPhaseChange: true)
    }

    private func settle(atExpanded expanded: Bool, notifyPhaseChange: Bool) {
        isExpanded = expanded
        surfaceView.transform = .identity
        surfaceView.alpha = 1
        surfaceView.isHidden = !expanded
        surfaceView.isUserInteractionEnabled = expanded
        surfaceView.accessibilityElementsHidden = !expanded

        collapsedButton.alpha = expanded ? 0 : 1
        collapsedButton.isHidden = expanded
        collapsedButton.isUserInteractionEnabled = !expanded
        collapsedButton.accessibilityElementsHidden = expanded

        searchTextField.alpha = expanded ? 1 : 0
        cancelButton.alpha = expanded ? 1 : 0

        let phase: TransitionPhase = expanded ? .expanded : .collapsed
        if notifyPhaseChange {
            setTransitionPhase(phase)
        } else {
            transitionPhase = phase
        }
    }

    private func stopActiveTransition() {
        guard let animator = transitionAnimator else { return }
        transitionAnimator = nil
        transitionGeometry = nil
        transitionStartExpanded = nil
        transitionEndExpanded = nil
        animator.stopAnimation(true)
    }

    private func setTransitionPhase(_ phase: TransitionPhase) {
        guard transitionPhase != phase else { return }
        transitionPhase = phase
        onTransitionPhaseChanged?(phase)
    }

    private func untransformedFrame(of view: UIView) -> CGRect {
        CGRect(
            x: view.center.x - view.bounds.width / 2,
            y: view.center.y - view.bounds.height / 2,
            width: view.bounds.width,
            height: view.bounds.height
        )
    }

    private func transform(from sourceFrame: CGRect, to targetFrame: CGRect) -> CGAffineTransform {
        CGAffineTransform(
            a: targetFrame.width / sourceFrame.width,
            b: 0,
            c: 0,
            d: targetFrame.height / sourceFrame.height,
            tx: targetFrame.midX - sourceFrame.midX,
            ty: targetFrame.midY - sourceFrame.midY
        )
    }

    private static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    @objc
    private func onCollapsedButtonTouchUp(_ sender: UIButton) {
        setExpanded(true, animated: true)
        onBegin?()
    }

    @objc
    private func onCancelButtonTouchUp(_ sender: UIButton) {
        setQuery("", notify: false)
        setExpanded(false, animated: true)
        onCancel?()
    }

    @objc
    private func onTextFieldEditingChanged(_ sender: UISearchTextField) {
        onQueryChanged?(sender.text)
    }
}
