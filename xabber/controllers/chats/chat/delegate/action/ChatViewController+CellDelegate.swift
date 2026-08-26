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
import WebKit
import RealmSwift
import CocoaLumberjack
import AVKit
import AVFoundation
import Alamofire
import MapKit

extension ChatViewController: ContextMenuDelegate {
    func contextMenuDidSelect(_ contextMenu: ContextMenu, cell: ContextMenuCell, targetedView: UIView, didSelect value: String, primary: String?) -> Bool {
        guard let primary = primary else { return false }
        guard let index = self.datasource.firstIndex(where: { $0.primary == primary }),
                let cell = self.messagesCollectionView.cellForItem(at: IndexPath(row: 0, section: index)) as? MessageCollectionViewCell else {
            return false
        }
        switch value {
            case "reply":
                self.inSearchMode.accept(false)
                self.forwardedIds.accept(Set<String>())
                self.attachedMessagesIds.accept([primary])
                self.editMessageId.accept(nil)
            case "forward":
                self.showShareViewController([primary])
            case "copy":
                if let text = formatSelectedMessagesBodyForCopy(forwardedIdsManual: [primary]) {
                    UIPasteboard.general.string = text
                    
                    ToastPresenter().presentSuccess(message: "Text was copied to clipboard")
                } else {
                    ToastPresenter().presentError(message: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
                }
            case "edit":
                self.inSearchMode.accept(false)
                self.forwardedIds.accept(Set<String>())
                self.attachedMessagesIds.accept([])
                self.editMessageId.accept(primary)
            case "report":
                let vc = AbuseReportViewController()
                vc.configureMessageReport(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    messagePrimary: primary
                )
                showModal(vc, parent: self)
            case "report_media":
                guard let referencePrimary = self.reportableMediaReferencePrimary(for: primary) else {
                    ToastPresenter().presentError(message: "Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
                    return false
                }
                let vc = AbuseReportViewController()
                vc.configureMediaReport(
                    owner: self.owner,
                    jid: self.jid,
                    conversationType: self.conversationType,
                    messagePrimary: primary,
                    referencePrimary: referencePrimary
                )
                showModal(vc, parent: self)
            case "delete":
                self.deleteMessages(forIds: Set([primary]))
            case "delete_error":
                if !self.deletePendingOutgoingMessageLocally(primary) {
                    self.deleteMessages(forIds: Set([primary]))
                }
            case "delete_sending":
                if !self.deletePendingOutgoingMessageLocally(primary) {
                    self.deleteMessages(forIds: Set([primary]))
                }
            case "retry":
                self.retryMessageSend(primary)
            case ChatPinnedMessageAction.pin.rawValue, ChatPinnedMessageAction.unpin.rawValue:
                guard let requestedAction = ChatPinnedMessageAction(rawValue: value),
                      let groupStanzaID = self.datasource[index].archivedId,
                      ChatPinnedMessageActionPolicy.action(
                        groupStanzaID: groupStanzaID,
                        pinnedMessageIDs: self.canonicalGroupProjectionState?.pinnedMessageIDs,
                        canPin: self.datasource[index].canPinMessage
                      ) == requestedAction else {
                    return false
                }
                self.performPinnedMessageMutation(
                    requestedAction,
                    groupStanzaID: groupStanzaID
                )
            case "select":
                self.selectMessage(in: cell)
            default: break
        }
        return true
    }
    
    func contextMenuDidDeselect(_ contextMenu: ContextMenu, cell: ContextMenuCell, targetedView: UIView, didDeselect value: String, primary: String?) {
        
    }
        
    func contextMenuDidAppear(_ contextMenu: ContextMenu) {
        
    }
    
    func contextMenuDidDisappear(_ contextMenu: ContextMenu) {
        
    }
    
    
}

//extension ChatViewController: AVAudioPlayerDelegate {
//    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
//        print("finish")
//        if self.currentPlayingUrl == self.recordedReferenceObject?.decodedUrl {
//            self.xabberInputView.recordAndPlayPanel.waveform.stop()
//            self.xabberInputView.recordAndPlayPanel.playButton.setImage(imageLiteral("play.fill"), for: .normal)
//            self.audioPlayer = nil
//            self.currentPlayingUrl = nil
//            try? AVAudioSession.sharedInstance().setActive(false)
//        } else {
//            self.currentPlayingView?.waveform.stop()
//            self.currentPlayingView?.iconButton.setImage(imageLiteral("play.fill"), for: .normal)
//            self.currentPlayingView = nil
//            self.audioPlayer = nil
//            try? AVAudioSession.sharedInstance().setActive(false)
//        }
//    }
//}

extension ChatViewController: SensitiveContentFirstPaneViewControllerDelegate {
    func onViewSensitiveMedia(messagePrimary: String, referencePrimary: String, urls: [URL], url: URL, isVideo: Bool) {
        if referencePrimary.isNotEmpty {
            revealSensitiveMediaAndRemapCommittedTimeline(
                referencePrimary: referencePrimary
            )
        }

        if isVideo {
            playVideo(withURL: url)
        } else {
            showGallery(urls: urls, from: url)
        }
    }
}

extension ChatViewController: MessageCellDelegate {
    func isInSelection() -> Bool {
        return self.isInSelectionMode.value
    }
    
    func didTapOnFile(url: URL) {
        self.openFile(url)
    }
    
    func didTapOnPhoto(message messagePrimary: String, urls: [URL], url: URL, referencePrimary: String, isSensitive: Bool) {
        if isSensitive {
            let vc = SensitiveContentFirstPaneViewController()
            vc.isFirstStep = true
            vc.urls = urls
            vc.url = url
            vc.delegate = self
            vc.messagePrimary = messagePrimary
            vc.referencePrimary = referencePrimary
            vc.isVideo = false
//            let nvc = UINavigationController(rootViewController: vc)
            showModal(vc)
        } else {
            self.showGallery(urls: urls, from: url)
        }
    }
    
    func didTapOnVideo(message messagePrimary: String, url: URL?, referencePrimary: String, isSensitive: Bool) {
        guard let url = url else { return }
        if isSensitive {
            let vc = SensitiveContentFirstPaneViewController()
            vc.isFirstStep = true
            vc.urls = [url]
            vc.url = url
            vc.delegate = self
            vc.messagePrimary = messagePrimary
            vc.referencePrimary = referencePrimary
            vc.isVideo = true
            showModal(vc)
        } else {
            self.playVideo(withURL: url)
        }
    }

    func didTapOnLocation(
        message messagePrimary: String,
        referencePrimary: String,
        coordinate: CLLocationCoordinate2D,
        address: String?,
        geoURI: String
    ) {
        let location = LocationAttachment(
            primary: referencePrimary,
            coordinate: coordinate,
            address: address,
            geoURI: geoURI,
            snapshotURL: nil
        )
        let controller = ChatLocationMapViewController(location: location)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    func didTapOnContact(message messagePrimary: String, contact: ContactAttachment) {
        guard showSkeletonObserver.value == false,
              isInSelectionMode.value == false else {
            return
        }
        showSharedContactInfo(for: contact)
    }

    internal func makeSharedContactInfoController(for contact: ContactAttachment) -> BaseViewController? {
        guard contact.jid.isNotEmpty else {
            return nil
        }
        let targetOwner = contact.owner.isNotEmpty ? contact.owner : self.owner
        switch contact.entity {
        case .contact:
            let controller = ContactInfoViewController()
            controller.owner = targetOwner
            controller.jid = contact.jid
            controller.conversationType = self.conversationType
            controller.footerView.chatsDelegate = self
            controller.chatStateDelegate = self
            controller.leftMenuDelegate = self.leftMenuDelegate
            return controller
        case .groupchat, .incognito:
            let controller = GroupchatInfoViewController()
            controller.owner = targetOwner
            controller.jid = contact.jid
            controller.footerView.chatsDelegate = self
            controller.chatStateDelegate = self
            controller.leftMenuDelegate = self.leftMenuDelegate
            return controller
        }
    }

    internal func showSharedContactInfo(for contact: ContactAttachment) {
        guard let controller = makeSharedContactInfoController(for: contact) else {
            return
        }
        showModal(controller, parent: self)
        removeObservers()
    }
    
    func didStopPlayingAudioCell() {
        VoiceMessagePlaybackCoordinator.shared.stopPlayback()
    }
    
    func canChangeAudioPosition(for referencePrimary: String) -> Bool {
        VoiceMessagePlaybackCoordinator.shared.canSeek(referencePrimary: referencePrimary)
    }
    
    func didSetAudioPosition(_ audioView: InlineAudiosGridView.AudioView?, percentage: Float) -> TimeInterval {
        guard let primary = audioView?.primary else { return 0 }
        return VoiceMessagePlaybackCoordinator.shared.seek(referencePrimary: primary, percentage: percentage)
    }
    
    func didTapOnAudio(_ audioView: InlineAudiosGridView.AudioView?, url: URL?) {
        if self.recordedReferenceObject != nil {
            return
        }
        if AudioRecorder.shared.isRunning {
            return
        }
        guard let primary = audioView?.primary,
              let descriptor = self.voiceMessageDescriptor(referencePrimary: primary) else {
            self.view.makeToast("Unable to play sound at the moment, please try again".localizeString(id: "audio_error_play_failed", arguments: []))
            return
        }
        audioView?.url = descriptor.decodedURL
        VoiceMessagePlaybackCoordinator.shared.handleTap(descriptor)
    }
    
    func didTapErrorButton(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }

        guard let indexPath = indexPathFor(cell),
              let primary = self.datasourceItem(at: indexPath)?.primary,
              let item = self.timelineSession?.snapshot.item(primary: primary) else {
            return
        }
        
        
        
        if item.messageError == "cert_error" || item.messageError == "omemo" {
            let vc = MessageSigningInfoViewController()
            vc.conversationType = self.conversationType
            vc.messagePrimary = primary
            vc.jid = self.jid
            vc.owner = self.owner
            showModal(vc, parent: self)
        } else {
            let errorMessage = "Unable to send file: \(item.messageError ?? "Unexpected error")"//
            let items = [
                ActionSheetPresenter.Item(destructive: false, title: "Resend", value: "retry"),
                ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete"),
            ]
            let itemsWithQuota = [
                ActionSheetPresenter.Item(destructive: false, title: self.blockInputFieldByTimeSignature.value ? "Update signature" :  "Retry", value: "retry"),
                ActionSheetPresenter.Item(destructive: false, title: "Manage Cloud Storage", value: "quota"),
                ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Message sending error",
                message: errorMessage,
                cancel: "Cancel",
                values: ["403", "400"].contains(item.messageErrorCode) ? itemsWithQuota : items,
                animated: true) { value in
                    switch value {
                        case "retry":
                            self.retryMessageSend(primary)
                        case "delete":
                            self.deleteSendingMessage(primary)
                        case "quota":
                            let vc = CloudStorageViewController()
                            vc.configure(jid: self.owner)
                            showModal(vc, parent: self)
                        default:
                            break
                    }
                }
//            if let view = (cell as? MessageContentCell)?.messageContainerView {
//                let error = ContextMenuItemWithImage(title: "Network error: quota exceeded", image: UIImage(imageLiteralResourceName: "information"))
//                let retry = ContextMenuItemWithImage(title: "Retry", image: UIImage(imageLiteralResourceName: "share"))
//                let quota = ContextMenuItemWithImage(title: "Manage quota", image: UIImage(imageLiteralResourceName: "menu"))
//                let delete = ContextMenuItemWithImage(title: "Delete", image: UIImage(imageLiteralResourceName: "trash"))
//                CM.MenuConstants.BottomMarginSpace = 54
//                CM.MenuConstants.BlurEffectDefault = UIBlurEffect(style: .regular)
////                CM.MenuConstants.
//                CM.items = [error, quota, retry, delete]
//                CM.showMenu(viewTargeted: view, delegate: self, animated: false)
//            }
        }
    }
    
    private func retryMessageSend(_ primary: String) {
        if self.showSkeletonObserver.value {
            return
        }
        if self.blockInputFieldByTimeSignature.value  {
            onSignButtonTouchUpInside()
        } else {
            retryMessageSendAfterQuotaCheck(primary)
        }
    }

    private func retryMessageSendAfterQuotaCheck(_ primary: String) {
        if mediaQuotaCheckIsRequired(for: primary) {
            CloudStorageQuotaRefreshCoordinator.shared.refresh(owner: self.owner, reason: .preUploadValidation, force: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch MediaUploadQuotaPolicy.currentAccess(jid: self.owner) {
                    case .available:
                        self.performRetryMessageSend(primary)
                    case .premiumRequired:
                        let didPresent = SubscribtionsPresenter().present(animated: true, owner: self.owner, parent: self)
                        if !didPresent {
                            ToastPresenter().presentError(message: "Premium is required to send images.".localizeString(id: "media_picker_error_premium_required", arguments: []))
                        }
                    }
                }
            }
        } else {
            performRetryMessageSend(primary)
        }
    }

    private func mediaQuotaCheckIsRequired(for primary: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) else {
                return false
            }
            return instance.references.contains { $0.kind == .media }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func performRetryMessageSend(_ primary: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                try realm.write {
                    instance.state = .sending
                    instance.messageError = nil
                }
            }
            LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.messages.retrySending(item: primary)
        })
    }
    
    private func deleteSendingMessage(_ primary: String) {
        if self.showSkeletonObserver.value {
            return
        }
        if !deletePendingOutgoingMessageLocally(primary) {
            deleteMessages(forIds: Set([primary]))
        }
    }
    
    func didTapAvatar(in cell: MessageCollectionViewCell) {
        return
    }
    
    func didTap(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        if isInSelectionMode.value {
            selectMessage(in: cell)
        } else {
            self.messagesCollectionView.endEditing(true)
        }
    }
    
    func didTapMessage(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        dismissKeyboard()
        if isInSelectionMode.value {
            selectMessage(in: cell)
        }
    }
    
    func didTapCellTopLabel(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        dismissKeyboard()
        if isInSelectionMode.value {
            selectMessage(in: cell)
        }
    }
    
    func didTapMessageTopLabel(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        dismissKeyboard()
        if isInSelectionMode.value {
            selectMessage(in: cell)
        }
    }
    
    func didTapMessageBottomLabel(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        dismissKeyboard()
        if isInSelectionMode.value {
            selectMessage(in: cell)
        }
    }
    
    func onLongTap(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        selectMessage(in: cell)
    }
    
    func onLongTapMessage(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        if self.isInSelectionMode.value {
            return
        }
        guard let indexPath = indexPathFor(cell) else {
                return
        }
        guard let item = datasourceItem(at: indexPath) else {
            return
        }
        let primary = item.primary
        let hasMedia = item.images.isNotEmpty || item.videos.isNotEmpty || item.files.isNotEmpty || item.audios.isNotEmpty
        let isLocallyDeletablePending = PendingOutgoingMessageDeletionPolicy.canDeleteLocally(
            outgoing: item.isOutgoing,
            archivedId: item.archivedId ?? "",
            state: item.state
        )
//        CM.updateWindow(window: self.view)
        
        CM.currentMessagePrimary = primary
        if item.state == .error {
            CM.items = [[
                ContextMenuItemWithImage(title: "Resend", image: imageLiteral("arrowshape.turn.up.backward")!, value: "retry", danger: false)
            ],[
                ContextMenuItemWithImage(title: "Delete", image: imageLiteral("trash")!, value: isLocallyDeletablePending ? "delete_error" : "delete", danger: true)
            ]]
        } else if item.isOutgoing {
            var actions = [
                ContextMenuItemWithImage(title: "Reply", image: imageLiteral("arrowshape.turn.up.backward")!, value: "reply", danger: false),
                ContextMenuItemWithImage(title: "Forward", image: imageLiteral("arrowshape.turn.up.right")!, value: "forward", danger: false),
                ContextMenuItemWithImage(title: "Copy", image: imageLiteral("doc.on.doc")!, value: "copy", danger: false),
                ContextMenuItemWithImage(title: "Edit", image: imageLiteral("xabber.pencil.cap")!, value: "edit", danger: false),
                ContextMenuItemWithImage(title: "Select", image: imageLiteral("checkmark.circle")!, value: "select", danger: false),
                ContextMenuItemWithImage(title: "Report Message".localizeString(id: "report_message_action", arguments: []), image: imageLiteral("exclamationmark.circle")!, value: "report", danger: false)
            ]
            if hasMedia {
                actions.append(ContextMenuItemWithImage(title: "Report Media".localizeString(id: "report_media_action", arguments: []), image: imageLiteral("exclamationmark.circle")!, value: "report_media", danger: false))
            }
            if let pinItem = pinnedMessageContextMenuItem(for: item) {
                actions.append(pinItem)
            }
            CM.items = [actions, [
                ContextMenuItemWithImage(title: "Delete", image: imageLiteral("trash")!, value: isLocallyDeletablePending ? "delete_sending" : "delete", danger: true)
            ]]
        } else {
            var actions = [
                ContextMenuItemWithImage(title: "Reply", image: imageLiteral("arrowshape.turn.up.backward")!, value: "reply", danger: false),
                ContextMenuItemWithImage(title: "Forward", image: imageLiteral("arrowshape.turn.up.right")!, value: "forward", danger: false),
                ContextMenuItemWithImage(title: "Copy", image: imageLiteral("doc.on.doc")!, value: "copy", danger: false),
                ContextMenuItemWithImage(title: "Select", image: imageLiteral("checkmark.circle")!, value: "select", danger: false),
                ContextMenuItemWithImage(title: "Report Message".localizeString(id: "report_message_action", arguments: []), image: imageLiteral("exclamationmark.circle")!, value: "report", danger: false)
            ]
            if hasMedia {
                actions.append(ContextMenuItemWithImage(title: "Report Media".localizeString(id: "report_media_action", arguments: []), image: imageLiteral("exclamationmark.circle")!, value: "report_media", danger: false))
            }
            if let pinItem = pinnedMessageContextMenuItem(for: item) {
                actions.append(pinItem)
            }
            CM.items = [actions, [
                ContextMenuItemWithImage(title: "Delete", image: imageLiteral("trash")!, value: "delete", danger: true)
            ]]
        }
        dismissKeyboard()
        CM.showMenu(viewTargeted: cell.contentView, delegate: self, animated: true)
    }

    private func pinnedMessageContextMenuItem(
        for item: ChatViewController.Datasource
    ) -> ContextMenuItemWithImage? {
        guard let groupStanzaID = item.archivedId,
              let action = ChatPinnedMessageActionPolicy.action(
                groupStanzaID: groupStanzaID,
                pinnedMessageIDs: canonicalGroupProjectionState?.pinnedMessageIDs,
                canPin: item.canPinMessage
              ) else {
            return nil
        }
        let title: String
        switch action {
        case .pin:
            title = "Pin".localizeString(id: "message_pin", arguments: [])
        case .unpin:
            title = "Unpin".localizeString(
                id: "group_chat__pinned_message__tooltip_unpin",
                arguments: []
            )
        }
        return ContextMenuItemWithImage(
            title: title,
            image: UIImage(systemName: action == .pin ? "pin" : "pin.slash")
                ?? imageLiteral("menu")!,
            value: action.rawValue,
            danger: false
        )
    }

    private func reportableMediaReferencePrimary(for messagePrimary: String) -> String? {
        do {
            let realm = try WRealm.safe()
            return realm
                .object(ofType: MessageStorageItem.self, forPrimaryKey: messagePrimary)?
                .references
                .first(where: { reference in
                    !reference.isLocallyHiddenByReport && [.media, .voice].contains(reference.kind)
                })?
                .primary
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }
    
    func onSwipe(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        if isInSelectionMode.value {
            return
        }
        guard let indexPath = indexPathFor(cell) else {
                return
        }
        guard let item = datasourceItem(at: indexPath) else {
            return
        }
        let primary = item.primary
        self.inSearchMode.accept(false)
        self.forwardedIds.accept(Set<String>())
        attachedMessagesIds.accept([primary])
    }
    
    func selectMessage(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        if self.inSearchMode.value {
            self.inSearchMode.accept(false)
        }
        
        if attachedMessagesIds.value.isNotEmpty || (editMessageId.value?.isNotEmpty ?? false) { return }
        if let contentCell = cell as? MessageContentCell {
            guard let indexPath = self.messagesCollectionView.indexPath(for: cell) else { return }
            guard let datasourceItemPrimary = self.datasourceItem(at: indexPath)?.primary else { return }
            guard let item = self.timelineSession?.snapshot.item(primary: datasourceItemPrimary) else { return }
            if item.displayAs == .system { return }
            if forwardedIds.value.contains(item.primary) {
                contentCell.setSelected(state: false)
                var value = self.forwardedIds.value
                value.remove(item.primary)
                self.forwardedIds.accept(value)
//                forwardedIds.value.remove(item.primary)
                if forwardedIds.value.isEmpty {
                    self.disableSelectMode()
                }
            } else {
                contentCell.setSelected(state: true)
                self.enableSelectMode()
                var value = self.forwardedIds.value
                value.insert(item.primary)
                self.forwardedIds.accept(value)
//                forwardedIds.value.insert(item.primary)
            }
        }
        if forwardedIds.value.isEmpty {
            self.disableSelectMode()
        }
    }
    
    func isSelected(primary: String) -> Bool {
        if self.inSearchMode.value {
            return false
        }
        if !self.isInSelectionMode.value {
            return false
        }
        return self.forwardedIds.value.contains(primary)
    }
    
    func enableSelectMode() {
        if self.showSkeletonObserver.value {
            return
        }
        if !isInSelectionMode.value {
            isInSelectionMode.accept(true)
        }
    }
    
    func disableSelectMode() {
        if self.showSkeletonObserver.value {
            return
        }
        if isInSelectionMode.value {
            isInSelectionMode.accept(false)
        }
    }
    
    @objc func deselectAllMessages() {
        if self.showSkeletonObserver.value {
            return
        }
        if forwardedIds.value.isNotEmpty {
            self.forwardedIds.accept(Set<String>())
//            forwardedIds.value.removeAll()
            self.messagesCollectionView.visibleCells.forEach {
                cell in
                guard let contentCell = cell as? MessageContentCell else { return }
                contentCell.setSelected(state: false)
            }
        }
        self.disableSelectMode()
        self.applyChatDatasource(
            self.datasource,
            mode: .fullReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine
        )
    }
    
    func downloadVideo(_ primary: String) {
        if self.showSkeletonObserver.value {
            return
        }
        do {
            let realm = try WRealm.safe()
            if let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary) {
                reference.prepare()
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func playVideo(withURL: URL?) {
        guard let url = withURL else { return }
        
        let player = AVPlayer(url: url)
        
        let controller = AVPlayerViewController()
        controller.player = player
        
        present(controller, animated: true) {
            player.play()
        }
    }
    
    func showGallery(urls: [URL], from url: URL) {
        let gallery = PhotoGallery(urls: urls, from: url)
        gallery.chatVCDelegate = self
        
        let nvc = UINavigationController(rootViewController: gallery)
        nvc.modalPresentationStyle = .fullScreen

        gallery.initialPage = urls.firstIndex(of: url) ?? 0
        present(nvc, animated: true, completion: nil)
        
    }
    
//    func onCopyMessage(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//
////        item.createLegacyBody()
//        switch item.displayAs {
//        case .initial: break
//        case .text, .quote:
//            UIPasteboard.general.string = item.legacyBody
//        case .files:
//            UIPasteboard.general.string = item.legacyBody
//        case .images:
//            UIPasteboard.general.string = item.legacyBody
//        case .voice:
//            UIPasteboard.general.string = item.legacyBody
//        case .call: break
//        case .system: break
//        case .sticker: break
//        }
//
//    }
//
//    func onReplyMessage(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        self.forwardedIds.accept(Set<String>())
////        forwardedIds.value.removeAll()
//        print("Call empty", #function)
//        attachedMessagesIds.accept([primary])
//    }
//
//    func onShareMessage(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        self.forwardedIds.accept(Set<String>())
//        let messageSet: Set = [primary]
//        forwardedIds.accept(messageSet)
////        forwardedIds.value.insert(primary)
//        showShareViewController(Array(forwardedIds.value))
//        cancelSelection()
//    }
//
//    func onDeleteMessage(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        deleteMessages(forIds: Set<String>([primary]))
//    }
//
//    func onMoreAction(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        var value = self.forwardedIds.value
//        value.insert(primary)
//        self.forwardedIds.accept(value)
////        forwardedIds.value.insert(primary)
//    }
//
//    func onRetrySending(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        DispatchQueue.global(qos: .default).async {
//            do {
//                let realm = try WRealm.safe()
//                try realm.write {
//                    realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)?.state = .sending
//                }
//            } catch {
//                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//            }
//        }
//        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//            user.messages.retrySending(item: primary)
//        })
//    }
//
//    func onEdit(cell: MessageCollectionViewCell) {
//        if attachedMessagesIds.value.isNotEmpty || forwardedIds.value.isNotEmpty { return }
//        guard let indexPath = indexPathFor(cell),
//            let item = residentMessages?[indexPath.section] else {
//                return
//        }
//        self.xabberInputView.textField.text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
//        editMessageId.accept(item.primary)
//    }
//
    func isEditable(cell: MessageCollectionViewCell) -> Bool {
        if self.showSkeletonObserver.value {
            return false
        }
        guard MessageDeleteManager.availability(owner),
              let indexPath = indexPathFor(cell),
              let primary = self.datasourceItem(at: indexPath)?.primary,
              let item = self.timelineSession?.snapshot.item(primary: primary) else {
            return false
        }
        return item.outgoing && item.archivedId.isNotEmpty && item.displayAs == .text
    }
    
    private func indexPathFor(_ cell: MessageCollectionViewCell) -> IndexPath? {
         return messagesCollectionView.indexPath(for: cell)
    }
    
    func onTapAttachment(cell: MessageCollectionViewCell, inlineItem: Bool, messageId: String?, index: Int, isSubforward: Bool) {
//        if self.showSkeletonObserver.value {
//            return
//        }
//
//        guard let indexPath = indexPathFor(cell) else {
//                return
//        }
//        let primary = self.datasource[indexPath.section].primary
//        let item = datasource[indexPath.section]
//        if inlineItem {
//            if let inline = item.forwards.first(where: { $0.messageId == messageId }) {
//                if isSubforward {
//                    self.showSubforwards(inline.subforwards.sorted(by: { ($0.originalDate ?? Date()) > ($1.originalDate ?? Date()) }))
//                } else {
//                    switch inline.kind {
//                    case .text, .quote:
//                        break
//                    case .images:
//                        showGallery(from: inline
//                                            .references
//                                            .filter({ $0.mimeType == MimeIconTypes.image.rawValue }),
//                                    start: index,
//                                    messageId: primary)
//                    case .videos:
//                        if inline.references[index].isDownloaded {
//                            playVideo(withURL: inline.references[index].localFileUrl)
//                        } else {
//                            downloadVideo(inline.references[index].primary)
//                        }
//                        
//                    case .files:
//                        if let uri = inline
//                            .references
//                            .filter({ $0.kind == .media })[index]
//                            .metadata?["uri"] as? String {
//                            openFile(URL(string: uri))
//                        }
//                    case .voice:
//                        didTapAudioCell(cell: cell, messageId: messageId, at: nil)
//                    }
//                }
//            }
//        } else {
//            switch item.kind {
//            case .photos(let photos):
//                showGallery(from: photos, start: index, messageId: primary)
//                
//            case .files(let files): //Videos go as files with mimeType == "video"
//                let _ = files.map {
//                    if $0.mimeType == "video" {
//                        playVideo(withURL: $0.downloadUrl)
//                        
//                    } else {
//                        openFile($0.downloadUrl)
//                    }
//                }
//            case .audio(_):
//                didTapAudioCell(cell: cell, messageId: nil, at: nil)
//            default: break
//            }
//        }
    }
    
    internal func openFile(_ url: URL?) {
        guard let url = url,
            UIApplication.shared.canOpenURL(url) else {
                return
        }
        YesNoPresenter().present(in: self, title: "Open this file", message: url.lastPathComponent, yesText: "Open", noText: "Cancel", animated: true) { (value) in
            if value {
                UIApplication.shared.open(url, options: [:]) { (_) in }
            }
        }
    }
    
    func didTapAudioCell(cell: MessageCollectionViewCell, messageId: String?, at index: Int?) {
        if self.showSkeletonObserver.value {
            return
        }
//
//        func play(at indexPath: IndexPath, messageId: String?, index: Int?) {
//            let references: [MessageReferenceStorageItem]?
//            
//            if let messageId = messageId {
//                references = residentMessages?[indexPath.section]
//                    .inlineForwards
//                    .first(where: { $0.messageId == messageId })?
//                    .references
//                    .toArray()
//            } else {
//                references = residentMessages?[indexPath.section]
//                    .references
//                    .toArray()
//                    .filter({ $0.kind == .voice })
//            }
//            
//            let reference: MessageReferenceStorageItem?
//            
//            if let index = index {
//                reference = references?[index]
//            } else {
//                reference = references?.first
//            }
//            
//            guard let item = reference else { return }
//            if !item.isDownloaded {
//                if item.metadata?["localFileUri"] == nil {
//                    item.prepare()
//                    return
//                }
//            }
//            
//            if let uri = item.metadata?["uri"] as? String,
//                let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") {
//                if OpusAudio.shared.currentPlayedFileUri != uri {
//                    OpusAudio.shared.resetPlayer()
//                }
//                OpusAudio.shared.getPlayer(for: url)
//            } else if let uri = item.metadata?["uriEmbded"] as? String,
//                      let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") {
//                if !OpusAudio.shared.getPlayerForPreview(for: url) {
//                    if let uri = item.metadata?["uri"] as? String,
//                        let url = URL(string: uri.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? "") {
//                        OpusAudio.shared.getPlayer(for: url)
//                    } else {
//                        return
//                    }
//                }
//            } else {
//                return
//            }
//            
//            playingMessageIndexPath = nil
//            
//            playingMessageUpdateTimer?.fire()
//            playingMessageUpdateTimer?.invalidate()
//            playingMessageUpdateTimer = nil
//            OpusAudio.shared.player?.delegate = self
//            playingMessageIndexPath = PlayingAudioCell(indexPath: indexPath,
//                                                       isForward: index != nil,
//                                                       index: nil,
//                                                       messageId: messageId,
//                                                       isPlaying: true)
//            if let path = playingMessageIndexPath,
//                let cell = messagesCollectionView.cellForItem(at: path.indexPath) as? CommonMessageCell {
//                cell.updateAudio(next: .play, messageId: path.messageId)
//            }
//            
//            OpusAudio.shared.player?.play()
//            playingMessageUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.2,
//                                                             repeats: true,
//                                                             block: playingMessageUpdateTimerCallback)
//        }
//        
//        func stop() {
//            if let path = playingMessageIndexPath,
//                let cell = messagesCollectionView.cellForItem(at: path.indexPath) as? CommonMessageCell {
//                cell.updateAudio(next: .pause, messageId: path.messageId)
//            }
//            OpusAudio.shared.player?.pause()
//            playingMessageIndexPath?.isPlaying = false
//            playingMessageUpdateTimer?.invalidate()
//            playingMessageUpdateTimer = nil
//        }
//        
//        guard let path = self.messagesCollectionView.indexPath(for: cell) else { return }
//        
//        if let current = playingMessageIndexPath {
//            if current.indexPath == path,
//                current.messageId == messageId,
//                current.index == index {
//                if current.isPlaying {
//                    stop()
//                } else {
//                    play(at: path, messageId: messageId, index: index)
//                }
//            } else {
//                (messagesCollectionView.cellForItem(at: current.indexPath) as? CommonMessageCell)?
//                    .updateAudio(next: .stop, messageId: current.messageId)
//                stop()
//                play(at: path, messageId: messageId, index: index)
//            }
//        } else {
//            play(at: path, messageId: messageId, index: index)
//        }
    }
    
    func didTapOnInitialFooterLabel(in cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
    }
    
    
    func onTapVoiceCall(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        VoIPManager.shared.startCall(owner: self.owner, jid: self.jid)
    }
    
}

extension ChatViewController: AudioPlayerBarViewDelegate {
    func audioPlayerBarViewDidTapClose(_ view: AudioPlayerBarView) {
        if VoiceMessagePlaybackCoordinator.shared.hasActivePlayback {
            VoiceMessagePlaybackCoordinator.shared.stopPlayback()
            self.hideSharedAudioPanel()
            self.sharedPlayerPaneldelegae?.shouldHide()
            return
        }
        self.hideSharedAudioPanel()
        self.sharedPlayerPaneldelegae?.shouldHide()
        self.xabberInputView.recordAndPlayPanel.pause()
        AudioManager.shared.player?.pause()
    }
    
    func audioPlayerBarViewDidTapPlayPause(_ view: AudioPlayerBarView) {
        if let snapshot = VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot,
           let descriptor = self.voiceMessageDescriptor(referencePrimary: snapshot.referencePrimary) {
            VoiceMessagePlaybackCoordinator.shared.handleTap(descriptor)
            return
        }
        if AudioManager.shared.player?.isPlaying == true {
            self.xabberInputView.recordAndPlayPanel.pause()
            AudioManager.shared.player?.pause()
            self.sharedAudioPlayerPanel?.swapState(to: .paused)
        } else {
            self.xabberInputView.recordAndPlayPanel.continuePlay()
            AudioManager.shared.player?.play()
            self.sharedAudioPlayerPanel?.swapState(to: .playing)
        }
    }
    
    func audioPlayerBarViewDidTapTitle(_ view: AudioPlayerBarView) {
        if let route = VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot?.route,
           route.owner == self.owner,
           route.jid == self.jid,
           route.conversationType == self.conversationType {
            self.scrollToMessage(
                messagePrimary: route.messagePrimary,
                archivedId: route.archivedId,
                date: route.sourceDate,
                centered: true,
                animated: false,
                highlight: true
            )
            return
        }
        if let primary = VoiceMessagePlaybackCoordinator.shared.currentPlaybackSnapshot?.containerMessagePrimary {
            self.scrollToMessage(
                messagePrimary: primary,
                archivedId: nil,
                date: Date(),
                centered: true,
                animated: false,
                highlight: true
            )
            return
        }
        if let primary = AudioManager.shared.messagePrimary {
            self.scrollToSearchedMessage(primary: primary)
        }
    }
    
    
}

final class ChatLocationMapViewController: UIViewController {
    let displayedLocation: LocationAttachment

    private let mapView = MKMapView()
    private let addressLabel: ChatLocationMapCaptionLabel = {
        let label = ChatLocationMapCaptionLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.backgroundColor = .systemBackground
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        return label
    }()

    init(location: LocationAttachment) {
        self.displayedLocation = location
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Location".localizeString(id: "location_fragment__address_error__title", arguments: [])
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Open".localizeString(id: "open", arguments: []),
            style: .plain,
            target: self,
            action: #selector(openInMaps)
        )
        setupMap()
        setupAddressLabel()
    }

    private func setupMap() {
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let annotation = MKPointAnnotation()
        annotation.coordinate = displayedLocation.coordinate
        annotation.title = displayedLocation.address
        mapView.addAnnotation(annotation)
        mapView.setRegion(
            MKCoordinateRegion(
                center: displayedLocation.coordinate,
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            ),
            animated: false
        )
    }

    private func setupAddressLabel() {
        let text = displayedLocation.address?.isNotEmpty == true ? displayedLocation.address : displayedLocation.geoURI
        addressLabel.text = text ?? displayedLocation.geoURI
        view.addSubview(addressLabel)
        NSLayoutConstraint.activate([
            addressLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            addressLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            addressLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }

    @objc
    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: displayedLocation.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = displayedLocation.address ?? displayedLocation.geoURI
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: displayedLocation.coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(
                mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        ])
    }
}

final class ChatLocationMapCaptionLabel: UILabel {
    let contentInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + contentInsets.left + contentInsets.right,
            height: size.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: contentInsets)
        let textRect = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return textRect.inset(
            by: UIEdgeInsets(
                top: -contentInsets.top,
                left: -contentInsets.left,
                bottom: -contentInsets.bottom,
                right: -contentInsets.right
            )
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }
}
