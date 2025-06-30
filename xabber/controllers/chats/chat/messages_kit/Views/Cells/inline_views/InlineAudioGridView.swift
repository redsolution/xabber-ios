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
//import MaterialComponents.MDCPalettes
//
//class InlineAudioGridView: InlineMediaBaseView {
//    
//    enum AudioCellPlayingState {
//        case loading
//        case play
//        case pause
//        case stop
//    }
//    
//    class AudioView: UIView {
//        
//        enum State {
//            case playing
//            case paused
//        }
//        
//        let stack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .horizontal
//            stack.alignment = .center
//            stack.distribution = .fill
//            stack.spacing = 8
//            
//            stack.isLayoutMarginsRelativeArrangement = true
//            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 6, right: 6)
//            
//            return stack
//        }()
//        
//        let loadingIndicator: UIActivityIndicatorView = {
//            let view = UIActivityIndicatorView(style: .gray)
//            
//            view.frame = CGRect(square: 44)
//            view.startAnimating()
//            
//            return view
//        }()
//        
//        let playButton: UIButton = {
//            let button = UIButton(frame: CGRect(square: 44))
//            
//            button.backgroundColor = MDCPalette.grey.tint300
//            button.tintColor = MDCPalette.grey.tint700
//            button.layer.cornerRadius = button.frame.width / 2
//            button.layer.masksToBounds = true
//            button.imageEdgeInsets = UIEdgeInsets(square: 10)
//            button.isUserInteractionEnabled = false
//            
//            return button
//        }()
//        
//        let contentStack: UIStackView = {
//            let stack = UIStackView()
//            
//            stack.axis = .vertical
//            stack.alignment = .leading
//            stack.distribution = .fill
//            
//            return stack
//        }()
//        
//        let waveform: AudioVisualizationView = {
//            let view = AudioVisualizationView()
//            
//            view.audioVisualizationMode = .read
//            view.audioVisualizationType = .top
//            view.backgroundColor = .clear
//            view.currentGradientPercentage = 100.0
//            view.gradientStartColor = MDCPalette.grey.tint800
//            view.gradientEndColor = MDCPalette.grey.tint900
//            view.barBackgroundFillColor = MDCPalette.grey.tint500
//            view.meteringLevelBarWidth = 2
//            view.meteringLevelBarCornerRadius = 0
//            view.meteringLevelBarInterItem = 1.5
//            view.progressBarLineHeight = 0.5
//            view.progressBarMiddleOffset = 1
//            view.audioVisualizationTimeInterval = 0.025
//            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
//            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
//            
//            return view
//        }()
//        
//        let durationLabel: UILabel = {
//            let label = UILabel()
//            
//            label.font = UIFont.preferredFont(forTextStyle: .caption1)
//            label.textColor = MDCPalette.grey.tint500
//            
//            return label
//        }()
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
//        internal func setup() {
//            addSubview(stack)
//            stack.fillSuperview()
//            stack.addArrangedSubview(playButton)
//            stack.addArrangedSubview(contentStack)
//            contentStack.addArrangedSubview(waveform)
//            contentStack.addArrangedSubview(durationLabel)
//            waveform.frame = CGRect(width: frame.width - 64, height: 24)
//            NSLayoutConstraint.activate([
//                contentStack.heightAnchor.constraint(equalToConstant: 46),
//                waveform.heightAnchor.constraint(equalToConstant: 24),
//                waveform.leftAnchor.constraint(equalTo: contentStack.leftAnchor, constant: 0),
//                waveform.rightAnchor.constraint(equalTo: contentStack.rightAnchor, constant: 0),
//                playButton.widthAnchor.constraint(equalToConstant: 44),
//                playButton.heightAnchor.constraint(equalToConstant: 44),
//            ])
//        }
//        
//        internal func configure(_ state: State, meters: [Float], loading: Bool, duration text: String?) {
//            durationLabel.text = text
//            waveform.meteringLevels = waveform.scaleOuterArrayToFitScreen(meters)
//            
//            switch state {
//            case .playing:
//                playButton.setImage(imageLiteral( "pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            case .paused:
//                playButton.setImage(imageLiteral( "play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            }
//            waveform.currentGradientPercentage = 0.0
//        }
//    }
//    
//    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {
//
//        let frame = self.frame
//        let padding: CGFloat = 0
//        let height: CGFloat = 64//MessageSizeCalculator.audioViewHeight
//        var offset: CGFloat = padding
//        return references
//            .filter({ $0.kind == .voice })
//            .compactMap { _ in
//                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
//                offset += height + padding
//                return rect
//            }
//    }
//    
//    var audioView: AudioView!
//    internal var state: AudioCellPlayingState = .play
//    internal var duration: TimeInterval = 0.0
//    internal var lastPlayedDuration: TimeInterval = 0.0
//    
//    override func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
//        super.configure(references, messageId: messageId, indexPath: indexPath)
//        self.messageId = messageId
//        subviews.forEach { $0.removeFromSuperview() }
//        let items = references.filter({ $0.kind == .voice })
//        if items.isEmpty { return }
////        prepareGrid(references).enumerated().forEach {
////            index, cell in
////            if let uri = items[index].metadata?["uri"] as? String,
////               let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") {
////                let view = AudioView(frame: cell)
////                addSubview(view)
////                view.configure(.paused,
////                               meters: items[index].meteringLevels ?? [0.0, 0.0],
////                               loading: items[index].meteringLevels == nil,
////                               duration: datasource?.audioMessageDurationString(at: indexPath, messageId: messageId, index: nil))
////                audioView = view
////                grid.append(GridItem(cell: cell, url: url))
////            }
////        }
//        
////        if let datasource = datasource {
////            state = datasource.audioMessageState(at: indexPath, messageId: messageId, index: nil)
////            duration = datasource.audioMessageDuration(at: indexPath, messageId: messageId, index: nil)
////            lastPlayedDuration = datasource.audioMessageCurrentDuration(at: indexPath, messageId: messageId, index: nil)
////        }
//        
//        audioView.waveform.startFrom = lastPlayedDuration
//        
//        switch state {
//        case .stop:
//            audioView.loadingIndicator.removeFromSuperview()
//            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//        case .loading:
//            audioView.playButton.setImage(nil, for: .normal)
//            audioView.loadingIndicator.startAnimating()
//            audioView.loadingIndicator.isHidden = false
//            audioView.playButton.addSubview(audioView.loadingIndicator)
//        case .play:
//            audioView.loadingIndicator.removeFromSuperview()
//            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//        case .pause:
//            audioView.loadingIndicator.removeFromSuperview()
//            audioView.playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            audioView.waveform.play(for: duration - lastPlayedDuration)
//        }
////        audioView.waveform
////            .currentGradientPercentage = datasource?
////                .audioMessageCurrentGradientPercentage(at: indexPath,
////                                                       messageId: messageId,
////                                                       index: nil)
//    }
//    
////    func animateButtonTap() {
////        UIView.animate(withDuration: 0.05,
////                       delay: 0.0,
////                       options: [],
////                       animations: {
////                        self.audioView.playButton.backgroundColor = MDCPalette.grey.tint400
////            })
////        UIView.animate(withDuration: 0.05,
////                   delay: 0.0,
////                   options: [],
////                   animations: {
////                    self.audioView.playButton.backgroundColor = MDCPalette.grey.tint300
////        })
////    }
//    
//    func update(state: AudioCellPlayingState) {
//        switch state {
//        case .play:
//            self.state = .pause
////            animateButtonTap()
//            audioView.playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            audioView.waveform.play(for: duration - lastPlayedDuration)
//        case .pause:
//            self.state = .play
//            audioView.waveform.pause()
//            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//        case .stop:
//            self.state = .play
//            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            audioView.waveform.stop()
//            audioView.durationLabel.text = "\(TimeInterval(0).minuteFormatedString) / \(duration.minuteFormatedString)"
//        default: return
//        }
//    }
//    
//    func update(durationLabel: String?) {
//        audioView.durationLabel.text = durationLabel
//    }
//    
//    override func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
//        for (index, item) in grid.enumerated() {
//            if item.cell.contains(point) {
//                callback?(messageId, index, false)
//            }
//        }
//    }
//    
//    
//}
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import AVFoundation

public class InlineAudiosGridView: InlineAttachmentView {
    
    public class PulseButton: UIButton {
        private let pulseLayer: PulseLayer = {
            let layer = PulseLayer()
            
            return layer
        }()
        
        public override init(frame: CGRect) {
            super.init(frame: frame)
            self.setupPulse()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.setupPulse()
        }
        
        private final func setupPulse() {
//            self.layer.sub
            self.subviews.first?.layer.insertSublayer(pulseLayer, at: 0)
//            self.layer.insertSublayer(pulseLayer, at: 100)
        }
        
        public func configurePulse(_ configure: ((PulseLayer) -> Void)?) {
            configure?(self.pulseLayer)
        }
        
        public final func startPulse() {
            self.pulseLayer.start()
        }
        
        public final func endPulse() {
            self.pulseLayer.stop()
        }
    }
    
    public class AudioView: UIView, MulticastAVAudioPlayerDelegate {
        
        var url: URL?
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 4, right: 4)
            
            return stack
        }()
        
        let iconButton: PulseButton = {
            let button = PulseButton(frame: CGRect(square: 36))
            
            button.backgroundColor = MDCPalette.blue.tint400
            button.tintColor = UIColor.white
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            button.isUserInteractionEnabled = true
            button.configurePulse { pulse in
                pulse.frame = CGRect(square: 36)
                pulse.radius = 22
                pulse.pulseInterval = 0.1
                pulse.fromValueForRadius = 0.8
                pulse.backgroundColor = UIColor.red.cgColor
            }
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 0
            
            return stack
        }()
        
        let waveform: AudioVisualizationView = {
            let view = AudioVisualizationView()
            
            view.audioVisualizationMode = .read
            view.audioVisualizationType = .both
            view.backgroundColor = .clear
            view.currentGradientPercentage = 0.0
            view.gradientStartColor = MDCPalette.blue.tint400
            view.gradientEndColor = MDCPalette.blue.tint700
            view.barBackgroundFillColor = MDCPalette.blue.tint200
            view.meteringLevelBarWidth = 2
            view.meteringLevelBarCornerRadius = 2
            view.meteringLevelBarInterItem = 1.5
            view.progressBarLineHeight = 0.5
            view.progressBarMiddleOffset = 0
            view.audioVisualizationTimeInterval = 0.025
            
            return view
        }()
        
        let durationLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            label.textColor = MDCPalette.grey.tint500
            
            return label
        }()
        
        init(frame: CGRect, url: URL?) {
            self.url = url
            super.init(frame: frame)
            setup()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        let activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
        var palette: MDCPalette = .amber
        
        internal func setup() {
            iconButton.frame = CGRect(
                origin: CGPoint(x: 4, y: 4),
                size: CGSize(width: 36, height: 36)
            )
            waveform.frame = CGRect(
                origin: CGPoint(x: 48, y: 2),
                size: CGSize(width: self.frame.width - 48 - 4, height: 26)
            )
            durationLabel.frame = CGRect(
                origin: CGPoint(x: 48, y: 28),
                size: CGSize(width: self.frame.width - 48 - 4, height: 12)
            )
            addSubview(iconButton)
            addSubview(waveform)
            addSubview(durationLabel)
//            addSubview(stack)
//            stack.fillSuperview()
//            stack.addArrangedSubview(iconButton)
//            stack.addArrangedSubview(contentStack)
//            contentStack.addArrangedSubview(waveform)
//            contentStack.addArrangedSubview(durationLabel)
//            NSLayoutConstraint.activate([
//                iconButton.widthAnchor.constraint(equalToConstant: 36),
//                iconButton.heightAnchor.constraint(equalToConstant: 36),
//                waveform.heightAnchor.constraint(equalToConstant: 20),
//                waveform.leftAnchor.constraint(equalTo: contentStack.leftAnchor),
//                waveform.rightAnchor.constraint(equalTo: contentStack.rightAnchor),
//                durationLabel.heightAnchor.constraint(equalToConstant: 20)
//            ])
        }
        
        var duration: TimeInterval = 0
        var primary: String = ""
        var delegate: MessageCellDelegate? = nil
        
        public func configure(_ primary: String, filename: String, size: String, duration: TimeInterval, pcm: [Float]) {
            iconButton.setImage(imageLiteral("play.fill"), for: .normal)
//            waveform.text = filename
            print("WAVEFORM", self.waveform.frame)
//            print("WAVEFORM", self.waveform.)
            if pcm.isEmpty {
                waveform.meteringLevels = (0..<52).compactMap { _ in return 0.1 }
            } else {
                waveform.meteringLevels = pcm.compactMap { return $0 < 0.1 ? 0.1 : $0 }
            }
//            waveform.meteringLevels = [0.2, 0.4, 0.7, 0.6, 0.5, 0.4, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
//            waveform.meteringLevels = waveform.scaleOuterArrayToFitScreen(waveform.meteringLevels!)
            durationLabel.text = duration.minuteFormatedString
            self.duration = duration
            self.primary = primary
            
            self.waveform.gradientStartColor = palette.tint500
            self.waveform.gradientEndColor = palette.tint500
            self.waveform.barBackgroundFillColor = palette.tint100
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(onPanGestureAppear))
            self.waveform.addGestureRecognizer(gesture)
            self.iconButton.backgroundColor = palette.tint500
            self.waveform.drawCallback = self.updateTimeLabel
            self.iconButton.addTarget(self, action: #selector(onPlayButtonTouchUpInside), for: .touchUpInside)
        }
        
        @objc
        private func onPlayButtonTouchUpInside(_ sender: UIButton) {
            self.delegate?.didTapOnAudio(self, url: self.url)
        }
        
        @objc
        private func onPanGestureAppear(_ sender: UIPanGestureRecognizer) {
            if self.delegate?.canChangeAudioPosition(for: self.primary) ?? false {
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
                        guard let newDuration = self.delegate?.didSetAudioPosition(self, percentage: percentage) else {
                            return
                        }
                        //                    self.waveform.
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
        }
        
        public func displayDownload() {
            self.iconButton.setImage(nil, for: .normal)
            
            self.activityIndicator.frame = self.iconButton.bounds
            self.activityIndicator.startAnimating()
            self.activityIndicator.isHidden = false
            self.activityIndicator.color = .white
            self.iconButton.addSubview(self.activityIndicator)
        }
        
        public final func updateTimeLabel() {
            if AudioManager.shared.player != nil {
                if let currentDuration = AudioManager.shared.player?.currentTime {
                    self.durationLabel.text = currentDuration.minuteFormatedString
                } else {
                    self.durationLabel.text = self.duration.minuteFormatedString
                }
            } else {
                self.durationLabel.text = self.duration.minuteFormatedString
            }
        }
        
        public func play(for duration: TimeInterval) {
            self.activityIndicator.removeFromSuperview()
            self.iconButton.setImage(imageLiteral("pause.fill"), for: .normal)
            self.iconButton.startPulse()
            UIView.animate(withDuration: 0.1, animations: { self.iconButton.backgroundColor = self.palette.tint300 })
//            self.iconButton.backgroundColor = palette.tint300
            self.waveform.play(for: duration)
        }
        
        public func continuePlay() {
            self.waveform.play(for: self.duration)
            self.iconButton.setImage(imageLiteral("pause.fill"), for: .normal)
            self.iconButton.startPulse()
            UIView.animate(withDuration: 0.1, animations: { self.iconButton.backgroundColor = self.palette.tint300 })
//            self.iconButton.backgroundColor = palette.tint300
            self.layoutSubviews()
        }
        
        public func pause() {
            self.waveform.pause()
            self.iconButton.setImage(imageLiteral("play.fill"), for: .normal)
            self.iconButton.endPulse()
            UIView.animate(withDuration: 0.1, animations: { self.iconButton.backgroundColor = self.palette.tint300 })
//            self.iconButton.backgroundColor = palette.tint300
        }
        
        public final func resetWaveform() {
            self.waveform.stop()
        }
        
        public func resetState() {
            self.waveform.pause()
            self.iconButton.setImage(imageLiteral("play.fill"), for: .normal)
            self.iconButton.endPulse()
            UIView.animate(withDuration: 0.1, animations: { self.iconButton.backgroundColor = self.palette.tint500 })
//            self.iconButton.backgroundColor = palette.tint500
        }
        
        func staticMulticastId() -> String {
            return "\(self.primary)_audio_view_smid"
        }
        
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
            
        }
        
        func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
            
        }
        
        func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
            
        }
        public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            print("finish")
            self.resetState()
            self.delegate?.didStopPlayingAudioCell()
        }
    }

    
    public var views: [AudioView] = []
    
    func prepareGrid(_ attachments: [AudioAttachment]) -> [CGRect] {
        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = CommonMessageSizeCalculator.inlineFileViewHeight//MessageSizeCalculator.fileViewHeight
        var offset: CGFloat = padding
        return attachments
            .compactMap { _ in
                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
                offset += height + padding
                return rect
            }
    }
    
    var palette: MDCPalette = .amber
    var delegate: MessageCellDelegate? = nil
    
    func configure(_ attachments: [AudioAttachment], palette: MDCPalette) {
        self.palette = palette
//        subviews.forEach { $0.removeFromSuperview() }
        if attachments.isEmpty { return }
        grid.removeAll()
        
        self.views.forEach { $0.removeFromSuperview() }
        self.views = []
        prepareGrid(attachments).enumerated().forEach {
            index, rect in
            let item = attachments[index]
//            if let url = item.url {
            let view = AudioView(frame: rect, url: item.url)
            view.palette = palette
            view.delegate = self.delegate
            let duration = item.duration as TimeInterval
            view.configure(item.primary, filename: item.name, size: item.prettySize, duration: duration, pcm: item.pcm)
            addSubview(view)
            views.append(view)
//            }
        }
    }
    
    func handleTouch(at point: CGPoint, callback: ((InlineAudiosGridView.AudioView?, URL?) -> Void)?) -> Bool {
        var isMyTouch: Bool = false
        self.views.forEach {
            item in
            if item.frame.contains(point) {
                isMyTouch = true
//                if item.waveform.isPlayed {
//                    item.waveform.pause()
//                    item.iconButton.setImage(imageLiteral("play.fill"), for: .normal)
//                } else {
//                    item.iconButton.setImage(imageLiteral("pause.fill"), for: .normal)
//                }
                callback?(item, item.url)
                //                callback?(messageId, index, false)
            }
        }
        return isMyTouch
    }
    
}
