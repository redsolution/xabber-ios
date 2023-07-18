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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes


protocol XabberInputBarDelegate: AnyObject {
    
    func textDidChange(_ inputBar: XabberInputBar, to text: String)
    func imageDidAttach(_ inputBar: XabberInputBar, image: UIImage)
    func sendButtonTouchUp(_ inputBar: XabberInputBar, with text: String)
    func attachmentButtonTouchUp(_ inputBar: XabberInputBar)
    func onStartRecording(_ inputBar: XabberInputBar)
    func onStopRecording(_ inputBar: XabberInputBar, state: XabberInputBar.RecordButtonState)
    func onSendVoiceMessage(_ inputBar: XabberInputBar)
    func onPinRecording(_ inputBar: XabberInputBar)
    func onRecordButtonDraggetOut(_ inputBar: XabberInputBar, to point: CGPoint)
    func heightDidChange(_ inputBar: XabberInputBar, to height: CGFloat)
}

public struct HorizontalEdgePadding {
    public let left: CGFloat
    public let right: CGFloat

    public static let zero = HorizontalEdgePadding(left: 0, right: 0)

    public init(left: CGFloat, right: CGFloat) {
        self.left = left
        self.right = right
    }
}

final class XabberInputBar: UIView {
    
    private var isRecordButtonPressed: Bool = false
    private var recordButtonInitialPosition: CGPoint = .zero
    
    final weak var delegate: XabberInputBarDelegate?
    
    internal let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .bar)
        
        return view
    }()
    
    final var backgroundView: UIView = {
        let view = UIView()
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .inputBarGray
        
        return view
    }()
    
    final var contentView: UIView = {
        let view = UIView()
        
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    /// A SeparatorLine that is anchored at the top of the MessageInputBar with a height of 1
    public final let separatorLine = SeparatorLine()
    
    public final let topStackView: InputStackView = {
        let stack = InputStackView(axis: .horizontal, spacing: 0)
        //part1
//        stack.isLayoutMarginsRelativeArrangement = true
//        stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
        
        stack.distribution = .fill
        stack.alignment = .top
        
//        stack.isUserInteractionEnabled = false
        
        return stack
    }()
    
    public final let rightStackView: InputStackView = {
        let stack = InputStackView(axis: .horizontal, spacing: 0)
        
        stack.alignment = .center
        
        return stack
    }()
    
    public final let leftStackView: InputStackView = {
        let stack = InputStackView(axis: .horizontal, spacing: 0)
        
        stack.alignment = .center
        
        return stack
    }()
    
    /// The InputTextView a user can input a message in
    final let inputTextView: InputTextView = {
        let textView = InputTextView()
        
        textView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        textView.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 13.0, *) {
            textView.backgroundColor = .systemBackground
        } else {
            textView.backgroundColor = .white
        }
        textView.textAlignment = .natural
        
        textView.layer.cornerRadius = 17
        textView.layer.masksToBounds = true
        textView.layer.borderWidth = 1
        
        if #available(iOS 13.0, *) {
            textView.layer.borderColor = UIColor.label.withAlphaComponent(0.1).cgColor
        } else {
            textView.layer.borderColor = MDCPalette.grey.tint700.withAlphaComponent(0.1).cgColor
        }
                
        return textView
    }()

    
    final let sendButton: InputBarButtonItem = {
        let button = InputBarButtonItem()
        
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.setImage(#imageLiteral(resourceName: "send").withRenderingMode(.alwaysTemplate), for: .normal)
        if #available(iOS 13.0, *) {
            button.tintColor = .secondaryLabel
        } else {
            button.tintColor = .gray
        }
        
        return button
    }()
    
    final let attachmentButton: InputBarButtonItem = {
        let button = InputBarButtonItem()
        
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.setImage(#imageLiteral(resourceName: "attach").withRenderingMode(.alwaysTemplate), for: .normal)
        if #available(iOS 13.0, *) {
            button.tintColor = .secondaryLabel
        } else {
            button.tintColor = .gray
        }
        button.isEnabled = true
        return button
    }()
    
    final let recordButton: InputBarButtonItem = {
        let button = InputBarButtonItem()
        
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.setImage(#imageLiteral(resourceName: "microphone").withRenderingMode(.alwaysTemplate), for: .normal)
        
        if #available(iOS 13.0, *) {
            button.tintColor = .secondaryLabel
        } else {
            button.tintColor = .gray
        }
        
//        button.isEnabled = false
        
        return button
    }()
    
    final let recordIndicatorView: ChatViewController.ToolsButton = {
        let view = ChatViewController.ToolsButton(frame: CGRect(origin: CGPoint(x: 0, y: 0), size: .zero))
        
        view.changeState(.hidden)
        view.layer.cornerRadius = 18
        
        return view
    }()

    final var padding: UIEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0) {
        didSet {
            updatePadding()
        }
    }
    
    final var topStackViewPadding: UIEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) {
        didSet {
            updateTopStackViewPadding()
        }
    }
    
    final var textViewPadding: UIEdgeInsets = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0) {
        didSet {
            updateTextViewPadding()
        }
    }
    
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
    
    /// A boolean that determines if the maxTextViewHeight should be auto updated on device rotation
    final var shouldAutoUpdateMaxTextViewHeight = true
    
    /// The maximum height that the InputTextView can reach
    final var maxTextViewHeight: CGFloat = 0 {
        didSet {
            textViewHeightAnchor?.constant = maxTextViewHeight
            invalidateIntrinsicContentSize()
        }
    }
    
    /// The height that will fit the current text in the InputTextView based on its current bounds
    
    private var inputTextViewMaxWidth: CGFloat = 326.0
    
    public var requiredInputTextViewHeight: CGFloat {
        let maxTextViewSize = CGSize(width: inputTextView.bounds.width, height: .greatestFiniteMagnitude)
        return max(32, inputTextView.sizeThatFits(maxTextViewSize).height.rounded(.down))
    }
    
    /// The fixed widthAnchor constant of the rightStackView
    public var rightStackViewWidthConstant: CGFloat = 56 {
        didSet {
            rightStackViewLayoutSet?.width?.constant = rightStackViewWidthConstant
        }
    }
    
    public private(set) var topStackViewHeightConstant: CGFloat = 0
    {
        didSet {
            topStackViewLayoutSet?.height?.constant = topStackViewHeightConstant
        }
    }
    
    /// The InputBarItems held in the leftStackView
    public private(set) var leftStackViewItems: [UIView] = []
    
    /// The InputBarItems held in the rightStackView
    public private(set) var rightStackViewItems: [UIView] = []
    
    /// The InputBarItems held in the bottomStackView
    public private(set) var bottomStackViewItems: [UIView] = []
    
    /// The InputBarItems held in the topStackView
    public private(set) var topStackViewItems: [UIView] = []
    
    /// The InputBarItems held to make use of their hooks but they are not automatically added to a UIStackView
    final var nonStackViewItems: [InputBarButtonItem] = []
    
    /// Returns a flatMap of all the items in each of the UIStackViews
    public var items: [UIView] {
        return [leftStackViewItems, rightStackViewItems, bottomStackViewItems, nonStackViewItems].flatMap { $0 }
    }
    
    
    final var frameInsets: HorizontalEdgePadding = .zero {
        didSet {
            updateFrameInsets()
        }
    }
    
    // MARK: - Auto-Layout Management
    
    private var textViewLayoutSet: NSLayoutConstraintSet?
    private var textViewHeightAnchor: NSLayoutConstraint?
    private var topStackViewLayoutSet: NSLayoutConstraintSet?
    private var leftStackViewLayoutSet: NSLayoutConstraintSet?
    private var rightStackViewLayoutSet: NSLayoutConstraintSet?
    private var contentViewLayoutSet: NSLayoutConstraintSet?
    private var replyForwardViewLayoutSet: NSLayoutConstraintSet?
    private var windowAnchor: NSLayoutConstraint?
    private var backgroundViewBottomAnchor: NSLayoutConstraint?
    private var topStackSeparatorLineLayoutSet: NSLayoutConstraintSet?
    private var sendButtonLayoutSet: NSLayoutConstraintSet?
    private var attachButtonLayoutSet: NSLayoutConstraintSet?
    private var recordButtonLayoutSet: NSLayoutConstraintSet?
    
    // MARK: - Initialization
    
    public convenience init() {
        self.init(frame: .zero)
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    final override func didMoveToWindow() {
        super.didMoveToWindow()
        setupConstraints(to: window)
    }
    
    // MARK: - Setup
    
    /// Sets up the default properties
    final func setup() {
        autoresizingMask = [.flexibleHeight]//, .flexibleBottomMargin]
        setupSubviews()
        setupConstraints()
        setupObservers()
        configure()
    }
    
    private var recordButtonMaxTopCoordinate: CGFloat = 100//UIScreen.main.bounds
    private var recordButtonMaxLeftCoordinate: CGFloat = 76//(UIScreen.main.bounds.width - 44) / 2 - 24
    
    public enum RecordButtonState {
        case active
        case pinned
        case cancelled
    }
    
    private var isRecordStart: Bool = false
    private var isRecordingPanelInPreviewMode: Bool = false
    public var recordButtonState: RecordButtonState = .active
    
    private func animateRecordButton(_ event: UIEvent) {
        guard let location = event.allTouches?.first?.location(in: self) else { return }
        let x = min(28.0, location.x - (UIScreen.main.bounds.width - 44))
        let y = location.y < -self.recordButtonMaxTopCoordinate ? -self.recordButtonMaxTopCoordinate : location.y
        if x < -self.recordButtonMaxLeftCoordinate {
            if [.active, .pinned].contains(self.recordButtonState) {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                self.recordButtonState = .cancelled
                self.recordIndicatorView.changeState(.deleted)
                UIView.animate(withDuration: 0.2) {
                    self.recordButton.backlightView.changeStateTo(cancelled: true)
                }
            }
        } else {
            if self.recordButtonState == .cancelled {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                self.recordButtonState = .active
                self.recordIndicatorView.changeState(.unlocked)
                UIView.animate(withDuration: 0.2) {
                    self.recordButton.backlightView.changeStateTo(cancelled: false)
                }
            }
        }
        if location.y < -self.recordButtonMaxTopCoordinate, self.recordButtonState != .cancelled {
            if self.recordButtonState != .pinned {
                self.recordButtonState = .pinned
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }
            self.recordIndicatorView.changeState(.locked)
        }
        UIView.performWithoutAnimation {
            self.recordButton.backlightView.center = CGPoint(x: x, y: y)
            self.recordButton.additionalAccesoryView.frame = CGRect(x: x - 24, y: -142 + y, width: 36, height: 72)
            self.recordButton.backlightView.layoutIfNeeded()
            self.recordButton.additionalAccesoryView.layoutIfNeeded()
        }
        self.delegate?.onRecordButtonDraggetOut(self, to: CGPoint(x: x, y: y))
    }
    
    private func setupRecordButton() {
        self.recordIndicatorView.delegate = self
        
        self.recordButton.additionalAccesoryView.isUserInteractionEnabled = false
        self.recordButton.additionalAccesoryView.addSubview(recordIndicatorView)
        if UIDevice.needBottomOffset {
            self.recordButton.additionalAccesoryView.frame = CGRect(x: 4, y: -122, width: 36, height: 72)
        } else {
            self.recordButton.additionalAccesoryView.frame = CGRect(x: 4, y: -92, width: 36, height: 72)
        }
        
    }
    
    private func configureRecordButton() {
        self.isRecordingPanelInPreviewMode = false
        self.recordButtonInitialPosition = CGPoint(x: 24, y: 16)
        self.recordButton.backlightView.frame = CGRect(square: 80)
        self.recordButton.backlightView.center = self.recordButton.center
        self.recordButton.configureShadow()
        self.recordButton.backlightView.alpha = 0.0
        self.isRecordButtonPressed = true
        self.recordButton.backlightView.updateShadow(to: 1, grow: 80, animated: true) { (result) in
            if !self.isRecordButtonPressed { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            DispatchQueue.main.async {
                self.attachmentButton.isHidden = true
                self.inputTextView.isHidden = true
                self.attachmentButton.layoutIfNeeded()
                self.inputTextView.layoutIfNeeded()
            }
            UIView.performWithoutAnimation {
                if self.recordButton.additionalAccesoryView.isHidden {
                    self.recordButton.additionalAccesoryView.isHidden = false
                }
            }
            DispatchQueue.global(qos: .userInteractive).async {
                self.delegate?.onStartRecording(self)
            }
            self.isRecordStart = true
        }
        UIView.performWithoutAnimation {
            self.recordButton.tintColor = .clear
        }
    }
    
    public func resetRecordButtonAfterPinned() {
        self.isRecordStart = false
        self.inputTextView.isHidden = false
        self.attachmentButton.isHidden = false
        self.recordButton.backlightView.hideShadow(animated: true) { (result) in
            self.recordButton.removeShadow()
            UIView.animate(withDuration: 0.1) {
                self.recordButton.setImage(#imageLiteral(resourceName: "microphone").withRenderingMode(.alwaysTemplate), for: .normal)
                if #available(iOS 13.0, *) {
                    self.recordButton.tintColor = .secondaryLabel
                } else {
                    self.recordButton.tintColor = .gray
                }
            }
        }
    }
    
    public final func resetRecordButton() {
        switch self.recordButtonState {
        case .active, .cancelled:
            self.isRecordButtonPressed = false
            self.recordButton.additionalAccesoryView.isHidden = true
            UIView.animate(withDuration: 0.2, delay: 0, options: [/*.allowUserInteraction,*/ .curveEaseIn]) {
                self.recordButton.backlightView.center = self.recordButtonInitialPosition
                self.recordButton.additionalAccesoryView.frame = CGRect(x: 4, y: -92, width: 36, height: 72)
            } completion: { (result) in
                
            }
            
            self.delegate?.onStopRecording(self, state: self.recordButtonState)
            self.isRecordStart = false
            self.recordButton.backlightView.hideShadow(animated: true) { (result) in
                self.recordButton.removeShadow()
                UIView.animate(withDuration: 0.1) {
                    if #available(iOS 13.0, *) {
                        self.recordButton.tintColor = .secondaryLabel
                    } else {
                        self.recordButton.tintColor = .gray
                    }
                }
                
                self.attachmentButton.isHidden = false
                self.inputTextView.isHidden = false
                
            }
        case .pinned:
            if !self.isRecordStart {
                self.recordButtonState = .cancelled
                self.resetRecordButton()
                return
            }
            if self.isRecordingPanelInPreviewMode {
                return
            }
            if !self.isRecordButtonPressed {
                self.recordButtonState = .cancelled
                self.resetRecordButton()
                return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .curveEaseIn]) {
                self.recordButton.backlightView.changeIcon(sendIcon: .stop)
                self.recordButton.backlightView.center = self.recordButtonInitialPosition
                self.recordButton.additionalAccesoryView.frame = CGRect(x: 4, y: -120, width: 36, height: 72)
            } completion: { (result) in
                self.recordIndicatorView.changeState(.hidden)
            }

            self.isRecordButtonPressed = false
            self.recordButton.bringSubviewToFront(self.recordButton.additionalAccesoryView)
            DispatchQueue.global(qos: .userInteractive).async {
                self.delegate?.onPinRecording(self)
            }
        }
        
    }
    
    private final func changeRecordButtonToSendButton() {
        self.recordButton.backlightView.hideShadow(animated: true) { (result) in
            self.recordButton.removeShadow()
            UIView.animate(withDuration: 0.1) {
                self.recordButton.tintColor = self.sendButton.tintColor
                self.recordButton.setImage(#imageLiteral(resourceName: "send").withRenderingMode(.alwaysTemplate), for: .normal)
            }
        }
    }
    
    @objc
    internal func onRecordButtonBacklightTouchUp(_ sender: AnyObject) {
        if self.isRecordingPanelInPreviewMode {
            DispatchQueue.global(qos: .userInitiated).async {
                self.delegate?.onSendVoiceMessage(self)
            }
            self.isRecordingPanelInPreviewMode = false
        } else {
            self.isRecordingPanelInPreviewMode = true
            DispatchQueue.global(qos: .userInitiated).async {
                self.delegate?.onStopRecording(self, state: self.recordButtonState)
            }
            self.changeRecordButtonToSendButton()
        }
        
    }
    
    private func configure() {
        self.inputTextView.textContainerInset = UIEdgeInsets(top: 6, left: 10, bottom: 7, right: 12)
        self.inputTextView.placeholderLabelInsets = UIEdgeInsets(top: 6, left: 12, bottom: 7, right: 12)
        self.sendButton.onTouchUpInside { (button) in
            self.didSelectSendButton()
        }
        
        self.attachmentButton.onTouchUpInside { (button) in
            self.didSelectAttachmentButton()
        }
        
        self.setupRecordButton()
        
        self.recordButton.backlightView.addTarget(
            self,
            action: #selector(self.onRecordButtonBacklightTouchUp),
            for: .touchUpInside
        )
        
        self.recordButton.onTouchDown { (button) in
            if self.isRecordingPanelInPreviewMode {
                DispatchQueue.global(qos: .userInteractive).async {
                    self.delegate?.onSendVoiceMessage(self)
                }
                self.isRecordingPanelInPreviewMode = false
            } else {
                self.configureRecordButton()
                self.recordIndicatorView.changeState(.unlocked)
                self.recordButton.backlightView.changeIcon(sendIcon: .microphone)
            }
        }
        
        self.recordButton.onTouchUpInside { (button) in
            self.resetRecordButton()
        }
        
        self.recordButton.onTouchUpOutside { (button) in
            self.resetRecordButton()
        }
        
        self.recordButton.onDragInside { (button, event) in
            self.animateRecordButton(event)
        }
        
        self.recordButton.onDragOutside { (button, event) in
            self.animateRecordButton(event)
        }
    }
    
    private func updateFrameInsets() {
        updatePadding()
        updateTopStackViewPadding()
    }
    
    /// Adds the required notification observers
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(XabberInputBar.textViewDidChange),
            name: UITextView.textDidChangeNotification, object: inputTextView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(XabberInputBar.textViewDidBeginEditing),
            name: UITextView.textDidBeginEditingNotification, object: inputTextView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(XabberInputBar.textViewDidEndEditing),
            name: UITextView.textDidEndEditingNotification, object: inputTextView
        )
    }
    
    /// Adds all of the subviews
    private func setupSubviews() {
        addSubview(backgroundView)
        addSubview(separatorLine)
        addSubview(topStackView)
        addSubview(contentView)
        contentView.addSubview(leftStackView)
        contentView.addSubview(inputTextView)
        contentView.addSubview(rightStackView)
        leftStackView.addArrangedSubview(attachmentButton)
        rightStackView.addArrangedSubview(sendButton)
        rightStackView.addArrangedSubview(recordButton)
        sendButton.isHidden = true
        sendButton.isEnabled = false
        bringSubviewToFront(contentView)
        addSubview(progressView)
    }
    
    // swiftlint:disable function_body_length colon
    /// Sets up the initial constraints of each subview
    private func setupConstraints() {
        progressView.addConstraints(
            topStackView.topAnchor,
            left: leftAnchor,
            right: rightAnchor,
            heightConstant: 4)
        
        // The constraints within the MessageInputBar
        separatorLine.addConstraints(topStackView.topAnchor, left: leftAnchor, right: rightAnchor)
        backgroundViewBottomAnchor = backgroundView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        backgroundViewBottomAnchor?.isActive = true
        
        topStackViewLayoutSet = NSLayoutConstraintSet(
            bottom: topStackView.bottomAnchor.constraint(equalTo: contentView.topAnchor, constant: -2),
            left: topStackView.leftAnchor.constraint(equalTo: safeAreaLayoutGuide.leftAnchor, constant: topStackViewPadding.left + frameInsets.left),
            right: topStackView.rightAnchor.constraint(equalTo: safeAreaLayoutGuide.rightAnchor, constant: -(topStackViewPadding.right + frameInsets.right)),
            height: topStackView.heightAnchor.constraint(equalToConstant: topStackViewHeightConstant)
        )
        
        backgroundView.addConstraints(topStackView.topAnchor, left: leftAnchor, right: rightAnchor)
        contentViewLayoutSet = NSLayoutConstraintSet(
            top:    contentView.topAnchor.constraint(equalTo: topStackView.bottomAnchor, constant: padding.top),
            bottom: contentView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -padding.bottom),
            left: contentView.leftAnchor.constraint(equalTo: safeAreaLayoutGuide.leftAnchor, constant: padding.left + frameInsets.left),
            right: contentView.rightAnchor.constraint(equalTo: safeAreaLayoutGuide.rightAnchor, constant: -(padding.right + frameInsets.right))
        )
        
        // Constraints Within the contentView
        textViewLayoutSet = NSLayoutConstraintSet(
            top:    inputTextView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: textViewPadding.top),
            bottom: inputTextView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -textViewPadding.bottom),
            left:   inputTextView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 44),// textViewPadding.left),
            right:  inputTextView.rightAnchor.constraint(equalTo: rightStackView.leftAnchor, constant: -textViewPadding.right),
            height: inputTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        )
        
        maxTextViewHeight = calculateMaxTextViewHeight()
        textViewHeightAnchor = inputTextView.heightAnchor.constraint(equalToConstant: maxTextViewHeight)
        
        leftStackViewLayoutSet = NSLayoutConstraintSet(
            bottom: leftStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            left: leftStackView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 6),
//            width: leftStackView.widthAnchor.constraint(equalToConstant: 44),
            height: leftStackView.heightAnchor.constraint(equalToConstant: 44)
        )
        
        
        rightStackViewLayoutSet = NSLayoutConstraintSet(
            bottom: rightStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            right:  rightStackView.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -6),
//            width:  rightStackView.widthAnchor.constraint(equalToConstant: 44),
            height: rightStackView.heightAnchor.constraint(equalToConstant: 44)
        )
        
        sendButtonLayoutSet = NSLayoutConstraintSet(
            width: sendButton.widthAnchor.constraint(equalToConstant: 36),
            height: sendButton.heightAnchor.constraint(equalToConstant: 36)
        )
        
        attachButtonLayoutSet = NSLayoutConstraintSet(
            width: attachmentButton.widthAnchor.constraint(equalToConstant: 36),
            height: attachmentButton.heightAnchor.constraint(equalToConstant: 36)
        )
        
        recordButtonLayoutSet = NSLayoutConstraintSet(
            width: recordButton.widthAnchor.constraint(equalToConstant: 36),
            height: recordButton.heightAnchor.constraint(equalToConstant: 36)
        )
        
        activateConstraints()
    }
    // swiftlint:enable function_body_length colon
    
    /// Respect iPhone X safeAreaInsets
    /// Adds a constraint to anchor the bottomAnchor of the contentView to the window's safeAreaLayoutGuide.bottomAnchor
    ///
    /// - Parameter window: The window to anchor to
    private func setupConstraints(to window: UIWindow?) {
        if let window = window {
            guard window.safeAreaInsets.bottom > 0 else { return }
            windowAnchor?.isActive = false
            windowAnchor = contentView.bottomAnchor.constraint(lessThanOrEqualToSystemSpacingBelow: window.safeAreaLayoutGuide.bottomAnchor, multiplier: 1)
//                windowAnchor = contentView.bottomAnchor.constraintsystem
            windowAnchor?.constant = -padding.bottom
            windowAnchor?.priority = UILayoutPriority(rawValue: 750)
            windowAnchor?.isActive = true
            backgroundViewBottomAnchor?.isActive = false
            
            bottomAnchor
                .constraint(
                    lessThanOrEqualToSystemSpacingBelow: window.safeAreaLayoutGuide.bottomAnchor,
                    multiplier: 1.0
                )
                .isActive = true
            backgroundViewBottomAnchor = backgroundView.bottomAnchor.constraint(equalTo: window.bottomAnchor)
            backgroundViewBottomAnchor?.isActive = true
        }
    }
    
    // MARK: - Constraint Layout Updates
    
    /// Updates the constraint constants that correspond to the padding UIEdgeInsets
    private func updatePadding() {
        
        topStackViewLayoutSet?.bottom?.constant = -padding.top
        
        contentViewLayoutSet?.top?.constant = padding.top
        contentViewLayoutSet?.left?.constant = padding.left
        contentViewLayoutSet?.right?.constant = -padding.right
        contentViewLayoutSet?.bottom?.constant = -padding.bottom
        windowAnchor?.constant = -padding.bottom
    }
    
    /// Updates the constraint constants that correspond to the textViewPadding UIEdgeInsets
    private func updateTextViewPadding() {
        textViewLayoutSet?.top?.constant = textViewPadding.top
        textViewLayoutSet?.left?.constant = textViewPadding.left
        textViewLayoutSet?.right?.constant = -textViewPadding.right
        textViewLayoutSet?.bottom?.constant = -textViewPadding.bottom
    }
    
    /// Updates the constraint constants that correspond to the topStackViewPadding UIEdgeInsets
    private func updateTopStackViewPadding() {
        topStackViewLayoutSet?.top?.constant = topStackViewPadding.top
        topStackViewLayoutSet?.left?.constant = topStackViewPadding.left + frameInsets.left
        topStackViewLayoutSet?.right?.constant = -(topStackViewPadding.right + frameInsets.right)
    }
    
    /// Invalidates the view’s intrinsic content size
    final override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        cachedIntrinsicContentSize = calculateIntrinsicContentSize()
        if previousIntrinsicContentSize?.height != cachedIntrinsicContentSize.height {
            previousIntrinsicContentSize = cachedIntrinsicContentSize
        }
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
                textViewHeightAnchor?.isActive = true
                inputTextView.isScrollEnabled = true
                isOverMaxTextViewHeight = true
            }
            inputTextViewHeight = maxTextViewHeight
        } else {
            if isOverMaxTextViewHeight {
                textViewHeightAnchor?.isActive = false //|| shouldForceTextViewMaxHeight
                inputTextView.isScrollEnabled = false
                isOverMaxTextViewHeight = false
//                inputTextView.invalidateIntrinsicContentSize()
            }
        }
        
        // Calculate the required height
        let totalPadding = padding.top + padding.bottom + topStackViewPadding.top + textViewPadding.top + textViewPadding.bottom
        let topStackViewHeight: CGFloat = topStackView.arrangedSubviews.isNotEmpty ? 48.0 : 0
        let requiredHeight = inputTextViewHeight + totalPadding + topStackViewHeight
        self.delegate?.heightDidChange(self, to: requiredHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: requiredHeight)
    }
        
    /// Returns the max height the InputTextView can grow to based on the UIScreen
    ///
    /// - Returns: Max Height
    final func calculateMaxTextViewHeight() -> CGFloat {
        if traitCollection.verticalSizeClass == .regular {
            return (UIScreen.main.bounds.height / 3).rounded(.down)
        }
        return (UIScreen.main.bounds.height / 5).rounded(.down)
    }
    
    /// Layout the given InputStackView's
    ///
    /// - Parameter positions: The UIStackView's to layout
    public func layoutStackViews(_ positions: [InputStackView.Position] = [.left, .right, .bottom, .top]) {
        
        guard superview != nil else { return }
        
        for position in positions {
            switch position {
            case .right:
                rightStackView.setNeedsLayout()
                rightStackView.layoutIfNeeded()
            case .top:
                topStackView.setNeedsLayout()
                topStackView.layoutIfNeeded()
            default: break
            }
        }
    }
    
    private final func performLayout(_ animated: Bool, _ animations: @escaping () -> Void) {
        deactivateConstraints()
        UIView.performWithoutAnimation { animations() }
        activateConstraints()
    }
    
    private final func activateConstraints() {
        contentViewLayoutSet?.activate()
        textViewLayoutSet?.activate()
        rightStackViewLayoutSet?.activate()
        leftStackViewLayoutSet?.activate()
        topStackViewLayoutSet?.activate()
        sendButtonLayoutSet?.activate()
        attachButtonLayoutSet?.activate()
        recordButtonLayoutSet?.activate()
        inputTextViewMaxWidth =  UIScreen.main.bounds.width - 88
    }
    
    /// Deactivates the NSLayoutConstraintSet's
    private final func deactivateConstraints() {
        contentViewLayoutSet?.deactivate()
        textViewLayoutSet?.deactivate()
        rightStackViewLayoutSet?.deactivate()
        leftStackViewLayoutSet?.deactivate()
        topStackViewLayoutSet?.deactivate()
        sendButtonLayoutSet?.deactivate()
        attachButtonLayoutSet?.deactivate()
        recordButtonLayoutSet?.deactivate()
    }
    
    final func setStackViewItems(_ items: [UIView], forStack position: InputStackView.Position, animated: Bool, sendButton: Bool = false, forceWidth: CGFloat? = nil, forceHeight: CGFloat? = nil) {
        if position == .top {
            self.topStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            self.topStackViewItems = items
            self.topStackViewItems.forEach { self.topStackView.addArrangedSubview($0) }
            if let forceHeight = forceHeight {
                self.setTopStackViewHeightConstant(to: forceHeight, animated: false)
            }
        }
        invalidateIntrinsicContentSize()
        return
    }

    final func setTopStackViewHeightConstant(to newValue: CGFloat, animated: Bool) {
        performLayout(animated) {
            self.topStackViewHeightConstant = newValue
            self.layoutStackViews([.top])
            guard self.superview != nil else { return }
            self.layoutIfNeeded()
        }
    }
    
    /// Invalidates the intrinsicContentSize
    final override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.verticalSizeClass != previousTraitCollection?.verticalSizeClass || traitCollection.horizontalSizeClass != previousTraitCollection?.horizontalSizeClass {
            if shouldAutoUpdateMaxTextViewHeight {
                maxTextViewHeight = calculateMaxTextViewHeight()
            }
            invalidateIntrinsicContentSize()
        }
    }
    
    @objc
    final func textViewDidChange() {
        let trimmedText = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        inputTextView.placeholderLabel.isHidden = !inputTextView.text.isEmpty
        
        items
            .compactMap { return $0 as? InputBarButtonItem }
            .forEach { $0.textViewDidChangeAction(with: inputTextView) }

        delegate?.textDidChange(self, to: trimmedText)
        
        if requiredInputTextViewHeight != inputTextView.bounds.height {
            invalidateIntrinsicContentSize()
        }
        UIView.performWithoutAnimation {
            if trimmedText.isNotEmpty {
                if !self.sendButton.isEnabled {
                    self.sendButton.isEnabled = true
                    self.sendButton.isHidden = false
                    self.recordButton.isHidden = true
                }
            } else {
                if self.sendButton.isEnabled {
                    self.sendButton.isEnabled = false
                    self.sendButton.isHidden = true
                    self.recordButton.isHidden = false
                }
            }
        }
    }
    
    func changeRecordToSend() {
        UIView.performWithoutAnimation {
            sendButton.isHidden = false
            sendButton.isEnabled = true
            recordButton.isHidden = true
            recordButton.isEnabled = false
        }
    }
    
    func changeSendToRecord() {
        UIView.performWithoutAnimation {
            sendButton.isHidden = true
            sendButton.isEnabled = false
            recordButton.isHidden = false
            recordButton.isEnabled = true
        }
    }
    
    /// Calls each items `keyboardEditingBeginsAction` method
    /// Invalidates the intrinsicContentSize so that the keyboard does not overlap the view
    @objc
    final func textViewDidBeginEditing() {
        items
            .compactMap { return $0 as? InputBarButtonItem }
            .forEach { $0.keyboardEditingBeginsAction() }
//        delegate?.messageInputBar(self, textBeginEdited: inputTextView.text)
    }
    
    /// Calls each items `keyboardEditingEndsAction` method
    @objc
    final func textViewDidEndEditing() {
        items
            .compactMap { return $0 as? InputBarButtonItem }
            .forEach { $0.keyboardEditingEndsAction() }
//        delegate?.messageInputBar(self, textEndEdited: inputTextView.text)
    }
    
    final func didSelectSendButton() {
        delegate?.sendButtonTouchUp(self, with: inputTextView.text)
    }
    
    final func didSelectAttachmentButton() {
        delegate?.attachmentButtonTouchUp(self)
    }
}

extension XabberInputBar: ChatToolsButtonDelegate {
    
    func onStop() {
        self.resetRecordButtonAfterPinned()
        self.delegate?.onStopRecording(self, state: self.recordButtonState)
    }
    
}
