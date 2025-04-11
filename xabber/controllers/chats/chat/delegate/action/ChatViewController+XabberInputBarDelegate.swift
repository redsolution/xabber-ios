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
import Kingfisher
import Realm
import YubiKit
import CocoaLumberjack
import AVFoundation


extension ChatViewController: UIPickerViewDelegate {
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
//        print(row)
        self.selectedAfterburnId = row
    }
}


extension ChatViewController: UIPickerViewDataSource {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return ChatMarkersManager.BurnMessagesTimerValues.allVerboseValues().count
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return ChatMarkersManager.BurnMessagesTimerValues.allVerboseValues()[row]
    }
    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat {
        return 32
    }
}

extension ChatViewController: XabberInputBarDelegate {
    
    
    func didReceiveRecordButtonPositionChange(to point: CGPoint) {
        print(#function, point)
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        var pos: CGFloat = point.y
        if pos > 24.0 {
            pos = 0
        }
        
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight + pos),
            size: CGSize(square: 38)
        )
    }
    
    func lockIndicatorShouldLock() {
        self.recordLockIndicator.removeTarget(self, action: #selector(onRecordLockIndicatorPauseActionTapped), for: .touchUpInside)
//        UIView.animate(withDuration: 0.33) {
        self.recordLockIndicator.setImage(imageLiteral("lock.fill"), for: .normal)
//        }
//        FeedbackManager.shared.tap()
    }
    
    func lockIndicatorShouldStop() {
        self.recordLockIndicator.addTarget(self, action: #selector(onRecordLockIndicatorPauseActionTapped), for: .touchUpInside)
        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.3,
            options: [.curveEaseInOut]) {
                self.recordLockIndicator.setImage(imageLiteral("stop.fill"), for: .normal)
                var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
                self.recordLockIndicator.frame = CGRect(
                    origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight),//52
                    size: CGSize(square: 38)
                )
            } completion: { _ in
                
            }
    }
    
    func onSendButtonTouchUpInsideWhenAudioWasRecorded() {
        self.shouldSendAudioMessage() {
            self.xabberInputView.resetStateAfterRecord()
            self.xabberInputView.changeSendButtonState(to: .record)
            self.xabberInputView.changeState(to: .normal)
            self.recordedReferenceObject = nil
        }
    }
    
    func lockIndicatorShouldUnlock() {
        self.recordLockIndicator.removeTarget(self, action: #selector(onRecordLockIndicatorPauseActionTapped), for: .touchUpInside)
//        UIView.animate(withDuration: 0.33) {
        self.recordLockIndicator.setImage(imageLiteral("lock.open.fill"), for: .normal)
//        }
        
//        FeedbackManager.shared.tap()
    }
    
    @objc
    func onMeteringLevelDidUpdate(_ notification: Notification) {
        guard let percentage: Float = notification.userInfo?[AudioRecorder.audioPercentageUserInfoKey] as? Float else {
            return
        }
//        print("PERCENTAGE", percentage)
        self.recordedPCM.append(percentage)
    }
    
    func recordAndPlayPanelDeleteButtonTouchUp() {
        self.recordedReferenceObject = nil
        AudioManager.shared.player?.stop()
        AudioManager.shared.player = nil
        self.xabberInputView.resetStateAfterRecord()
        self.hideSharedAudioPanel()
        self.sharedPlayerPaneldelegae?.shouldHide()
        self.recordLockIndicator.isHidden = true
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight),
            size: CGSize(square: 38)
        )
        self.xabberInputView.resetStateAfterRecord()
//        self.xabberInputView.isSendButtonEnabled = false
        self.xabberInputView.changeSendButtonState(to: .record)
        self.xabberInputView.changeState(to: .normal)
        self.recordedReferenceObject = nil
        do {
            try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        FeedbackManager.shared.generate(feedback: .success)
    }
    
    func didStopPlayingAudio() {
        AudioManager.shared.player = nil
        self.currentPlayingUrl = nil
        self.hideSharedAudioPanel()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func recordAndPlayPanelPlayButtonTouchUp() {
        func play(url: URL?) throws {
            AudioManager.shared.player?.stop()
            self.currentPlayingView?.resetState()
            self.currentPlayingView?.waveform.reset()
            if let url = url, let data = try AudioManager.shared.load(url) {
                AudioManager.shared.player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.m4a.rawValue)
                AudioManager.shared.currentPlayingTitle = self.ownerSender.displayName
                AudioManager.shared.currentPlayingSubtitle = "Voice Message"
                self.xabberInputView.recordAndPlayPanel.play(for: AudioManager.shared.player?.duration ?? 0)
                AudioManager.shared.addMulticastDelegate(self.xabberInputView)
                AudioManager.shared.addMulticastDelegate(self.sharedAudioPlayerPanel)
                self.currentPlayingUrl = url
                self.xabberInputView.recordAndPlayPanel.playButton.setImage(imageLiteral("pause.fill"), for: .normal)
            } else {
                throw AudioManager.AudioManagerError.fileNotFound
            }
            AudioManager.shared.player?.play()
            self.configureSharedAudioPanel()
            self.sharedAudioPlayerPanel?.swapState(to: .playing)
        }
        let url = self.recordedReferenceObject?.decodedUrl
        do {
            if AudioManager.shared.player == nil {
                try play(url: url)
            } else {
                if (AudioManager.shared.player?.isPlaying ?? false) {
                    if self.currentPlayingUrl == url {
                        AudioManager.shared.player?.pause()
                        self.xabberInputView.recordAndPlayPanel.pause()
                        self.sharedAudioPlayerPanel?.swapState(to: .paused)
                    } else {
                        try play(url: url)
                    }
                    
                } else {
                    if self.currentPlayingUrl == url {
                        AudioManager.shared.player?.play()
                        self.xabberInputView.recordAndPlayPanel.continuePlay()
                        self.sharedAudioPlayerPanel?.swapState(to: .playing)
                    } else {
                        try play(url: url)
                    }
                }
            }
        } catch {
            self.view.makeToast("Unable to play sound at the moment, please try again".localizeString(id: "audio_error_play_failed", arguments: []))
        }
    }
    
    @objc
    func onRecordLockIndicatorPauseActionTapped(_ sender: UIButton) {
        self.onAudioMessageDidStop()
    }
    
    func onAudioMessageDidStop() {
        self.recordLockIndicator.isHidden = true
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight),
            size: CGSize(square: 38)
        )
        do {
            try AudioRecorder.shared.stopRecording(cancel: false, shouldSend: false)
            FeedbackManager.shared.generate(feedback: .success)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func resetRecordState() {
        do { try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false) } catch {  }
        self.xabberInputView.cancelRecord()
        self.recordLockIndicator.isHidden = true
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight),
            size: CGSize(square: 38)
        )
        self.recordedReferenceObject = nil
        self.recordedPCM = []
    }
    
    func didSetAudioPositionBar(percentage: Float) -> TimeInterval {
        guard let duration = AudioManager.shared.player?.duration else {
            return 0
        }
//        AudioManager.shared.removeMulticastDelegate(self.currentPlayingView)
        let position: TimeInterval = TimeInterval(Float(duration) * percentage)
        AudioManager.shared.player?.currentTime = position
//        AudioManager.shared.addMulticastDelegate(self.currentPlayingView)
        let newDuration = position
        return newDuration
    }
    
    func onAudioMessageStartRecord() {
        func fail(message: String?) {
            if let message = message {
                DispatchQueue.main.async {
                    self.view.makeToast(message)
                }
            }
            self.resetRecordState()
        }
        func updateRecordLockFrame() {
            var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
            self.recordLockIndicator.frame = CGRect(
                origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 100 - inputHeight),
                size: CGSize(square: 38)
            )
        }
        FeedbackManager.shared.generate(feedback: .success)
        self.recordLockIndicator.isHidden = false
        updateRecordLockFrame()
        
        
        print("panGestureRecognizerSelector", #function)
        self.recordedPCM = []
        AudioRecorder.shared.askPermission { granted, requested in
            if granted {
//                self.xabberInputView.changeState(to: .record)
//                self.xabberInputView.sendButton.showPulse()
                self.xabberInputView.recordPanel.resetAndStart()
            
                AudioRecorder.shared.startRecording(visualNotificationFreq: 0.01) { url, error, shouldSend in
                    do {
                        if let rawUrl = url {
                            let unwrUrl = URL(fileURLWithPath: rawUrl.absoluteString)
//                            let encodedUrl = try AudioMessageReceiver.shared.encode(url: rawUrl)
//                            let decodedUrl = try AudioMessageReceiver.shared.decode(url: encodedUrl)
                            
                            let data = try Data(contentsOf: unwrUrl)
                            AudioManager.shared.cache(rawUrl, data: data)
                            let pcm = self.recordedPCM//try AudioMessageReceiver.shared.getPCM(decoded: decodedUrl)
                            let duration = try AudioMessageReceiver.shared.getDuration(decoded: rawUrl)
                            self.xabberInputView.cancelRecord()
                            if shouldSend {
                                self.shouldSendAudioMessage(rawUrl: rawUrl, duration: duration, pcm: pcm) {
                                    self.recordLockIndicator.isHidden = true
                                    updateRecordLockFrame()
                                    self.xabberInputView.resetStateAfterRecord()
                                    self.xabberInputView.changeSendButtonState(to: .record)
                                    self.xabberInputView.changeState(to: .normal)
                                    self.recordedReferenceObject = nil
                                }
                            } else {
                                self.recordedReferenceObject = try self.willSendAudioMessage(rawUrl: rawUrl, duration: duration, pcm: pcm)
                                self.xabberInputView.recordAndPlayPanel.configure(pcm: pcm, duration: TimeInterval(duration))
                                self.xabberInputView.changeState(to: .recordAndPlay)
                                self.xabberInputView.isSendButtonEnabled = true
                                self.xabberInputView.changeSendButtonState(to: .send)
                                self.lockIndicatorShouldStop()
                                self.recordLockIndicator.isHidden = true
                                updateRecordLockFrame()
                            }
                        } else {
                            fail(message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: []))
                        }
                    } catch {
                        fail(message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: []))
                    }
                    
                } failure: {
                    fail(message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: []))
                }
            } else {
                fail(message: nil)
                YesNoPresenter().present(
                    in: self,
                    style: .actionSheet,
                    title: nil,
                    message: "Unable to record sound because the permission has not been granted. This can be changed in your settings.".localizeString(id: "audio_error_no_permission", arguments: []),
                    yesText: "Open application settings",
                    dangerYes: false,
                    showCancelAction: true,
                    noText: "Cancel",
                    animated: true) { value in
                        if value {
                            guard let url = URL(string: UIApplication.openSettingsURLString),
                                UIApplication.shared.canOpenURL(url) else {
                                    return
                            }
                            let optionsKeyDictionary = [UIApplication.OpenExternalURLOptionsKey(rawValue: "universalLinksOnly"): NSNumber(value: true)]
                            
                            UIApplication.shared.open(url, options: optionsKeyDictionary, completionHandler: nil)
                        }
                    }
            }
        }
        
        
    }
    
    func willSendAudioMessage(rawUrl: URL, duration: Int, pcm: [Float]) throws -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.owner = self.owner
        reference.jid = self.jid
        reference.mimeType = "audio"
        reference.conversationType = self.conversationType
        reference.metadata = [
            "name": "Voice message",
            "media-type": "audio/ogg",
            "desc": "Voice message",
            "uri": rawUrl.absoluteString,
            "filename": "Voice message",
        ]
        reference.duration = duration
        reference.meteringLevels = pcm
        reference.primary = UUID().uuidString
        reference.url = rawUrl.absoluteString
        reference.decodedUrl = rawUrl
        return reference
    }
    
    func shouldSendAudioMessage(rawUrl: URL? = nil, duration: Int? = nil, pcm: [Float]? = nil, callback: (() -> Void)?) {
        DispatchQueue.main.async {
            do {
                if let reference = self.recordedReferenceObject {
                    self.sendAudioMessage(reference)
                    callback?()
                } else {
                    if let rawUrl = rawUrl,
                       let duration = duration,
                       let pcm = pcm {
                        let reference = try self.willSendAudioMessage(rawUrl: rawUrl, duration: duration, pcm: pcm)
                        self.sendAudioMessage(reference)
                        callback?()
                    }
                }
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    func sendAudioMessage(_ reference: MessageReferenceStorageItem) {
        let forwarded: [String] = self.attachedMessagesIds.value
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.messages.sendMediaMessage([reference], to: self.jid, forwarded: forwarded, conversationType: self.conversationType)
            self.recordedReferenceObject = nil
            DispatchQueue.main.async {
                if let primary = self.messagesObserver?.first?.primary {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                        .invalidateLastMessageCachedSize(primary: primary)
                }
                FeedbackManager.shared.generate(feedback: .success)
                self.clearAttachments()
                self.unreadMessagePositionId = nil
                self.scrollToLastOrUnreadItem()
            }
        })
    }
    
//    func
    
    func onAudioMessageDidCancel() {
        print("panGestureRecognizerSelector", #function)
        self.xabberInputView.resetStateAfterRecord()
        self.recordLockIndicator.isHidden = true
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 48 - inputHeight),
            size: CGSize(square: 38)
        )
        do {
            try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func onAudioMessageDidSet() {
        print("panGestureRecognizerSelector", #function)
        

    }
    
    func onAudioMessageShouldSend() {
        print("panGestureRecognizerSelector", #function)
        self.xabberInputView.recordPanel.done()
        self.recordLockIndicator.isHidden = true
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 48 - inputHeight),
            size: CGSize(square: 38)
        )
        self.xabberInputView.sendButton.hidePulse()
        self.xabberInputView.changeState(to: self.xabberInputView.state)
        do {
            try AudioRecorder.shared.stopRecording(cancel: false, shouldSend: true)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    func onIdentityVerification() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        showModal(vc)
    }
    
    func onUpdateSignature() {
        SignatureManager.shared.delegate = self
        FeedbackManager.shared.tap()
        if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
            YubiKitExternalLocalization.nfcScanAlertMessage = "Generate digital signature for message"
            YubiKitManager.shared.startNFCConnection()
            YubiKitManager.shared.delegate = SignatureManager.shared
            SignatureManager.shared.currentAction = .signature
        }
    }
    
    func onCheckDevices() {
        let vc = DevicesListViewController()
        vc.configure(for: self.owner)
        showModal(vc)
    }
    
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {
//        print("self.messagesCollectionView.contentOffset.y", self.messagesCollectionView.contentOffset.y)
        if self.messagesCollectionView.contentOffset.y < 0 { // -340
            self.messagesCollectionView.contentOffset.y = -height - 8
        }
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: height + 8, left: 0, bottom: 0, right: 0)
//        let offset = messagesCollectionView.contentOffset.y
//        messageCollectionViewTopInset = height + 4 //offset - height + barHeight
//        messagesCollectionView.setContentOffset(CGPoint(x: 0, y: -height), animated: true)
//        print("OFFSET", offset - height)
//        messagesCollectionView.contentOffset.y -= offset
//        messagesCollectionView.contentOffset.y -= height
    }
    
    func onAfterburnButtonTouchUp() {
//        print(#function)
        if UIDevice.current.userInterfaceIdiom == .pad {
            let items = ChatMarkersManager.BurnMessagesTimerValues.values().compactMap {
                return ActionSheetPresenter.Item(destructive: false, title: ChatMarkersManager.BurnMessagesTimerValues.verbose($0), value: "\($0.rawValue)", isEnabled: true)
            }
            
            ActionSheetPresenter().present(
                in: self,
                title: "Burn message after",
                message: nil,
                cancel: "Cancel",
                values: items,
                animated: true) { value in
                    let rawValue = Int(value)
                    let selectedInterval = ChatMarkersManager.BurnMessagesTimerValues(rawValue: rawValue ?? 0) ?? .off
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(
                            ofType: LastChatsStorageItem.self,
                            forPrimaryKey: LastChatsStorageItem.genPrimary(
                                jid: self.jid,
                                owner: self.owner,
                                conversationType: self.conversationType)) {
                            if instance.afterburnInterval == Double(selectedInterval.rawValue) {
                                return
                            }
                            if selectedInterval == .off && instance.afterburnInterval <= 0 {
                                return
                            }
                            try realm.write {
                                if instance.isInvalidated { return }
                                instance.afterburnInterval = Double(selectedInterval.rawValue)
                            }
                        }
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                    }
                    let item = MessageReferenceStorageItem()
                    item.kind = .systemMessage
                    item.owner = self.owner
                    item.jid = self.jid
                    item.conversationType = self.conversationType
                    item.isDownloaded = true
                    item.begin = 0
                    item.end = 0
                    item.metadata = [
                        "ephemeral-timer": selectedInterval.rawValue,
                    ]
                    item.primary = UUID().uuidString
                    var body = "Self-destruct timer was set to \(ChatMarkersManager.BurnMessagesTimerValues.verbose(selectedInterval))"
                    if selectedInterval == .off {
                        body = "Self-destruct timer was disabled"
                    }
                    AccountManager.shared.find(for: self.owner)?.messages.sendSystemMessage(
                        body,
                        attachments: [item],
                        to: self.jid,
                        conversationType: self.conversationType
                    )
                    UIView.performWithoutAnimation {
                        switch selectedInterval {
                            case .off:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "stopwatch"), for: .normal)
                            case .s5:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.circle"), for: .normal)
                            case .s10:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.circle"), for: .normal)
                            case .s15:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.circle"), for: .normal)
                            case .s30:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "30.circle"), for: .normal)
                            case .m1:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "1.square"), for: .normal)
                            case .m5:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.square"), for: .normal)
                            case .m10:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.square"), for: .normal)
                            case .m15:
                                self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.square"), for: .normal)
                        }
                    }
                    FeedbackManager.shared.generate(feedback: .success)
//                    self.messagesCount += 1
//                    self.shouldUpdatePreviousMessage = true
//                    self.runDatasetUpdateTask()
                }
            return
        }
        
        let message = "\n\n\n\n\n\n\n\n"
        let alert = UIAlertController(title: "Burn message after", message: message, preferredStyle: UIAlertController.Style.actionSheet)
         
        let picker = UIPickerView(frame: CGRect(x: 0, y: 20, width: alert.view.frame.width - 16, height: 140))
        picker.dataSource = self
        picker.delegate = self
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType)) {
                let selectedValue = ChatMarkersManager.BurnMessagesTimerValues(rawValue: Int(instance.afterburnInterval)) ?? .off
                let selectedValueId = ChatMarkersManager.BurnMessagesTimerValues.values().firstIndex(of: selectedValue) ?? 0
                picker.selectRow(selectedValueId, inComponent: 0, animated: false)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        
        alert.view.addSubview(picker)
//        alert.iPadPopoverControllerInit(viewController: self)
        if UIDevice.current.userInterfaceIdiom == .pad {
            alert.modalPresentationStyle = .popover
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
                popoverController.canOverlapSourceViewRect = true
            }
        }
        let okAction = UIAlertAction(title: "Done", style: .default, handler: {
            (alert: UIAlertAction!) -> Void in
            let selectedInterval = ChatMarkersManager.BurnMessagesTimerValues.values()[self.selectedAfterburnId]
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType)) {
                    if instance.afterburnInterval == Double(selectedInterval.rawValue) {
                        return
                    }
                    if selectedInterval == .off && instance.afterburnInterval <= 0 {
                        return
                    }
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.afterburnInterval = Double(selectedInterval.rawValue)
                    }
                }
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
            let item = MessageReferenceStorageItem()
            item.kind = .systemMessage
            item.owner = self.owner
            item.jid = self.jid
            item.conversationType = self.conversationType
            item.isDownloaded = true
            item.begin = 0
            item.end = 0
            item.metadata = [
                "ephemeral-timer": selectedInterval.rawValue,
            ]
            item.primary = UUID().uuidString
            var body = "Self-destruct timer was set to \(ChatMarkersManager.BurnMessagesTimerValues.verbose(selectedInterval))"
            if selectedInterval == .off {
                body = "Self-destruct timer was disabled"
            }
            AccountManager.shared.find(for: self.owner)?.messages.sendSystemMessage(
                body,
                attachments: [item],
                to: self.jid,
                conversationType: self.conversationType
            )
            UIView.performWithoutAnimation {
                switch selectedInterval {
                    case .off:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "stopwatch"), for: .normal)
                    case .s5:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.circle"), for: .normal)
                    case .s10:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.circle"), for: .normal)
                    case .s15:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.circle"), for: .normal)
                    case .s30:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "30.circle"), for: .normal)
                    case .m1:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "1.square"), for: .normal)
                    case .m5:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "5.square"), for: .normal)
                    case .m10:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "10.square"), for: .normal)
                    case .m15:
                        self.xabberInputView.timerButton.setImage(UIImage(systemName: "15.square"), for: .normal)
                }
            }
            FeedbackManager.shared.generate(feedback: .success)
//            self.messagesCount += 1
//            self.shouldUpdatePreviousMessage = true
//            self.runDatasetUpdateTask()
            
        })
        
        alert.addAction(okAction)
//        alert.addAction(cancelAction)
        self.present(alert, animated: true)
    }
    
    internal func addImage(_ image: UIImage) -> MessageReferenceStorageItem? {
        guard let url = URL(string: [UUID().uuidString, "png"].joined(separator: ".")) else { return nil }
        let item = MessageReferenceStorageItem()
        item.kind = .media
        item.owner = self.owner
        item.jid = self.jid
        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
        item.temporaryData = image.pngData()
        item.conversationType = self.conversationType
        item.metadata = [
            "name": "Memoji",
            "size": item.temporaryData?.count ?? 0,
            "media-type": MimeType(url: url).value,
            "desc": "Memoji",
            "uri": url.absoluteString,
            "filename": url.lastPathComponent,
            "width": image.size.width.rounded(),
            "height": image.size.height.rounded(),
        ]
        ImageCache.default.store(image, forKey: url.absoluteString)
        item.primary = UUID().uuidString
        item.localFileUrl = item.temporaryData?.saveToTemporaryDir(name: url.lastPathComponent)
        
        return item
    }
    
    func attachmentButtonTouchUp() {
//      if (AccountManager.shared.find(for: self.owner)?.xuploads.isAvailable() ?? false)
        if AccountManager.shared.find(for: self.owner)?.cloudStorage.isAvailable() ?? false {
            self.showImagePicker()
        } else {
//            if let domain = self.owner.split(separator: "@").last {
//                self.showToast(
//                    error: "We're still determining whether or not \(domain) server supports file transfer."
//                )
//            } else {
//                self.showToast(
//                    error: "We're still determining whether or not your server supports file transfer."
//                )
//            }
        }
    }
    
    func onTextDidChange(to text: String?) {
        self.draftMessageText.accept(text)
    }
    
    func sendButtonTouchUp( with text: String) {
        func sendMessage(_ text: String) {
            if self.recordedReferenceObject != nil {
                self.onSendButtonTouchUpInsideWhenAudioWasRecorded()
            } else {
                self.xabberInputView.textField.text = ""
                self.xabberInputView.textViewDidChange()
                let forwarded: [String] = self.attachedMessagesIds.value
                self.draftMessageText.accept(nil)
    //            canUpdateDataset = true
    //            self.shouldChangeOffsetOnUpdate = false
                self.messagesCollectionView.scrollToTop(animated: true)
                if let editedMessage = editMessageId.value,
                    editedMessage.isNotEmpty {
                    let primary = editedMessage
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                        user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                        user.messages.editSimpleMessage(text, primary: primary)
                        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                                .invalidateLastMessageCachedSize(primary: primary)
                        if let index = self.datasource.firstIndex(where: { $0.primary == primary }) {
                            self.messagesCollectionView.reloadSections(IndexSet([index]))//(at: [IndexPath(item: 0, section: index)])
                        }
    //                    self.canUpdateDataset = true
    //                    self.runDatasetUpdateTask()
                    })
                } else {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                        user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                        _ = user.messages.sendSimpleMessage(
                            text,
                            to: self.jid,
                            forwarded: forwarded,
                            conversationType: self.conversationType
                        )
                        if let primary = self.messagesObserver?.first?.primary {
                            (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                                .invalidateLastMessageCachedSize(primary: primary)
                        }
                        FeedbackManager.shared.generate(feedback: .success)
                    })
                }
                self.clearAttachments()
                self.unreadMessagePositionId = nil
                self.scrollToLastOrUnreadItem()
            }
        }
        if showSkeletonObserver.value {
            return
        }
        
        if self.conversationType.isEncrypted {
            do {
                let realm = try WRealm.safe()
                let collection = realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND (state_ == %@ OR state_ == %@ OR state_ == %@)", self.owner, self.jid, SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.ignore.rawValue, SignalDeviceStorageItem.TrustState.distrusted.rawValue)
                if collection.isEmpty {
                    sendMessage(text)
                } else {
                    let items = [
                        ActionSheetPresenter.Item(destructive: false, title: "Identity verification", value: "identity"),
                        ActionSheetPresenter.Item(destructive: true, title: "Send anyway", value: "send")
                    ]
                    ActionSheetPresenter().present(
                        in: self,
                        title: "Untrusted device warning",
                        message: "The recipient has added a new device for which you haven't yet performed an identity verification. If you send the message right now, it will be possible to decipher the message contents on this new device. It is recommended that you perform an identity verification now.",
                        cancel: "Cancel",
                        values: items,
                        animated: true, cancelAction: {
                        }) { value in
                            switch value {
                                case "identity":
                                    do {
                                        let realm = try WRealm.safe()
                                        if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType)) {
                                            try realm.write {
                                                instance.draftMessage = text
                                            }
                                        }
                                    } catch {
                                        DDLogDebug("ChatViewController: \(#function)")
                                    }
                                    let vc = TrustedDevicesViewController()
                                    vc.jid = self.jid
                                    vc.owner = self.owner
                                    showModal(vc)
                                case "send":
                                    sendMessage(text)
                                default:
                                    break
                            }
                        }
                }
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        } else {
            sendMessage(text)
        }
        
        
    }
}
