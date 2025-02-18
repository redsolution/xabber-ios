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
import Alamofire
import ContextMenuSwift

extension ChatViewController: ContextMenuDelegate {
    func contextMenuDidSelect(_ contextMenu: ContextMenuSwift.ContextMenu, cell: ContextMenuSwift.ContextMenuCell, targetedView: UIView, didSelect item: ContextMenuSwift.ContextMenuItem, forRowAt index: Int) -> Bool {
        return false
    }
    
    func contextMenuDidDeselect(_ contextMenu: ContextMenuSwift.ContextMenu, cell: ContextMenuSwift.ContextMenuCell, targetedView: UIView, didSelect item: ContextMenuSwift.ContextMenuItem, forRowAt index: Int) {
        
    }
    
    func contextMenuDidAppear(_ contextMenu: ContextMenuSwift.ContextMenu) {
        
    }
    
    func contextMenuDidDisappear(_ contextMenu: ContextMenuSwift.ContextMenu) {
        
    }
    
    
}

extension ChatViewController: MessageCellDelegate {
    func isInSelection() -> Bool {
        return self.isInSelectionMode.value
    }
    
    
    
    func didTapErrorButton(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }

        guard let indexPath = indexPathFor(cell),
            let item = messagesObserver?[indexPath.section] else {
                return
        }
        let primary = item.primary
        
        
        
        if item.messageError == "cert_error" || item.messageError == "omemo" {
            let vc = MessageSigningInfoViewController()
            vc.conversationType = self.conversationType
            vc.messagePrimary = primary
            vc.jid = self.jid
            vc.owner = self.owner
            showModal(vc)
        } else {
            let errorMessage = "Unable to send file: \(item.messageError ?? "Unexpected error")"//
            let items = [
                ActionSheetPresenter.Item(destructive: false, title: "Retry", value: "retry"),
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
                            showModal(vc)
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
    }
    
    private func deleteSendingMessage(_ primary: String) {
        if self.showSkeletonObserver.value {
            return
        }
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func didTapAvatar(in cell: MessageCollectionViewCell) {
//        if self.showSkeletonObserver.value {
//            return
//        }
//        if groupchat {
//            guard let indexPath = indexPathFor(cell),
//                let item = messagesObserver?[indexPath.section],
//                let userId = item.groupchatMetadata?["id"] as? String else {
//                    return
//            }
//            let vc = GroupchatContactInfoViewController()
//            vc.owner = self.owner
//            vc.jid = self.jid
//            vc.userId = userId
//            vc.shouldResetNavbar = true
//            showModal(vc)
//        }
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
    
    func onSwipe(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        if isInSelectionMode.value {
            return
        }
        guard let indexPath = indexPathFor(cell),
            let item = messagesObserver?[indexPath.section] else {
                return
        }
        let primary = item.primary
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
            let item = self.messagesObserver![indexPath.section]
            if item.displayAs == .system { return }
            contentCell.setSelected(UIColor.blue.withAlphaComponent(0.2))
            if forwardedIds.value.contains(item.primary) {
                var value = self.forwardedIds.value
                value.remove(item.primary)
                self.forwardedIds.accept(value)
//                forwardedIds.value.remove(item.primary)
                if forwardedIds.value.isEmpty {
                    self.disableSelectMode()
                }
            } else {
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
                if contentCell.isSelected() {
                    contentCell.setSelected(UIColor.blue.withAlphaComponent(0.2))
                }
            }
        }
        self.disableSelectMode()
        self.messagesCollectionView.reloadDataAndKeepOffset()
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
    
    func showGallery(from array: [MessageReferenceStorageItem.Model], start image: Int, messageId: String) {
//        if array[0].isOriginalMissed
        if self.showSkeletonObserver.value {
            return
        }
        var urls: [URL] = array.compactMap {
            item in
            guard let urlUnwr = item.metadata?["uri"] as? String,
                let url = URL(string: urlUnwr) else { return nil}
            return url
        }
        
        let senderInfo = PhotoGallery.getSenderName(messageId: messageId)
        
        if image > 0 {
            let prefix = urls.prefix(upTo: image < urls.count ? image : 0)
            let suffix = urls.suffix(from: image < urls.count ? image : 0)
            urls = Array(suffix)
            urls.append(contentsOf: prefix)
        }
        
        let gallery = PhotoGallery(urls: urls,
                                   senders: [senderInfo.senderName],
                                   dates: [senderInfo.date],
                                   times: [senderInfo.time],
                                   messageIds: [messageId],
                                   calledFromChat: true)
        gallery.chatVCDelegate = self
        
        let nvc = UINavigationController(rootViewController: gallery)
        nvc.modalPresentationStyle = .fullScreen

        gallery.initialPage = image
        present(nvc, animated: true, completion: nil)
        
    }
    
//    func onCopyMessage(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = messagesObserver?[indexPath.section] else {
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
//            let item = messagesObserver?[indexPath.section] else {
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
//            let item = messagesObserver?[indexPath.section] else {
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
//            let item = messagesObserver?[indexPath.section] else {
//                return
//        }
//        let primary = item.primary
//        deleteMessages(forIds: Set<String>([primary]))
//    }
//
//    func onMoreAction(cell: MessageCollectionViewCell) {
//        guard let indexPath = indexPathFor(cell),
//            let item = messagesObserver?[indexPath.section] else {
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
//            let item = messagesObserver?[indexPath.section] else {
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
//            let item = messagesObserver?[indexPath.section] else {
//                return
//        }
//        self.xabberInputView.textField.text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
//        editMessageId.accept(item.primary)
//    }
//
//    func onPinMessage(cell: MessageCollectionViewCell) {
//        guard groupchat,
//            let indexPath = indexPathFor(cell),
//            let item = messagesObserver?[indexPath.section] else {
//                return
//        }
//        var origin = self.view.center
//        let keyboardHeight = 432 / UIScreen.main.scale
//        if self.view.bounds.height - origin.x < keyboardHeight {
//            origin.x = self.view.bounds.height - keyboardHeight - 44
//        }
//        self.view.makeToastActivity(origin)
//        let messageId = item.archivedId
//        guard messageId.isNotEmpty else { return }
//
//        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//            session.groupchat?.pinMessage(stream, groupchat: self.jid, message: messageId) { (error) in
//                DispatchQueue.main.async {
//                    self.view.hideToastActivity()
//                    if let error = error {
//                        var message = "Internal error: \(error)"
//                        switch error {
//                        case "not-allowed": message = "You haven`t permissions to pin messages"
//                        default: break
//                        }
//                        self.showToast(error: message)
//                    } else {
//                        self.pinnedMessageId.accept(messageId)
//                    }
//                }
//            }
//        }) {
//            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                user.groupchats.pinMessage(stream, groupchat: self.jid, message: messageId) { (error) in
//                    DispatchQueue.main.async {
//                        self.view.hideToastActivity()
//                        if let error = error {
//                            var message = "Internal error: \(error)"
//                            switch error {
//                            case "not-allowed": message = "You haven`t permissions to pin messages"
//                            default: break
//                            }
//                            self.showToast(error: message)
//                        } else {
//                            self.pinnedMessageId.accept(messageId)
//                        }
//                    }
//                }
//            })
//        }
//
//
//    }
    
    func isEditable(cell: MessageCollectionViewCell) -> Bool {
        if self.showSkeletonObserver.value {
            return false
        }
        guard MessageDeleteManager.availability(owner),
            let indexPath = indexPathFor(cell),
            let item = messagesObserver?[indexPath.section] else {
                return false
        }
        return item.outgoing && item.archivedId.isNotEmpty && item.displayAs == .text
    }
    
    private func indexPathFor(_ cell: MessageCollectionViewCell) -> IndexPath? {
         return messagesCollectionView.indexPath(for: cell)
    }
    
    func onTapAttachment(cell: MessageCollectionViewCell, inlineItem: Bool, messageId: String?, index: Int, isSubforward: Bool) {
        if self.showSkeletonObserver.value {
            return
        }

        guard let indexPath = indexPathFor(cell) else {
                return
        }
        let primary = self.datasource[indexPath.section].primary
        let item = datasource[indexPath.section]
        if inlineItem {
            if let inline = item.forwards.first(where: { $0.messageId == messageId }) {
                if isSubforward {
                    self.showSubforwards(inline.subforwards.sorted(by: { ($0.originalDate ?? Date()) > ($1.originalDate ?? Date()) }))
                } else {
                    switch inline.kind {
                    case .text, .quote:
                        break
                    case .images:
                        showGallery(from: inline
                                            .references
                                            .filter({ $0.mimeType == MimeIconTypes.image.rawValue }),
                                    start: index,
                                    messageId: primary)
                    case .videos:
                        if inline.references[index].isDownloaded {
                            playVideo(withURL: inline.references[index].localFileUrl)
                        } else {
                            downloadVideo(inline.references[index].primary)
                        }
                        
                    case .files:
                        if let uri = inline
                            .references
                            .filter({ $0.kind == .media })[index]
                            .metadata?["uri"] as? String {
                            openFile(URL(string: uri))
                        }
                    case .voice:
                        didTapAudioCell(cell: cell, messageId: messageId, at: nil)
                    }
                }
            }
        } else {
            switch item.kind {
            case .photos(let photos):
                showGallery(from: photos, start: index, messageId: primary)
                
            case .files(let files): //Videos go as files with mimeType == "video"
                let _ = files.map {
                    if $0.mimeType == "video" {
                        playVideo(withURL: $0.downloadUrl)
                        
                    } else {
                        openFile($0.downloadUrl)
                    }
                }
            case .audio(_):
                didTapAudioCell(cell: cell, messageId: nil, at: nil)
            default: break
            }
        }
    }
    
    internal func showSubforwards(_ items: [MessageForwardsInlineStorageItem.Model]) {
        let vc = SubforwardsViewController()
        vc.configure(owner, jid: jid, items: items)
        showModal(vc)
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
//                references = messagesObserver?[indexPath.section]
//                    .inlineForwards
//                    .first(where: { $0.messageId == messageId })?
//                    .references
//                    .toArray()
//            } else {
//                references = messagesObserver?[indexPath.section]
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
//        var uri: URL? = nil
//        var title: String = ""
//        switch self.entity {
//        case .contact:
//            uri = URL(string: "https://www.xabber.com/learn/regular")
//            title = "Regular chats"
//        case .groupchat:
//            uri = URL(string: "https://www.xabber.com/learn/groups")
//            title = "Public groups"
//        case .bot:
//            uri = URL(string: "https://www.xabber.com/learn/bot")
//            title = "Bots"
//        case .server:
//            uri = URL(string: "https://www.xabber.com/learn/server")
//            title = "Servers"
//        case .incognitoChat:
//            uri = URL(string: "https://www.xabber.com/learn/incognito")
//            title = "Incognito groups"
//        case .privateChat:
//            uri = URL(string: "https://www.xabber.com/learn/private")
//            title = "Private chats"
//        case .encryptedChat:
//            uri = URL(string: "https://www.xabber.com/learn/encrypted")
//            title = "Encrypted chats"
//        case .issue:
//            uri = URL(string: "https://www.xabber.com/learn/issue")
//            title = "Issue"
//        }
//        guard let url = uri else { return }
//        
//        let vc = XabberWebViewController()
//        vc.configure(url: url, title: title)
//        showModal(vc)
    }
    
    
    func onTapVoiceCall(cell: MessageCollectionViewCell) {
        if self.showSkeletonObserver.value {
            return
        }
        VoIPManager.shared.startCall(owner: self.owner, jid: self.jid)
    }
    
}
