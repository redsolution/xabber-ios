////
////
////
////  This program is free software; you can redistribute it and/or
////  modify it under the terms of the GNU General Public License as
////  published by the Free Software Foundation; either version 3 of the
////  License.
////
////  This program is distributed in the hope that it will be useful,
////  but WITHOUT ANY WARRANTY; without even the implied warranty of
////  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
////  General Public License for more details.
////
////  You should have received a copy of the GNU General Public License along
////  with this program; if not, write to the Free Software Foundation, Inc.,
////  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
////
////
////
//
//import Foundation
//import UIKit
//import RxSwift
//import RxCocoa
//import MaterialComponents.MDCPalettes
////import SoundWave
//import CocoaLumberjack
//
//extension ChatViewController {
//    class RecordingPanel: UIView {
//        
//        enum State {
//            case locked
//            case unlocked
//            case preview
//        }
//        
//        internal var currentState: State = .unlocked
//        internal var isPlayed: Bool = false
//        internal var duration: TimeInterval? = nil
//        
//        let stack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.alignment = .center
//            stack.distribution = .fill
////            stack.distribution = .fillProportionally
//            stack.spacing = 8
//            
////            stack.isLayoutMarginsRelativeArrangement = true
////            stack.layoutMargins = UIEdgeInsets(
////                top: 8,
////                bottom: 8,
////                left: 8,
////                right: 8
////            )
//            
//            return stack
//        }()
//        
//        internal let indicatorView: UIButton = {
//            let view = UIButton()
//            
//            view.setImage(imageLiteral("record")?.withRenderingMode(.alwaysTemplate), for: .disabled)
//            view.isEnabled = false
//            view.alpha = 1.0
//            view.tintColor = .systemRed
//            view.imageEdgeInsets = UIEdgeInsets(
//                top: 4,
//                bottom: 4,
//                left: 4,
//                right: 4
//            )
//            
//            return view
//        }()
//        
//        internal let durationLabel: UILabel = {
//            let label = UILabel()
//            
//            if #available(iOS 13.0, *) {
//                label.textColor = .secondaryLabel
//            } else {
//                label.textColor = .gray
//            }
//            
//            label.text = ""
//            
//            return label
//        }()
//        
//        let cancelButton: UIButton = {
//            let button = UIButton()
//            
//            button.setImage(imageLiteral( "chevron.left"), for: .disabled)
//            button.imageView?.tintColor = MDCPalette.grey.tint500
//            button.setImage(nil, for: .normal)
//            button.setTitleColor(MDCPalette.grey.tint500, for: .disabled)
//            button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
//            button.setTitle("Slide to cancel".localizeString(id: "chat_slide_to_cancel_audio_record", arguments: []),
//                            for: .disabled)
//            button.setTitle("Cancel".localizeString(id: "cancel", arguments: []),
//                            for: .normal)
//            button.isEnabled = false
//            button.titleLabel?.textAlignment = .left
//            button.titleLabel?.lineBreakMode = .byClipping
//            button.titleEdgeInsets = UIEdgeInsets(top: 2, bottom: 2, left: 8, right: 0)
//            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
//            
//            return button
//        }()
//        
//        let deleteButton: UIButton = {
//            let button = UIButton()
//            
//            button.setImage(imageLiteral( "trash")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            if #available(iOS 13.0, *) {
//                button.tintColor = .secondaryLabel
//            } else {
//                button.tintColor = MDCPalette.grey.tint500
//            }
//            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            button.imageEdgeInsets = UIEdgeInsets(top: 4, bottom: 4, left: 2, right: 10)
//            
//            return button
//        }()
//        
//        let preview: UIView = {
//            let view = UIView(frame: CGRect(square: 36))
//            
//            view.layer.cornerRadius = view.frame.width / 2
//            view.backgroundColor = .green
//            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
//            
//            return view
//        }()
//        
//        let previewStack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.alignment = .center
//            stack.distribution = .fill
////            stack.spacing = 8
//            
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 12, right: 12)
//            
//            return stack
//        }()
//        
//        let playButton: UIButton = {
//            let button = UIButton()
//            
//            button.tintColor = .white
//            button.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            button.backgroundColor = .clear
//            
//            
//            return button
//        }()
//        
//        let timeLabel: UILabel = {
//            let label = UILabel()
//            
//            label.font = UIFont.preferredFont(forTextStyle: .caption1)
//            label.textColor = .white
//            label.backgroundColor = .clear
//            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
//            
//            return label
//        }()
//        
//        let waveform: AudioVisualizationView = {
//            let view = AudioVisualizationView(frame: CGRect(width: 250, height: 32))
//            
//            view.audioVisualizationMode = .read
//            view.audioVisualizationType = .top
//            view.backgroundColor = .clear
//            view.currentGradientPercentage = 100.0
//            view.gradientStartColor = MDCPalette.grey.tint50
//            view.gradientEndColor = MDCPalette.grey.tint100
//            view.barBackgroundFillColor = MDCPalette.grey.tint200
//            view.meteringLevelBarWidth = 2
//            view.meteringLevelBarCornerRadius = 0
//            view.meteringLevelBarInterItem = 1.5
//            view.progressBarLineHeight = 0.5
//            view.progressBarMiddleOffset = 1
//            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
//            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
//            
//            return view
//        }()
//            
//        
//        internal var meters: [Float] = []
//        
//        open var cancelCallback: (() -> Void)? = nil
//        open var deleteCallback: (() -> Void)? = nil
//        
//        @objc
//        internal func onCancel(_ sender: UIButton) {
//            cancelCallback?()
//        }
//        
//        @objc
//        internal func onDelete(_ sender: UIButton) {
//            deleteCallback?()
//        }
//        
//        override init(frame: CGRect) {
//            super.init(frame: frame)
//            setup()
//        }
//        
//        required init?(coder: NSCoder) {
//            super.init(coder: coder)
//            setup()
//        }
//        
//        open var cancelButtonRightConstant: CGFloat = -24 {
//            didSet {
//                cancelButtonConstraintsSet?.right?.constant = cancelButtonRightConstant
//                var alpha = 1.0 - ((abs(self.cancelButtonRightConstant) - 24) / 50.0)
//                if alpha < 0.0 {
//                    alpha = 0.0
//                }
//                if alpha > 1.0 {
//                    alpha = 1.0
//                } else if currentState == .locked {
//                    alpha = 1.0
//                }
//                if currentState == .locked {
//                    cancelButtonConstraintsSet?.right?.constant = -40
//                } else {
//                    cancelButtonConstraintsSet?.right?.constant = cancelButtonRightConstant
//                }
//                UIView.performWithoutAnimation {
//                    self.cancelButton.alpha = alpha
//                }
//            }
//        }
//        
//        internal var waveformContstraints: [NSLayoutConstraint] = []
//        internal var unlockedConstraints: [NSLayoutConstraint] = []
//        internal var cancelButtonConstraintsSet: NSLayoutConstraintSet? = nil
//        
//        internal func setup() {
//            
//            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
//            previewStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
//            addSubview(stack)
////            stack.fillSuperview()
//            stack.fillSuperviewWithOffset(top: 0, bottom: 2, left: 8, right: 8)
//            stack.addArrangedSubview(indicatorView)
//            stack.addArrangedSubview(durationLabel)
//            stack.addArrangedSubview(deleteButton)
//            stack.addArrangedSubview(cancelButton)
//            stack.addArrangedSubview(preview)
//            cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
//            deleteButton.addTarget(self, action: #selector(onDelete), for: .touchUpInside)
//            cancelButton.isHidden = false
//            deleteButton.isHidden = true
//            preview.isHidden = true
//            
//            preview.addSubview(previewStack)
//            previewStack.fillSuperview()
//            previewStack.addArrangedSubview(playButton)
//            previewStack.addArrangedSubview(waveform)
//            previewStack.addArrangedSubview(timeLabel)
//            
//            unlockedConstraints = [
//                indicatorView.widthAnchor.constraint(equalToConstant: 28),
//                indicatorView.heightAnchor.constraint(equalToConstant: 28),
//                durationLabel.widthAnchor.constraint(equalToConstant: 72)
//            ]
//            
//            cancelButtonConstraintsSet = NSLayoutConstraintSet(
//                right: cancelButton.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: cancelButtonRightConstant),
//                height: cancelButton.heightAnchor.constraint(equalToConstant: 36)
//            )
//            
//            waveformContstraints = [
//                preview.heightAnchor.constraint(equalToConstant: 34),
//                deleteButton.widthAnchor.constraint(equalToConstant: 36),
//                deleteButton.heightAnchor.constraint(equalToConstant: 36),
//                waveform.leftAnchor.constraint(equalTo: playButton.rightAnchor, constant: 8),
//                waveform.rightAnchor.constraint(equalTo: timeLabel.leftAnchor, constant: -8),
//                waveform.heightAnchor.constraint(equalToConstant: 24),
//            ]
//            NSLayoutConstraint.activate(unlockedConstraints)
//            cancelButtonConstraintsSet?.activate()
//            playButton.addTarget(self, action: #selector(onPlayButtonTapped), for: .touchUpInside)
//        }
//        
//        open func configurePreview(color: UIColor, duration: String, meters: [Float]) {
//            self.meters = meters
//            
//            waveform.reset()
//            timeLabel.text = duration
//            preview.backgroundColor = color
//        }
//        
//        open func enableCancelButton() {
//            if !cancelButton.isEnabled {
//                cancelButton.isEnabled = true
//            }
//        }
//        
//        @objc
//        internal func onPlayButtonTapped(_ sender: UIButton) {
//            if isPlayed {
//                pause()
//            } else {
//                if let duration = self.duration {
//                    play(for: duration)
//                }
//            }
//        }
//        
//        open var onPlayCallback: (() -> Void)? = nil
//        open var onPauseCallback: (() -> Void)? = nil
//        open var onEndPlayingCallback: (() -> Void)? = nil
//        
//        open func play(for duration: TimeInterval) {
//            isPlayed = true
//            self.waveform.barBackgroundFillColor = MDCPalette.grey.tint400
//            self.playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            self.waveform.play(for: duration)
//            waveform.playChronometer?.timerDidComplete = waveformEndPlaying
//            onPlayCallback?()
//        }
//        
//        open func pause() {
//            isPlayed = false
//            self.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            self.waveform.pause()
//            onPauseCallback?()
//        }
//        
//        open func waveformEndPlaying() {
//            isPlayed = false
//            self.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            onEndPlayingCallback?()
//        }
//        
//        open func updateTimeLabel(_ interval: TimeInterval) {
//            self.duration = interval
//            durationLabel.text = interval.minuteFormatedString
//            durationLabel.layoutIfNeeded()
//        }
//        
//        open func animateRecordIndicator() {
//            stopAnimateRecordIndicator()
//            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { (_) in
//                UIView.animate(withDuration: 0.9,
//                               delay: 0.0,
//                               options: [.repeat, .autoreverse],
//                               animations: {
//                                    self.indicatorView.alpha = 0.6
//                               },
//                               completion: nil)
//            }
//        }
//        
//        open func stopAnimateRecordIndicator() {
//            indicatorView.layer.removeAllAnimations()
//            indicatorView.layoutIfNeeded()
//        }
//        
//        open func reset() {
//            
//        }
//        
//        internal func updateState(_ state: State) {
//            currentState = state
//            switch state {
//            case .locked, .unlocked:
//                if state == .locked {
//                    cancelButton.isEnabled = state == .locked
//                    cancelButtonRightConstant = -8
//                }
//                cancelButton.isEnabled = state == .locked
//                
//                indicatorView.isHidden = false
//                durationLabel.isHidden = false
//                
//                cancelButton.isHidden = false
//                deleteButton.isHidden = true
//                preview.isHidden = true
//                
//                cancelButton.isUserInteractionEnabled = true
//                stack.layoutIfNeeded()
//                NSLayoutConstraint.deactivate(waveformContstraints)
//                NSLayoutConstraint.activate(unlockedConstraints)
//                cancelButtonConstraintsSet?.activate()
//                
//            case .preview:
//                waveform.barBackgroundFillColor = MDCPalette.grey.tint200
//                NSLayoutConstraint.activate(waveformContstraints)
//                NSLayoutConstraint.deactivate(unlockedConstraints)
//                stack.layoutSubviews()
//                waveform.layoutIfNeeded()
//                cancelButtonConstraintsSet?.deactivate()
//                indicatorView.isHidden = true
//                durationLabel.isHidden = true
//                cancelButton.isHidden = true
//                deleteButton.isHidden = false
//                preview.layer.cornerRadius = preview.frame.height / 2
//                preview.isHidden = false
//                waveform.currentGradientPercentage = 0.0
//                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { (_) in
//                    self.waveform.meteringLevels = self.waveform.scaleOuterArrayToFitScreen(self.meters)
//                }
//            }
//        }
//        
//        open func changeState(_ state: State) {
//
//        }
//    }
//    
//    func showRecordingPanel() {
//
//    }
//    
//    func hideRecordingPanel() {
//    }
//}
