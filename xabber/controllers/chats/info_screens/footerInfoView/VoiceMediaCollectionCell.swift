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

import UIKit
import MaterialComponents.MDCPalettes
import AVFAudio
import RealmSwift
import CocoaLumberjack
import MaterialComponents

class VoiceMediaCollectionCell: UICollectionViewCell {
    static let cellName = "VoiceMediaCollectionCell"
    
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
        
        let primaryStack: UIStackView = {
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
            stack.alignment = .fill
            stack.distribution = .fillEqually
            
            return stack
        }()
        
        let nameAndTimeStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.distribution = .fill
            
            return stack
        }()
        
        let durationAndDateStack: UIStackView = {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.distribution = .fill
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 0, right: 12)
            
            return stack
        }()
        
        let nameLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 16)
            label.textColor = .black
            label.textAlignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            
            return label
        }()
        
        let durationLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            label.textAlignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            
            return label
        }()
        
        let dateLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            label.textAlignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            
            return label
        }()
        
        let timeAndDateLabel: UILabel = {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = MDCPalette.grey.tint500
            label.textAlignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            
            return label
        }()
        
        let separatorLine: UIView = {
            let view = UIView()
            view.backgroundColor = .systemGray5
            view.translatesAutoresizingMaskIntoConstraints = false
            
            return view
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
            addSubview(primaryStack)
            primaryStack.fillSuperview()
            primaryStack.addArrangedSubview(playButton)
            primaryStack.addArrangedSubview(contentStack)
            contentStack.addArrangedSubview(nameAndTimeStack)
            nameAndTimeStack.addArrangedSubview(nameLabel)
            nameAndTimeStack.addArrangedSubview(timeAndDateLabel)
            contentStack.addArrangedSubview(durationAndDateStack)
            
            durationAndDateStack.addArrangedSubview(durationLabel)
            durationAndDateStack.addArrangedSubview(dateLabel)
            addSubview(separatorLine)
            NSLayoutConstraint.activate([
                contentStack.heightAnchor.constraint(equalToConstant: 46),
                playButton.widthAnchor.constraint(equalToConstant: 44),
                playButton.heightAnchor.constraint(equalToConstant: 44),
                
                durationLabel.leftAnchor.constraint(equalTo: durationAndDateStack.leftAnchor),
                durationLabel.rightAnchor.constraint(equalTo: dateLabel.leftAnchor),
                dateLabel.rightAnchor.constraint(equalTo: durationAndDateStack.rightAnchor),
                
                separatorLine.leftAnchor.constraint(equalTo: durationAndDateStack.leftAnchor),
                separatorLine.rightAnchor.constraint(equalTo: rightAnchor),
                separatorLine.bottomAnchor.constraint(equalTo: bottomAnchor),
                separatorLine.heightAnchor.constraint(equalToConstant: 0.5),
                
                nameLabel.leftAnchor.constraint(equalTo: nameAndTimeStack.leftAnchor),
                timeAndDateLabel.leftAnchor.constraint(equalTo: nameLabel.rightAnchor),
                timeAndDateLabel.rightAnchor.constraint(equalTo: nameAndTimeStack.rightAnchor),
            ])
        }
        
        internal func configure(_ state: State, meters: [Float], loading: Bool, duration text: String, senderName: String, date: String, send_time: String, sizeInBytes: String) {
            durationLabel.text = text + ", " + sizeInBytes
            nameLabel.text = senderName
            timeAndDateLabel.text = date + ", " + send_time
            
            switch state {
            case .playing:
                playButton.setImage(imageLiteral("pause")?.withRenderingMode(.alwaysTemplate), for: .normal)
            case .paused:
                playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
            }
        }
    }
    
    var audioView = AudioView()
    internal var state: AudioCellPlayingState = .play
    internal var duration: TimeInterval = 0.0
    internal var lastPlayedDuration: TimeInterval = 0.0
    internal var date: String = ""
    internal var send_time: String = ""
    internal var sender: String = ""
    private var audioUrl = URL(string: "")
    var owner: String = ""
    var sizeInBytes: String = ""
    
    override func prepareForReuse() {
        super.prepareForReuse()
        audioView.removeFromSuperview()
        audioView = .init(frame: .zero)
    }
    
    func setup(url: URL, meters: [Float], date: String, send_time: String, senderName: String? = nil, owner: String? = nil, sizeInBytes: String) {
        self.owner = owner ?? ""
        self.sizeInBytes = sizeInBytes
        
        audioView.backgroundColor = .white
        audioView.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(audioView)
        makeConstraints()
        
        self.date = date
        self.send_time = send_time
        self.sender = senderName ?? ""

        self.audioUrl = url
        configure(meters: meters)
    }
    
    func configure(meters: [Float]) {
//        if reference.audioDuration != nil {
//            duration = reference.audioDuration!
//        }
        audioView.configure(.paused,
                            meters: meters,
                            loading: false,
                            duration: lastPlayedDuration.minuteFormatedString + " / " + duration.minuteFormatedString,
                            senderName: self.sender,
                            date: self.date,
                            send_time: send_time,
                            sizeInBytes: sizeInBytes)
        
        switch state {
        case .stop:
            audioView.loadingIndicator.removeFromSuperview()
            audioView.playButton.setImage(imageLiteral("play")?.withRenderingMode(.alwaysTemplate), for: .normal)
            deactivateDurationLabel()
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
            deactivateDurationLabel()
        }
    }
    
    func activateDurationLabel() {
        self.audioView.durationLabel.textColor = .systemBlue
    }
    
    func deactivateDurationLabel() {
        self.audioView.durationLabel.textColor = MDCPalette.grey.tint500
    }
    
    func update(state: AudioCellPlayingState) {
//        switch state {
//        case .play:
//            self.state = .pause
//            lastPlayedDuration = OpusAudio.shared.player?.currentTime ?? 0.0
//            duration = OpusAudio.shared.player?.duration ?? 0
//            audioView.playButton.setImage(imageLiteral( "pause").withRenderingMode(.alwaysTemplate), for: .normal)
//            OpusAudio.shared.player?.play()
//            activateDurationLabel()
//        case .pause:
//            self.state = .play
//            audioView.playButton.setImage(imageLiteral( "play").withRenderingMode(.alwaysTemplate), for: .normal)
//            OpusAudio.shared.player?.pause()
//            deactivateDurationLabel()
//        case .stop:
//            self.state = .play
//            audioView.playButton.setImage(imageLiteral( "play").withRenderingMode(.alwaysTemplate), for: .normal)
//            audioView.durationLabel.text = "\(TimeInterval(0).minuteFormatedString) / \(duration.minuteFormatedString), \(sizeInBytes)"
//        default: return
//        }
    }
    
    func setupOpusAudio() {
//        guard let url = audioUrl else { return }
//        if OpusAudio.shared.currentPlayedFileUri != url.absoluteString {
//            OpusAudio.shared.resetPlayer()
//        }
//        OpusAudio.shared.getPlayer(for: url)
    }
    
    func timerUpdateTask() {
//        guard let player = OpusAudio.shared.player else { return }
//        lastPlayedDuration = player.currentTime
//        audioView.durationLabel.text = lastPlayedDuration.minuteFormatedString + " / " + duration.minuteFormatedString + ", " + sizeInBytes
    }
    
    func reset() {
        update(state: .stop)
//        OpusAudio.shared.resetPlayer()
        deactivateDurationLabel()
    }
    
    func makeConstraints() {
        NSLayoutConstraint.activate([
            audioView.leftAnchor.constraint(equalTo: self.leftAnchor),
            audioView.topAnchor.constraint(equalTo: self.topAnchor),
            audioView.rightAnchor.constraint(equalTo: self.rightAnchor),
            audioView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }
    
    func editModeDisabled() {
        deselect()
    }
    
    func select() {
        audioView.playButton.backgroundColor = MDCPalette.grey.tint100
        audioView.backgroundColor = .systemGray5
    }
    
    func deselect() {
        audioView.playButton.backgroundColor = MDCPalette.grey.tint300
        audioView.backgroundColor = .white
    }
}


