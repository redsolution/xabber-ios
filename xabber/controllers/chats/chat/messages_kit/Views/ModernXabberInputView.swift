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
import AVFoundation

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
    func onAudioMessageStartRecord()
    func onAudioMessageDidCancel()
    func onAudioMessageDidSet()
    func onAudioMessageShouldSend()
    func onAudioMessageDidStop()
    func didReceiveRecordButtonPositionChange(to point: CGPoint)
    func lockIndicatorShouldLock()
    func lockIndicatorShouldUnlock()
    func lockIndicatorShouldStop()
    func onSendButtonTouchUpInsideWhenAudioWasRecorded()
    func recordAndPlayPanelDeleteButtonTouchUp()
    func recordAndPlayPanelPlayButtonTouchUp()
    func didStopPlayingAudio()
    func didSetAudioPositionBar(percentage: Float) -> TimeInterval
}

protocol SendButtonDelegate {
    func onTouchesEnded(at timestamp: TimeInterval)
}

class ModernXabberInputView: UIView {
    static let edgeHorizontalInset: CGFloat = 8
    static let minimumComposerHeight: CGFloat = 44
    static let defaultBarHeight: CGFloat = 55

    private enum LiquidGlassMetrics {
        static let usesNativeGlassEffect = true
        static let composerHorizontalInset: CGFloat = 0
        static let composerVerticalInset: CGFloat = 0
        static let composerCornerRadius: CGFloat = 22
        static let buttonSize: CGFloat = 44
        static let textVerticalInset: CGFloat = 4
        static let verticalReserve: CGFloat = ModernXabberInputView.defaultBarHeight - ModernXabberInputView.minimumComposerHeight
        static let contentTopOffset: CGFloat = 6
        static let previewHorizontalInset: CGFloat = 8
        static let previewCornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1.0 / UIScreen.main.scale
        static let toolbarBorderAlpha: CGFloat = 0.34
    }

    private static func makeGlassEffect(
        interactive: Bool = false,
        tintAlpha: CGFloat = 0.16,
        fallbackStyle: UIBlurEffect.Style = .systemMaterial,
        prefersNativeGlass: Bool = true
    ) -> UIVisualEffect {
        if LiquidGlassMetrics.usesNativeGlassEffect, prefersNativeGlass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = interactive
            return effect
        } else {
            return UIBlurEffect(style: fallbackStyle)
        }
    }

    private static func makeGlassEffectView(
        interactive: Bool = false,
        tintAlpha: CGFloat = 0.16,
        fallbackStyle: UIBlurEffect.Style = .systemMaterial,
        prefersNativeGlass: Bool = true
    ) -> UIVisualEffectView {
        let view = UIVisualEffectView(
            effect: makeGlassEffect(
                interactive: interactive,
                tintAlpha: tintAlpha,
                fallbackStyle: fallbackStyle,
                prefersNativeGlass: prefersNativeGlass
            )
        )
        view.isUserInteractionEnabled = interactive
        view.contentView.isUserInteractionEnabled = interactive
        view.clipsToBounds = true
        return view
    }

    private static func applyGlassLayer(
        to view: UIView,
        cornerRadius: CGFloat,
        borderAlpha: CGFloat = 0.28
    ) {
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = LiquidGlassMetrics.borderWidth
        view.layer.borderColor = UIColor.separator.withAlphaComponent(borderAlpha).cgColor
    }

    private static func applyToolbarGlassLayer(to view: UIVisualEffectView) {
        view.clipsToBounds = true
        let radius = LiquidGlassMetrics.composerCornerRadius
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        if #available(iOS 26.0, *) {
            view.cornerConfiguration = .uniformCorners(radius: .fixed(Double(radius)))
        }
        view.layer.borderWidth = LiquidGlassMetrics.borderWidth
        view.layer.borderColor = UIColor.separator.withAlphaComponent(LiquidGlassMetrics.toolbarBorderAlpha).cgColor
    }

    private static func removeChrome(from button: UIButton) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.layer.borderWidth = 0
        button.layer.borderColor = UIColor.clear.cgColor
    }

    private static func applyGlassShadow(
        to view: UIView,
        opacity: Float = 0.16,
        radius: CGFloat = 18,
        yOffset: CGFloat = 8
    ) {
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = opacity
        view.layer.shadowRadius = radius
        view.layer.shadowOffset = CGSize(width: 0, height: yOffset)
        view.layer.masksToBounds = false
    }

    class MessagesPanel: UIView {
        
        open var delegate: ChatViewMessagesPanelDelegate? = nil

        private let glassShadowView: UIView = {
            let view = UIView()
            view.isUserInteractionEnabled = false
            ModernXabberInputView.applyGlassShadow(to: view, opacity: 0.12, radius: 14, yOffset: 6)
            return view
        }()

        private let glassEffectView: UIVisualEffectView = {
            let view = ModernXabberInputView.makeGlassEffectView(
                interactive: false,
                tintAlpha: 0.14,
                fallbackStyle: .systemThinMaterial,
                prefersNativeGlass: false
            )
            ModernXabberInputView.applyGlassLayer(
                to: view,
                cornerRadius: LiquidGlassMetrics.previewCornerRadius,
                borderAlpha: 0.30
            )
            return view
        }()
        
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
            label.textColor = .tintColor
            label.font = UIFont.systemFont(ofSize: 14)
            
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
            
            button.setImage(imageLiteral("xmark"), for: .normal)
            button.tintColor = .tintColor
            
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
            self.indicatorButton.setImage(imageLiteral("xabber.pencil.cap"),for: .normal)
            self.indicatorButton.tintColor = .tintColor
        }
        
        public func configureForForward() {
            self.indicatorButton.setImage(
                imageLiteral("arrowshape.turn.up.left"),
                for: .normal
            )
            self.indicatorButton.tintColor = .tintColor
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
            self.backgroundColor = .clear
            self.addSubview(glassShadowView)
            self.glassShadowView.addSubview(glassEffectView)
            self.addSubview(indicatorButton)
            self.addSubview(verticalLine)
            self.addSubview(titleLabel)
            self.addSubview(messageLabel)
            self.addSubview(closeButton)
            self.closeButton.addTarget(self, action: #selector(onCloseButtonTouchUpInside), for: .touchUpInside)
            self.indicatorButton.addTarget(self, action: #selector(onIndicatorButtonTouchUpInside), for: .touchUpInside)
        }
        
        public func update() {
            let horizontalInset = LiquidGlassMetrics.previewHorizontalInset
            self.glassShadowView.frame = CGRect(
                x: horizontalInset,
                y: 0,
                width: max(0, bounds.width - horizontalInset * 2),
                height: bounds.height
            )
            self.glassEffectView.frame = self.glassShadowView.bounds
            ModernXabberInputView.applyGlassLayer(
                to: self.glassEffectView,
                cornerRadius: LiquidGlassMetrics.previewCornerRadius,
                borderAlpha: 0.30
            )
            self.glassShadowView.layer.shadowPath = UIBezierPath(
                roundedRect: self.glassShadowView.bounds,
                cornerRadius: LiquidGlassMetrics.previewCornerRadius
            ).cgPath
            self.indicatorButton.frame = CGRect(
                origin: CGPoint(x: horizontalInset, y: 0),
                size: CGSize(width: 44, height: 40)
            )
            self.verticalLine.frame = CGRect(
                origin: CGPoint(x: horizontalInset + 50, y: 8),
                size: CGSize(width: 2, height: max(0, bounds.height - 16))
            )
            self.verticalLine.layer.cornerRadius = 1
            self.titleLabel.frame = CGRect(
                origin: CGPoint(x: horizontalInset + 58, y: 3),
                size: CGSize(width: bounds.width - horizontalInset * 2 - 104, height: 19)
            )
            self.messageLabel.frame = CGRect(
                origin: CGPoint(x: horizontalInset + 58, y: 21),
                size: CGSize(width: bounds.width - horizontalInset * 2 - 104, height: 18)
            )
            self.closeButton.frame = CGRect(
                origin: CGPoint(x: bounds.width - horizontalInset - 40, y: 0),
                size: CGSize(width: 40, height: 40)
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
    
    class SearchPanel: UIView {
        
        enum State {
            case empty
            case withResults
        }
        
        var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular {
            didSet {
                if self.conversationType == .omemo {
                    self.changeChatButton.setTitle("Search non-encrypted messages", for: .normal)
                } else {
                    self.changeChatButton.setTitle("Search encrypted messages", for: .normal)
                }
            }
        }
        
        var state: State = .empty
        
        var shouldShowSeekUpDownButtons: Bool = true
        
        open var onChangeConversationTypeCallback: ((ClientSynchronizationManager.ConversationType) -> Void)? = nil
        open var onSeekUpCallback: (() -> Void)? = nil
        open var onSeekDownCallback: (() -> Void)? = nil
        open var onChangeViewStateCallback: (() -> Void)? = nil
        
        let listButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("list.bullet", dimension: 24), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        let changeChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitle("Search encrypted messages", for: .normal)
            button.tintColor = .tintColor
            button.setTitleColor(.tintColor, for: .normal)
            
            return button
        }()
        
        let activityIndicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            
            view.startAnimating()
            view.isHidden = true
            
            return view
        }()
        
        let counterLabel: UILabel = {
            let label = UILabel()
            
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.textAlignment = .center
            label.textColor = .tintColor
            
            return label
        }()
        
        let seekUpButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("chevron.up", dimension: 24), for: .normal)
            button.tintColor = .tintColor
            button.isHidden = true
            
            return button
        }()
        
        let seekDownButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("chevron.down", dimension: 24), for: .normal)
            button.tintColor = .tintColor
            button.isHidden = true
            
            return button
        }()
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            stack.spacing = 0
            
            return stack
        }()
        
        let spacerView: UIView = {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return view
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setup()
        }
        
        func activateConstraints() {
            NSLayoutConstraint.activate([
                self.listButton.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                self.listButton.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                self.listButton.widthAnchor.constraint(equalToConstant: 36),
                self.listButton.heightAnchor.constraint(equalToConstant: 36),
                self.stack.leadingAnchor.constraint(equalTo: self.listButton.trailingAnchor, constant: 8),
                self.stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
                self.stack.topAnchor.constraint(equalTo: self.topAnchor),
                self.stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                self.seekUpButton.widthAnchor.constraint(equalToConstant: 44),
                self.seekDownButton.widthAnchor.constraint(equalToConstant: 44),
                self.counterLabel.heightAnchor.constraint(equalToConstant: 36),
                self.seekUpButton.heightAnchor.constraint(equalToConstant: 36),
                self.seekDownButton.heightAnchor.constraint(equalToConstant: 36),
                self.activityIndicator.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                self.activityIndicator.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                self.activityIndicator.widthAnchor.constraint(equalToConstant: 36),
                self.activityIndicator.heightAnchor.constraint(equalToConstant: 36)
            ])
        }
        
        open var isInLoadingState: Bool = false {
            didSet {
                self.changeState(to: self.state)
            }
        }
        
        open func changeState(to newState: State) {
            self.state = newState
            self.activityIndicator.frame = CGRect(origin: CGPoint(x: self.frame.midX - 36, y: 0), size: CGSize(square: 36))
            switch newState {
                case .empty:
//                    self.changeChatButton.isHidden  = true
                    self.listButton.isHidden        = true
                    self.counterLabel.isHidden      = true
                    self.seekUpButton.isHidden      = true
                    self.seekDownButton.isHidden    = true
                    self.activityIndicator.isHidden = true
                case .withResults:
//                    self.changeChatButton.isHidden  = true
                    self.listButton.isHidden        = self.isInLoadingState
                    self.counterLabel.isHidden      = self.isInLoadingState ? true : false
                    self.seekUpButton.isHidden      = self.isInLoadingState ? true : !self.shouldShowSeekUpDownButtons
                    self.seekDownButton.isHidden    = self.isInLoadingState ? true : !self.shouldShowSeekUpDownButtons
                    self.activityIndicator.isHidden = !self.isInLoadingState
            }
        }
        
        open func updateResults(current: Int, total: Int) {
            if total == 0 {
                self.counterLabel.text = "0 found"
                return
            }
            if current < 0 {
                self.counterLabel.text = "\(total) found"
                return
            }
            self.counterLabel.text = "\(current + 1) of \(total)"
        }
        
        @objc
        private func onChangeConversationTypeButtonTouchUp(_ sender: UIButton) {
            self.onChangeConversationTypeCallback?(self.conversationType)
        }
        
        @objc
        private func onSeekUpButtonTouchUp(_ sender: UIButton) {
            self.onSeekUpCallback?()
        }
        
        @objc
        private func onSeekDownButtonTouchUp(_ sender: UIButton) {
            self.onSeekDownCallback?()
        }
        
        @objc
        private func onChangeViewStateTouchUp(_ sender: UIButton) {
            self.onChangeViewStateCallback?()
        }
        
        func setup() {
            self.stack.translatesAutoresizingMaskIntoConstraints = false
            self.listButton.translatesAutoresizingMaskIntoConstraints = false
            self.activityIndicator.translatesAutoresizingMaskIntoConstraints = false
            self.counterLabel.translatesAutoresizingMaskIntoConstraints = false
            self.seekUpButton.translatesAutoresizingMaskIntoConstraints = false
            self.seekDownButton.translatesAutoresizingMaskIntoConstraints = false
            self.spacerView.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(self.stack)
            self.addSubview(self.listButton)
            self.addSubview(self.activityIndicator)
            self.stack.addArrangedSubview(self.counterLabel)
            self.stack.addArrangedSubview(self.spacerView)
            self.stack.addArrangedSubview(self.seekUpButton)
            self.stack.addArrangedSubview(self.seekDownButton)
            self.activateConstraints()
            self.changeChatButton.addTarget(self, action: #selector(onChangeConversationTypeButtonTouchUp), for: .touchUpInside)
            self.seekUpButton.addTarget(self, action: #selector(onSeekUpButtonTouchUp), for: .touchUpInside)
            self.seekDownButton.addTarget(self, action: #selector(onSeekDownButtonTouchUp), for: .touchUpInside)
            self.listButton.addTarget(self, action: #selector(onChangeViewStateTouchUp), for: .touchUpInside)
        }
    }

    final class MentionSuggestionsPanel: UIView, UITableViewDataSource, UITableViewDelegate {

        final class SuggestionCell: UITableViewCell {

            static let reuseIdentifier = "MentionSuggestionCell"

            private let avatarView: AvatarView = {
                let view = AvatarView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
                view.backgroundColor = .systemGray5
                return view
            }()

            private let nicknameLabel: UILabel = {
                let label = UILabel()
                label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
                label.textColor = .label
                return label
            }()

            private let secondaryLabel: UILabel = {
                let label = UILabel()
                label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
                label.textColor = .secondaryLabel
                return label
            }()

            private let labelsStack: UIStackView = {
                let stack = UIStackView()
                stack.axis = .vertical
                stack.spacing = 2
                stack.alignment = .fill
                return stack
            }()

            override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
                super.init(style: style, reuseIdentifier: reuseIdentifier)
                selectionStyle = .default
                backgroundColor = .clear
                contentView.backgroundColor = .clear
                labelsStack.addArrangedSubview(nicknameLabel)
                labelsStack.addArrangedSubview(secondaryLabel)
                avatarView.translatesAutoresizingMaskIntoConstraints = false
                labelsStack.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(avatarView)
                contentView.addSubview(labelsStack)
                NSLayoutConstraint.activate([
                    avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
                    avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                    avatarView.widthAnchor.constraint(equalToConstant: 32),
                    avatarView.heightAnchor.constraint(equalToConstant: 32),
                    labelsStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
                    labelsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
                    labelsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                    labelsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
                ])
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func configure(with item: ComposerMentionCandidate) {
                nicknameLabel.text = item.nickname
                secondaryLabel.text = item.secondaryText
                avatarView.initials = item.avatarInitials
            }
        }

        private enum State {
            case empty
            case loading
            case results
        }

        private let blurView: UIVisualEffectView = {
            let effect = UIBlurEffect(style: .systemMaterial)
            let view = UIVisualEffectView(effect: effect)
            view.clipsToBounds = true
            view.layer.cornerRadius = 18
            view.layer.cornerCurve = .continuous
            return view
        }()

        private let tableView: UITableView = {
            let tableView = UITableView(frame: .zero, style: .plain)
            tableView.separatorStyle = .none
            tableView.backgroundColor = .clear
            tableView.showsVerticalScrollIndicator = false
            tableView.keyboardDismissMode = .none
            return tableView
        }()

        private let emptyLabel: UILabel = {
            let label = UILabel()
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            label.text = "No users found"
            label.isHidden = true
            return label
        }()

        private let activityIndicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .medium)
            view.hidesWhenStopped = true
            return view
        }()

        private var state: State = .empty
        private(set) var items: [ComposerMentionCandidate] = []
        private(set) var highlightedIndex: Int = 0
        var onSelect: ((ComposerMentionCandidate) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        private func setup() {
            isHidden = true
            clipsToBounds = false
            backgroundColor = .clear
            layer.shadowColor = UIColor.black.withAlphaComponent(0.22).cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: 0, height: 8)

            addSubview(blurView)
            blurView.contentView.addSubview(tableView)
            blurView.contentView.addSubview(emptyLabel)
            blurView.contentView.addSubview(activityIndicator)

            blurView.translatesAutoresizingMaskIntoConstraints = false
            tableView.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            activityIndicator.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
                blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
                blurView.topAnchor.constraint(equalTo: topAnchor),
                blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
                tableView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
                tableView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
                tableView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 6),
                tableView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -6),
                emptyLabel.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
                activityIndicator.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor)
            ])

            tableView.dataSource = self
            tableView.delegate = self
            tableView.rowHeight = 52
            tableView.register(SuggestionCell.self, forCellReuseIdentifier: SuggestionCell.reuseIdentifier)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 18).cgPath
        }

        func update(items: [ComposerMentionCandidate], isLoading: Bool) {
            self.items = items
            if isLoading {
                state = .loading
            } else if items.isEmpty {
                state = .empty
            } else {
                state = .results
            }
            highlightedIndex = min(highlightedIndex, max(items.count - 1, 0))
            applyState()
        }

        func preferredHeight(maxHeight: CGFloat) -> CGFloat {
            switch state {
            case .loading, .empty:
                return 84
            case .results:
                let contentHeight = CGFloat(items.count) * tableView.rowHeight + 12
                return min(max(contentHeight, 52), maxHeight)
            }
        }

        func moveSelection(offset: Int) {
            guard !items.isEmpty else { return }
            highlightedIndex = max(0, min(items.count - 1, highlightedIndex + offset))
            refreshSelection(animated: true)
        }

        @discardableResult
        func selectHighlightedItem() -> ComposerMentionCandidate? {
            guard !items.isEmpty, highlightedIndex < items.count else { return nil }
            let item = items[highlightedIndex]
            onSelect?(item)
            return item
        }

        private func applyState() {
            switch state {
            case .loading:
                isHidden = false
                tableView.isHidden = true
                emptyLabel.isHidden = true
                activityIndicator.startAnimating()
            case .empty:
                isHidden = false
                tableView.isHidden = true
                emptyLabel.isHidden = false
                activityIndicator.stopAnimating()
            case .results:
                isHidden = false
                tableView.isHidden = false
                emptyLabel.isHidden = true
                activityIndicator.stopAnimating()
                tableView.reloadData()
                refreshSelection(animated: false)
            }
        }

        private func refreshSelection(animated: Bool) {
            guard !items.isEmpty else { return }
            let indexPath = IndexPath(row: highlightedIndex, section: 0)
            tableView.selectRow(at: indexPath, animated: animated, scrollPosition: .none)
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SuggestionCell.reuseIdentifier, for: indexPath) as? SuggestionCell else {
                return UITableViewCell()
            }
            cell.configure(with: items[indexPath.row])
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            highlightedIndex = indexPath.row
            onSelect?(items[indexPath.row])
        }
    }
    
    class SelectionPanel: UIView {
        
        var delegate: MessagesSelectionPanelActionDelegate? = nil
        
        let deleteButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("trash"), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        let shareButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("square.and.arrow.up"), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        
        let replyButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("arrowshape.turn.up.left"), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        let copyButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("doc.on.doc"), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        let forwardButton: UIButton = {
            let button = UIButton()
            
            button.setImage(imageLiteral("arrowshape.turn.up.right"), for: .normal)
            button.tintColor = .tintColor
            
            return button
        }()
        
        let stack:UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .equalSpacing
            
            
            return stack
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
            self.addSubview(self.stack)
            self.stack.addArrangedSubview(self.deleteButton)
            self.stack.addArrangedSubview(self.shareButton)
            self.stack.addArrangedSubview(self.copyButton)
            self.stack.addArrangedSubview(self.replyButton)
            self.stack.addArrangedSubview(self.forwardButton)
            self.deleteButton.addTarget(self, action: #selector(onDeleteButtonPress), for: .touchUpInside)
            self.shareButton.addTarget(self, action: #selector(onShareButtonPress), for: .touchUpInside)
            self.copyButton.addTarget(self, action: #selector(onCopyButtonPress), for: .touchUpInside)
            self.replyButton.addTarget(self, action: #selector(onReplyButtonPress), for: .touchUpInside)
            self.forwardButton.addTarget(self, action: #selector(onForwardButtonPress), for: .touchUpInside)
            var constraints = [self.deleteButton, self.shareButton, self.copyButton, self.replyButton, self.forwardButton].compactMap({ return [
                $0.widthAnchor.constraint(equalToConstant: 44),
                $0.heightAnchor.constraint(equalToConstant: 38)
            ] }).flatMap({ $0 })
//            constraints.append(contentsOf: [
//                stack.heightAnchor.constraint(equalToConstant: 38),
//                stack.leftAnchor.constraint(equalTo: self.leftAnchor),
//                stack.rightAnchor.constraint(equalTo: self.rightAnchor)
//            ])
            NSLayoutConstraint.activate(constraints)
        }
        
        final func update() {
            stack.frame = self.bounds
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
            
        }
        
    }

    class RecordAndPlayPanel: UIView {
        let recordIndicatorSize: CGFloat = 8

        private let glassShadowView: UIView = {
            let view = UIView()
            view.isUserInteractionEnabled = false
            ModernXabberInputView.applyGlassShadow(to: view, opacity: 0.10, radius: 12, yOffset: 5)
            return view
        }()

        private let glassEffectView: UIVisualEffectView = {
            let view = ModernXabberInputView.makeGlassEffectView(
                interactive: false,
                tintAlpha: 0.12,
                fallbackStyle: .systemThinMaterial,
                prefersNativeGlass: false
            )
            ModernXabberInputView.applyGlassLayer(to: view, cornerRadius: 19, borderAlpha: 0.24)
            return view
        }()
        
        let deleteButton: UIButton = {
            let button = UIButton(frame: CGRect(width: 44, height: 38))
            
            button.tintColor = .tintColor
            button.setImage(imageLiteral("trash"), for: .normal)
            button.tintColor = .systemRed
            
            return button
        }()
        
        let playButton: UIButton = {
            let button = UIButton(frame: CGRect(width: 38, height: 38))
            
            button.tintColor = .systemBackground
            button.setImage(imageLiteral("play.fill"), for: .normal)
            
            return button
        }()
        
        let backghroundWaveform: UIView = {
            let view = UIView(frame: .zero)
            
            view.layer.cornerRadius = 19
            
            return view
        }()
        
        let waveform: AudioVisualizationView = {
            let view = AudioVisualizationView()
            
            view.audioVisualizationMode = .read
            view.audioVisualizationType = .both
            view.backgroundColor = .clear
            view.currentGradientPercentage = 0.0
            view.gradientStartColor = UIColor.systemBackground
            view.gradientEndColor = UIColor.systemBackground
            view.barBackgroundFillColor = UIColor.systemBackground.withAlphaComponent(0.34)
            view.meteringLevelBarWidth = 2
            view.meteringLevelBarCornerRadius = 2
            view.meteringLevelBarInterItem = 1.5
            view.progressBarLineHeight = 0.5
            view.progressBarMiddleOffset = 0
            view.audioVisualizationTimeInterval = 0.025
            
            return view
        }()
        
        
        
        let timeLabel: UILabel = {
            let label = UILabel(frame: CGRect(width: 72, height: 20))
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = .systemBackground
            label.text = ""
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        
        internal var delegate: XabberInputBarDelegate? = nil
        
        internal func setup() {
            self.backgroundColor = .clear
            self.addSubview(glassShadowView)
            self.glassShadowView.addSubview(glassEffectView)
            self.addSubview(deleteButton)
            self.addSubview(backghroundWaveform)
            self.backghroundWaveform.addSubview(playButton)
            self.backghroundWaveform.addSubview(waveform)
            self.backghroundWaveform.addSubview(timeLabel)
            self.deleteButton.addTarget(self, action: #selector(self.onDeleteButtonTouchUpInside), for: .touchUpInside)
            self.playButton.addTarget(self, action: #selector(self.onPlayButtonTouchUpInside), for: .touchUpInside)
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(self.onPanGestureAppear))
            self.waveform.addGestureRecognizer(gesture)
            self.waveform.drawCallback = updateTimeLabel
        }
        
        public final func updateTimeLabel() {
            if AudioManager.shared.player != nil {
                if let currentDuration = AudioManager.shared.player?.currentTime {
                    self.timeLabel.text = currentDuration.minuteFormatedString
                } else {
                    self.timeLabel.text = self.duration.minuteFormatedString
                }
            } else {
                self.timeLabel.text = self.duration.minuteFormatedString
            }
        }
        
        @objc
        private func onPanGestureAppear(_ sender: UIPanGestureRecognizer) {
            let point = sender.translation(in: self)
            let fullWidth: CGFloat = self.waveform.frame.width
            let currentPosition: CGFloat = [[point.x, 1.0].max() ?? 1.0, fullWidth].min() ?? 1.0
            let percentage = Float(currentPosition / fullWidth)
            switch sender.state {
                case .changed:
                    self.waveform.pause()
                    self.waveform.currentGradientPercentage = percentage
                case .ended:
                    self.waveform.stop()
                    self.waveform.currentGradientPercentage = percentage
                    guard let newDuration = self.delegate?.didSetAudioPositionBar(percentage: percentage) else {
                        return
                    }
                    self.waveform.startFrom = newDuration
                    self.waveform.play(for: self.duration - newDuration)
                case .cancelled, .failed:
                    guard let currentDuration = AudioManager.shared.player?.currentTime else {
                        return
                    }
                    let percentage: Float = Float(currentDuration / duration)
                    self.waveform.currentGradientPercentage = percentage
                    self.waveform.play(for: self.duration - currentDuration)
                default:
                    break
            }
            self.waveform.setNeedsDisplay()
        }
        
        var palette: MDCPalette = .amber
        
        final func update() {
            self.glassShadowView.frame = self.bounds
            self.glassEffectView.frame = self.glassShadowView.bounds
            ModernXabberInputView.applyGlassLayer(to: self.glassEffectView, cornerRadius: 19, borderAlpha: 0.24)
            self.glassShadowView.layer.shadowPath = UIBezierPath(
                roundedRect: self.glassShadowView.bounds,
                cornerRadius: 19
            ).cgPath
            self.backghroundWaveform.backgroundColor = palette.tint500.withAlphaComponent(0.82)
            self.backghroundWaveform.layer.borderWidth = LiquidGlassMetrics.borderWidth
            self.backghroundWaveform.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
            self.backghroundWaveform.layer.cornerCurve = .continuous
            self.deleteButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 44, height: 38)
            )
            self.deleteButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.10)
            self.deleteButton.layer.cornerRadius = 19
            self.deleteButton.layer.cornerCurve = .continuous
            self.backghroundWaveform.frame = CGRect(
                origin: CGPoint(x: 52, y: 0),
                size: CGSize(width: self.frame.width - 60, height: 38)
            )
            self.playButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 38, height: 38)
            )
            self.waveform.frame = CGRect(
                origin: CGPoint(x: 38, y: 6),
                size: CGSize(width: self.backghroundWaveform.frame.width - 86, height: 26)
            )
            self.timeLabel.frame = CGRect(
                origin: CGPoint(x: self.backghroundWaveform.frame.width - 44, y: 4),
                size: CGSize(width: 44, height: 30)
            )
        }
        
        var startDate: Date? = nil
        var duration: TimeInterval = 0
        
        func configure(pcm: [Float], duration: TimeInterval) {
            if pcm.isEmpty {
                waveform.meteringLevels = (0..<52).compactMap { _ in return 0.1 }
            } else {
                waveform.meteringLevels = pcm.compactMap { return $0 < 0.1 ? 0.1 : $0 }
            }
            self.timeLabel.text = duration.minuteFormatedString
            self.duration = duration
            
        }
        
        @objc
        internal func onDeleteButtonTouchUpInside(_ sender: UIButton) {
            self.delegate?.recordAndPlayPanelDeleteButtonTouchUp()
        }
        
        @objc
        internal func onPlayButtonTouchUpInside(_ sender: UIButton) {
            self.delegate?.recordAndPlayPanelPlayButtonTouchUp()
        }
        
        func play(for duration: TimeInterval) {
            self.duration = duration
            self.startDate = Date()
            self.waveform.play(for: self.duration)
            self.playButton.setImage(imageLiteral("pause.fill"), for: .normal)
            AudioManager.shared.player?.play()
        }
        
        func pause() {
            self.waveform.pause()
            self.playButton.setImage(imageLiteral("play.fill"), for: .normal)
            AudioManager.shared.player?.pause()
        }
        
        func continuePlay() {
            self.waveform.play(for: self.duration)
            self.playButton.setImage(imageLiteral("pause.fill"), for: .normal)
            AudioManager.shared.player?.play()
        }
        
        func resetElements() {
            self.startDate = nil
            self.waveform.meteringLevels = []
            self.duration = 0
            self.timeLabel.text = nil
        }
        
    }
    
    class RecordPanel: UIView {
        let recordIndicatorSize: CGFloat = 8
        
        var palette: MDCPalette = .amber

        private let glassShadowView: UIView = {
            let view = UIView()
            view.isUserInteractionEnabled = false
            ModernXabberInputView.applyGlassShadow(to: view, opacity: 0.10, radius: 12, yOffset: 5)
            return view
        }()

        private let glassEffectView: UIVisualEffectView = {
            let view = ModernXabberInputView.makeGlassEffectView(
                interactive: false,
                tintAlpha: 0.12,
                fallbackStyle: .systemThinMaterial,
                prefersNativeGlass: false
            )
            ModernXabberInputView.applyGlassLayer(to: view, cornerRadius: 19, borderAlpha: 0.24)
            return view
        }()
        
        let recordIndicator: UIView = {
            let view = UIView()
            
            view.backgroundColor = .systemRed
            view.layer.masksToBounds = true
            
            return view
        }()
                
        let slideToCancelButton: UIButton = {
            let view = UIButton()
            
            view.setImage(imageLiteral("chevron.left", dimension: 18, forceStrong: false), for: .normal)
            view.setTitle("Slide to cancel".localizeString(id: "chat_slide_to_cancel_audio_record", arguments: []), for: .normal)
            view.setTitleColor(.secondaryLabel, for: .normal)
            view.tintColor = .secondaryLabel
            view.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .regular)
            view.imageEdgeInsets = UIEdgeInsets(top: 5, bottom: 5, left: 8, right: 16)
            
            return view
        }()
        
        let cancelButton: UIButton = {
            let button = UIButton()
            
            button.setTitle("Cancel", for: .normal)
            button.isHidden = true
            button.setTitleColor(.tintColor, for: .normal)
            
            return button
        }()
        
        let timeLabel: UILabel = {
            let label = UILabel(frame: CGRect(width: 72, height: 20))
            
            label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
            label.textColor = .label
            label.text = ""
            
            return label
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }
        
        internal var slideToCancelButtonCenter: CGPoint = .zero
        
        internal var delegate: XabberInputBarDelegate? = nil
        
        internal func setup() {
            self.backgroundColor = .clear
            self.addSubview(glassShadowView)
            self.glassShadowView.addSubview(glassEffectView)
            self.addSubview(recordIndicator)
            self.addSubview(timeLabel)
            self.addSubview(slideToCancelButton)
            self.addSubview(cancelButton)
            self.cancelButton.addTarget(self, action: #selector(self.onCancelRecordTouchUpInside), for: .touchUpInside)
        }
        
        @objc
        internal func onCancelRecordTouchUpInside(_ sender: UIButton) {
            self.delegate?.onAudioMessageDidCancel()
            self.resetElements()
        }
        
        @objc
        internal func onStopRecordTouchUpInside(_ sender: UIButton) {
            self.delegate?.onAudioMessageDidStop()
        }
        
        final func update() {
            self.glassShadowView.frame = self.bounds
            self.glassEffectView.frame = self.glassShadowView.bounds
            ModernXabberInputView.applyGlassLayer(to: self.glassEffectView, cornerRadius: 19, borderAlpha: 0.24)
            self.glassShadowView.layer.shadowPath = UIBezierPath(
                roundedRect: self.glassShadowView.bounds,
                cornerRadius: 19
            ).cgPath
            self.recordIndicator.frame = CGRect(
                origin: CGPoint(x: 2, y: 15),
                size: CGSize(square: recordIndicatorSize)
            )
            self.recordIndicator.layer.cornerRadius = recordIndicatorSize / 2
            self.timeLabel.textColor = .label
            self.timeLabel.frame = CGRect(
                origin: CGPoint(x: 24, y: 2),
                size: CGSize(width: 74, height: 34)
            )
            let offset: CGFloat = 90
            self.slideToCancelButton.frame = CGRect(
                origin: CGPoint(x: offset, y: 0),
                size: CGSize(width: self.frame.width - 140, height: 38)
            )
            self.cancelButton.frame = CGRect(
                origin: CGPoint(x: self.frame.width / 2 - 32, y: 0),
                size: CGSize(width: 108, height: 38)
            )
//            self.cancelButton.center = self.center
//            self.slideToCancelButtonCenter = self.slideToCancelButton.center
        }
        
        func resetElements() {
            self.update()
            let timeInterval: TimeInterval = 0
            self.timeLabel.text = timeInterval.minuteFormatedString
            self.unlock()
            self.slideToCancelButton.isHidden = false
            self.cancelButton.isHidden = true
            self.lockIndicatorIsStop = false
        }
        
        var startDate: Date? = nil
        var updateTimer: Timer? = nil
        var lockIndicatorIsStop: Bool = false
        
        func changeIndicatorToStop() {
            self.delegate?.lockIndicatorShouldStop()
            
        }
        
        func resetAndStart() {
//            self.recordPanelLock = false
            self.startDate = Date()
            let timeInterval: TimeInterval = 0
            self.timeLabel.text = timeInterval.minuteFormatedString
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { timer in
                if let date = self.startDate {
                    let currentDate = Date()
                    let timeInterval = currentDate.timeIntervalSince1970 - date.timeIntervalSince1970
//                    DispatchQueue.main.async {
                    self.timeLabel.text = timeInterval.minuteFormatedString
//                    }
                }
            })
            RunLoop.main.add(updateTimer!, forMode: .default)
            self.recordIndicator.alpha = 0.3
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                usingSpringWithDamping: 0.6,
                initialSpringVelocity: 0.3,
                options: [.autoreverse, .repeat]) {
                    self.recordIndicator.alpha = 1.0
                } completion: { _ in
                    
                }
        }
        
        func done() {
            self.updateTimer?.invalidate()
            self.updateTimer = nil
            self.recordIndicator.layer.removeAllAnimations()

        }
        
        func slideToCancel(diffX: CGFloat) {
//            if abs(diffX) < 2 { return }
            let offset: CGFloat = 90 + (diffX / 2)
            self.slideToCancelButton.frame = CGRect(
                origin: CGPoint(x: offset, y: 0),
                size: CGSize(width: self.frame.width - 140, height: 38)
            )
//            self.slideToCancelButton.alpha = alpha < 1.0 ? alpha : 1.0
//            self.done()
        }
        
        func slideToLock(point: CGPoint) {
//            let startPoint = CGPoint(
//                x: self.frame.width + 18,
//                y: self.frame.minY - 88
//            )
//            self.lockIndicator.center = startPoint.offset(by: CGSize(width: 0, height: point.y))
        }
        var lockState: Bool = false
        func lock() {
            if !lockState {
                lockState = true
                self.delegate?.lockIndicatorShouldLock()
                FeedbackManager.shared.generate(feedback: .success)
            }
        }
        
        func unlock() {
            if lockState {
                lockState = false
                self.delegate?.lockIndicatorShouldUnlock()
                FeedbackManager.shared.generate(feedback: .success)
            }
            
        }
    }
    
    open var accountPalette: MDCPalette = AccountColorManager.colors.first!.palette {
        didSet {
            self.recordPanel.palette = accountPalette
            self.recordAndPlayPanel.palette = accountPalette
            self.recordPanel.update()
            self.recordAndPlayPanel.update()
        }
    }
    
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
        case search
        case record
        case recordAndPlay
    }

    private struct LiquidGlassLayoutState: Equatable {
        let bounds: CGRect
        let composerFrame: CGRect
        let contentBounds: CGRect
        let textFieldFrame: CGRect
        let attachButtonFrame: CGRect
        let timerButtonFrame: CGRect
        let sendButtonFrame: CGRect
        let state: InputBarState
        let isTextFieldHidden: Bool
        let isAttachHidden: Bool
        let isTimerHidden: Bool
        let isSendHidden: Bool
    }

    private var lastLiquidGlassLayoutState: LiquidGlassLayoutState?
    
    private var textViewHeightAnchor: NSLayoutConstraint?
    private var didActivateComposerConstraints = false
    private var textFieldTrailingToTimerConstraint: NSLayoutConstraint?
    private var textFieldTrailingToSendConstraint: NSLayoutConstraint?

    /// The maximum height that the InputTextView can reach
    final var maxTextViewHeight: CGFloat = 130 {
        didSet {
            textViewHeightAnchor?.constant = maxTextViewHeight
            invalidateIntrinsicContentSize()
        }
    }
    
    /// The height that will fit the current text in the InputTextView based on its current bounds
    
    private var inputTextViewMaxWidth: CGFloat = 326.0

    private var composerTextVerticalPadding: CGFloat {
        LiquidGlassMetrics.textVerticalInset * 2
    }

    private var requiredTextViewFittingHeight: CGFloat {
        let fittingWidth = textField.bounds.width > 0 ? textField.bounds.width : inputTextViewMaxWidth
        let maxTextViewSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        return textField.sizeThatFits(maxTextViewSize).height.rounded(.down)
    }
    
    public var requiredInputTextViewHeight: CGFloat {
        if isSelectionPanelShowed {
            return ModernXabberInputView.minimumComposerHeight
        }
        let textViewHeight = min(self.requiredTextViewFittingHeight, self.maxTextViewHeight)
        return max(ModernXabberInputView.minimumComposerHeight, textViewHeight + self.composerTextVerticalPadding)
    }
    
    private let mainInputShadowView: UIView = {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true
        return view
    }()

    private let mainInputGlassView: UIVisualEffectView = {
        let view = ModernXabberInputView.makeGlassEffectView(
            interactive: true,
            fallbackStyle: .systemMaterial
        )
        ModernXabberInputView.applyToolbarGlassLayer(to: view)
        return view
    }()

    let textField: InputTextView = {
        let field = InputTextView(frame: .zero)
        
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        field.backgroundColor = .clear
        field.layer.cornerRadius = 0
        field.layer.borderWidth = 0
        field.layer.borderColor = UIColor.clear.cgColor
        field.layer.masksToBounds = false
        field.placeholderTextColor = .secondaryLabel
        field.alpha = 1.0
        
        return field
    }()
    
    class SendButton: UIButton {
        let pulseView: UIView = {
            let view = UIView(frame: .zero)
                       
            return view
        }()
        
        var delegate: SendButtonDelegate? = nil
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            print("xabber_input", "SEND BUTTON", #function, touches, event, event?.timestamp)
            self.delegate?.onTouchesEnded(at: Date().timeIntervalSince1970)
        }
        
        let sendIcon: UIImageView = {
            let view = UIImageView(image: imageLiteral("xabber.paperplane.fill"))
            
            view.tintColor = .systemBackground
            
            return view
        }()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
//            self.layer.addSublayer(pulseLayer)
//            self.layer.addSublayer(filledPulseLayer)
//            self.addlayer
//            self.pulseView.layer.addSublayer(self.pulseLayer)
//            self.pulseView.layer.addSublayer(self.filledPulseLayer)
            
            
//            self.filledPulseLayer.position = self.center
//            
//            self.pulseLayer.position = self.center
//            self.pulseLayer.radius = 44
            self.addSubview(pulseView)
            self.sendSubviewToBack(pulseView)
            self.pulseView.frame = CGRect(x: 22, y: 19, width: 0, height: 0)
            self.pulseView.isHidden = true
            self.addSubview(sendIcon)
//            self.sendIcon.center = center
            self.bringSubviewToFront(self.sendIcon)
            self.sendIcon.frame = CGRect(
                origin: .zero,
                size: self.sendIcon.sizeThatFits(CGSize(square: 24))
            )
            self.sendIcon.center = center
            self.sendIcon.isHidden = true
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func showPulse() {
            self.pulseView.isHidden = false
            self.pulseView.layer.masksToBounds = true
            self.sendIcon.isHidden = false
//            self.filledPulseLayer.position = self.pulseView.center
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0.5,
                options: [.curveEaseInOut]) {
                    self.pulseView.frame = CGRect(x: -42, y: -45, width: 128, height: 128)
                    self.pulseView.layer.cornerRadius = 64
                } completion: { _ in
                    
                }
        }
        
        func hidePulse() {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0.5,
                options: [.curveEaseInOut]) {
                    self.pulseView.frame = CGRect(x: 22, y: 19, width: 0, height: 0)
                    self.pulseView.layer.cornerRadius = 64
                } completion: { _ in
                    
                }
            
            self.pulseView.isHidden = true
            self.pulseView.layer.masksToBounds = false
            self.sendIcon.isHidden = true
        }
    }
    
    let sendButton: SendButton = {
        let button = SendButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))
        
        button.setImage(imageLiteral("mic", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
        ModernXabberInputView.removeChrome(from: button)
                        
        return button
    }()
   
    let attachButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))
        
        button.setImage(imageLiteral("paperclip", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
        ModernXabberInputView.removeChrome(from: button)
        
        return button
    }()
    
    let timerButton: UIButton = {
        let button = UIButton(frame: CGRect(square: ModernXabberInputView.LiquidGlassMetrics.buttonSize))
        
        button.setImage(imageLiteral("stopwatch", dimension: 24), for: .normal)
        button.tintColor = .secondaryLabel
        button.isEnabled = true
        ModernXabberInputView.removeChrome(from: button)
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
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        button.isHidden = true
        ModernXabberInputView.removeChrome(from: button)
        
        return button
    }()
    
    internal let selectionPanel: SelectionPanel = {
        let view = SelectionPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    internal let recordPanel: RecordPanel = {
        let view = RecordPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    internal let recordAndPlayPanel: RecordAndPlayPanel = {
        let view = RecordAndPlayPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()
    
    internal let searchPanel: SearchPanel = {
        let view = SearchPanel(frame: .zero)
        
        view.isHidden = true
        
        return view
    }()

    internal let mentionPanel: MentionSuggestionsPanel = {
        let view = MentionSuggestionsPanel(frame: .zero)
        view.isHidden = true
        return view
    }()
    
    let forwardPanel: MessagesPanel = {
        let view = MessagesPanel(frame: .zero)
        
        view.backgroundColor = .clear
        view.isHidden = true
        
        return view
    }()
    
    let editPanel: MessagesPanel = {
        let view = MessagesPanel()
        
        view.backgroundColor = .clear
        view.isHidden = true
        
        return view
    }()
    
    public var delegate: XabberInputBarDelegate? = nil {
        didSet {
            self.recordAndPlayPanel.delegate = self.delegate
            self.recordPanel.delegate = self.delegate
        }
    }

    var mentionConversationType: ClientSynchronizationManager.ConversationType = .regular
    var mentionCandidatesProvider: ((String) -> [ComposerMentionCandidate])? = nil
    var mentionMembersCountProvider: (() -> Int)? = nil
    var mentionUsersReloadHandler: (() -> Void)? = nil
    private var currentMentionQuery: ComposerMentionQueryState? = nil
    private var isMentionUsersReloadInFlight: Bool = false
    private var isApplyingComposerMutation: Bool = false
    
    public var barHeight: CGFloat = ModernXabberInputView.defaultBarHeight
    
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

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard self.superview != nil else {
            self.mentionPanel.removeFromSuperview()
            return
        }
        self.attachMentionPanelIfNeeded()
    }

    private func mentionPanelHitView(for point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !self.mentionPanel.isHidden,
              self.mentionPanel.alpha > 0.01,
              self.mentionPanel.isUserInteractionEnabled else {
            return nil
        }

        let mentionPoint = self.mentionPanel.convert(point, from: self)
        return self.mentionPanel.hitTest(mentionPoint, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || self.mentionPanelHitView(for: point, with: event) != nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.isUserInteractionEnabled, !self.isHidden, self.alpha > 0.01 else {
            return nil
        }

        if let mentionHitView = self.mentionPanelHitView(for: point, with: event) {
            return mentionHitView
        }

        return super.hitTest(point, with: event)
    }

    private func attachMentionPanelIfNeeded() {
        guard let superview = self.superview else { return }
        if self.mentionPanel.superview !== superview {
            self.mentionPanel.removeFromSuperview()
            superview.addSubview(self.mentionPanel)
        }
        superview.bringSubviewToFront(self.mentionPanel)
    }
    
    private func addObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewDidChange),
            name: UITextView.textDidChangeNotification, object: textField
        )
    }

    private func updateComposerControlLayout() {
        let shouldTrailToTimer = !self.timerButton.isHidden
        self.textFieldTrailingToTimerConstraint?.isActive = shouldTrailToTimer
        self.textFieldTrailingToSendConstraint?.isActive = !shouldTrailToTimer
        self.mainInputGlassView.layoutIfNeeded()
        self.contentView.layoutIfNeeded()
        self.startPositionSendButton = self.sendButton.center
    }

    private func currentComposerContentHeight() -> CGFloat {
        max(ModernXabberInputView.minimumComposerHeight, self.cachedIntrinsicContentSize.height)
    }

    private func composerFrame(contentHeight: CGFloat) -> CGRect {
        let rawFrame = CGRect(
            x: 0,
            y: self.topInset + LiquidGlassMetrics.contentTopOffset,
            width: max(0, self.bounds.width),
            height: contentHeight
        ).insetBy(
            dx: LiquidGlassMetrics.composerHorizontalInset,
            dy: LiquidGlassMetrics.composerVerticalInset
        )
        return CGRect(
            x: rawFrame.minX,
            y: rawFrame.minY,
            width: max(0, rawFrame.width),
            height: max(0, rawFrame.height)
        )
    }

    private func updateComposerContentLayout() {
        self.updateComposerControlLayout()
    }

    public func setupFrames(_ frame: CGRect) {
        self.frame = frame
        self.updateComposerContentLayout()
        self.backgroundColor = .clear
        self.layoutLiquidGlassAppearance()
        self.updateBottomPanels(withOffset: 0)
        self.selectionPanel.update()
        self.recordPanel.update()
        self.recordAndPlayPanel.update()
    }
    
    final func setup() {
        self.backgroundColor = .clear
        self.addSubview(self.mainInputShadowView)
        self.mainInputShadowView.addSubview(self.mainInputGlassView)
        self.contentView.backgroundColor = .clear
        self.contentView.isUserInteractionEnabled = true
        [
            self.contentView,
            self.attachButton,
            self.textField,
            self.timerButton,
            self.sendButton
        ].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        self.mainInputGlassView.contentView.addSubview(self.contentView)
        self.contentView.addSubview(self.attachButton)
        self.contentView.addSubview(self.textField)
        self.contentView.addSubview(self.timerButton)
        self.contentView.addSubview(self.sendButton)
        self.contentView.addSubview(self.stateButton)
        
        self.sendButton.delegate = self
        [
            self.attachButton,
            self.timerButton,
            self.sendButton,
            self.stateButton
        ].forEach { ModernXabberInputView.removeChrome(from: $0) }
        self.textField.backgroundColor = .clear
        self.textField.layer.borderWidth = 0
        self.textField.layer.borderColor = UIColor.clear.cgColor
        
        self.addSubview(self.selectionPanel)
        self.addSubview(self.forwardPanel)
        self.addSubview(self.editPanel)
        self.addSubview(self.searchPanel)
        self.addSubview(self.recordAndPlayPanel)
        self.addSubview(self.recordPanel)
        self.bringSubviewToFront(searchPanel)
        
        self.stateButton.fillSuperview()
        self.stateButton.isHidden = true
        self.textField.delegate = self
        self.textField.keyHandler = self
        self.textField.typingAttributes = self.baseComposerAttributes()
        self.addObservers()
        self.attachButton.addTarget(self, action: #selector(self.onAttachButtonTouchUp), for: .touchUpInside)
        self.timerButton.addTarget(self,  action: #selector(self.onTimerButtonTouchUp), for: .touchUpInside)
        self.stateButton.addTarget(self,  action: #selector(self.onStateButtonTouchUp), for: .touchUpInside)
        self.mentionPanel.onSelect = { [weak self] item in
            self?.insertMentionCandidate(item)
        }
        self.forwardPanel.update(title: "title", normal: "message")
        self.editPanel.configureForEdit()
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(panGestureRecognizerSelector))
        gesture.delegate = self
//        gesture.requiresExclusiveTouchType = true
//        gesture.cancelsTouchesInView = true
//        
//        gesture.delaysTouchesBegan = true
//        gesture.
//        self.sendButton.addTarget(self, action: #selector(onSendButtonTouchUpInside), for: .touchUpInside)
        self.sendButton.gestureRecognizers?.forEach {
            self.sendButton.removeGestureRecognizer($0)
        }
        self.sendButton.addGestureRecognizer(gesture)
//        let touchGesture = UITapGestureRecognizer(target: self, action: #selector(onTouchSendButton))
//        touchGesture.delegate = self
//        self.sendButton.addGestureRecognizer(touchGesture)
    }
    
    
    
    public var state: InputBarState = .normal {
        didSet {
            print("change state to \(self.state)")
        }
    }
    
    public var shouldHideTimer: Bool = true {
        didSet {
            self.changeState(to: self.state)
        }
    }
    
    public func changeState(to state: InputBarState) {
        if state != .normal {
            self.hideMentionSuggestions()
        }
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
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .updateSignature:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
                self.stateButton.setTitle("Update signature", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .identityVerification:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
                self.searchPanel.isHidden =     true
//                self.sendButton.isEnabled =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.stateButton.setTitle("Identity verification", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .checkDevices:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     false
                self.searchPanel.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.stateButton.setTitle("Check devices", for: .normal)
                self.stateButton.setTitleColor(.systemBlue, for: .normal)
            case .skeleton:
                self.state = state
//                self.sendButton.isEnabled =     false
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .selection:
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  false
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .search:
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      true
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     false
            case .record:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      false
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     false
                self.recordAndPlayPanel.isHidden = true
                self.searchPanel.isHidden =     true
            case .recordAndPlay:
                self.state = state
                self.attachButton.isHidden =    true
                self.textField.isHidden =       true
                self.timerButton.isHidden =     true
                self.sendButton.isHidden =      false
                self.stateButton.isHidden =     true
                self.selectionPanel.isHidden =  true
                self.recordPanel.isHidden =     true
                self.recordAndPlayPanel.isHidden = false
                self.searchPanel.isHidden =     true
                
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
    var isEditPanelShowed: Bool = false
    
    public final func updateBottomPanels(withOffset offset: CGFloat) {
        selectionPanel.frame = CGRect(
            origin: CGPoint(x: 16, y: offset + 2),
            size: CGSize(width: self.bounds.width - 32, height: 38)
        )
        recordPanel.frame = CGRect(
            origin: CGPoint(x: 8, y: offset + 6),
            size: CGSize(width: self.bounds.width - 60, height: 38)
        )
        recordAndPlayPanel.frame = CGRect(
            origin: CGPoint(x: 8, y: offset + 6),
            size: CGSize(width: self.bounds.width - 60, height: 38)
        )
        searchPanel.frame = CGRect(
            origin: CGPoint(x: 16, y: offset + 6),
            size: CGSize(width: self.bounds.width - 32, height: 38)
        )
        self.layoutMentionPanel()
    }
    
    public func showForwardPanel() {
        if self.isForwardPanelShowed {
            return
        }
        self.isForwardPanelShowed = true
        self.topInset = 44
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.forwardPanel.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: self.bounds.width, height: 40)
            )
            self.updateBottomPanels(withOffset: 40)
            self.forwardPanel.update()
            self.forwardPanel.configureForForward()
            self.forwardPanel.isHidden = false
            self.barHeight = self.cachedIntrinsicContentSize.height + LiquidGlassMetrics.verticalReserve
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
            self.barHeight = self.cachedIntrinsicContentSize.height + LiquidGlassMetrics.verticalReserve
            var inputHeight: CGFloat = self.barHeight + self.keyboardHeight + self.topInset
            if self.keyboardHeight == 0 {
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
            }
            self.updateBottomPanels(withOffset: 0)
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
        }
        
    }
    
    public func showEditPanel() {
        if self.isEditPanelShowed {
            return
        }
        self.isEditPanelShowed = true
        self.topInset = 44
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.editPanel.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: self.bounds.width, height: 40)
            )
            self.updateBottomPanels(withOffset: 40)
            self.editPanel.update()
            self.editPanel.configureForEdit()
            self.editPanel.isHidden = false
            self.barHeight = self.cachedIntrinsicContentSize.height + LiquidGlassMetrics.verticalReserve
            var inputHeight: CGFloat = self.barHeight + self.keyboardHeight + self.topInset
            if self.keyboardHeight == 0 {
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
            }
            
            self.delegate?.onHeightChanged(to: inputHeight, bar: 0)
        }
        
    }
    
    public func hideEditPanel() {
        if !self.isEditPanelShowed {
            return
        }
        self.isEditPanelShowed = false
        self.topInset = 0
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.editPanel.isHidden = true
            self.barHeight = self.cachedIntrinsicContentSize.height + LiquidGlassMetrics.verticalReserve
            var inputHeight: CGFloat = self.barHeight + self.keyboardHeight + self.topInset
            if self.keyboardHeight == 0 {
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
            }
            self.updateBottomPanels(withOffset: 0)
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
            self.updateComposerContentLayout()
            let frame = CGRect(
                origin: CGPoint(x: self.frame.minX, y: screenHeight - inputHeight),
                size: CGSize(width: self.bounds.width, height: inputHeight)
            )
            self.frame = frame
//            NSLayoutConstraint.activate([
//                self.heightAnchor.constraint(equalToConstant: inputHeight)
//            ])
            self.heightConstraint?.constant = inputHeight
            self.layoutMentionPanel()
            additionalAnimations?()
        }
        self.layoutSubviews()
    }

    open var heightConstraint: NSLayoutConstraint? = nil
    
    final func activateConstraints() {
        guard !self.didActivateComposerConstraints else { return }
        self.didActivateComposerConstraints = true

        let textTrailingToTimer = self.textField.trailingAnchor.constraint(equalTo: self.timerButton.leadingAnchor)
        let textTrailingToSend = self.textField.trailingAnchor.constraint(equalTo: self.sendButton.leadingAnchor)
        self.textFieldTrailingToTimerConstraint = textTrailingToTimer
        self.textFieldTrailingToSendConstraint = textTrailingToSend

        NSLayoutConstraint.activate([
            self.contentView.leadingAnchor.constraint(equalTo: self.mainInputGlassView.contentView.leadingAnchor),
            self.contentView.trailingAnchor.constraint(equalTo: self.mainInputGlassView.contentView.trailingAnchor),
            self.contentView.topAnchor.constraint(equalTo: self.mainInputGlassView.contentView.topAnchor),
            self.contentView.bottomAnchor.constraint(equalTo: self.mainInputGlassView.contentView.bottomAnchor),

            self.attachButton.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.attachButton.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor),
            self.attachButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.attachButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.textField.leadingAnchor.constraint(equalTo: self.attachButton.trailingAnchor),
            self.textField.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: LiquidGlassMetrics.textVerticalInset),
            self.textField.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -LiquidGlassMetrics.textVerticalInset),

            self.timerButton.trailingAnchor.constraint(equalTo: self.sendButton.leadingAnchor),
            self.timerButton.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor),
            self.timerButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.timerButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),

            self.sendButton.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.sendButton.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor),
            self.sendButton.widthAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize),
            self.sendButton.heightAnchor.constraint(equalToConstant: LiquidGlassMetrics.buttonSize)
        ])

        self.updateComposerControlLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutLiquidGlassAppearance()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        self.updateLiquidGlassColors()
    }

    private func layoutLiquidGlassAppearance() {
        let contentHeight = self.currentComposerContentHeight()
        let composerFrame = self.composerFrame(contentHeight: contentHeight)
        self.mainInputShadowView.isHidden = self.state == .selection || self.state == .search || self.state == .skeleton
        self.mainInputShadowView.frame = composerFrame
        self.mainInputGlassView.frame = self.mainInputShadowView.bounds
        ModernXabberInputView.applyToolbarGlassLayer(to: self.mainInputGlassView)
        self.updateComposerContentLayout()

        let layoutState = LiquidGlassLayoutState(
            bounds: self.bounds,
            composerFrame: composerFrame,
            contentBounds: self.contentView.bounds,
            textFieldFrame: self.textField.frame,
            attachButtonFrame: self.attachButton.frame,
            timerButtonFrame: self.timerButton.frame,
            sendButtonFrame: self.sendButton.frame,
            state: self.state,
            isTextFieldHidden: self.textField.isHidden,
            isAttachHidden: self.attachButton.isHidden,
            isTimerHidden: self.timerButton.isHidden,
            isSendHidden: self.sendButton.isHidden
        )
        guard layoutState != self.lastLiquidGlassLayoutState else { return }
        self.lastLiquidGlassLayoutState = layoutState

        self.updateLiquidGlassColors()
    }

    private func updateLiquidGlassColors() {
        self.mainInputShadowView.layer.shadowColor = nil
        self.mainInputShadowView.layer.shadowOpacity = 0
        self.mainInputShadowView.layer.shadowRadius = 0
        self.mainInputShadowView.layer.shadowOffset = .zero
        self.mainInputShadowView.layer.shadowPath = nil
        self.mainInputGlassView.layer.borderColor = UIColor.separator.withAlphaComponent(LiquidGlassMetrics.toolbarBorderAlpha).cgColor
        self.textField.backgroundColor = .clear
        self.textField.layer.borderWidth = 0
        self.textField.layer.borderColor = UIColor.clear.cgColor
        [
            self.attachButton,
            self.timerButton,
            self.sendButton,
            self.stateButton
        ].forEach { ModernXabberInputView.removeChrome(from: $0) }
    }
    
    @objc
    final func textViewDidChange(force: Bool = false) {
        if !self.isApplyingComposerMutation {
            self.normalizeTypingAttributesAtCursor()
        }
        let trimmedText = textField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        self.textField.placeholderLabel.isHidden = !self.textField.text.isEmpty
        self.message = trimmedText
        
        let currentContentHeight = self.contentView.bounds.height > 0
            ? self.contentView.bounds.height
            : self.currentComposerContentHeight()
        if force || abs(requiredInputTextViewHeight - currentContentHeight) > 0.5 {
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
            self.updateComposerControlLayout()
        }
        self.delegate?.onTextDidChange(to: trimmedText.isEmpty ? nil : trimmedText)
        self.updateMentionSuggestions()
    }

    func baseComposerAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: self.textField.font ?? UIFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.label
        ]
    }

    func mentionComposerAttributes(for entity: ComposerMentionEntity) -> [NSAttributedString.Key: Any] {
        var attributes = self.baseComposerAttributes()
        attributes[.font] = UIFont.systemFont(ofSize: 14, weight: .semibold)
        attributes[.foregroundColor] = self.accountPalette.tint700
        attributes[.backgroundColor] = self.accountPalette.tint100.withAlphaComponent(0.75)
        attributes[.composerMention] = entity
        attributes[.link] = entity.uri
        return attributes
    }

    func currentPayload() -> ComposerMessagePayload {
        ComposerMentionSerializer.payload(
            from: self.textField.attributedText ?? NSAttributedString(string: "", attributes: self.baseComposerAttributes())
        )
    }

    func setComposerText(_ text: String?) {
        let value = text ?? ""
        let attributed = NSAttributedString(string: value, attributes: self.baseComposerAttributes())
        self.applyComposerAttributedText(attributed, selectedRange: NSRange(location: attributed.length, length: 0))
    }

    func setComposerBody(_ body: String, references: [MessageReferenceStorageItem]) {
        let attributed = ComposerMentionSerializer.attributedText(
            body: body,
            references: references,
            baseAttributes: self.baseComposerAttributes(),
            mentionAttributesProvider: { [weak self] entity in
                self?.mentionComposerAttributes(for: entity) ?? [.composerMention: entity]
            }
        )
        self.applyComposerAttributedText(attributed, selectedRange: NSRange(location: attributed.length, length: 0))
    }

    func clearComposer() {
        self.hideMentionSuggestions()
        self.setComposerText(nil)
    }

    func refreshMentionSuggestions() {
        guard self.currentMentionQuery != nil else { return }
        self.isMentionUsersReloadInFlight = false
        self.updateMentionSuggestions()
    }

    private func applyComposerAttributedText(_ attributedText: NSAttributedString, selectedRange: NSRange? = nil) {
        self.isApplyingComposerMutation = true
        self.textField.attributedText = attributedText
        self.textField.typingAttributes = self.baseComposerAttributes()
        if let selectedRange {
            self.textField.selectedRange = selectedRange
        }
        self.isApplyingComposerMutation = false
        self.textField.placeholderLabel.isHidden = !self.textField.text.isEmpty
    }

    private func normalizeTypingAttributesAtCursor() {
        self.textField.typingAttributes = self.baseComposerAttributes()
    }

    private func layoutMentionPanel() {
        guard !self.mentionPanel.isHidden else { return }
        self.attachMentionPanelIfNeeded()
        guard let superview = self.superview else { return }
        let maxHeight = min(260, UIScreen.main.bounds.height * 0.34)
        let height = self.mentionPanel.preferredHeight(maxHeight: maxHeight)
        let width = max(220, self.bounds.width - 84)
        let localFrame = CGRect(
            x: 40,
            y: -(height + 8),
            width: width,
            height: height
        )
        self.mentionPanel.frame = self.convert(localFrame, to: superview)
    }

    private func hideMentionSuggestions() {
        self.currentMentionQuery = nil
        self.isMentionUsersReloadInFlight = false
        self.mentionPanel.isHidden = true
    }

    private func updateMentionSuggestions() {
        guard self.state == .normal,
              self.mentionConversationType == .group,
              self.textField.markedTextRange == nil,
              let attributedText = self.textField.attributedText else {
            self.hideMentionSuggestions()
            return
        }

        guard let query = ComposerMentionQueryDetector.activeQuery(
            in: attributedText,
            selectedRange: self.textField.selectedRange
        ) else {
            self.hideMentionSuggestions()
            return
        }

        self.currentMentionQuery = query
        let candidates = self.mentionCandidatesProvider?(query.query) ?? []
        let membersCount = self.mentionMembersCountProvider?() ?? candidates.count
        let shouldReload = membersCount == 0 && !self.isMentionUsersReloadInFlight
        if shouldReload {
            self.isMentionUsersReloadInFlight = true
            self.mentionUsersReloadHandler?()
        }

        self.mentionPanel.update(items: candidates, isLoading: shouldReload)
        self.layoutMentionPanel()
    }

    private func resolvedMentionQuery(in attributedText: NSAttributedString) -> ComposerMentionQueryState? {
        if let currentMentionQuery {
            return currentMentionQuery
        }

        return ComposerMentionQueryDetector.activeQuery(
            in: attributedText,
            selectedRange: self.textField.selectedRange
        )
    }

    private func insertMentionCandidate(_ candidate: ComposerMentionCandidate) {
        guard let attributedText = self.textField.attributedText,
              let mentionQuery = self.resolvedMentionQuery(in: attributedText) else {
            return
        }
        let entity = candidate.mentionEntity
        let result = ComposerMentionEditor.insertMention(
            in: attributedText,
            replacementRange: mentionQuery.replacementRange,
            entity: entity,
            baseAttributes: self.baseComposerAttributes(),
            mentionAttributes: self.mentionComposerAttributes(for: entity)
        )
        self.applyComposerAttributedText(result.attributedText, selectedRange: result.selectedRange)
        self.hideMentionSuggestions()
        self.textField.becomeFirstResponder()
    }
    
    enum SendButtonState {
        case record
        case send
    }
    
    public var isSendButtonEnabled: Bool = false
    
    public var startRecordTimer: Timer? = nil
    
    
    final func changeSendButtonState(to state: SendButtonState) {
        self.sendButtonState = state
        switch state {
            case .record:
//                self.sendButton.setImage(imageLiteral( "microphone").withRenderingMode(.alwaysTemplate), for: .normal)
                self.sendButton.setImage(imageLiteral("mic.fill", dimension: 24), for: .normal)
                self.sendButton.tintColor = .secondaryLabel
                self.attachButton.isEnabled = self.isSendButtonEnabled
                self.sendButton.isEnabled = self.isSendButtonEnabled
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
        
        let contentHeight = max(ModernXabberInputView.minimumComposerHeight, self.cachedIntrinsicContentSize.height)
        self.barHeight = contentHeight + LiquidGlassMetrics.verticalReserve
        var inputHeight: CGFloat = self.barHeight + keyboardHeight + self.topInset
        if keyboardHeight == 0 {
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
        }
        
        //UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseIn]) {
        UIView.performWithoutAnimation {
            self.updateComposerContentLayout()
            self.layoutMentionPanel()
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
        if self.isSelectionPanelShowed {
            return CGSize(width: UIView.noIntrinsicMetric, height: ModernXabberInputView.minimumComposerHeight)
        }

        var inputTextViewHeight = self.requiredTextViewFittingHeight
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
        
        let requiredHeight = max(
            ModernXabberInputView.minimumComposerHeight,
            inputTextViewHeight + self.composerTextVerticalPadding
        )
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
                self.hideMentionSuggestions()
                self.delegate?.sendButtonTouchUp(with: textField.text)
//                self.message = ""
//                self.textField.text = ""
            case .record:
                break
//                if self.state != .record {
//                    self.delegate?.onAudioMessageStartRecord()
//                    FeedbackManager.shared.generate(feedback: .success)
//                }
        }
    }
    
    private func returnSendButtonToInitialPosition() {
        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.6,
            options: [.curveEaseOut]
        ) {
            self.sendButton.center = self.startPositionSendButton
        } completion: { _ in
            
        }
    }
    
    func cancelRecord() {
        self.startRecordTimer?.invalidate()
        self.startRecordTimer = nil
        self.recordStartDate = nil
        self.sendButton.gestureRecognizers?.forEach {
            recognizer in
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        self.recordPanel.resetElements()
        self.recordAndPlayPanel.resetElements()
        self.changeState(to: .normal)
        self.textViewDidChange(force: true)
        self.sendButton.hidePulse()
        self.returnSendButtonToInitialPosition()
        self.recordPanelLock = false
        self.recordPanel.done()
    }
    
    @objc
    private func panGestureRecognizerSelector(_ sender: UIPanGestureRecognizer) {
        
        print("xabber_input", "drag")
//        return
//        print()

        
        switch sender.state {
            case .began:
                break
            case .changed:
                if self.isDragPositionGone(sender.translation(in: self)) {
                    self.cancelRecord()
                } else {
                    let point = sender.translation(in: self)
                    
                    self.sendButton.center = self.startPositionSendButton.padding(x: point.x, y: point.y)
                }
            case .ended:
//                self.sendButton.hidePulse()
                if self.recordPanelLock {
                    self.sendButton.setImage(imageLiteral("xabber.paperplane.fill", dimension: 24), for: .normal)
                    self.sendButton.tintColor = self.accountPalette.tint600
                    self.recordPanel.slideToCancelButton.isHidden = true
                    self.recordPanel.cancelButton.isHidden = false
                    self.recordPanel.changeIndicatorToStop()
                    self.startRecordTimer?.fire()
                    
                } else {
                    self.cancelRecord()
                    self.delegate?.onAudioMessageShouldSend()
                    self.recordPanelLock = false
                }
                self.returnSendButtonToInitialPosition()
            case .cancelled:
                self.cancelRecord()
                self.returnSendButtonToInitialPosition()
                self.delegate?.onAudioMessageDidCancel()
            case .failed:
                self.cancelRecord()
                self.returnSendButtonToInitialPosition()
                self.delegate?.onAudioMessageDidCancel()
            default:
                self.returnSendButtonToInitialPosition()
                self.delegate?.onAudioMessageDidCancel()
        }
    }
    
    func resetStateAfterRecord() {
        self.changeState(to: self.state)
        self.recordPanel.resetElements()
        self.returnSendButtonToInitialPosition()
        self.textViewDidChange(force: true)
        self.recordPanelLock = false
        
        self.recordPanel.done()
        self.cancelRecord()
        self.sendButton.hidePulse()
    }
    
//    @objc
//    func onSendButtonTouchUpInside(_ sender: AnyObject) {
//        print("xabber_input", #function)
//        if self.recordPanelLock {
//            self.cancelRecord()
//            self.returnSendButtonToInitialPosition()
//            self.delegate?.onAudioMessageShouldSend()
//        } else {
//            self.cancelRecord()
//            self.returnSendButtonToInitialPosition()
//            self.delegate?.onAudioMessageShouldSend()
//        }
//    }
    
    var startPositionSendButton: CGPoint!
    var recordPanelLock = false
    
    
    func isDragPositionGone(_ position: CGPoint) -> Bool {
        self.recordPanel.slideToCancel(diffX: position.x)
        self.recordPanel.slideToLock(point: position)
        self.delegate?.didReceiveRecordButtonPositionChange(to: position)
        if position.x < -120 {
            self.delegate?.onAudioMessageDidCancel()
            return true
        }
        if position.y < -108 {
            self.recordPanel.lock()
            self.recordPanelLock = true
        } else if position.y > -108 {
            self.recordPanel.unlock()
            self.recordPanelLock = false
        }
        return false
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
    
    var recordStartDate: TimeInterval? = nil
}

extension ModernXabberInputView: UITextViewDelegate, InputTextViewKeyHandler {
    func textViewDidChangeSelection(_ textView: UITextView) {
        if !self.isApplyingComposerMutation {
            self.normalizeTypingAttributesAtCursor()
        }
        self.updateMentionSuggestions()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        self.hideMentionSuggestions()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n", !self.mentionPanel.isHidden {
            if self.mentionPanel.selectHighlightedItem() != nil {
                return false
            }
        }

        guard let attributedText = textView.attributedText else {
            return true
        }

        if let mutation = ComposerMentionEditor.mutationForEditing(
            attributedText: attributedText,
            range: range,
            replacementText: text,
            baseAttributes: self.baseComposerAttributes()
        ) {
            self.applyComposerAttributedText(mutation.attributedText, selectedRange: mutation.selectedRange)
            return false
        }

        return true
    }

    func inputTextView(_ textView: InputTextView, shouldHandle key: UIKey) -> Bool {
        guard !self.mentionPanel.isHidden else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            self.mentionPanel.moveSelection(offset: -1)
            return true
        case .keyboardDownArrow:
            self.mentionPanel.moveSelection(offset: 1)
            return true
        case .keyboardEscape:
            self.hideMentionSuggestions()
            return true
        default:
            return false
        }
    }
}

extension ModernXabberInputView: UIGestureRecognizerDelegate {
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        print("xabber_input", #function, 1)
        
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        print("xabber_input", #function, otherGestureRecognizer.debugDescription)

        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        print("xabber_input", #function, otherGestureRecognizer.debugDescription)
        return false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        print("xabber_input", #function, 2)
        
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        print("xabber_input", #function, "touch", 3)
        print("xabber_input", "timestamp", touch.timestamp)
        print("xabber_input", "timestamp", touch.estimatedProperties)
        if touch.phase == .began {
            switch sendButtonState {
                case .record:
                    FeedbackManager.shared.generate(feedback: .success)
                    if self.state == .recordAndPlay {
                        self.delegate?.onSendButtonTouchUpInsideWhenAudioWasRecorded()
                        
                    } else if self.recordPanelLock {
                        self.cancelRecord()
                        self.returnSendButtonToInitialPosition()
                        self.delegate?.onAudioMessageShouldSend()
                    } else {
                        if self.state != .record {
                            self.startRecordTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false, block: { _ in
                                self.changeState(to: .record)
                                self.sendButton.pulseView.backgroundColor = self.accountPalette.tint500
                                self.sendButton.showPulse()
                                DispatchQueue.main.async {
                                    self.delegate?.onAudioMessageStartRecord()
                                }
                                self.startRecordTimer?.invalidate()
                                self.startRecordTimer = nil
                            })
                            RunLoop.current.add(self.startRecordTimer!, forMode: .default)
                            self.recordStartDate = Date().timeIntervalSince1970
                        } else {
                            self.cancelRecord()
                            self.returnSendButtonToInitialPosition()
                            self.delegate?.onAudioMessageDidCancel()
                        }
                    }
                case .send:
                    self.hideMentionSuggestions()
                    self.delegate?.sendButtonTouchUp(with: textField.text)
            }
        }
        
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        print("xabber_input", #function, "press", 4)
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        print("xabber_input", #function, "event", event.type)
//        if !gestureRecognizer.delaysTouchesBegan {
//            return true
//        }
//        if event.type == .touches {
//            
//            
//        }
        return true
    }
}

extension ModernXabberInputView: MulticastAVAudioPlayerDelegate {
    func staticMulticastId() -> String {
        return "xabber_input_view_smid"
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        
    }
    
    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        
    }
    
    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("finish")
        self.recordAndPlayPanel.waveform.stop()
        self.recordAndPlayPanel.playButton.setImage(imageLiteral("play.fill"), for: .normal)
        self.delegate?.didStopPlayingAudio()
        
    }
}

extension ModernXabberInputView: SendButtonDelegate {
    func onTouchesEnded(at timestamp: TimeInterval) {
        guard let start = self.recordStartDate else {
            return
        }
        if timestamp - start < 0.7 {
            self.cancelRecord()
            self.returnSendButtonToInitialPosition()
            self.delegate?.onAudioMessageDidCancel()
        } else {
            self.cancelRecord()
            self.delegate?.onAudioMessageShouldSend()
            self.recordPanelLock = false
        }
    }
}

extension NSAttributedString.Key {
    static let composerMention = NSAttributedString.Key("xabber.composer.mention")
}

final class ComposerMentionEntity: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool = true

    let memberId: String
    let nickname: String
    let uri: String
    let node: String?
    let jid: String?

    init(memberId: String, nickname: String, uri: String, node: String?, jid: String?) {
        self.memberId = memberId
        self.nickname = nickname
        self.uri = uri
        self.node = node
        self.jid = jid
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let memberId = coder.decodeObject(of: NSString.self, forKey: "memberId") as String?,
              let nickname = coder.decodeObject(of: NSString.self, forKey: "nickname") as String?,
              let uri = coder.decodeObject(of: NSString.self, forKey: "uri") as String? else {
            return nil
        }
        self.memberId = memberId
        self.nickname = nickname
        self.uri = uri
        self.node = coder.decodeObject(of: NSString.self, forKey: "node") as String?
        self.jid = coder.decodeObject(of: NSString.self, forKey: "jid") as String?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(self.memberId, forKey: "memberId")
        coder.encode(self.nickname, forKey: "nickname")
        coder.encode(self.uri, forKey: "uri")
        coder.encode(self.node, forKey: "node")
        coder.encode(self.jid, forKey: "jid")
    }
}

struct ComposerMentionCandidate: Equatable {
    let memberId: String
    let nickname: String
    let uri: String
    let node: String?
    let jid: String?
    let secondaryText: String

    var avatarInitials: String {
        let source = nickname.isEmpty ? (jid ?? memberId) : nickname
        let tokens = source
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .prefix(2)
            .compactMap { $0.first }
        let value = String(tokens)
        return value.isEmpty ? "@" : value.uppercased()
    }

    var mentionEntity: ComposerMentionEntity {
        ComposerMentionEntity(
            memberId: memberId,
            nickname: nickname,
            uri: uri,
            node: node,
            jid: jid
        )
    }
}

struct ComposerMessagePayload {
    let body: String
    let references: [MessageReferenceStorageItem]
}

struct ComposerMentionQueryState: Equatable {
    let triggerRange: NSRange
    let replacementRange: NSRange
    let query: String
}

struct ComposerTextMutation {
    let attributedText: NSAttributedString
    let selectedRange: NSRange
}

enum ComposerMentionQueryDetector {
    static func activeQuery(in attributedText: NSAttributedString, selectedRange: NSRange) -> ComposerMentionQueryState? {
        guard selectedRange.length == 0 else { return nil }
        let text = attributedText.string as NSString
        guard selectedRange.location <= text.length else { return nil }
        let location = selectedRange.location
        let mentionRanges = ComposerMentionEditor.mentionRanges(in: attributedText)
        if mentionRanges.contains(where: { NSLocationInRange(location, $0) && location > $0.location && location < $0.upperBound }) {
            return nil
        }

        var scanLocation = location
        while scanLocation > 0 {
            let previousIndex = scanLocation - 1
            let character = text.character(at: previousIndex)
            if character == 64 { // "@"
                let needsBoundaryCheck = previousIndex > 0
                if needsBoundaryCheck {
                    let boundaryCharacter = text.character(at: previousIndex - 1)
                    if !Self.isBoundaryCharacter(boundaryCharacter) {
                        return nil
                    }
                }
                let triggerRange = NSRange(location: previousIndex, length: 1)
                let replacementRange = NSRange(location: previousIndex, length: location - previousIndex)
                if mentionRanges.contains(where: { NSIntersectionRange($0, replacementRange).length > 0 }) {
                    return nil
                }
                let query = text.substring(with: NSRange(location: previousIndex + 1, length: location - previousIndex - 1))
                if query.contains(where: { $0.isWhitespace || $0.isNewline }) {
                    return nil
                }
                return ComposerMentionQueryState(triggerRange: triggerRange, replacementRange: replacementRange, query: query)
            }
            if Self.isTerminatingCharacter(character) {
                return nil
            }
            scanLocation -= 1
        }
        return nil
    }

    private static func isBoundaryCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }

    private static func isTerminatingCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else {
            return true
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

enum ComposerMentionEditor {
    static func mentionRanges(in attributedText: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attributedText.enumerateAttribute(.composerMention, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
            guard value is ComposerMentionEntity else { return }
            ranges.append(range)
        }
        return ranges
    }

    static func mutationForEditing(
        attributedText: NSAttributedString,
        range: NSRange,
        replacementText: String,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> ComposerTextMutation? {
        let mentionRanges = mentionRanges(in: attributedText)
        guard !mentionRanges.isEmpty else { return nil }

        let affectedRanges: [NSRange]
        if range.length > 0 {
            affectedRanges = mentionRanges.filter { NSIntersectionRange($0, range).length > 0 }
        } else {
            let isDeletingBackward = replacementText.isEmpty && range.location > 0
            let isDeletingForward = replacementText.isEmpty && range.location < attributedText.length
            let backwardProbe = NSRange(location: max(0, range.location - 1), length: isDeletingBackward ? 1 : 0)
            let forwardProbe = NSRange(location: range.location, length: isDeletingForward ? 1 : 0)

            affectedRanges = mentionRanges.filter {
                (range.location > $0.location && range.location < $0.upperBound)
                || (backwardProbe.length > 0 && NSIntersectionRange($0, backwardProbe).length > 0)
                || (forwardProbe.length > 0 && NSIntersectionRange($0, forwardProbe).length > 0)
            }
        }

        guard !affectedRanges.isEmpty else { return nil }

        let replacementRange = affectedRanges.dropFirst().reduce(affectedRanges[0]) { partial, next in
            NSUnionRange(partial, next)
        }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let replacement = NSAttributedString(string: replacementText, attributes: baseAttributes)
        mutable.replaceCharacters(in: replacementRange, with: replacement)
        let location = replacementRange.location + replacement.length
        return ComposerTextMutation(
            attributedText: mutable,
            selectedRange: NSRange(location: location, length: 0)
        )
    }

    static func insertMention(
        in attributedText: NSAttributedString,
        replacementRange: NSRange,
        entity: ComposerMentionEntity,
        baseAttributes: [NSAttributedString.Key: Any],
        mentionAttributes: [NSAttributedString.Key: Any]
    ) -> ComposerTextMutation {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let mentionText = entity.normalizedNickname
        let mention = NSMutableAttributedString(string: mentionText, attributes: mentionAttributes)
        mention.addAttributes(mentionAttributes, range: NSRange(location: 0, length: mention.length))
        mention.append(NSAttributedString(string: " ", attributes: baseAttributes))
        mutable.replaceCharacters(in: replacementRange, with: mention)
        let location = replacementRange.location + mention.length
        return ComposerTextMutation(
            attributedText: mutable,
            selectedRange: NSRange(location: location, length: 0)
        )
    }
}

enum ComposerMentionRangeCodec {
    static func escapedRange(for rawRange: NSRange, in body: String) -> NSRange? {
        let nsBody = body as NSString
        guard rawRange.location >= 0, rawRange.upperBound <= nsBody.length else { return nil }
        let prefix = nsBody.substring(to: rawRange.location)
        let segment = nsBody.substring(with: rawRange)
        let location = prefix.xmlEscaping(reverse: false).count
        let length = segment.xmlEscaping(reverse: false).count
        return NSRange(location: location, length: length)
    }

    static func rawRange(for escapedRange: NSRange, in body: String) -> NSRange? {
        let nsBody = body as NSString
        let bodyLength = nsBody.length
        guard escapedRange.location >= 0,
              escapedRange.length >= 0 else {
            return nil
        }

        var rawStart: Int?
        var rawEnd: Int?

        for rawIndex in 0...bodyLength {
            let escapedLength = nsBody.substring(to: rawIndex).xmlEscaping(reverse: false).count
            if rawStart == nil && escapedLength == escapedRange.location {
                rawStart = rawIndex
            }
            if rawStart != nil && escapedLength == escapedRange.upperBound {
                rawEnd = rawIndex
                break
            }
        }

        guard let rawStart,
              let rawEnd,
              rawStart < rawEnd else {
            return nil
        }

        return NSRange(location: rawStart, length: rawEnd - rawStart)
    }
}

enum ComposerMentionSerializer {
    static func payload(from attributedText: NSAttributedString) -> ComposerMessagePayload {
        let body = attributedText.string
        let references = self.references(from: attributedText, body: body)
        return ComposerMessagePayload(body: body, references: references)
    }

    static func attributedText(
        body: String,
        references: [MessageReferenceStorageItem],
        baseAttributes: [NSAttributedString.Key: Any],
        mentionAttributesProvider: (ComposerMentionEntity) -> [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: body, attributes: baseAttributes)
        for reference in references where reference.kind == .mention {
            guard let rawRange = ComposerMentionRangeCodec.rawRange(for: reference.range, in: body),
                  let entity = mentionEntity(from: reference) else {
                continue
            }
            output.addAttributes(mentionAttributesProvider(entity), range: rawRange)
        }
        return output
    }

    private static func references(from attributedText: NSAttributedString, body: String) -> [MessageReferenceStorageItem] {
        var output: [MessageReferenceStorageItem] = []
        for run in mentionRuns(in: attributedText) {
            guard let escapedRange = ComposerMentionRangeCodec.escapedRange(for: run.range, in: body) else {
                continue
            }
            let reference = MessageReferenceStorageItem()
            reference.kind = .mention
            reference.begin = escapedRange.location
            reference.end = escapedRange.location + escapedRange.length
            reference.metadata = [
                "uri": run.entity.uri,
                "node": run.entity.node as Any,
                "memberId": run.entity.memberId,
                "nickname": run.entity.normalizedNickname,
                "jid": run.entity.jid as Any
            ].compactMapValues { $0 }
            reference.url = run.entity.uri
            output.append(reference)
        }
        return output.sorted(by: { $0.begin < $1.begin })
    }

    static func mentionEntity(from reference: MessageReferenceStorageItem) -> ComposerMentionEntity? {
        guard let uri = reference.metadata?["uri"] as? String ?? reference.url else {
            return nil
        }
        let nickname = reference.metadata?["nickname"] as? String ?? ""
        let memberId = reference.metadata?["memberId"] as? String ?? Self.memberId(from: uri) ?? ""
        let jid = reference.metadata?["jid"] as? String
        let node = reference.metadata?["node"] as? String
        return ComposerMentionEntity(
            memberId: memberId,
            nickname: Self.normalizedNickname(
                from: nickname.isEmpty ? reference.bodyFragment(in: reference.messageBody) : nickname
            ),
            uri: uri,
            node: node,
            jid: jid
        )
    }

    private static func memberId(from uri: String) -> String? {
        guard let query = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        let normalizedQuery = query.replacingOccurrences(of: ";", with: "&")
        return normalizedQuery
            .split(separator: "&")
            .compactMap { component -> String? in
                let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "id" else { return nil }
                return parts[1]
            }
            .first
    }

    private static func normalizedNickname(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    private struct MentionRun {
        let range: NSRange
        let entity: ComposerMentionEntity
    }

    private static func mentionRuns(in attributedText: NSAttributedString) -> [MentionRun] {
        var runs: [MentionRun] = []
        attributedText.enumerateAttribute(.composerMention, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
            guard let entity = value as? ComposerMentionEntity,
                  range.length > 0 else {
                return
            }

            if let last = runs.last,
               last.range.upperBound == range.location,
               last.entity.isEquivalent(to: entity) {
                let mergedRange = NSRange(location: last.range.location, length: last.range.length + range.length)
                runs[runs.count - 1] = MentionRun(range: mergedRange, entity: last.entity)
            } else {
                runs.append(MentionRun(range: range, entity: entity))
            }
        }
        return runs
    }
}

private extension MessageReferenceStorageItem {
    var messageBody: String {
        if let realm = self.realm,
           let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.messageId) {
            return message.body
        }
        return ""
    }

    func bodyFragment(in body: String) -> String {
        let nsBody = body as NSString
        guard self.begin >= 0, self.end <= nsBody.length, self.begin < self.end else { return "" }
        return nsBody.substring(with: self.range)
    }
}

private extension ComposerMentionEntity {
    var normalizedNickname: String {
        let trimmed = self.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else {
            return trimmed
        }
        return String(trimmed.dropFirst())
    }

    func isEquivalent(to other: ComposerMentionEntity) -> Bool {
        self.memberId == other.memberId &&
        self.normalizedNickname == other.normalizedNickname &&
        self.uri == other.uri &&
        self.node == other.node &&
        self.jid == other.jid
    }
}
