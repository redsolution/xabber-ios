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
import AVKit

extension SubforwardsViewController: MessageCellDelegate {
    func isInSelection() -> Bool {
        return true
    }
    
    func didTapOnInitialFooterLabel(in cell: MessageCollectionViewCell) {
        
    }
    
    func onTapVoiceCall(cell: MessageCollectionViewCell) {
        
    }
    
    func didTap(in cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapErrorButton(cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapMessage(in cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapAvatar(in cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapCellTopLabel(in cell: MessageCollectionViewCell) {
        return
    }
    
    func onPinMessage(cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapMessageTopLabel(in cell: MessageCollectionViewCell) {
        return
    }
    
    func didTapMessageBottomLabel(in cell: MessageCollectionViewCell) {
        return
    }
    
    func onCopyMessage(cell: MessageCollectionViewCell) {
        return
    }
    
    func onReplyMessage(cell: MessageCollectionViewCell) {
        return
    }
    
    func onShareMessage(cell: MessageCollectionViewCell) {
        return
    }
    
    func onDeleteMessage(cell: MessageCollectionViewCell) {
        return
    }
    
    func onMoreAction(cell: MessageCollectionViewCell) {
        return
    }
    
    func onRetrySending(cell: MessageCollectionViewCell) {
        return
    }
    
    func onEdit(cell: MessageCollectionViewCell) {
        return
    }
    
    func onTapAttachment(cell: MessageCollectionViewCell, inlineItem: Bool, messageId: String?, index: Int, isSubforward: Bool) {
        guard let indexPath = messagesCollectionView.indexPath(for: cell) else {
                return
        }
        let item = subforwards[indexPath.section]
        if inlineItem {
            if let inline = item.subforwards.first(where: { $0.messageId == messageId }) {
                if isSubforward {
                    showSubforwards(inline.subforwards.sorted(by: { ($0.originalDate ?? Date()) > ($1.originalDate ?? Date()) }))
                } else {
                    switch inline.kind {
                    case .text, .quote:
                        break
                    case .images:
                        showGallery(from: inline
                                            .references
                                            .filter({ $0.mimeType == MimeIconTypes.image.rawValue }),
                                    start: index,
                                    messageId: messageId ?? "")
                    case .videos:
                        playVideo(withURL: inline.references.first?.downloadUrl)
                    case .files:
                        if let uri = inline
                            .references
                            .filter({ $0.kind == .media })[index]
                            .metadata?["uri"] as? String {
                            openFile(URL(string: uri))
                        }
                    case .voice:
                        didTapAudioCell(cell: cell, messageId: messageId, at: nil)
                        break
                    }
                }
            }

        } else {
            switch item.kind {
            case .text, .quote:
                break
            case .files:
                if let uri = item
                    .references
                    .filter({ $0.kind == .media })[index]
                    .metadata?["uri"] as? String {
                    openFile(URL(string: uri))
                }
            case .images:
                showGallery(from: item
                                    .references
                                    .filter({ $0.mimeType == MimeIconTypes.image.rawValue }),
                            start: index,
                            messageId: messageId ?? "")
            case .videos:
                playVideo(withURL: item.references.first?.downloadUrl)
            case .voice:
                didTapAudioCell(cell: cell, messageId: nil, at: nil)
                break
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
        YesNoPresenter().present(in: self, title: "Open this file".localizeString(id: "open_file_message", arguments: []),
                                 message: url.lastPathComponent,
                                 yesText: "Open".localizeString(id: "groupchat_membership_type_open", arguments: []),
                                 noText: "Cancel".localizeString(id: "cancel", arguments: []),
                                 animated: true) { (value) in
            if value {
                UIApplication.shared.open(url, options: [:]) { (_) in }
            }
        }
    }
    
    func showGallery(from array: [MessageReferenceStorageItem.Model], start image: Int, messageId: String) {
        
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
                                   messageIds: [messageId])
        
        let nvc = UINavigationController(rootViewController: gallery)
        nvc.modalPresentationStyle = .overFullScreen

        gallery.initialPage = image
        present(nvc, animated: true, completion: nil)
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
    
    
    func didTapAudioCell(cell: MessageCollectionViewCell, messageId: String?, at index: Int?) {
//        
//        func play(at indexPath: IndexPath, messageId: String?, index: Int?) {
//            let references: [MessageReferenceStorageItem.Model]?
//            
//            if let messageId = messageId {
//                references = subforwards[indexPath.section]
//                    .subforwards
//                    .first(where: { $0.messageId == messageId })?
//                    .references
//            } else {
//                references = subforwards[indexPath.section]
//                    .references
//                    .filter({ $0.kind == .voice })
//            }
//            
//            let reference: MessageReferenceStorageItem.Model?
//            
//            if let index = index {
//                reference = references?[index]
//            } else {
//                reference = references?.first
//            }
//            
//            guard let item = reference else { return }
//            
//            if let uri = item.metadata?["uriEmbded"] as? String,
//                let url = URL(string: uri) {
//                if !OpusAudio.shared.getPlayerForPreview(for: url) {
//                    if let uri = item.metadata?["uri"] as? String,
//                        let url = URL(string: uri) {
//                        OpusAudio.shared.getPlayer(for: url)
//                    } else {
//                        return
//                    }
//                }
//            } else if let uri = item.metadata?["uri"] as? String,
//                let url = URL(string: uri) {
//                if OpusAudio.shared.currentPlayedFileUri != uri {
//                    OpusAudio.shared.resetPlayer()
//                }
//                OpusAudio.shared.getPlayer(for: url)
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
//            playingMessageIndexPath = ChatViewController.PlayingAudioCell(indexPath: indexPath,
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
////            OpusAudio.shared.player?.pause()
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
        
    func onLongTap(cell: MessageCollectionViewCell) {
        return
    }
    
    func onSwipe(cell: MessageCollectionViewCell) {
        onReplyMessage(cell: cell)
    }
}
