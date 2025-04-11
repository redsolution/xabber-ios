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
                size: CGSize(width: 44, height: 40)
            )
            self.verticalLine.frame = CGRect(
                origin: CGPoint(x: 50, y: 2),
                size: CGSize(width: 1, height: 42)
            )
            self.titleLabel.frame = CGRect(
                origin: CGPoint(x: 56, y: 2),
                size: CGSize(width: bounds.width - 96, height: 20)
            )
            self.messageLabel.frame = CGRect(
                origin: CGPoint(x: 56, y: 20),
                size: CGSize(width: bounds.width - 96, height: 20)
            )
            self.closeButton.frame = CGRect(
                origin: CGPoint(x: bounds.width - 40, y: 0),
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
            
            return stack
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
//                self.changeChatButton.leftAnchor.constraint(equalTo: self.stack.leftAnchor),
//                self.changeChatButton.rightAnchor.constraint(equalTo: self.stack.rightAnchor),
//                self.listButton.leftAnchor.constraint(equalTo: self.stack.leftAnchor),
//                self.listButton.widthAnchor.constraint(equalToConstant: 44),
                self.counterLabel.leftAnchor.constraint(equalTo: self.stack.leftAnchor, constant: 88),
                self.counterLabel.rightAnchor.constraint(equalTo: self.seekUpButton.leftAnchor),
                self.seekUpButton.widthAnchor.constraint(equalToConstant: 44),
                self.seekUpButton.rightAnchor.constraint(equalTo: self.seekDownButton.leftAnchor),
                self.seekDownButton.widthAnchor.constraint(equalToConstant: 44),
                self.seekDownButton.rightAnchor.constraint(equalTo: self.stack.rightAnchor),
                self.listButton.heightAnchor.constraint(equalToConstant: 36),
//                self.changeChatButton.heightAnchor.constraint(equalToConstant: 36),
                self.counterLabel.heightAnchor.constraint(equalToConstant: 36),
                self.seekUpButton.heightAnchor.constraint(equalToConstant: 36),
                self.seekDownButton.heightAnchor.constraint(equalToConstant: 36)
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
            self.addSubview(self.stack)
            self.stack.fillSuperview()
            self.addSubview(self.listButton)
            self.listButton.frame = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(square: 36))
            
            self.addSubview(self.activityIndicator)
            self.activityIndicator.frame = CGRect(origin: CGPoint(x: self.bounds.midX, y: 0), size: CGSize(square: 36))
//            self.stack.addArrangedSubview(self.listButton)
//            self.stack.addArrangedSubview(self.changeChatButton)
            self.stack.addArrangedSubview(self.counterLabel)
            self.stack.addArrangedSubview(self.seekUpButton)
            self.stack.addArrangedSubview(self.seekDownButton)
            self.activateConstraints()
            self.changeChatButton.addTarget(self, action: #selector(onChangeConversationTypeButtonTouchUp), for: .touchUpInside)
            self.seekUpButton.addTarget(self, action: #selector(onSeekUpButtonTouchUp), for: .touchUpInside)
            self.seekDownButton.addTarget(self, action: #selector(onSeekDownButtonTouchUp), for: .touchUpInside)
            self.listButton.addTarget(self, action: #selector(onChangeViewStateTouchUp), for: .touchUpInside)
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
            self.backghroundWaveform.backgroundColor = palette.tint500
            self.deleteButton.frame = CGRect(
                origin: CGPoint(x: 0, y: 0),
                size: CGSize(width: 44, height: 38)
            )
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
            self.recordIndicator.frame = CGRect(
                origin: CGPoint(x: 2, y: 15),
                size: CGSize(square: recordIndicatorSize)
            )
            self.recordIndicator.layer.cornerRadius = recordIndicatorSize / 2
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
//        print("maxTextViewSize", maxTextViewSize, textField.sizeThatFits(maxTextViewSize).height.rounded(.down))
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
        let button = SendButton(frame: CGRect(width: 44, height: 38))
        
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
            size: CGSize(width: 40, height: 38)
        )
        let textFieldFrame = CGRect(
            origin: CGPoint(x: 40, y: 0),
            size: CGSize(width: self.frame.width - 84, height: 38)
        )
        let timerButtonFrame = CGRect(
            origin: CGPoint(x: self.frame.width - 84, y: 0),
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
        
//        blurredEffectView.frame = self.bounds
        self.backgroundColor = .systemBackground
        self.updateBottomPanels(withOffset: 0)
        self.selectionPanel.update()
        self.recordPanel.update()
        self.recordAndPlayPanel.update()
        self.startPositionSendButton = self.sendButton.center
    }
    
    final func setup() {
        
        
//        self.addSubview(self.blurredEffectView)
        
        self.contentView.addSubview(self.attachButton)
        self.contentView.addSubview(self.textField)
        self.contentView.addSubview(self.timerButton)
        self.contentView.addSubview(self.sendButton)
        self.contentView.addSubview(self.stateButton)
        self.addSubview(self.contentView)
        
        self.sendButton.delegate = self
        
        self.addSubview(self.selectionPanel)
        self.addSubview(self.forwardPanel)
        self.addSubview(self.editPanel)
        self.addSubview(self.searchPanel)
        self.addSubview(self.recordAndPlayPanel)
        self.addSubview(self.recordPanel)
        
        self.stateButton.fillSuperview()
        self.stateButton.isHidden = true
        self.addObservers()
        self.attachButton.addTarget(self, action: #selector(self.onAttachButtonTouchUp), for: .touchUpInside)
        self.timerButton.addTarget(self,  action: #selector(self.onTimerButtonTouchUp), for: .touchUpInside)
        self.stateButton.addTarget(self,  action: #selector(self.onStateButtonTouchUp), for: .touchUpInside)
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
    
    public func hideEditPanel() {
        if !self.isEditPanelShowed {
            return
        }
        self.isEditPanelShowed = false
        self.topInset = 0
        self.update(screenHeight: self.screenHeight, keyboardHeight: self.keyboardHeight, animate: true) {
            self.editPanel.isHidden = true
            self.barHeight = self.cachedIntrinsicContentSize.height + 11
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
        
        self.barHeight = self.cachedIntrinsicContentSize.height + 11
        var inputHeight: CGFloat = self.barHeight + keyboardHeight + self.topInset
        if keyboardHeight == 0 {
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
        }
        UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseIn]) {
            self.textField.frame = CGRect(
                origin: CGPoint(x: 40, y: 0),
                size: CGSize(width: self.frame.width - 84, height: self.cachedIntrinsicContentSize.height)
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
