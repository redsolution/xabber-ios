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

class InlineAudioGridView: InlineMediaBaseView {
    
    enum AudioCellPlayingState {
        case loading
        case play
        case pause
        case stop
    }
    
    class AudioView: UIView {
        
        enum State {
            case playing
            case paused
        }
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 6, right: 6)
            
            return stack
        }()
        
        let loadingIndicator: UIActivityIndicatorView = {
            let view = UIActivityIndicatorView(style: .gray)
            
            view.frame = CGRect(square: 44)
            view.startAnimating()
            
            return view
        }()
        
        let playButton: UIButton = {
            let button = UIButton(frame: CGRect(square: 44))
            
            button.backgroundColor = MDCPalette.grey.tint300
            button.tintColor = MDCPalette.grey.tint700
            button.layer.cornerRadius = button.frame.width / 2
            button.layer.masksToBounds = true
            button.imageEdgeInsets = UIEdgeInsets(square: 10)
            button.isUserInteractionEnabled = false
            
            return button
        }()
        
        let contentStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            
            return stack
        }()
        
        let waveform: AudioVisualizationView = {
            let view = AudioVisualizationView()
            
            view.audioVisualizationMode = .read
            view.audioVisualizationType = .top
            view.backgroundColor = .clear
            view.currentGradientPercentage = 100.0
            view.gradientStartColor = MDCPalette.grey.tint800
            view.gradientEndColor = MDCPalette.grey.tint900
            view.barBackgroundFillColor = MDCPalette.grey.tint500
            view.meteringLevelBarWidth = 2
            view.meteringLevelBarCornerRadius = 0
            view.meteringLevelBarInterItem = 1.5
            view.progressBarLineHeight = 0.5
            view.progressBarMiddleOffset = 1
            view.audioVisualizationTimeInterval = 0.025
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            return view
        }()
        
        let durationLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            
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
        
        internal func setup() {
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(playButton)
            stack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(waveform)
            contentStack.addArrangedSubview(durationLabel)
            waveform.frame = CGRect(width: frame.width - 64, height: 24)
            NSLayoutConstraint.activate([
                contentStack.heightAnchor.constraint(equalToConstant: 46),
                waveform.heightAnchor.constraint(equalToConstant: 24),
                waveform.leftAnchor.constraint(equalTo: contentStack.leftAnchor, constant: 0),
                waveform.rightAnchor.constraint(equalTo: contentStack.rightAnchor, constant: 0),
                playButton.widthAnchor.constraint(equalToConstant: 44),
                playButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        
        internal func configure(_ state: State, meters: [Float], loading: Bool, duration text: String?) {
            durationLabel.text = text
            waveform.meteringLevels = waveform.scaleOuterArrayToFitScreen(meters)
            
            switch state {
            case .playing:
                playButton.setImage(imageLiteral( "pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
            case .paused:
                playButton.setImage(imageLiteral( "play")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
            waveform.currentGradientPercentage = 0.0
        }
    }
    
    override internal func prepareGrid(_ references: [MessageReferenceStorageItem.Model]) -> [CGRect] {

        let frame = self.frame
        let padding: CGFloat = 0
        let height: CGFloat = MessageSizeCalculator.audioViewHeight
        var offset: CGFloat = padding
        return references
            .filter({ $0.kind == .voice })
            .compactMap { _ in
                let rect = CGRect(x: 0, y: offset, width: frame.width, height: height)
                offset += height + padding
                return rect
            }
    }
    
    var audioView: AudioView!
    internal var state: AudioCellPlayingState = .play
    internal var duration: TimeInterval = 0.0
    internal var lastPlayedDuration: TimeInterval = 0.0
    
    override func configure(_ references: [MessageReferenceStorageItem.Model], messageId: String?, indexPath: IndexPath) {
        super.configure(references, messageId: messageId, indexPath: indexPath)
        self.messageId = messageId
        subviews.forEach { $0.removeFromSuperview() }
        let items = references.filter({ $0.kind == .voice })
        if items.isEmpty { return }
        prepareGrid(references).enumerated().forEach {
            index, cell in
            if let uri = items[index].metadata?["uri"] as? String,
               let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") {
                let view = AudioView(frame: cell)
                addSubview(view)
                view.configure(.paused,
                               meters: items[index].meteringLevels ?? [0.0, 0.0],
                               loading: items[index].meteringLevels == nil,
                               duration: datasource?.audioMessageDurationString(at: indexPath, messageId: messageId, index: nil))
                audioView = view
                grid.append(GridItem(cell: cell, url: url))
            }
        }
        
        if let datasource = datasource {
            state = datasource.audioMessageState(at: indexPath, messageId: messageId, index: nil)
            duration = datasource.audioMessageDuration(at: indexPath, messageId: messageId, index: nil)
            lastPlayedDuration = datasource.audioMessageCurrentDuration(at: indexPath, messageId: messageId, index: nil)
        }
        
        audioView.waveform.startFrom = lastPlayedDuration
        
        switch state {
        case .stop:
            audioView.loadingIndicator.removeFromSuperview()
            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
        case .loading:
            audioView.playButton.setImage(nil, for: .normal)
            audioView.loadingIndicator.startAnimating()
            audioView.loadingIndicator.isHidden = false
            audioView.playButton.addSubview(audioView.loadingIndicator)
        case .play:
            audioView.loadingIndicator.removeFromSuperview()
            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
        case .pause:
            audioView.loadingIndicator.removeFromSuperview()
            audioView.playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
            audioView.waveform.play(for: duration - lastPlayedDuration)
        }
        audioView.waveform
            .currentGradientPercentage = datasource?
                .audioMessageCurrentGradientPercentage(at: indexPath,
                                                       messageId: messageId,
                                                       index: nil)
    }
    
//    func animateButtonTap() {
//        UIView.animate(withDuration: 0.05,
//                       delay: 0.0,
//                       options: [],
//                       animations: {
//                        self.audioView.playButton.backgroundColor = MDCPalette.grey.tint400
//            })
//        UIView.animate(withDuration: 0.05,
//                   delay: 0.0,
//                   options: [],
//                   animations: {
//                    self.audioView.playButton.backgroundColor = MDCPalette.grey.tint300
//        })
//    }
    
    func update(state: AudioCellPlayingState) {
        switch state {
        case .play:
            self.state = .pause
//            animateButtonTap()
            audioView.playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
            audioView.waveform.play(for: duration - lastPlayedDuration)
        case .pause:
            self.state = .play
            audioView.waveform.pause()
            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
        case .stop:
            self.state = .play
            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
            audioView.waveform.stop()
            audioView.durationLabel.text = "\(TimeInterval(0).minuteFormatedString) / \(duration.minuteFormatedString)"
        default: return
        }
    }
    
    func update(durationLabel: String?) {
        audioView.durationLabel.text = durationLabel
    }
    
    override func handleTouch(at point: CGPoint, callback: ((String?, Int, Bool) -> Void)?) {
        for (index, item) in grid.enumerated() {
            if item.cell.contains(point) {
                callback?(messageId, index, false)
            }
        }
    }
    
    
}

