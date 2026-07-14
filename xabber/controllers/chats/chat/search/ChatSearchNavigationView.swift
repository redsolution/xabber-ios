//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import UIKit

enum ChatSearchNavigationLayout {
    static let nominalHeight: CGFloat = 60
    static let controlHeight: CGFloat = 44
    static let searchIconPointSize: CGFloat = 16
    static let searchIconOpticalInsets = NSDirectionalEdgeInsets(
        top: 0,
        leading: 8,
        bottom: 8,
        trailing: 0
    )
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 6
    static let interItemSpacing: CGFloat = 8

    struct Frames: Equatable {
        let field: CGRect
        let cancel: CGRect
    }

    static func frames(
        containerWidth: CGFloat,
        safeAreaInsets: UIEdgeInsets = .zero,
        layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> Frames {
        let leading = horizontalInset + safeAreaInsets.left
        let trailing = horizontalInset + safeAreaInsets.right
        let cancelX = max(leading, containerWidth - trailing - controlHeight)
        let fieldWidth = max(
            0,
            cancelX - interItemSpacing - leading
        )
        let leftToRight = Frames(
            field: CGRect(
                x: leading,
                y: verticalInset,
                width: fieldWidth,
                height: controlHeight
            ),
            cancel: CGRect(
                x: cancelX,
                y: verticalInset,
                width: controlHeight,
                height: controlHeight
            )
        )
        guard layoutDirection == .rightToLeft else { return leftToRight }
        return Frames(
            field: mirrored(leftToRight.field, in: containerWidth),
            cancel: mirrored(leftToRight.cancel, in: containerWidth)
        )
    }

    private static func mirrored(_ frame: CGRect, in width: CGFloat) -> CGRect {
        CGRect(
            x: width - frame.maxX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }
}

final class ChatSearchSingleLineTextField: UITextField {
    let maxLines = 1
}

final class ChatSearchNavigationView: UIView, UITextFieldDelegate {
    struct RenderState: Equatable {
        let query: String
        let isRemoteSearching: Bool
    }

    static let inputAccessibilityIdentifier = ChatSearchAccessibilityIdentifier.input
    static let submitAccessibilityIdentifier = ChatSearchAccessibilityIdentifier.submit
    static let loadingAccessibilityIdentifier = ChatSearchAccessibilityIdentifier.loading
    static let clearAccessibilityIdentifier = ChatSearchAccessibilityIdentifier.clear
    static let cancelAccessibilityIdentifier = ChatSearchAccessibilityIdentifier.cancel

    var onSubmit: ((String) -> Void)?
    var onTextChanged: ((String?) -> Void)?
    var onClear: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var hasPendingFocusRequest = false
    private(set) var focusAttemptCount = 0

    let surfaceView: UIVisualEffectView
    private let localization: ChatSearchLocalization
    private let prefersNativeGlass: Bool
    private(set) var adaptiveEnvironment = ChatSearchAdaptiveEnvironment.standard
    private(set) var adaptiveSurfaceStyle = ChatSearchAdaptiveAppearance.surfaceStyle(
        for: .standard
    )

    let textField: ChatSearchSingleLineTextField = {
        let field = ChatSearchSingleLineTextField()
        field.accessibilityIdentifier = inputAccessibilityIdentifier
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.clearButtonMode = .never
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = false
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.adjustsFontSizeToFitWidth = false
        field.textColor = .label
        field.tintColor = .systemBlue
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }()

    let submitButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = submitAccessibilityIdentifier
        button.tintColor = NativeGlassBarStyle.iconTintColor
        button.setImage(
            imageLiteral(
                "magnifyingglass",
                dimension: ChatSearchNavigationLayout.searchIconPointSize
            ),
            for: .normal
        )
        return button
    }()

    let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.accessibilityIdentifier = loadingAccessibilityIdentifier
        indicator.color = NativeGlassBarStyle.iconTintColor
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private(set) lazy var loadingAccessibilityElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityIdentifier = Self.loadingAccessibilityIdentifier
        element.accessibilityLabel = localization.text(.loading)
        element.accessibilityTraits = [.updatesFrequently]
        element.isAccessibilityElement = true
        return element
    }()

    let clearButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = clearAccessibilityIdentifier
        button.tintColor = .secondaryLabel
        button.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        button.isHidden = true
        return button
    }()

    let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = cancelAccessibilityIdentifier
        return button
    }()

    var text: String? {
        get { textField.text }
        set {
            textField.text = newValue ?? ""
            updateClearVisibility()
            updateAccessibilityState()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: ChatSearchNavigationLayout.nominalHeight)
    }

    override init(frame: CGRect) {
        localization = .production()
        prefersNativeGlass = true
        surfaceView = UIVisualEffectView(
            effect: NativeGlassBarStyle.makeEffect(
                role: .clearInputSurface,
                interactive: true
            )
        )
        super.init(frame: frame)
        setup(prefersNativeGlass: true)
    }

    init(
        frame: CGRect,
        prefersNativeGlass: Bool,
        localization: ChatSearchLocalization = .production()
    ) {
        self.localization = localization
        self.prefersNativeGlass = prefersNativeGlass
        surfaceView = UIVisualEffectView(
            effect: NativeGlassBarStyle.makeEffect(
                role: .clearInputSurface,
                interactive: true,
                prefersNativeGlass: prefersNativeGlass
            )
        )
        super.init(frame: frame)
        setup(prefersNativeGlass: prefersNativeGlass)
    }

    required init?(coder: NSCoder) {
        localization = .production()
        prefersNativeGlass = true
        surfaceView = UIVisualEffectView(
            effect: NativeGlassBarStyle.makeEffect(
                role: .clearInputSurface,
                interactive: true
            )
        )
        super.init(coder: coder)
        setup(prefersNativeGlass: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = ChatSearchNavigationLayout.frames(
            containerWidth: bounds.width,
            safeAreaInsets: safeAreaInsets,
            layoutDirection: adaptiveEnvironment.layoutDirection
        )
        surfaceView.frame = frames.field
        cancelButton.frame = frames.cancel

        let fieldBounds = surfaceView.contentView.bounds
        let isRightToLeft = adaptiveEnvironment.layoutDirection == .rightToLeft
        submitButton.frame = CGRect(
            x: isRightToLeft
                ? max(0, fieldBounds.width - ChatSearchNavigationLayout.controlHeight)
                : 0,
            y: 0,
            width: ChatSearchNavigationLayout.controlHeight,
            height: ChatSearchNavigationLayout.controlHeight
        )
        loadingIndicator.frame = submitButton.frame
        clearButton.frame = CGRect(
            x: isRightToLeft
                ? 0
                : max(0, fieldBounds.width - ChatSearchNavigationLayout.controlHeight),
            y: 0,
            width: ChatSearchNavigationLayout.controlHeight,
            height: ChatSearchNavigationLayout.controlHeight
        )
        textField.frame = CGRect(
            x: isRightToLeft ? clearButton.frame.maxX : submitButton.frame.maxX,
            y: 0,
            width: max(
                0,
                isRightToLeft
                    ? submitButton.frame.minX - clearButton.frame.maxX
                    : clearButton.frame.minX - submitButton.frame.maxX
            ),
            height: ChatSearchNavigationLayout.controlHeight
        )
        loadingAccessibilityElement.accessibilityFrameInContainerSpace =
            loadingIndicator.convert(loadingIndicator.bounds, to: self)
        [submitButton, clearButton, cancelButton].forEach {
            $0.updateChatSearchAccessibilityFrame()
        }
        cancelButton.layer.cornerRadius = ChatSearchNavigationLayout.controlHeight / 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillPendingFocusRequestIfPossible()
        [submitButton, clearButton, cancelButton].forEach {
            $0.updateChatSearchAccessibilityFrame()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory ||
                previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast ||
                previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle ||
                previousTraitCollection?.layoutDirection != traitCollection.layoutDirection else {
            return
        }
        applyAdaptiveEnvironment(.current(for: self))
    }

    func applyAdaptiveEnvironment(_ environment: ChatSearchAdaptiveEnvironment) {
        adaptiveEnvironment = environment
        semanticContentAttribute = environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        surfaceView.semanticContentAttribute = semanticContentAttribute
        textField.font = ChatSearchAdaptiveLayoutPolicy.scaledFont(
            baseSize: 17,
            weight: .regular,
            textStyle: .body,
            contentSizeCategory: environment.contentSizeCategory,
            maximumPointSize: 28
        )
        adaptiveSurfaceStyle = ChatSearchAdaptiveAppearance.applySurface(
            to: surfaceView,
            role: .clearInputSurface,
            cornerStyle: .capsule,
            interactive: true,
            prefersNativeGlass: prefersNativeGlass,
            environment: environment
        )
        ChatSearchAdaptiveAppearance.applyDetachedButton(
            cancelButton,
            environment: environment
        )
        // These controls are positioned with frames in layoutSubviews. The
        // shared glass helpers opt into Auto Layout, including on every trait
        // refresh, so restore this view's manual-layout contract afterwards.
        [submitButton, clearButton, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
        }
        setNeedsLayout()
    }

    func render(_ state: RenderState) {
        if textField.text != state.query {
            textField.text = state.query
        }
        updateClearVisibility()
        submitButton.isHidden = state.isRemoteSearching
        loadingIndicator.isHidden = !state.isRemoteSearching
        if state.isRemoteSearching {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        updateAccessibilityState()
    }

    @discardableResult
    func requestInputFocusWhenAttached() -> Bool {
        guard window != nil else {
            hasPendingFocusRequest = true
            return false
        }
        hasPendingFocusRequest = false
        focusAttemptCount += 1
        return textField.becomeFirstResponder()
    }

    func didMoveToWindowForTesting() {
        fulfillPendingFocusRequestIfPossible()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitCurrentText()
        return true
    }

    private func setup(prefersNativeGlass: Bool) {
        textField.accessibilityLabel = localization.text(.searchField)
        textField.placeholder = localization.text(.searchField)
        submitButton.accessibilityLabel = localization.text(.searchTitle)
        loadingIndicator.accessibilityLabel = localization.text(.loading)
        clearButton.accessibilityLabel = localization.text(.clear)
        cancelButton.accessibilityLabel = localization.text(.cancel)
        accessibilityIdentifier = ChatSearchAccessibilityIdentifier.topBar
        isAccessibilityElement = false
        loadingIndicator.isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false

        NativeGlassBarStyle.applySurface(
            to: surfaceView,
            role: .clearInputSurface,
            cornerStyle: .capsule,
            interactive: true,
            prefersNativeGlass: prefersNativeGlass
        )
        surfaceView.isUserInteractionEnabled = true
        surfaceView.contentView.isUserInteractionEnabled = true
        textField.delegate = self

        addSubview(surfaceView)
        surfaceView.contentView.addSubview(submitButton)
        surfaceView.contentView.addSubview(loadingIndicator)
        surfaceView.contentView.addSubview(textField)
        surfaceView.contentView.addSubview(clearButton)
        addSubview(cancelButton)

        NativeGlassBarStyle.applyIconButtonStyle(
            to: submitButton,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: imageLiteral(
                "magnifyingglass",
                dimension: ChatSearchNavigationLayout.searchIconPointSize
            ),
            prefersNativeGlass: false
        )
        var submitConfiguration = UIButton.Configuration.plain()
        submitConfiguration.image = imageLiteral(
            "magnifyingglass",
            dimension: ChatSearchNavigationLayout.searchIconPointSize
        )
        submitConfiguration.baseForegroundColor = NativeGlassBarStyle.iconTintColor
        submitConfiguration.contentInsets = ChatSearchNavigationLayout.searchIconOpticalInsets
        submitButton.configuration = submitConfiguration
        NativeGlassBarStyle.applyIconButtonStyle(
            to: clearButton,
            tintColor: .secondaryLabel,
            image: UIImage(systemName: "xmark.circle.fill"),
            prefersNativeGlass: false
        )
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: cancelButton,
            tintColor: NativeGlassBarStyle.iconTintColor,
            image: UIImage(systemName: "xmark")
        )
        submitButton.addTarget(self, action: #selector(onSubmitButtonTouchUp), for: .touchUpInside)
        clearButton.addTarget(self, action: #selector(onClearButtonTouchUp), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(onCancelButtonTouchUp), for: .touchUpInside)
        textField.addTarget(self, action: #selector(onTextFieldEditingChanged), for: .editingChanged)
        applyAdaptiveEnvironment(.current(for: self))
        updateAccessibilityState()
    }

    private func fulfillPendingFocusRequestIfPossible() {
        guard hasPendingFocusRequest,
              window != nil else {
            return
        }
        _ = requestInputFocusWhenAttached()
    }

    private func updateClearVisibility() {
        clearButton.isHidden = (textField.text ?? "").isEmpty
    }

    private func updateAccessibilityState() {
        textField.accessibilityValue = textField.text
        submitButton.accessibilityElementsHidden = submitButton.isHidden
        loadingIndicator.accessibilityElementsHidden = loadingIndicator.isHidden
        loadingAccessibilityElement.accessibilityElementsHidden = loadingIndicator.isHidden
        clearButton.accessibilityElementsHidden = clearButton.isHidden
        cancelButton.accessibilityElementsHidden = cancelButton.isHidden

        var orderedElements: [Any] = [textField]
        if !submitButton.isHidden {
            orderedElements.append(submitButton)
        } else if !loadingIndicator.isHidden {
            orderedElements.append(loadingAccessibilityElement)
        }
        if !clearButton.isHidden {
            orderedElements.append(clearButton)
        }
        if !cancelButton.isHidden {
            orderedElements.append(cancelButton)
        }
        accessibilityElements = orderedElements
    }

    private func submitCurrentText() {
        onSubmit?(textField.text ?? "")
    }

    @objc
    private func onSubmitButtonTouchUp() {
        submitCurrentText()
    }

    @objc
    private func onClearButtonTouchUp() {
        textField.text = ""
        updateClearVisibility()
        updateAccessibilityState()
        onTextChanged?(nil)
        onClear?()
    }

    @objc
    private func onCancelButtonTouchUp() {
        onCancel?()
    }

    @objc
    private func onTextFieldEditingChanged() {
        updateClearVisibility()
        updateAccessibilityState()
        onTextChanged?(textField.text)
    }
}

typealias ChatSearchInputBarView = ChatSearchNavigationView
