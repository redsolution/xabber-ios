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
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 6
    static let interItemSpacing: CGFloat = 8

    struct Frames: Equatable {
        let field: CGRect
        let cancel: CGRect
    }

    static func frames(
        containerWidth: CGFloat,
        safeAreaInsets: UIEdgeInsets = .zero
    ) -> Frames {
        let leading = horizontalInset + safeAreaInsets.left
        let trailing = horizontalInset + safeAreaInsets.right
        let cancelX = max(leading, containerWidth - trailing - controlHeight)
        let fieldWidth = max(
            0,
            cancelX - interItemSpacing - leading
        )
        return Frames(
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
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 12
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
            imageLiteral("magnifyingglass", dimension: NativeGlassBarStyle.iconSize),
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
            safeAreaInsets: safeAreaInsets
        )
        surfaceView.frame = frames.field
        cancelButton.frame = frames.cancel

        let fieldBounds = surfaceView.contentView.bounds
        submitButton.frame = CGRect(
            x: 0,
            y: 0,
            width: ChatSearchNavigationLayout.controlHeight,
            height: ChatSearchNavigationLayout.controlHeight
        )
        loadingIndicator.frame = submitButton.frame
        clearButton.frame = CGRect(
            x: max(0, fieldBounds.width - ChatSearchNavigationLayout.controlHeight),
            y: 0,
            width: ChatSearchNavigationLayout.controlHeight,
            height: ChatSearchNavigationLayout.controlHeight
        )
        textField.frame = CGRect(
            x: submitButton.frame.maxX,
            y: 0,
            width: max(0, clearButton.frame.minX - submitButton.frame.maxX),
            height: ChatSearchNavigationLayout.controlHeight
        )
        loadingAccessibilityElement.accessibilityFrameInContainerSpace =
            loadingIndicator.convert(loadingIndicator.bounds, to: self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillPendingFocusRequestIfPossible()
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
            image: imageLiteral("magnifyingglass", dimension: NativeGlassBarStyle.iconSize),
            prefersNativeGlass: false
        )
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
