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
import AVFoundation
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
import Kingfisher
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import AudioToolbox
import MediaPlayer
import WebRTC
import CryptoSwift


protocol VoIPCallManagerDelegate {
    func shouldDismiss()
    func didChangeState(to state: VoIPCall.State)
    func didChangeMyVideoMode(to state: VoIPCall.VideoState)
    func didChangeOpponentVideoMode(to state: VoIPCall.VideoState)
    func didChangeSpeakerState(to enabled: Bool)
    func didChangeMicState(to enabled: Bool)
}

class CallScreenViewController: BaseViewController {
    
    private var username: String = ""
        
    var accountPalette: MDCPalette = AccountColorManager.shared.topPalette()
    
    internal let initialAvatarSize: CGSize = CGSize(square: 152)
    
    open var shouldHideAppTabBar: Bool = false
    
    public var callState: BehaviorRelay<VoIPCall.State> = BehaviorRelay(value: .initiated)
    
    public var micEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    public var speakerEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    public var videoEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    public var remoteVideoEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    public var localVideoEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    public var anyoneVideoEnabled: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    public var previousSpeakerModeState: Bool = false
    
    internal var localRenderer: RTCEAGLVideoView? = nil
    internal var remoteRenderer: RTCEAGLVideoView? = nil
    
    internal var player: AVAudioPlayer? = nil
    internal var dualToneData: Data? = nil
    internal var dualToneBusyData: Data? = nil
    internal var playBusy: Bool = false
    internal var outgoing: Bool = false
    internal var connected: Bool = false
    
    internal var startCallDate: Date? = nil
    internal var callDurationTimer: Timer? = nil
    
    internal var videoSize: CGSize = .zero
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var isCollapsed: Bool = false
    
    internal var sid: String? = nil
    
    internal var backgroundView: CallScreenBackgroundView = {
        let view = CallScreenBackgroundView()
        
        return view
    }()
    
    internal var avatarView: UIImageView = {
        let view: UIImageView = UIImageView()
        view.image = imageLiteral( "dumb_avatar")?.withRenderingMode(.alwaysTemplate)
        view.tintColor = .secondaryLabel
        view.frame = CGRect(origin: .zero, size: CGSize(square: 128))
        view.contentMode = .scaleAspectFill
        return view
    }()
    
    internal let mainStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        
        stack.isLayoutMarginsRelativeArrangement = true
        let topStackPadding: CGFloat
        if #available(iOS 10, *) {
            topStackPadding = 0
        } else {
            topStackPadding = 10
        }
        stack.layoutMargins = UIEdgeInsets(top: topStackPadding, bottom: 16, left: 16, right: 16)
        
        return stack
    }()
    
    internal let topStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 8
        
        return stack
    }()
    
    internal let centralStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 32
        
        return stack
    }()
    
    internal let bottomStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .bottom
        stack.distribution = .equalSpacing
        
        return stack
    }()
    
    internal let statusStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 6
        
        return stack
    }()
    
    internal let buttonsStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.alignment = .top
        stack.distribution = .fillEqually
        stack.spacing = 24
        
        return stack
    }()
    
    internal let videoSwitchStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 20
        
        return stack
    }()
    
    internal let speakerSwitchStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 20
        
        return stack
    }()
    
    internal let localVideoView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        
        view.layer.cornerRadius = 4
        view.layer.masksToBounds = true
        
        return view
    }()
    
    internal let vendorLabel: UIButton = {
        let button = UIButton()
        button.setTitle("xabber call".localizeString(id: "chat_xabber_call_hint", arguments: [])
                            .uppercased(), for: .normal)
        button.setImage(imageLiteral( "security")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = UIColor(red:1, green:1, blue:1, alpha:0.0)
        button.titleLabel?.performLayout(as: .vendorLabel)
        return button
    }()
    
    internal let usernameLabel: UILabel = {
        let label = UILabel()
        
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 0
        label.textColor = UIColor(red:1, green:1, blue:1, alpha:0.87)
        label.textAlignment = .center
        
        return label
    }()
    
    internal let statusLabel: UILabel = {
        let label = UILabel()
        
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 0
        label.textColor = UIColor(red:1, green:1, blue:1, alpha:0.87)
        label.textAlignment = .center
        
        return label
    }()
    
    internal let jidLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        label.textColor = UIColor.white.withAlphaComponent(0.87)
        
        return label
    }()
    
    internal let endCallSwitchStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 20
        
        return stack
    }()
    
    internal let micSwitchStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = 20
        
        return stack
    }()
    
    internal var videoModeSwitch: UIButton = {
        let button = UIButton(frame: CGRect(square: 64))
        button.setImage(imageLiteral( "video-off")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.performLayout(isEndCall: false)
        return button
    }()
    
    internal var speakerModeSwitch: UIButton = {
        let button = UIButton(frame: CGRect(square: 64))
        button.setImage(imageLiteral( "volume-high")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.performLayout(isEndCall: false)
        return button
    }()
    
    internal var micModeSwitch: UIButton = {
        let button  = UIButton(frame: CGRect(square: 64))
        button.setImage(imageLiteral( "microphone")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.performLayout(isEndCall: false)
        return button
    }()
    
    internal var cameraModeSwitch: UIButton = {
        let button = UIButton(frame: CGRect(square: 64))
        button.setImage(imageLiteral( "camera-retake")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.performLayout(isEndCall: false)
        button.isHidden = true
        return button
    }()
    
    internal var endCallButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 64))
        button.setImage(imageLiteral( "phone-hangup")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.performLayout(isEndCall: true)
        return button
    }()
        
    internal var switchCameraButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 44))
        button.setImage(imageLiteral( "camera-retake")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.imageEdgeInsets = UIEdgeInsets(top: 8, bottom: 8, left: 8, right: 8)
        button.backgroundColor = .clear
        button.tintColor = UIColor.white.withAlphaComponent(0.75)
        button.isHidden = true
        return button
    }()
    
    internal var speakerModeSwitchAdd: UIButton = {
        let button = UIButton(frame: CGRect(square: 40))
        button.setImage(imageLiteral( "baseline_speaker_light_white_48pt")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.imageEdgeInsets = UIEdgeInsets(top: 6, bottom: 6, left: 6, right: 6)
        button.tintColor = UIColor.white.withAlphaComponent(0.85)
        button.isHidden = true
        return button
    }()
    
    private func loadLabels() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                usernameLabel.text = instance.displayName
                usernameLabel.performLayout(as: .usernameLabel)
                username = instance.displayName
            } else {
                usernameLabel.text = jid
                usernameLabel.performLayout(as: .usernameLabel)
                username = jid
            }
        } catch {
            DDLogDebug("CallScreenViewController: \(#function), \(error.localizedDescription)")
        }
    }
    
    func loadAvatar() {
        let avatarImageView = UIImageView(frame: CGRect(x: 4,
                                                        y: 4,
                                                        width: initialAvatarSize.width - 8,
                                                        height: initialAvatarSize.height - 8))
        avatarImageView.contentMode = .scaleAspectFill
        DefaultAvatarManager.shared.getAvatar(url: nil, jid: self.jid, owner: self.owner, size: 144) { image in
            if let image = image {
                avatarImageView.image = image
            } else {
                avatarImageView.image = UIImageView.getDefaultAvatar(for: self.jid, owner: self.owner, size: 144)
            }
        }
        layoutAvatarSubview(avatarImageView)
        avatarView.addSubview(avatarImageView)
        layoutAvatar()
    }
    
    private func layoutAvatarSubview(_ view: UIView) {
        view.layer.masksToBounds = false
        view.layer.borderWidth = 0
        view.layer.masksToBounds = true
        view.layer.cornerRadius = (initialAvatarSize.width - 8) / 2
        view.clipsToBounds = true
    }
    
    private func layoutAvatar() {
        self.avatarView.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        self.avatarView.layer.masksToBounds = false
        self.avatarView.layer.borderWidth = 0
        self.avatarView.layer.masksToBounds = true
        self.avatarView.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        if let image = UIImage(named: AccountMasksManager.shared.mask128pt), AccountMasksManager.shared.load() != "square" {
            self.avatarView.mask = UIImageView(image: image)
        } else {
            self.avatarView.mask = nil
        }
        self.avatarView.clipsToBounds = true
        self.avatarView.layoutIfNeeded()
    }
    
    private func startTimeUpdate() {
        if callDurationTimer != nil { return }
        callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true, block: { (_) in
            let timeString: String
            if let date = self.startCallDate {
                timeString = Date().timeIntervalSince(date).minuteFormatedString
            } else {
                timeString = ""
            }
            if timeString.isNotEmpty {
                self.statusLabel.text = "\(timeString)"
            }
            self.statusLabel.performLayout(as: self.isCollapsed ? .statusLabelSmall : .statusLabel)
        })
    }
    
    private func endTimeUpdate() {
        callDurationTimer?.invalidate()
        callDurationTimer = nil
    }
    
    private func playLineBusy() {
        if outgoing && !connected {
            playBusy = true
            dualToneBusyData = NSDataAsset(name: "phone_busy")?.data
            guard dualToneBusyData != nil else { return }
            player?.stop()
            do {
                self.player = try AVAudioPlayer(data: self.dualToneBusyData!, fileTypeHint: "wav")
                self.player?.numberOfLoops = 1
                self.player?.prepareToPlay()
                self.player?.play()
            } catch {
                DDLogDebug("cant create audio player for dual tone")
            }
        }
    }
    
    private func playDualTone() {
        dualToneData = NSDataAsset(name: "phone_dt_ants")?.data
        guard dualToneData != nil else { return }
        do {
            self.player = try AVAudioPlayer(data: dualToneData!, fileTypeHint: "mp3")
            self.player?.numberOfLoops = 30
            self.player?.prepareToPlay()
            self.player?.play()
        } catch {
            DDLogDebug("cant create audio player for dual tone")
        }
    }
    
    private func playConnecting() {
        dualToneData = NSDataAsset(name: "phone_connecting")?.data
        player?.stop()
        guard dualToneData != nil else { return }
        do {
            self.player = try AVAudioPlayer(data: dualToneData!, fileTypeHint: "wav")
            self.player?.numberOfLoops = 30
            self.player?.prepareToPlay()
            self.player?.play()
        } catch {
            DDLogDebug("cant create audio player for dual tone")
        }
    }
    
    private func updateLocalVideoRenderer(enabled: Bool) {
//        switchCameraButton.frame = CGRect(x: view.frame.maxX - 60, y: 22, width: 40, height: 40)
//        switchCameraButton.isHidden = !enabled
        if self.remoteVideoEnabled.value {
            self.localVideoView.isHidden = false
            self.localRenderer?.removeFromSuperview()
            VoIPManager.shared.disableLocalVideo(nil)
        } else {
            self.localVideoView.isHidden = true
            self.collapse(reverse: !enabled)
        }
        UIView.animate(withDuration: 0.33) {
            self.updateLocalVideoView(hide: !enabled)
            if enabled {
                if self.remoteVideoEnabled.value {
                    let localRenderer = RTCEAGLVideoView(frame: self.localVideoView.bounds)
                    localRenderer.contentMode = .scaleAspectFill
                    VoIPManager.shared.enableLocalVideo(localRenderer)
                    self.localVideoView.addSubview(localRenderer)
                    localRenderer.fillSuperview()
                    self.localRenderer = localRenderer
                } else {
                    let localRenderer = RTCEAGLVideoView(frame: .zero)
                    localRenderer.restorationIdentifier = "videoRenderer"
                    VoIPManager.shared.enableLocalVideo(localRenderer)
                    
                    self.view.insertSubview(localRenderer, aboveSubview: self.backgroundView)
                    localRenderer.delegate = self
                    self.localRenderer = localRenderer
                }
            } else {
                self.localRenderer?.removeFromSuperview()
                VoIPManager.shared.disableLocalVideo(nil)
            }
        }
    }
    
    private func updateRemoteVideoRenderer(enabled: Bool) {
        if self.localVideoEnabled.value {
            self.updateLocalVideoRenderer(enabled: self.localVideoEnabled.value)
        }
        if enabled {
            let remoteRenderer = RTCEAGLVideoView(frame: .zero)
            remoteRenderer.restorationIdentifier = "videoRenderer"
            VoIPManager.shared.enableRemoteVideo(remoteRenderer)
            self.view.insertSubview(remoteRenderer, aboveSubview: backgroundView)
//            remoteRenderer.delegate = self
            self.remoteRenderer = remoteRenderer
        } else {
            if self.remoteRenderer != nil {
                self.remoteRenderer?.removeFromSuperview()
                VoIPManager.shared.disableRemoteVideo(self.remoteRenderer!, completionHandler: nil)
            }
        }
    }
    
    private func updateAvatarVisibility(hide: Bool) {
        UIView.animate(withDuration: 0.33) {
            self.avatarView.alpha = hide ? 0.0 : 1.0
        }
    }
    
    private func subscribeStates() {
        VoIPManager.shared
            .cameraResolution
            .asObservable()
            .subscribe(onNext: { (resolution) in
                DispatchQueue.main.async {
                    let height = self.view.frame.height / 5
                    let width: CGFloat
                    switch UIDevice.current.orientation {
                    case .portraitUpsideDown, .portrait:
                        width = height * CGFloat(resolution.verticalAspectRatio)
                    case .landscapeLeft, .landscapeRight:
                        width = height * CGFloat(resolution.horizontalAspectRatio)
                    default:
                        width = (height / 4) * 3
                        break
                    }
                    let origin = self.localVideoView.frame.origin
                    UIView.animate(withDuration: 0.33, animations: {
                        self.localVideoView.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
                    })
                }
            })
            .disposed(by: bag)

        micEnabled.asObservable()
            .subscribe(onNext: { (value) in
                if value {
                    VoIPManager.shared.enableAudio()
                    self.micModeSwitch.setImage(imageLiteral( "microphone")?.withRenderingMode(.alwaysTemplate), for: .normal)
                } else {
                    VoIPManager.shared.disableAudio()
                    self.micModeSwitch.setImage(imageLiteral( "microphone-off")?.withRenderingMode(.alwaysTemplate), for: .normal)
                }
                UIView.animate(withDuration: 0.33, animations: {
                    self.micModeSwitch.setActive(value)
                })
            })
            .disposed(by: bag)

        speakerEnabled.asObservable()
            .subscribe(onNext: { (value) in
                UIView.animate(withDuration: 0.33, animations: {
                    self.speakerModeSwitch.setActive(value)
                })
                if value {
                    self.speakerModeSwitchAdd.alpha = 1.0
                    SoundManager.changeAudioPort(.speaker)
                    self.speakerModeSwitch.setImage(imageLiteral( "volume-high")?.withRenderingMode(.alwaysTemplate), for: .normal)
                } else {
                    self.speakerModeSwitchAdd.alpha = 0.6
                    SoundManager.changeAudioPort(.initial)
                    self.speakerModeSwitch.setImage(imageLiteral( "volume-low")?.withRenderingMode(.alwaysTemplate), for: .normal)
                }
            })
            .disposed(by: bag)

        videoEnabled
            .asObservable()
            .subscribe(onNext: { (value) in
                print("video enabled: \(value)")
                UIView.animate(withDuration: 0.33, animations: {
                    self.videoModeSwitch.setActive(value)
                })
                if value {
                    VoIPManager.shared.enableVideo()
                    self.speakerModeSwitch.setImage(imageLiteral( "video-off")?.withRenderingMode(.alwaysTemplate), for: .normal)
                } else {
                    VoIPManager.shared.disableVideo()
                    self.speakerModeSwitch.setImage(imageLiteral( "video")?.withRenderingMode(.alwaysTemplate), for: .normal)
                }
            })
            .disposed(by: bag)
        
        anyoneVideoEnabled
            .asObservable()
            .subscribe(onNext: { (value) in
                if value {
                    self.previousSpeakerModeState = self.speakerEnabled.value
                    self.speakerEnabled.accept(true)
                } else {
                    self.speakerEnabled.accept(self.previousSpeakerModeState)
                }
            })
            .disposed(by: bag)
        
        localVideoEnabled.subscribe(onNext: { (value) in
            if value {
                if !self.anyoneVideoEnabled.value {
                    self.anyoneVideoEnabled.accept(true)
                }
            } else {
                if !self.remoteVideoEnabled.value {
                    self.anyoneVideoEnabled.accept(false)
                }
            }
        })
        .disposed(by: bag)

        remoteVideoEnabled.subscribe(onNext: { (value) in
            if value {
                if !self.anyoneVideoEnabled.value {
                    self.anyoneVideoEnabled.accept(true)
                }
            } else {
                if !self.localVideoEnabled.value {
                    self.anyoneVideoEnabled.accept(false)
                }
            }
        })
        .disposed(by: bag)

        callState.asObservable().debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance).subscribe { state in
            print(state, "observable")
            switch state {
            case .initiated:
                self.statusLabel.text = "Calling..."
                    .localizeString(id: "dialog_jingle_message__status_calling", arguments: [])
                self.backgroundView.update(.calling, animate: true)
            case .proposed:
                self.playDualTone()
                self.statusLabel.text = "Calling..."
                    .localizeString(id: "dialog_jingle_message__status_calling", arguments: [])
                self.backgroundView.update(.calling, animate: true)
            case .confirmed:
                self.statusLabel.text = "Calling..."
                    .localizeString(id: "dialog_jingle_message__status_calling", arguments: [])
                self.backgroundView.update(.calling, animate: true)
            case .notConfirmed:
                break
            case .accepted:
                self.playConnecting()
                self.statusLabel.text = "Connecting..."
                    .localizeString(id: "dialog_jingle_message__status_connecting", arguments: [])
                self.backgroundView.update(.calling, animate: true)
            case .connecting:
                self.statusLabel.text = "Connecting..."
                    .localizeString(id: "dialog_jingle_message__status_connecting", arguments: [])
                self.backgroundView.update(.connecting, animate: true)
            case .connected:
                self.player?.stop()
                FeedbackManager.shared.generate(feedback: .success)
//                if self.initalCallType == .video {
//                    self.videoEnabled.value = true
//                }
                if self.startCallDate == nil {
                    self.startCallDate = Date()
                }
//                self.statusLabel.text = "Connected"
                self.backgroundView.update(.connected, animate: true)
                self.startTimeUpdate()
            case .disconnected:
                FeedbackManager.shared.generate(feedback: .error)
                self.statusLabel.text = "Disconnected"
                    .localizeString(id: "dialog_jingle_message__status_disconnected", arguments: [])
                self.statusLabel.layoutIfNeeded()
                if self.isCollapsed {
                    self.remoteVideoEnabled.accept(false)
                    self.localVideoEnabled.accept(false)
                    self.updateLocalVideoRenderer(enabled: false)
                    self.updateRemoteVideoRenderer(enabled: false)
                    self.collapse(reverse: true)
                }
                self.backgroundView.update(.disconnected, animate: true)
            case .holded:
                break
            case .ended:
                self.startCallDate = nil
                self.statusLabel.text = "Call ended"
                    .localizeString(id: "dialog_jingle_message__status_ended", arguments: [])
                self.statusLabel.layoutIfNeeded()
//                self.micSwitchStack.isHidden = true
//                self.videoModeSwitch.isHidden = true
//                self.speakerModeSwitch.isHidden = true
//                self.endCallButton.setImage(imageLiteral( "security").withRenderingMode(.alwaysTemplate), for: .normal)
                self.backgroundView.update(.rejected, animate: true)
                if self.isCollapsed {
                    self.updateLocalVideoRenderer(enabled: false)
                    self.updateRemoteVideoRenderer(enabled: false)
                    self.collapse(reverse: true)
                }
            }
        } onError: { error in
            
        } onCompleted: {
            
        } onDisposed: {
            
        }.disposed(by: bag)

        
    }
    
    private func subscribeControls() {
        endCallButton.rx.tap.bind {
//            DispatchQueue.main.async {
                print("end call")
                VoIPManager.shared.endCall()
                self.dismiss(animated: true, completion: {
                    self.unsubscribeStates()
                    self.unsubscribeControls()
                })
//            }
        }
        .disposed(by: bag)
        
        micModeSwitch.rx.tap.bind {
            self.micEnabled.accept(!self.micEnabled.value)
        }
        .disposed(by: bag)
        
        speakerModeSwitch.rx.tap.bind {
            self.speakerEnabled.accept(!self.speakerEnabled.value)
        }
        .disposed(by: bag)
        
        speakerModeSwitchAdd.rx.tap.bind {
            self.speakerEnabled.accept(!self.speakerEnabled.value)
        }
        .disposed(by: bag)
        
        videoModeSwitch.rx.tap.bind {
            self.videoEnabled.accept(!self.videoEnabled.value)
        }
        .disposed(by: bag)
        
        cameraModeSwitch.rx.tap.bind {
            if self.localRenderer != nil {
                VoIPManager.shared.switchCamera(local: self.localRenderer!)
            }
        }.disposed(by: bag)
        
        switchCameraButton.rx.tap.bind {
            if self.localRenderer != nil {
                VoIPManager.shared.switchCamera(local: self.localRenderer!)
            }
        }.disposed(by: bag)
    }
    
    private func unsubscribeStates() {
        self.bag = DisposeBag()
    }
    
    private func unsubscribeControls() {
        
    }
    
    private func activateConstraints() {
        [videoModeSwitch, cameraModeSwitch, speakerModeSwitch, micModeSwitch, endCallButton].forEach {
            $0.collapse(animate: false, reverse: true)
        }
        avatarView.widthAnchor.constraint(equalToConstant: initialAvatarSize.width).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: initialAvatarSize.height).isActive = true
        
        videoSwitchStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        speakerSwitchStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        micSwitchStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
    }
    
    private func updateLocalVideoView(hide: Bool) {
        let resolution = VoIPManager.shared.cameraResolution.value
        
        let height = self.view.frame.height / 6
        let width: CGFloat = (height * CGFloat(resolution.width)) / CGFloat(resolution.height)
        let frameSize = CGSize(width: width, height: height)
        let origin: CGPoint
        localVideoView.layer.cornerRadius = 2
        localVideoView.clipsToBounds = true
        if hide {
            origin = CGPoint(x: self.view.frame.width + 16,
                                 y: self.view.frame.height - frameSize.height - 96)
        } else {
            origin = CGPoint(x: self.view.frame.width - frameSize.width - 16,
                                 y: self.view.frame.height - frameSize.height - 96)
        }
        localVideoView.frame = CGRect(origin: origin, size: frameSize)
    }
    
    private func collapse(reverse: Bool = false) {
        func findLabel(in stack: UIStackView) -> UILabel? {
            for item in stack.arrangedSubviews {
                if let label = item as? UILabel {
                    return label
                }
            }
            return nil
        }
        isCollapsed = !reverse
        
        self.statusStack.spacing = reverse ? 6 : 4
        [videoSwitchStack, speakerSwitchStack, micSwitchStack].forEach { findLabel(in: $0)?.isHidden = !reverse }
        self.speakerModeSwitch.isHidden = !reverse
        self.cameraModeSwitch.isHidden = reverse
//        speakerModeSwitch.collapse(animate: true, reverse: reverse)
        UIView.animateKeyframes(withDuration: 0.35, delay: 0, options: [], animations: {
//            self.speakerModeSwitch.colla
            self.topStack.isHidden = !reverse
            self.topStack.layoutIfNeeded()
//            self.bottomStack.isHidden = !reverse
            self.bottomStack.layoutIfNeeded()
        }, completion: {
            result in
        })
        
    }
    
    private func configureButtonsStack() {
        func createLabel(with text: String) -> UILabel {
            let label = UILabel()
            label.text = text
            label.performLayout(as: .buttonsLabel)
            return label
        }
        
        videoSwitchStack.addArrangedSubview(videoModeSwitch)
        speakerSwitchStack.addArrangedSubview(speakerModeSwitch)
        speakerSwitchStack.addArrangedSubview(cameraModeSwitch)
        micSwitchStack.addArrangedSubview(micModeSwitch)
        endCallSwitchStack.addArrangedSubview(endCallButton)
        buttonsStack.addArrangedSubview(micSwitchStack)
        buttonsStack.addArrangedSubview(videoSwitchStack)
        buttonsStack.addArrangedSubview(speakerSwitchStack)
        buttonsStack.addArrangedSubview(endCallSwitchStack)
        cameraModeSwitch.setActive(true)
    }
    
    private func configure() {
        backgroundView.update(.calling, animate: false)
        view.addSubview(backgroundView)
        backgroundView.fillSuperview()
        view.backgroundColor = .blue
        view.addSubview(mainStack)
        mainStack.fillSuperview()
        topStack.addArrangedSubview(vendorLabel)
        configureButtonsStack()
        statusLabel.text = "Start call".localizeString(id: "dialog_jingle_message__status_start_call", arguments: [])
        statusLabel.performLayout(as: .statusLabel)
        [usernameLabel, statusLabel].forEach { statusStack.addArrangedSubview($0) }
        centralStack.addArrangedSubview(statusStack)
        centralStack.addArrangedSubview(avatarView)
//        centralStack.addArrangedSubview(buttonsStack)
        jidLabel.text = jid
        bottomStack.addArrangedSubview(buttonsStack)
        [topStack, centralStack, bottomStack].forEach { mainStack.addArrangedSubview($0) }
        updateLocalVideoView(hide: true)
        view.addSubview(localVideoView)
        view.addSubview(switchCameraButton)
        view.addSubview(speakerModeSwitchAdd)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        if #available(iOS 11, *) {
            let guide = view.safeAreaLayoutGuide
            print(guide)
            mainStack.layoutMargins = UIEdgeInsets(top: 6, bottom: 16, left: 16, right: 16)
        } else {
            mainStack.layoutMargins = UIEdgeInsets(top: 20, bottom: 16, left: 16, right: 16)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        subscribeStates()
        subscribeControls()
        self.navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    override func reloadDatasource() {
        if let image = UIImage(named: AccountMasksManager.shared.mask128pt), AccountMasksManager.shared.load() != "square" {
            avatarView.mask = UIImageView(image: image)
        } else {
            avatarView.mask = nil
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activateConstraints()
        backgroundView.jid = jid
        backgroundView.owner = owner
        loadLabels()
        loadAvatar()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribeStates()
        unsubscribeControls()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}

private extension UIButton {
    
    func performLayout(isEndCall: Bool) {
        self.layer.cornerRadius = self.frame.width / 2
        self.layer.borderWidth = 0
        self.layer.masksToBounds = true
        self.clipsToBounds = true
        self.backgroundColor = isEndCall ? .red : UIColor.white.withAlphaComponent(0.2)
        self.tintColor = MDCPalette.blueGrey.tint50.withAlphaComponent(0.75)
        self.imageEdgeInsets = UIEdgeInsets(top: 12, bottom: 12, left: 12, right: 12)
    }
    
    func setActive(_ value: Bool) {
        self.backgroundColor = value ? UIColor.white.withAlphaComponent(0.8) : UIColor.white.withAlphaComponent(0.2)
        self.tintColor = value ? MDCPalette.blueGrey.tint500.withAlphaComponent(0.75) : MDCPalette.blueGrey.tint50.withAlphaComponent(0.75)
    }
    
    func collapse(animate: Bool, reverse: Bool = false) {
        func animateSet() {
            if !reverse {
                print(self.constraints)
                self.widthAnchor.constraint(equalToConstant: 0).isActive = true
                self.heightAnchor.constraint(equalToConstant: 0).isActive = true
            } else {
                print(self.constraints)
                self.widthAnchor.constraint(equalToConstant: 64).isActive = true
                self.heightAnchor.constraint(equalToConstant: 64).isActive = true
            }
        }
        if animate {
            UIView.animate(withDuration: 0.33) {
                self.alpha = reverse ? 1.0 : 0.0
                self.isHidden = !reverse
            }
        } else {
            animateSet()
        }
    }
}

private extension UILabel {
    
    enum Layout {
        case buttonsLabel
        case vendorLabel
        case usernameLabel
        case usernameLabelSmall
        case statusLabel
        case statusLabelSmall
        case jidLabel
        case fingerprint
    }
    
    func performLayout(as layout: Layout) {
        var textContent = text ?? ""
        self.lineBreakMode = .byWordWrapping
        self.numberOfLines = 0
        switch layout {
        case .buttonsLabel:
            self.textColor = UIColor.white
            self.alpha = 0.75
            self.textAlignment = .center
            let textString = NSMutableAttributedString(string: textContent, attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.14
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            self.attributedText = textString
        case .vendorLabel:
            self.textColor = UIColor.white.withAlphaComponent(0.87)
            self.textAlignment = .center
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 16, weight: .medium)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.14
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.15, range: textRange)
            self.attributedText = textString
        case .usernameLabel:
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 24, weight: .medium)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.21
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.5, range: textRange)
            self.attributedText = textString
        case .statusLabel:
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 15, weight: .regular)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.2
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.5, range: textRange)
            self.attributedText = textString
        case .jidLabel:
            break
        case .usernameLabelSmall:
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 15, weight: .medium)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.21
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.5, range: textRange)
            self.attributedText = textString
        case .statusLabelSmall:
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 12, weight: .regular)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.2
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.5, range: textRange)
            self.attributedText = textString
        case .fingerprint:
            if textContent.count > 34 {
                textContent = String(textContent.prefix(34) + "...")
            }
            let textString = NSMutableAttributedString(string: textContent, attributes: [
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 12, weight: .medium)
                ])
            let textRange = NSRange(location: 0, length: textString.length)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 1.21
            textString.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
            textString.addAttribute(NSAttributedString.Key.kern, value: -0.5, range: textRange)
            self.attributedText = textString
            self.lineBreakMode = .byTruncatingTail
        }
        self.sizeToFit()
    }
    
}

extension CallScreenViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
    
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        
    }
    
    func popoverPresentationControllerShouldDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) -> Bool {
        return true
    }
}

extension CallScreenViewController: RTCVideoViewDelegate {
    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        self.videoSize = size
        if let videoView = self.view.subviews.first(where: { $0.restorationIdentifier == "videoRenderer" }) {
            if (self.videoSize.width > 0 && self.videoSize.height > 0) {
                
                let frameSize = UIScreen.main.bounds.size//  view.frame.size
                var scale: CGFloat = 1
                if frameSize.height > videoSize.height {
                    scale = frameSize.height / videoSize.height
                } else if frameSize.width > videoSize.width {
                    scale = videoSize.width / frameSize.width
                } else {
                    videoView.frame = CGRect(origin: .zero, size: size)
                }
                var videoFrame: CGRect = .zero
                videoFrame.size.width = size.width * scale
                videoFrame.size.height = size.height * scale
                videoView.frame = videoFrame
                videoView.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            } else {
                videoView.frame = view.bounds
            }
        }
    }
}

extension CallScreenViewController: VoIPCallManagerDelegate {
    func didChangeOpponentVideoMode(to state: VoIPCall.VideoState) {
        self.remoteVideoEnabled.accept(state == .enabled)
        DispatchQueue.main.async {
            switch state {
            case .enabled:
                self.collapse()
                self.updateAvatarVisibility(hide: true)
                self.updateRemoteVideoRenderer(enabled: true)
            case .disabled:
                self.collapse(reverse: true)
                if !self.localVideoEnabled.value {
                    self.updateAvatarVisibility(hide: false)
                }
                self.updateRemoteVideoRenderer(enabled: false)
            }
        }
    }
    
    func didChangeMyVideoMode(to state: VoIPCall.VideoState) {
        self.localVideoEnabled.accept(state == .enabled)
        DispatchQueue.main.async {
            switch state {
            case .enabled:
                self.updateAvatarVisibility(hide: true)
                self.updateLocalVideoRenderer(enabled: true)
                break
            case .disabled:
                self.updateLocalVideoRenderer(enabled: false)
                if !self.remoteVideoEnabled.value {
                    self.updateAvatarVisibility(hide: false)
                }
                break
            }
        }
    }
    
    func didChangeState(to state: VoIPCall.State) {
        callState.accept(state)
    }
    
    func shouldDismiss() {
        self.dismiss(animated: true, completion: nil)
    }
    
    func didChangeSpeakerState(to enabled: Bool) {
        self.speakerEnabled.accept(enabled)
    }
    
    func didChangeMicState(to enabled: Bool) {
        self.micEnabled.accept(enabled)
    }
}
