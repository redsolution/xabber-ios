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
import AVFoundation
import Cache
import RealmSwift
import CocoaLumberjack

extension ChatViewController {
    internal func startRecord() {
        print(#function)
//        FeedbackManager.shared.generate(feedback: .success)
        
        AudioRecorder.shared.askPermission(completion: { (value, request) in
            if request {
                self.deleteRecord()
                return
            }
            if value {
                DispatchQueue.main.async {
                    AudioManager.shared.player?.stop()
                    if let path = self.playingMessageIndexPath {
                        self.playingMessageIndexPath = nil
                        self.messagesCollectionView.reloadItems(at: [path.indexPath])
                    }
                    self.playingMessageUpdateTimer?.fire()
                    self.playingMessageUpdateTimer?.invalidate()
                    self.playingMessageUpdateTimer = nil
                    self.recordingPanel.animateRecordIndicator()
                }
                DispatchQueue.global().async {
                    AudioRecorder
                        .shared
                        .startRecording(
                            visualNotificationFreq: 0.05,
                            completion: {
                                (url, error) in
                                if error != nil {
                                    self.showToast(error: "Can`t record voice message".localizeString(id: "message_manager_error_cant_record_voice", arguments: []))
                                    self.deleteRecord()
                                } else {
                                    self.recordedFileUrl = url
                                    self.recordedFileDate = Date()
                                }
                    }) {
                        self.deleteRecord()
                    }
                }
                self.addMeteringObservers()
            } else {
                self.showToast(error: "The application does not have access to microphone. Go to settings and enable microphone access if you want to record audio messages".localizeString(id: "message_manager_no_microphone_access", arguments: []))
                self.deleteRecord()
            }
        })
    }
    
    internal func stopRecord() {
        print(#function)
        notifyVoiceMessageEndRecording()
        do {
            recordingPanel.stopAnimateRecordIndicator()            
            try AudioRecorder.shared.stopRecording()
            let stopDate = Date()
            if let url = recordedFileUrl,
                let date = recordedFileDate,
                stopDate.timeIntervalSince(date) > 1 {
                AudioManager.shared.player = try AVAudioPlayer(contentsOf: url, fileTypeHint: "wav")
                if let duration = AudioManager.shared.player?.duration {
                    self.recordingPanel.updateTimeLabel(duration)
                }
                self.recordingPanel
                    .configurePreview(color: self.accountPallete.tint500,
                                      duration: stopDate.timeIntervalSince(date).minuteFormatedString,
                                      meters: OpusAudio.shared.preparePreview(for: url))
                self.recordingPanel.changeState(.preview)
                OpusAudio.shared.encode(for: url) { (encodedData, meters, error) in
                    if error != nil {
                        self.showToast(error: "Can`t encode voice message".localizeString(id: "message_manager_cant_encode_voice", arguments: [""]))
                        self.deleteRecord()
                    } else {
                        do {
                            OpusAudio.shared.cache(
                                url,
                                data: try Data(
                                    contentsOf: URL(fileURLWithPath: url.absoluteString)
                                )
                            )
                        } catch {
                            self.showToast(error: "Can`t encode voice message. \(error.localizedDescription)".localizeString(id: "message_manager_cant_encode_voice", arguments: ["\(error.localizedDescription)"]))
                            self.deleteRecord()
                            return
                        }
                        let item = MessageReferenceStorageItem()
                        item.kind = .voice
                        item.owner = self.owner
                        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
                        item.temporaryData = encodedData
                        item.isDownloaded = true
                        item.metadata = [
                            "filename": "voice_message.ogg",
                            "name": "Voice message",
                            "size": item.temporaryData?.count ?? 0,
                            "media-type": "audio/ogg",
                            "uriEmbded": "\(url.absoluteString)",
                            "uri": url.absoluteString,
                            "meters": meters.map { return "\($0)"}.joined(separator: " "),
                            "duration": Int(stopDate.timeIntervalSince(date))
                        ]
                        item.primary = UUID().uuidString
                        item.localFileUrl = item.temporaryData!.saveToTemporaryDir(name: url.lastPathComponent)
                        self.recordedFileReference = item
                    }
                }
            } else {
                deleteRecord()
            }
        } catch {
            deleteRecord()
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func deleteRecord() {
        print(#function)
        try? AudioRecorder.shared.stopRecording()
        self.recordingPanel.removeFromSuperview()
//        self.xabberInputBar.resetRecordButtonAfterPinned()
        self.onRecordingPanelWillEnd()
        self.endRecording()
        DispatchQueue.main.async {
            do {
                try AudioRecorder.shared.stopRecording()
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
        if let url = self.recordedFileUrl {
            notifyVoiceMessageEndRecording()
            DispatchQueue.global(qos: .default).async {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }
        }
    }
    
    @objc
    internal func didUpdateMeteringLevel(_ notification: Notification) {
        if let date = self.recordedFileDate {
            self.recordingPanel.updateTimeLabel(Date().timeIntervalSince(date))
        } else {
            deleteRecord()
        }
        if let date = lastRecordingNotificationRequestDate {
            if Date().timeIntervalSince(date) > 5 {
                notifyVoiceMessageRecording()
            }
        } else {
            notifyVoiceMessageRecording()
        }
    }
    
    internal func endRecording() {
        print(#function)
        isAudioMessageSendProcess = false
        removeMeteringObservers()
        onRecordingPanelWillEnd()
        recordedFileDate = nil
        recordedFileUrl = nil
        recordedFileReference = nil
        recordingPanel.changeState(.unlocked)
    }
    
    func showToast(error message: String) {
        print(#function)
        let midX: CGFloat = self.view.frame.midX
        let midY: CGFloat = self.view.bounds.maxY - (108 + self.view.safeAreaInsets.bottom)
        self.view.makeToast(message,
                            point: CGPoint(x: midX, y: midY),
                            title: nil,
                            image: nil,
                            completion: nil)
    }
    
    internal func willSendAudioMessage() {
        DispatchQueue.main.async {
            self.recordingPanel.removeFromSuperview()
        }
        if isAudioMessageSendProcess { return }
        isAudioMessageSendProcess = true
        if let item = recordedFileReference {
            let attachedMessages = self.attachedMessagesIds.value
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.messages.sendMediaMessage([item],
                                               to: self.jid,
                                               forwarded: attachedMessages, conversationType: self.conversationType)
                self.canUpdateDataset = true
                self.messagesCount += 1
                self.runDatasetUpdateTask()
                DispatchQueue.main.async {
                    let prevIndexPath = IndexPath(row: 0, section: 1)
                    if self.messagesCollectionView.indexPathsForVisibleItems.contains(prevIndexPath) {
                        self.messagesCollectionView.reloadItems(at: [prevIndexPath])
                    }
                }
            })
            print("Call empty", #function)
            self.attachedMessagesIds.accept([])
            self.forwardedIds.accept(Set<String>())
            self.endRecording()
        } else {
            do {
                try self.onSendAudioMessage()
            } catch {
                self.showToast(error: "Can`t send voice message. 1".localizeString(id: "message_manager_error_cant_send_voice", arguments: []))
                self.deleteRecord()
                return
            }
        }
    }
    
    internal func onSendAudioMessage() throws {
        try AudioRecorder.shared.stopRecording()
        notifyVoiceMessageEndRecording()
        let endedAt: Date = Date()
        guard let url = recordedFileUrl,
              let startedAt = recordedFileDate,
              endedAt.timeIntervalSince(startedAt) > 1 else {
            self.deleteRecord()
            return
        }
        let item = MessageReferenceStorageItem()
        item.kind = .voice
        item.owner = self.owner
        item.jid = self.jid
        item.conversationType = self.conversationType
        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
        item.isDownloaded = true
        item.metadata = [
            "filename": "voice_message.ogg",
            "name": "Voice message",
            "media-type": "audio/ogg",
            "uri": url.absoluteString,
            "uriEmbded": "\(url.absoluteString)",
            "duration": Int(endedAt.timeIntervalSince(startedAt))
        ]
        item.primary = UUID().uuidString
        let referencePrimary = item.primary
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            let messagePrimary = user
                .messages
                .willSendMediaMessage([item],
                                      to: self.jid,
                                      forwarded: self.attachedMessagesIds.value, conversationType: self.conversationType)
            self.canUpdateDataset = true
            self.messagesCount += 1
            self.runDatasetUpdateTask()
            DispatchQueue.main.async {
                let prevIndexPath = IndexPath(row: 0, section: 1)
                if self.messagesCollectionView.indexPathsForVisibleItems.contains(prevIndexPath) {
                    self.messagesCollectionView.reloadItems(at: [prevIndexPath])
                }
            }
            OpusAudio.shared.encode(for: url) { (encodedData, meters, error) in
                if error != nil {
                    DispatchQueue.main.async {
                        self.showToast(error: "Can`t encode voice message".localizeString(id: "message_manager_cant_encode_voice", arguments: [""]))
                        self.deleteRecord()
                    }
                } else {
                    do {
                        OpusAudio.shared.cache(url,
                                               data: try Data(contentsOf: URL(fileURLWithPath: url.absoluteString)))
                        let realm = try WRealm.safe()
                        guard let item = realm.object(
                                ofType: MessageReferenceStorageItem.self,
                                forPrimaryKey: referencePrimary
                        ) else {
                            DispatchQueue.main.async {
                                self.showToast(error: "Can`t encode voice message".localizeString(id: "message_manager_cant_encode_voice", arguments: [""]))
                                self.deleteRecord()
                            }
                            return
                        }
                        item.temporaryData = encodedData
                        let localFileUrl = encodedData
                            .saveToTemporaryDir(name: url.lastPathComponent + ".ogg")
                        try realm.write{
                            item.metadata?["size"] = encodedData.count
                            item.metadata?["meters"] = meters.map { "\($0)" }.joined(separator: " ")
                            item.localFileUrl = localFileUrl
                        }
                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                            user.messages.continueSendMediaMessage(messagePrimary)
                        })
                        
                    } catch {
                        self.showToast(error: "Can`t encode voice message. \(error.localizedDescription)".localizeString(id: "message_manager_cant_encode_voice", arguments: ["\(error.localizedDescription)"]))
                        DispatchQueue.main.async {
                            self.deleteRecord()
                        }
                        return
                    }
                }
            }

        })
        print("Call empty", #function)
        self.attachedMessagesIds.accept([])
        self.forwardedIds.accept(Set<String>())
        self.endRecording()
    }
    
    internal func onSendAudioMessageOld() throws {
        print(#function)
        
        try AudioRecorder.shared.stopRecording()
        notifyVoiceMessageEndRecording()
        let stopDate = Date()
        if let url = self.recordedFileUrl,
            let date = self.recordedFileDate,
            stopDate.timeIntervalSince(date) > 1 {
            
            OpusAudio.shared.encode(for: url) { (encodedData, meters, error) in
                if error != nil {
                    self.showToast(error: "Can`t encode voice message".localizeString(id: "message_manager_cant_encode_voice", arguments: [""]))
                    self.deleteRecord()
                } else {
                    do {
                        OpusAudio.shared.cache(
                            url,
                            data: try Data(contentsOf: URL(fileURLWithPath: url.absoluteString))
                        )
                    } catch {
                        self.showToast(error: "Can`t encode voice message. \(error.localizedDescription)".localizeString(id: "message_manager_cant_encode_voice", arguments: ["\(error.localizedDescription)"]))
                        self.deleteRecord()
                        return
                    }
                    let item = MessageReferenceStorageItem()
                    item.kind = .voice
                    item.conversationType = self.conversationType
                    item.owner = self.owner
                    item.jid = self.jid
                    item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
                    item.temporaryData = encodedData
                    item.metadata = [
                        "filename": "voice_message.ogg",
                        "name": "Voice message",
                        "size": item.temporaryData?.count ?? 0,
                        "media-type": "audio/ogg",
                        "uri": url.absoluteString,
                        "uriEmbded": "\(url.absoluteString)",
                        "meters": meters.map{ return "\($0)"}.joined(separator: " "),
                        "duration": Int(stopDate.timeIntervalSince(date))
                    ]
                    item.primary = UUID().uuidString
                    item.localFileUrl = item.temporaryData!.saveToTemporaryDir(name: url.lastPathComponent + ".ogg")
                    let attachedMessages = self.attachedMessagesIds.value
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.messages.sendMediaMessage([item],
                                                       to: self.jid,
                                                       forwarded: attachedMessages, conversationType: self.conversationType)
                    })
                }
            }
        } else {
            self.deleteRecord()
        }
    }
    
    internal func onRecordingPanelWillPlay() {
        print(#function)
        guard let url = recordedFileUrl else { return }
        do {
            if AudioManager.shared.player?.url != url {
                AudioManager.shared.player = try AVAudioPlayer(contentsOf: url, fileTypeHint: "wav")
            }
            AudioManager.shared.player?.prepareToPlay()
            AudioManager.shared.player?.play()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onRecordingPanelWillPause() {
        print(#function)
        AudioManager.shared.player?.pause()
    }
    
    
    
    internal func onRecordingPanelWillEnd() {
//        print(#function)
        AudioManager.shared.player?.stop()
        AudioManager.shared.player = nil
//        AudioManager.shared.player.
    }
    
    
    open func onCancelRecord() {
        print(#function)
        deleteRecord()
//        self.xabberInputBar.resetRecordButtonAfterPinned()
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    open func onDeleteRecord() {
        print(#function)
        deleteRecord()
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    internal func notifyVoiceMessageRecording() {
        print(#function)
        lastRecordingNotificationRequestDate = Date()
        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
            user.chatStates.composing(stream, to: self.jid, type: .voice)
        })
    }
    
    internal func notifyVoiceMessageEndRecording() {
        print(#function)
        lastRecordingNotificationRequestDate = nil
        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
            user.chatStates.pause(stream, to: self.jid)
        })
    }
}
