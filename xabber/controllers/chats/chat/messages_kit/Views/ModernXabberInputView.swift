//
//  ModernXabberInputView.swift
//  xabber
//
//  Created by Игорь Болдин on 16.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes

protocol ChatViewMessagesPanelDelegate {
    func messagesPanelOnClose()
    func messagesPanelOnIndicatorTouch()
}

protocol XabberInputBarDelegate: AnyObject {
    func sendButtonTouchUp(with text: String)
    func attachmentButtonTouchUp()
    func onAfterburnButtonTouchUp()
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat)
    func onCheckDevices()
    func onUpdateSignature()
    func onIdentityVerification()
    func onTextDidChange(to text: String?)
}

class ModernXabberInputView: UIView {
    
    class MessagesPanel: UIView {
        
        open var delegate: ChatViewMessagesPanelDelegate? = nil
        
        let indicatorButton: UIButton = {
            let button = UIButton(frame: .zero)
            
            button.tintColor = .systemGray
            
            return button
        }()
        
        let verticalLine: UIView = {
            let view = UIView()
            
            view.backgroundColor = .systemBlue
            
            return view
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            
            return label
        }()
        
        let messageLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        let closeButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("xmark", dimension: 24), for: .normal)
            button.tintColor = .systemGray
            
            return button
        }()
        
        public func update(title: String, attributed text: NSAttributedString) {
            self.titleLabel.text = title
            self.messageLabel.attributedText = text
        }
        
        public func update(title: String, normal text: String) {
            self.titleLabel.text = title
            self.messageLabel.text = text
        }
        
        public func configureForEdit() {
            self.indicatorButton.setImage(imageLiteral("xabber.pencil.cap", dimension: 24),for: .normal)
        }
        
        public func configureForForward() {
            self.indicatorButton.setImage(
                imageLiteral("arrowshape.turn.up.left", dimension: 24),
                for: .normal
            )
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setup()
        }
        
        private func setup() {
            self.addSubview(indicatorButton)
            self.addSubview(verticalLine)
            self.addSubview(titleLabel)
            self.addSubview(messageLabel)
            self.addSubview(closeButton)
            self.closeButton.addTarget(self, action: #selector(onCloseButtonTouchUpInside), for: .touchUpInside)
            self.indicatorButton.addTarget(self, action: #selector(onIndicatorButtonTouchUpInside), for: .touchUpInside)
        }
        
        public func update() {
            self.indicatorButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 44, height: 44)
            )
            self.verticalLine.frame = CGRect(
                origin: CGPoint(x: 59, y: 2),
                size: CGSize(width: 1, height: 42)
            )
            self.titleLabel.frame = CGRect(
                origin: CGPoint(x: 67, y: 2),
                size: CGSize(width: bounds.width - 111, height: 20)
            )
            self.messageLabel.frame = CGRect(
                origin: CGPoint(x: 67, y: 24),
                size: CGSize(width: bounds.width - 111, height: 20)
            )
            self.closeButton.frame = CGRect(
                origin: CGPoint(x: bounds.width - 44, y: 0),
                size: CGSize(width: 44, height: 44)
            )
            self.layoutSubviews()
        }
        
        @objc
        private func onCloseButtonTouchUpInside(_ sender: UIButton) {
            self.delegate?.messagesPanelOnClose()
        }
        
        @objc
        private func onIndicatorButtonTouchUpInside(_ sender: UIButton) {
            self.delegate?.messagesPanelOnIndicatorTouch()
        }
    }
    
    class SelectionPanel: UIView {
        
        var delegate: MessagesSelectionPanelActionDelegate? = nil
        
        let deleteButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("trash", dimension: 24), for: .normal)
            button.tintColor = .systemGray
            
            return button
        }()
        
        let shareButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("square.and.arrow.up", dimension: 24), for: .normal)
            button.tintColor = .systemGray
            
            return button
        }()
        
        
        let replyButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("arrowshape.turn.up.left", dimension: 24), for: .normal)
            button.tintColor = .systemGray
            
            return button
        }()
        
        let forwardButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("arrowshape.turn.up.right", dimension: 24), for: .normal)
            button.tintColor = .systemGray
            
            return button
        }()
        
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal var buttonConstraints: [NSLayoutConstraint] = []
        
        internal func setup() {
            addSubview(deleteButton)
            addSubview(shareButton)
            addSubview(replyButton)
            addSubview(forwardButton)
            deleteButton.addTarget(self, action: #selector(onDeleteButtonPress), for: .touchUpInside)
            shareButton.addTarget(self, action: #selector(onShareButtonPress), for: .touchUpInside)
            replyButton.addTarget(self, action: #selector(onReplyButtonPress), for: .touchUpInside)
            forwardButton.addTarget(self, action: #selector(onForwardButtonPress), for: .touchUpInside)
        }
        
        final func update() {
            deleteButton.frame = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(square: 44))
            shareButton.frame = CGRect(origin: CGPoint(x: 44 + ((frame.width - 44 * 4) / 3), y: 0), size: CGSize(square: 44))
            replyButton.frame = CGRect(origin: CGPoint(x: 88 + 2 * ((frame.width - 44 * 4) / 3), y: 0), size: CGSize(square: 44))
            forwardButton.frame = CGRect(origin: CGPoint(x: frame.width - 44, y: 0), size: CGSize(square: 44))
        }
        
        @objc
        internal func onCloseButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onClose: self)
        }
        
        @objc
        internal func onDeleteButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onDelete: self)
        }
        
        @objc
        internal func onCopyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onCopy: self)
        }
        
        @objc
        internal func onShareButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onShare: self)
        }
        
        @objc
        internal func onReplyButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onReply: self)
        }
        
        @objc
        internal func onForwardButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onForward: self)
        }
        
        @objc
        internal func onEditButtonPress(_ sender: UIButton) {
            delegate?.selectionPanel(onEdit: self)
        }
        
        open func show() {
            NSLayoutConstraint.activate(buttonConstraints)
        }
        
        open func hide() {
            NSLayoutConstraint.deactivate(buttonConstraints)
        }
        
        open func updateSelectionCount(_ count: Int) {
//            self.selectionLabel.text = "\(count)"
        }
        
    }
    
    open var accountPalette: MDCPalette = AccountColorManager.colors.first!.palette
    
    public var keyboardHeight: CGFloat = 0
    private var screenHeight: CGFloat = 0
    
    private var sendButtonState: SendButtonState = .record
    
    final var padding: UIEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        
    final var textViewPadding: UIEdgeInsets = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    
    /// Returns the most recent size calculated by `calculateIntrinsicContentSize()`
    final override var intrinsicContentSize: CGSize {
        return cachedIntrinsicContentSize
    }
    
    /// The intrinsicContentSize can change a lot so the delegate method
    /// `inputBar(self, didChangeIntrinsicContentTo: size)` only needs to be called
    /// when it's different
    public private(set) var previousIntrinsicContentSize: CGSize?
    
    /// The most recent calculation of the intrinsicContentSize
    private lazy var cachedIntrinsicContentSize: CGSize = calculateIntrinsicContentSize()
    
    /// A boolean that indicates if the maxTextViewHeight has been met. Keeping track of this
    /// improves the performance
    public private(set) var isOverMaxTextViewHeight = false
    
    
    var message: String = ""
    
    enum InputBarState {
        case normal
        case identityVerification
        case updateSignature
        case checkDevices
        case skeleton
        case selection
    }
    
    private var textViewHeightAnchor: NSLayoutConstraint?
    /// The maximum height that the InputTextView can reach
    final var maxTextViewHeight: CGFloat = 130 {
        didSet {
            textViewHeightAnchor?.constant = maxTextViewHeight
            invalidateIntrinsicContentSize()
        }
    }
    
    /// The height that will fit the current text in the InputTextView based on its current bounds
    
    private var inputTextViewMaxWidth: CGFloat = 326.0
    
    public var requiredInputTextViewHeight: CGFloat {
        if isSelectionPanelShowed {
            return 38.0
        }
        let maxTextViewSize = CGSize(width: textField.bounds.width, height: .greatestFiniteMagnitude)
        print("maxTextViewSize", maxTextViewSize, textField.sizeThatFits(maxTextViewSize).height.rounded(.down))
        return max(32, textField.sizeThatFits(maxTextViewSize).height.rounded(.down))
    }
    
    let blurredEffectView: UIVisualEffectView = {
        let blurEffect = UIBlurEffect(style: .systemMaterial)
        let blurredEffectView = UIVisualEffectView(effect: blurEffect)
        
        return blurredEffectView
    }()
        
    let textField: InputTextView = {
        let field = InputTextView(frame: .zero)
        
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        field.backgroundColor = .white
        field.layer.cornerRadius = 18
        field.layer.masksToBounds = true
        
        field.alpha = 0.79
        
        return field
    }()
    
    let sendButton: UIButton = {
        let button = UIButton(frame: CGRect(width: 44, height: 38))
        
        button.setImage(imageLiteral("mic", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
                        
        return button
    }()
   
    let attachButton: UIButton = {
        let button = UIButton(frame: CGRect(width: 44, height: 38))
        
        button.setImage(imageLiteral("paperclip", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
        
        return button
    }()
    
    let timerButton: UIButton = {
        let button = UIButton(frame: CGRect(width: 44, height: 38))
        
        button.setImage(imageLiteral("stopwatch", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
        button.isEnabled = true
//        button.isHidden = true
        
        return button
    }()
    
    let contentView: UIView = {
        let view = UIView(frame: .zero)
        
        return view
    }()
    
    let stateButton: UIButton = {
        let button = UIButton()
        
        button.backgroundColor = .clear
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.textColor = .systemBlue
        button.isHidden = true
        
        return button
    }()
    
    internal let selectionPanel: SelectionPanel = {
        let view = SelectionPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    let forwardPanel: MessagesPanel = {
        let view = MessagesPanel(frame: .zero)
        
        view.backgroundColor = .clear
        view.isHidden = true
        
        return view
    }()
    
    let editPanel: UIView = {
        let view = UIView()
        
        view.backgroundColor = .clear
        
        return view
    }()
    
    public var delegate: XabberInputBarDelegate? = nil
    
    public var barHeight: CGFloat = 49
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setupFrames(frame)
        self.setup()
        self.activateConstraints()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setup()
        self.activateConstraints()
    }
    
    private func addObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewDidChange),
            name: UITextView.textDidChangeNotification, object: textField
        )
    }
    
    public func setupFrames(_ frame: CGRect) {
        self.frame = frame
        let attachButtonFrame = CGRect(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: 44, height: 38)
        )
        let textFieldFrame = CGRect(
            origin: CGPoint(x: 44, y: 0),
            size: CGSize(width: self.frame.width - 88, height: 38)
        )
        let timerButtonFrame = CGRect(
            origin: CGPoint(x: self.frame.width - 88, y: 0),
            size: CGSize(width: 44, height: 38)
        )
        let sendButtonFrame = CGRect(
            origin: CGPoint(x: self.frame.width - 44, y: 0),
            size: CGSize(width: 44, height: 38)
        )
        
        self.attachButton.frame = attachButtonFrame
        self.textField.frame = textFieldFrame
        self.timerButton.frame = timerButtonFrame
        self.sendButton.frame = sendButtonFrame
        self.contentView.frame = CGRect(
            origin: CGPoint(x: 0, y: 6),
            size: CGSize(width: self.bounds.width, height: 38)
        )
        
        blurredEffectView.frame = self.bounds
        selectionPanel.frame = CGRect(
            origin: CGPoint(x: 16, y: 6),
            size: CGSize(width: self.bounds.width - 32, height: 38)
        )
        selectionPanel.update()
    }
    
    final func setup() {
        
        
        self.addSubview(self.blurredEffectView)
        
        contentView.addSubview(attachButton)
        contentView.addSubview(textField)
        contentView.addSubview(timerButton)
        contentView.addSubview(sendButton)
        contentView.addSubview(stateButton)
        addSubview(contentView)
        
        addSubview(selectionPanel)
        addSubview(forwardPanel)
        
        stateButton.fillSuperview()
        stateButton.isHidden = true
        self.addObservers()
        self.attachButton.addTarget(self, action: #selector(onAttachButtonTouchUp), for: .touchUpInside)
        self.timerButton.addTarget(self, action: #selector(onTimerButtonTouchUp), for: .touchUpInside)
        self.sendButton.addTarget(self, action: #selector(onSendButtonTouchUp), for: .touchUpInside)
        self.stateButton.addTarget(self, action: #selector(onStateButtonTouchUp), for: .touchUpInside)
        self.forwardPanel.update(title: "title", normal: "message")
    }
    
    public var state: InputBarState = .normal
    
    public var shouldHideTimer: Bool = true {
        didSet {
            self.changeState(to: self.state)
        }
    }
    
    public func changeState(to state: InputBarState) {
        switch state {
            case .normal:
                self.state = state
                self.attachButton.isHidden =    false
                self.textField.isHidden =       false
                self.timerButton.isHidden =     self.shouldHideTimer
                self.sendButton.isHidden =      false
                self.stateButton.isHidden =     true
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
            case .updateSignature:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.stateButton.setTitle("Update signature", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .identityVerification:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.stateButton.setTitle("Identity verification", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .checkDevices:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.stateButton.setTitle("Check devices", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .skeleton:
                self.state = state
//                self.sendButton.isEnabled =     false
                self.selectionPanel.isHidden =  true
            case .selection:
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  false
        }
        self.layoutSubviews()
    }
    
    var isSelectionPanelShowed: Bool = false
    
    public func showSelectionPanel() {
        self.textField.resignFirstResponder()
        self.isSelectionPanelShowed = true
        self.invalidateIntrinsicContentSize()
        self.attachButton.isHidden =    true
        self.textField.isHidden =       true
        self.timerButton.isHidden =     true
        self.sendButton.isHidden =      true
        self.stateButton.isHidden =     true
        self.selectionPanel.isHidden =  false
    }
    
    public func hideSelectionPanel() {
        self.isSelectionPanelShowed = false
        self.invalidateIntrinsicContentSize()
        self.changeState(to: self.state)
    }
    
    var topInset: CGFloat = 0
    var isForwardPanelShowed: Bool = false
    
    public func showForwardPanel() {
        if self.isForwardPanelShowed {
            return
        }
        self.isForwardPanelShowed = true
        self.topInset = 48
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.forwardPanel.frame = CGRect(
                origin: CGPoint(x: 0, y: 4),
                size: CGSize(width: self.bounds.width, height: 44)
            )
            self.forwardPanel.update()
            self.forwardPanel.configureForForward()
            self.forwardPanel.isHidden = false
            self.barHeight = self.cachedIntrinsicContentSize.height + 11
            var inputHeight: CGFloat = self.barHeight + self.keyboardHeight + self.topInset
            if self.keyboardHeight == 0 {
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
            }
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
        }
        
    }
    
    public func hideForwardPanel() {
        if !self.isForwardPanelShowed {
            return
        }
        self.isForwardPanelShowed = false
        self.topInset = 0
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.forwardPanel.isHidden = true
            self.barHeight = self.cachedIntrinsicContentSize.height + 11
            var inputHeight: CGFloat = self.barHeight + self.keyboardHeight + self.topInset
            if self.keyboardHeight == 0 {
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
            }
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
        }
        
    }
    
    final func update(screenHeight: CGFloat, keyboardHeight: CGFloat, animate: Bool = false, additionalAnimations: (() -> Void)? = nil) {
        func doAnimate(_ block: @escaping () -> Void) {
            if animate {
                UIView.animate(withDuration: 0.16, delay: 0.0, options: [.showHideTransitionViews, .curveEaseInOut], animations: block)
            } else {
                block()
            }
        }
        
        self.keyboardHeight = keyboardHeight
        self.screenHeight = screenHeight
        var inputHeight: CGFloat = self.barHeight + keyboardHeight + topInset
        if keyboardHeight == 0 {
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
        }
        doAnimate {
            self.contentView.frame = CGRect(
                origin: CGPoint(x: 0, y: self.topInset + 6),
                size: CGSize(width: self.bounds.width, height: self.cachedIntrinsicContentSize.height)
            )
            let frame = CGRect(
                origin: CGPoint(x: 0, y: screenHeight - inputHeight),
                size: CGSize(width: self.bounds.width, height: inputHeight)
            )
            self.frame = frame
            self.blurredEffectView.frame = self.bounds
            additionalAnimations?()
        }
        self.layoutSubviews()
    }
        
    final func activateConstraints() {
        
    }
    
    @objc
    final func textViewDidChange(force: Bool = false) {
        let trimmedText = textField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        self.textField.placeholderLabel.isHidden = !self.textField.text.isEmpty
        self.message = trimmedText
        
        if force || (requiredInputTextViewHeight != textField.bounds.height) {
            invalidateIntrinsicContentSize()
        }

        UIView.animate(withDuration: 0.16, delay: 0.0, options: [.showHideTransitionViews]) {
            if self.state == .normal {
                if self.textField.text.isEmpty {
                    self.timerButton.isHidden = self.shouldHideTimer
                } else {
                    self.timerButton.isHidden = true
                }
            }
            if trimmedText.isNotEmpty {
                self.changeSendButtonState(to: .send)
            } else {
                self.changeSendButtonState(to: .record)
            }
        }
        self.delegate?.onTextDidChange(to: trimmedText.isEmpty ? nil : trimmedText)
    }
    
    enum SendButtonState {
        case record
        case send
    }
    
    public var isSendButtonEnabled: Bool = false
    
    final func changeSendButtonState(to state: SendButtonState) {
        self.sendButtonState = state
        switch state {
            case .record:
//                self.sendButton.setImage(imageLiteral( "microphone").withRenderingMode(.alwaysTemplate), for: .normal)
                self.sendButton.setImage(imageLiteral("xabber.paperplane.fill", dimension: 24), for: .normal)
                self.sendButton.tintColor = .secondaryLabel
                self.attachButton.isEnabled = self.isSendButtonEnabled
                self.sendButton.isEnabled = false //self.isSendButtonEnabled
            case .send:
                self.sendButton.setImage(imageLiteral("xabber.paperplane.fill", dimension: 24), for: .normal)
                self.sendButton.tintColor = self.isSendButtonEnabled ? self.accountPalette.tint600 : .secondaryLabel
                self.sendButton.isEnabled = self.isSendButtonEnabled
                self.attachButton.isEnabled = self.isSendButtonEnabled
        }
    }
    
    final public func updateSendButtonState() {
        self.changeSendButtonState(to: self.sendButtonState)
    }
    
    
    /// Invalidates the view’s intrinsic content size
    final override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        cachedIntrinsicContentSize = calculateIntrinsicContentSize()
        if previousIntrinsicContentSize?.height != cachedIntrinsicContentSize.height {
            previousIntrinsicContentSize = cachedIntrinsicContentSize
        }
        
        self.barHeight = self.cachedIntrinsicContentSize.height + 11
        var inputHeight: CGFloat = self.barHeight + keyboardHeight + self.topInset
        if keyboardHeight == 0 {
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
        }
        UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseIn]) {
            self.textField.frame = CGRect(
                origin: CGPoint(x: 44, y: 0),
                size: CGSize(width: self.frame.width - 88, height: self.cachedIntrinsicContentSize.height)
            )
            self.contentView.frame = CGRect(
                origin: CGPoint(x: 0, y: self.topInset + 6),
                size: CGSize(width: self.bounds.width, height: self.cachedIntrinsicContentSize.height)
            )
            self.attachButton.frame = CGRect(
                origin: CGPoint(x: 0, y: self.cachedIntrinsicContentSize.height - 38),
                size: CGSize(width: 44, height: 38)
            )
            self.sendButton.frame = CGRect(
                origin: CGPoint(x: self.frame.width - 44, y: self.cachedIntrinsicContentSize.height - 38),
                size: CGSize(width: 44, height: 38)
            )
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
            self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight)
        }
        self.layoutSubviews()
        
    }
    
    // MARK: - Layout Helper Methods
    
    /// Calculates the correct intrinsicContentSize of the MessageInputBar. This takes into account the various padding edge
    /// insets, InputTextView's height and top/bottom InputStackView's heights.
    ///
    /// - Returns: The required intrinsicContentSize
    final func calculateIntrinsicContentSize() -> CGSize {
        var inputTextViewHeight = requiredInputTextViewHeight
        if inputTextViewHeight >= maxTextViewHeight {
            if !isOverMaxTextViewHeight {
//                textViewHeightAnchor?.isActive = true
                textField.isScrollEnabled = true
                isOverMaxTextViewHeight = true
            }
            inputTextViewHeight = maxTextViewHeight
        } else {
            if isOverMaxTextViewHeight {
//                textViewHeightAnchor?.isActive = false //|| shouldForceTextViewMaxHeight
                textField.isScrollEnabled = false
                isOverMaxTextViewHeight = false
            }
        }
        
        let requiredHeight = inputTextViewHeight
//        print("requiredHeight", requiredHeight)
//        self.delegate?.heightDidChange(self, to: requiredHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: requiredHeight)
    }
    
    @objc
    private func onAttachButtonTouchUp(_ sender: UIButton) {
        self.delegate?.attachmentButtonTouchUp()
    }
    
    @objc
    private func onTimerButtonTouchUp(_ sender: UIButton) {
        self.delegate?.onAfterburnButtonTouchUp()
    }
    
    @objc
    private func onSendButtonTouchUp(_ sender: UIButton) {
        switch self.sendButtonState {
            case .send:
                self.delegate?.sendButtonTouchUp(with: textField.text)
//                self.message = ""
//                self.textField.text = ""
            case .record:
                break
        }
    }
    
    @objc
    private func onStateButtonTouchUp(_ sender: UIButton) {
        switch state {
            case .updateSignature:
                self.delegate?.onUpdateSignature()
            case .checkDevices:
                self.delegate?.onCheckDevices()
            case .identityVerification:
                self.delegate?.onIdentityVerification()
            default: break
        }
    }
}
