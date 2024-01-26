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


extension ChatViewController: UIPickerViewDelegate {
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        print(row)
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
    
    func onIdentityVerification() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        self.navigationController?.pushViewController(vc, animated: true)
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
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {
        print("self.messagesCollectionView.contentOffset.y", self.messagesCollectionView.contentOffset.y)
        if self.messagesCollectionView.contentOffset.y < 0 { // -340
            self.messagesCollectionView.contentOffset.y = -height - 8
        }
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: height + 8, left: 0, bottom: 100, right: 0)
//        let offset = messagesCollectionView.contentOffset.y
//        messageCollectionViewTopInset = height + 4 //offset - height + barHeight
//        messagesCollectionView.setContentOffset(CGPoint(x: 0, y: -height), animated: true)
//        print("OFFSET", offset - height)
//        messagesCollectionView.contentOffset.y -= offset
//        messagesCollectionView.contentOffset.y -= height
    }
    
    func onAfterburnButtonTouchUp() {
        print(#function)
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
                    self.canUpdateDataset = true
                    self.messagesCount += 1
                    self.shouldUpdatePreviousMessage = true
                    self.runDatasetUpdateTask()
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
            self.canUpdateDataset = true
            self.messagesCount += 1
            self.shouldUpdatePreviousMessage = true
            self.runDatasetUpdateTask()
            
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
    
    func onTextDidChange(to text: String?) {
        self.draftMessageText.accept(text)
    }
    
    func sendButtonTouchUp( with text: String) {
        func sendMessage(_ text: String) {
            self.xabberInputView.textField.text = ""
            self.xabberInputView.textViewDidChange()
            let forwarded: [String] = self.attachedMessagesIds.value
            self.draftMessageText.accept(nil)
            canUpdateDataset = true
            self.shouldChangeOffsetOnUpdate = false
            self.messagesCollectionView.scrollToTop(animated: true)
            if let editedMessage = editMessageId.value,
                editedMessage.isNotEmpty {
                let primary = editedMessage
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                    user.messages.editSimpleMessage(text, primary: primary)
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
                            .invalidateLastMessageCachedSize(primary: primary)
                    self.canUpdateDataset = true
                    self.runDatasetUpdateTask()
                })
            } else {
                AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                    
                    user.messages.sendSimpleMessage(
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
                    self.canUpdateDataset = true
                    self.messagesCount += 1
                    self.shouldUpdatePreviousMessage = true
                    self.runDatasetUpdateTask()
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
//                        self.messagesCollectionView.scrollToTop(animated: true)
//                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
//                        self.canUpdateDataset = true
                        self.shouldUpdatePreviousMessage = true
                        self.runDatasetUpdateTask()
                    }
                })
            }
            self.clearAttachments()
        }
        if showSkeletonObserver.value {
            return
        }
        if !self.isSkeletonHided {
            return
        }
        
        if [.omemo, .axolotl, .omemo1].contains(self.conversationType) {
            do {
                let realm = try WRealm.safe()
                let collection = realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND (state_ == %@ OR state_ == %@)", self.owner, self.jid, SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.Ignore.rawValue)
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
                                    self.navigationController?.pushViewController(vc, animated: true)
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
