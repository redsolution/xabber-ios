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
    
    func onSendButtonTouchUpInsideWhenAudioWasRecorded() {
        guard let sessionID = self.recordedReferenceSessionID else {
            self.shouldSendAudioMessage(callback: nil)
            return
        }
        self.onAudioMessagePreviewSend(sessionID: sessionID)
    }
    
    @objc
    func onMeteringLevelDidUpdate(_ notification: Notification) {
        guard self.activeAudioRecordingSessionID != nil,
              let percentage: Float = notification.userInfo?[AudioRecorder.audioPercentageUserInfoKey] as? Float else {
            return
        }
        self.recordedPCM.append(percentage)
        self.xabberInputView.updateRecordingMeteringLevel(percentage)
    }
    
    func recordAndPlayPanelDeleteButtonTouchUp(sessionID: UUID) {
        self.onAudioMessagePreviewDelete(sessionID: sessionID)
    }
    
    func didStopPlayingAudio() {
        AudioManager.shared.player = nil
        self.currentPlayingUrl = nil
        self.hideSharedAudioPanel()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func recordAndPlayPanelPlayButtonTouchUp(sessionID: UUID) {
        guard self.recordedReferenceSessionID == sessionID else { return }
        func play(url: URL?) throws {
            AudioManager.shared.player?.stop()
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
    
    func resetRecordState() {
        do { try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false) } catch {  }
        self.xabberInputView.cancelRecord()
        self.hideRecordingLockOverlay()
        self.activeAudioRecordingSessionID = nil
        self.recordedReferenceSessionID = nil
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
    
    func onAudioMessageStartRecord(sessionID: UUID) {
        self.activeAudioRecordingSessionID = sessionID
        self.recordedReferenceSessionID = nil
        self.recordedReferenceObject = nil
        self.recordedPCM = []
        self.stopRecordedPreviewPlayback()

        AudioRecorder.shared.askPermission { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      self.activeAudioRecordingSessionID == sessionID else {
                    return
                }

                guard granted else {
                    self.failAudioRecording(sessionID: sessionID, message: nil)
                    self.presentMicrophonePermissionPrompt()
                    return
                }

                AudioRecorder.shared.startRecording(
                    visualNotificationFreq: 0.01,
                    completion: { [weak self] url, error, shouldSend in
                        DispatchQueue.main.async {
                            self?.handleAudioRecordingFinished(
                                sessionID: sessionID,
                                url: url,
                                error: error,
                                shouldSend: shouldSend
                            )
                        }
                    },
                    failure: { [weak self] in
                        DispatchQueue.main.async {
                            self?.failAudioRecording(
                                sessionID: sessionID,
                                message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: [])
                            )
                        }
                    },
                    started: { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self = self,
                                  self.activeAudioRecordingSessionID == sessionID else {
                                return
                            }
                            self.xabberInputView.audioRecordingDidStart(sessionID: sessionID)
                        }
                    }
                )
            }
        }
    }
    
    func willSendAudioMessage(rawUrl: URL, duration: Int, pcm: [Float]) throws -> MessageReferenceStorageItem {
        return VoiceMessageReferenceBuilder.make(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            rawUrl: rawUrl,
            duration: duration,
            meteringLevels: pcm
        )
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
        self.requestOutgoingAutoScrollAfterDatasourceUpdate()
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.messages.sendMediaMessage([reference], to: self.jid, forwarded: forwarded, conversationType: self.conversationType)
            self.recordedReferenceObject = nil
            self.recordedReferenceSessionID = nil
            DispatchQueue.main.async {
                FeedbackManager.shared.generate(feedback: .success)
                self.clearAttachments()
                self.unreadMessagePositionId = nil
            }
        })
    }
    
    func onAudioMessageDidCancel(sessionID: UUID) {
        guard self.activeAudioRecordingSessionID == sessionID else { return }
        do {
            try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        self.cleanupCancelledAudioRecording(sessionID: sessionID)
    }
    
    func onAudioMessageDidFinish(sessionID: UUID, intent: VoiceRecordingFinishIntent) {
        guard self.activeAudioRecordingSessionID == sessionID else { return }
        self.hideRecordingLockOverlay()
        do {
            try AudioRecorder.shared.stopRecording(
                cancel: false,
                shouldSend: intent == .sendImmediately
            )
            FeedbackManager.shared.generate(feedback: .success)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            self.failAudioRecording(
                sessionID: sessionID,
                message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: [])
            )
        }
    }

    func onAudioMessagePreviewDelete(sessionID: UUID) {
        guard self.recordedReferenceSessionID == sessionID else { return }
        self.deleteRecordedPreviewFiles()
        self.stopRecordedPreviewPlayback()
        self.recordedReferenceObject = nil
        self.recordedReferenceSessionID = nil
        self.recordedPCM = []
        self.hideRecordingLockOverlay()
        self.xabberInputView.audioRecordingDidCancel(sessionID: sessionID)
        FeedbackManager.shared.generate(feedback: .success)
    }

    func onAudioMessagePreviewSend(sessionID: UUID) {
        guard self.recordedReferenceSessionID == sessionID,
              self.recordedReferenceObject != nil else {
            return
        }
        self.stopRecordedPreviewPlayback()
        self.shouldSendAudioMessage { [weak self] in
            guard let self = self else { return }
            self.recordedReferenceObject = nil
            self.recordedReferenceSessionID = nil
            self.recordedPCM = []
            self.hideRecordingLockOverlay()
            self.xabberInputView.audioRecordingDidSend(sessionID: sessionID)
        }
    }

    func cancelActiveAudioRecordingForLifecycle() {
        if let sessionID = self.activeAudioRecordingSessionID {
            self.onAudioMessageDidCancel(sessionID: sessionID)
        } else if AudioRecorder.shared.isRunning {
            self.resetRecordState()
        }
    }

    private func handleAudioRecordingFinished(
        sessionID: UUID,
        url: URL?,
        error: Error?,
        shouldSend: Bool
    ) {
        guard self.activeAudioRecordingSessionID == sessionID else {
            if let url = url {
                self.deleteRecordedFile(at: url)
            }
            return
        }

        guard error == nil,
              let rawUrl = url else {
            self.failAudioRecording(
                sessionID: sessionID,
                message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: [])
            )
            return
        }

        do {
            let data = try self.loadRecordingData(from: rawUrl)
            AudioManager.shared.cache(rawUrl, data: data)
            let pcm = self.recordedPCM
            let duration = try AudioMessageReceiver.shared.getDuration(decoded: rawUrl)
            guard duration >= 1 else {
                self.deleteRecordedFile(at: rawUrl)
                self.cleanupCancelledAudioRecording(sessionID: sessionID)
                return
            }

            if shouldSend {
                self.shouldSendAudioMessage(rawUrl: rawUrl, duration: duration, pcm: pcm) { [weak self] in
                    guard let self = self,
                          self.activeAudioRecordingSessionID == sessionID else {
                        return
                    }
                    self.activeAudioRecordingSessionID = nil
                    self.recordedReferenceSessionID = nil
                    self.recordedReferenceObject = nil
                    self.recordedPCM = []
                    self.hideRecordingLockOverlay()
                    self.xabberInputView.audioRecordingDidSend(sessionID: sessionID)
                }
            } else {
                self.recordedReferenceObject = try self.willSendAudioMessage(rawUrl: rawUrl, duration: duration, pcm: pcm)
                self.recordedReferenceSessionID = sessionID
                self.activeAudioRecordingSessionID = nil
                self.recordedPCM = []
                self.xabberInputView.recordAndPlayPanel.configure(pcm: pcm, duration: TimeInterval(duration))
                self.hideRecordingLockOverlay()
                self.xabberInputView.audioRecordingPreviewReady(sessionID: sessionID)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            self.failAudioRecording(
                sessionID: sessionID,
                message: "Unable to record sound at the moment, please try again".localizeString(id: "audio_error_record_failed", arguments: []),
                rawUrl: rawUrl
            )
        }
    }

    private func failAudioRecording(sessionID: UUID, message: String?, rawUrl: URL? = nil) {
        guard self.activeAudioRecordingSessionID == sessionID || self.recordedReferenceSessionID == sessionID else {
            return
        }
        if let rawUrl = rawUrl {
            self.deleteRecordedFile(at: rawUrl)
        }
        do {
            try AudioRecorder.shared.stopRecording(cancel: true, shouldSend: false)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        if let message = message {
            self.view.makeToast(message)
        }
        self.activeAudioRecordingSessionID = nil
        self.recordedReferenceSessionID = nil
        self.recordedReferenceObject = nil
        self.recordedPCM = []
        self.hideRecordingLockOverlay()
        self.xabberInputView.audioRecordingDidFail(sessionID: sessionID)
    }

    private func cleanupCancelledAudioRecording(sessionID: UUID) {
        self.activeAudioRecordingSessionID = nil
        self.recordedReferenceSessionID = nil
        self.recordedReferenceObject = nil
        self.recordedPCM = []
        self.hideRecordingLockOverlay()
        self.xabberInputView.audioRecordingDidCancel(sessionID: sessionID)
    }

    private func hideRecordingLockOverlay() {
        self.xabberInputView.hideRecordingLockOverlay()
    }

    private func stopRecordedPreviewPlayback() {
        AudioManager.shared.player?.stop()
        AudioManager.shared.player = nil
        self.currentPlayingUrl = nil
        self.xabberInputView.recordAndPlayPanel.waveform.stop()
        self.xabberInputView.recordAndPlayPanel.playButton.setImage(imageLiteral("play.fill"), for: .normal)
        self.hideSharedAudioPanel()
        self.sharedPlayerPaneldelegae?.shouldHide()
    }

    private func deleteRecordedPreviewFiles() {
        guard let reference = self.recordedReferenceObject else { return }
        if let decodedUrl = reference.decodedUrl {
            AudioManager.shared.remove(decodedUrl)
            self.deleteRecordedFile(at: decodedUrl)
        }
        if let localFileUrl = reference.localFileUrl,
           localFileUrl != reference.decodedUrl {
            self.deleteRecordedFile(at: localFileUrl)
        }
    }

    private func deleteRecordedFile(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    private func loadRecordingData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            return try Data(contentsOf: URL(fileURLWithPath: url.absoluteString))
        }
    }

    private func presentMicrophonePermissionPrompt() {
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
                guard value,
                      let url = URL(string: UIApplication.openSettingsURLString),
                      UIApplication.shared.canOpenURL(url) else {
                    return
                }
                let optionsKeyDictionary = [UIApplication.OpenExternalURLOptionsKey(rawValue: "universalLinksOnly"): NSNumber(value: true)]
                UIApplication.shared.open(url, options: optionsKeyDictionary, completionHandler: nil)
            }
    }
    
    func onIdentityVerification() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        showModal(vc, parent: self)
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
        showModal(vc, parent: self)
    }

    func onCheckContactDevices() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        showModal(vc, parent: self)
    }
    
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {
        let wasNearBottom = self.isNearBottom()
        let visibleAnchor = wasNearBottom ? nil : self.capturePagingAnchorIfNeeded(direction: .older)
        let inputMetrics = self.currentChatComposerKeyboardLayoutMetrics(
            visualHeight: height
        )
        self.applyChatComposerFrameUpdate(
            inputHeight: inputMetrics.collectionObstructionHeight,
            source: .composerHeight,
            wasNearBottom: wasNearBottom,
            visibleAnchor: visibleAnchor
        )
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
                    guard self.handleAutoDeleteTimerAccess(for: selectedInterval) else {
                        return
                    }
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
                                instance.applyAutoDeleteTimer(
                                    Double(selectedInterval.rawValue),
                                    updatedAt: Date().timeIntervalSince1970,
                                    updatedBy: self.owner
                                )
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
            guard self.handleAutoDeleteTimerAccess(for: selectedInterval) else {
                return
            }
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
                        instance.applyAutoDeleteTimer(
                            Double(selectedInterval.rawValue),
                            updatedAt: Date().timeIntervalSince1970,
                            updatedBy: self.owner
                        )
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

    private func handleAutoDeleteTimerAccess(for selectedInterval: ChatMarkersManager.BurnMessagesTimerValues) -> Bool {
        switch AutoDeleteMessagesPolicy.currentAccess(timerSeconds: Double(selectedInterval.rawValue), jid: self.owner) {
            case .available:
                return true
            case .premiumRequired:
                let vc = PremiumSubscribtionViewController()
                vc.owner = self.owner
                vc.jid = self.owner
                navigationController?.pushViewController(vc, animated: true)
                return false
        }
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
        NSLog("ATTACHMENT_TAP event=delegate_entry")
        self.showImagePicker()
    }
    
    func onTextDidChange(to text: String?) {
        self.draftMessageText.accept(text)
    }

    func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload) {
        guard !self.showSkeletonObserver.value else { return }
        let menuState = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: self.scheduledMessageService.isScheduleAvailable(owner: self.owner),
            isEditingMessage: self.editMessageId.value?.isNotEmpty == true,
            hasRecordedAudio: self.recordedReferenceObject != nil,
            hasUnsupportedMediaAttachment: false,
            conversationType: self.conversationType
        ))
        self.sendOptionsContextMenu?.closeMenu(withAnimation: false)

        let menu = ContextMenu(window: self.view.window ?? self.view)
        ChatSendOptionsContextMenuBuilder.configure(menu)
        menu.items = ChatSendOptionsContextMenuBuilder.makeItems(menuState: menuState)
        menu.currentMessagePrimary = nil
        menu.onItemTap = { [weak self] value in
            guard let self else { return false }
            return ChatSendOptionsContextMenuBuilder.handleSelection(value) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    self?.showScheduleDatePicker(for: payload)
                }
            }
        }
        menu.onViewDismiss = { [weak self, weak menu] _ in
            guard let self,
                  self.sendOptionsContextMenu === menu else {
                return
            }
            self.sendOptionsContextMenu = nil
        }
        self.sendOptionsContextMenu = menu
        menu.showMenu(viewTargeted: sourceView, delegate: self, animated: true)
    }

    func scheduledMessagesButtonTouchUp() {
        guard !self.showSkeletonObserver.value else { return }
        self.sendOptionsContextMenu?.closeMenu(withAnimation: false)
        self.openScheduledMessagesModal()
    }

    private func showScheduleDatePicker(for payload: ComposerMessagePayload) {
        guard self.canSchedulePayload(payload, showError: true) else { return }
        let picker = ScheduledMessageDatePickerViewController { [weak self] selectedDate in
            self?.sendScheduledMessage(payload: payload, deliverAt: selectedDate)
        }
        self.present(picker, animated: true)
    }

    private func canSchedulePayload(_ payload: ComposerMessagePayload, showError: Bool) -> Bool {
        let menuState = ChatSendOptionsMenuPolicy.makeMenuState(scheduleContext: ChatScheduleActionContext(
            scheduleAvailable: self.scheduledMessageService.isScheduleAvailable(owner: self.owner),
            isEditingMessage: self.editMessageId.value?.isNotEmpty == true,
            hasRecordedAudio: self.recordedReferenceObject != nil,
            hasUnsupportedMediaAttachment: false,
            conversationType: self.conversationType
        ))
        guard payload.body.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty,
              menuState.schedule.isEnabled else {
            if showError {
                ToastPresenter().presentError(message: self.scheduleErrorMessage(for: menuState.schedule.disabledReason))
            }
            return false
        }
        return true
    }

    private func sendScheduledMessage(payload: ComposerMessagePayload, deliverAt: Date) {
        guard self.canSchedulePayload(payload, showError: true) else { return }
        let request = ChatScheduledMessageSendRequest(
            owner: self.owner,
            conversation: self.jid,
            conversationType: self.conversationType,
            deliverAt: deliverAt,
            body: payload.body,
            references: payload.references,
            forwardedMessagePrimaries: self.attachedMessagesIds.value
        )
        let coordinator = ChatScheduledMessageSendCoordinator(service: self.scheduledMessageService)
        _ = coordinator.schedule(
            request,
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.completeScheduledMessageSend()
                }
            },
            onFailure: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    ToastPresenter().presentError(message: self.scheduleErrorMessage(for: error))
                }
            }
        )
    }

    private func completeScheduledMessageSend() {
        self.xabberInputView.clearComposer()
        self.xabberInputView.textViewDidChange()
        self.draftMessageText.accept(nil)
        self.clearAttachments()
        self.unreadMessagePositionId = nil
        self.refreshScheduledMessagesComposerButtonState()
        FeedbackManager.shared.generate(feedback: .success)
        self.openScheduledMessagesModal()
    }

    private func openScheduledMessagesModal() {
        let vc = ScheduledMessagesViewController()
        vc.owner = self.owner
        vc.jid = self.jid
        vc.conversationType = self.conversationType
        vc.scheduledMessageService = self.scheduledMessageService
        vc.onDidDisappear = { [weak self] in
            self?.refreshScheduledMessagesComposerButtonState()
        }
        showModal(vc, parent: self)
    }

    private func scheduleErrorMessage(for reason: ChatSendOptionsDisabledReason?) -> String {
        switch reason {
        case .scheduleUnavailable:
            return "Scheduled messages are unavailable on this server.".localizeString(id: "schedule_unavailable_error", arguments: [])
        case .editingMessage:
            return "Scheduled editing is not supported.".localizeString(id: "schedule_editing_unavailable_error", arguments: [])
        case .unsupportedMedia:
            return "Only text messages can be scheduled right now.".localizeString(id: "schedule_media_unavailable_error", arguments: [])
        case .encryptedConversation:
            return "Scheduled messages are unavailable in encrypted chats.".localizeString(id: "schedule_encrypted_unavailable_error", arguments: [])
        case .silentSendUnsupported, .none:
            return "Could not schedule message.".localizeString(id: "schedule_send_failed_error", arguments: [])
        }
    }

    private func scheduleErrorMessage(for error: XMPPMessageScheduleManager.ScheduleError) -> String {
        switch error {
        case .unavailable:
            return "Scheduled messages are unavailable on this server.".localizeString(id: "schedule_unavailable_error", arguments: [])
        default:
            return "Could not schedule message.".localizeString(id: "schedule_send_failed_error", arguments: [])
        }
    }
    
    func sendButtonTouchUp( with text: String) {
        #if DEBUG || CHAT_PERFORMANCE_LAB
        if let performanceFixtureSendHandler {
            performanceFixtureSendHandler(text)
            self.xabberInputView.clearComposer()
            self.xabberInputView.textViewDidChange()
            return
        }
        #endif
        let payload = self.xabberInputView.currentPayload()
        func sendMessage(_ payload: ComposerMessagePayload) {
            if self.recordedReferenceObject != nil {
                self.onSendButtonTouchUpInsideWhenAudioWasRecorded()
            } else {
                self.xabberInputView.clearComposer()
                self.xabberInputView.textViewDidChange()
                let forwarded: [String] = self.attachedMessagesIds.value
                self.draftMessageText.accept(nil)
                if let editedMessage = editMessageId.value,
                    editedMessage.isNotEmpty {
                    let primary = editedMessage
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                        user.messages.editSimpleMessage(payload.body, primary: primary, references: payload.references)
                    })
                } else {
                    self.beginSendToLocalRowSignpost()
                    self.requestOutgoingAutoScrollAfterDatasourceUpdate()
                    FeedbackManager.shared.generate(feedback: .success)
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                        _ = user.messages.sendSimpleMessage(
                            payload.body,
                            to: self.jid,
                            forwarded: forwarded,
                            conversationType: self.conversationType,
                            references: payload.references
                        )
                    })
                }
                self.clearAttachments()
                self.unreadMessagePositionId = nil
            }
        }
        if showSkeletonObserver.value {
            return
        }
        
        if self.conversationType.isEncrypted {
            let availability = self.currentOmemoSendAvailability()
            guard availability.canSend else {
                self.onUpdateOmemoSendAvailability(availability)
                return
            }
            sendMessage(payload)
        } else {
            sendMessage(payload)
        }
        
        
    }
}
