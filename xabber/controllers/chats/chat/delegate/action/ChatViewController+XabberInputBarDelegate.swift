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


extension ChatViewController: XabberInputBarDelegate {
        
    internal func addImage(_ image: UIImage) -> MessageReferenceStorageItem? {
        guard let url = URL(string: [UUID().uuidString, "png"].joined(separator: ".")) else { return nil }
        let item = MessageReferenceStorageItem()
        item.kind = .media
        item.owner = self.owner
        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
        item.temporaryData = image.pngData()
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
    
    func attachmentButtonTouchUp(_ inputBar: XabberInputBar) {
//      if (AccountManager.shared.find(for: self.owner)?.xuploads.isAvailable() ?? false)
        if let account = AccountManager.shared.find(for: self.owner), let _ = account.getDefaultUploader() {
            self.showImagePicker()
        } else {
            if let domain = self.owner.split(separator: "@").last {
                self.showToast(
                    error: "We're still determining whether or not \(domain) server supports file transfer."
                )
            } else {
                self.showToast(
                    error: "We're still determining whether or not your server supports file transfer."
                )
            }
        }
    }
    
    func textDidChange(_ inputBar: XabberInputBar, to text: String) {
        
    }
    
    func imageDidAttach(_ inputBar: XabberInputBar, image: UIImage) {
        
    }
    
    func sendButtonTouchUp(_ inputBar: XabberInputBar, with text: String) {
        if showSkeletonObserver.value {
            return
        }
        var messageText: String = ""
        var media: [MessageReferenceStorageItem] = []
        for component in inputBar.inputTextView.components {
            if let image = component as? UIImage,
                let refItem = addImage(image.safeResize(to: 1024)){
                media.append(refItem)
            } else if let text = component as? String {
                messageText = text
            }
        }
        let forwarded: [String] = self.attachedMessagesIds.value
        
        inputBar.inputTextView.text = ""
        
        canUpdateDataset = true
        if let editedMessage = editMessageId.value,
            editedMessage.isNotEmpty {
            let primary = editedMessage
            AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                user.messages.editSimpleMessage(messageText, primary: primary)
                (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                        .invalidateLastMessageCachedSize(primary: primary)
                self.canUpdateDataset = true
                self.runDatasetUpdateTask()
            })
        } else {
            AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                if media.isNotEmpty {
                    user.messages.sendMediaMessage(media, to: self.jid, forwarded: forwarded, conversationType: self.conversationType)
                } else {
                    user.messages.sendSimpleMessage(messageText, to: self.jid, forwarded: forwarded, conversationType: self.conversationType)
                }
                if let primary = self.messagesObserver?.first?.primary {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                        .invalidateLastMessageCachedSize(primary: primary)
                }
                FeedbackManager.shared.generate(feedback: .success)
                self.canUpdateDataset = true
                self.messagesCount += 1
                self.shouldUpdatePreviousMessage = true
                self.runDatasetUpdateTask()
            })
        }
        
        self.clearAttachments()
    }
    
    func onStartRecording(_ inputBar: XabberInputBar) {
        print(#function)
        DispatchQueue.main.async {
            self.showRecordingPanel()
            self.startRecord()
        }
    }
    
    func onStopRecording(_ inputBar: XabberInputBar, state: XabberInputBar.RecordButtonState) {
        print(#function)
        DispatchQueue.main.async {
            switch state {
            case .active:
                self.recordingPanel.removeFromSuperview()
                do {
                    try self.onSendAudioMessage()
                } catch {
                    self.deleteRecord()
                }
                
                break
            case .pinned:
                self.stopRecord()
                break
            case .cancelled:
                self.deleteRecord()
            }
        }
    }
    
    func onSendVoiceMessage(_ inputBar: XabberInputBar) {
        print(#function)
        DispatchQueue.main.async {
            self.willSendAudioMessage()
            self.xabberInputBar.resetRecordButtonAfterPinned()
        }
        self.messagesCount += 1
        self.runDatasetUpdateTask()
        self.messagesCollectionView.scrollToTop()
    }
    
    func onPinRecording(_ inputBar: XabberInputBar) {
        print(#function)
        DispatchQueue.main.async {
            self.recordingPanel.changeState(.locked)
        }
    }
    
    func onRecordButtonDraggetOut(_ inputBar: XabberInputBar, to point: CGPoint) {
        self.recordingPanel.cancelButtonRightConstant = point.x
    }
    
    func heightDidChange(_ inputBar: XabberInputBar, to height: CGFloat) {
        UIView.animate(
            withDuration: 0.2,
            delay: 0.0,
            options: [.curveEaseOut]) {
            self.toolsButton.frame = CGRect(
                x: self.view.bounds.width - 50,
                y: self.view.bounds.height - height - 50 - (UIDevice.needBottomOffset ? 32 : 0),
                width: 36,
                height: 44)
        } completion: { (result) in
            
        }
    }
}
