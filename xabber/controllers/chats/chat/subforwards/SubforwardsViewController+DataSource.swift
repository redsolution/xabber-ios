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
import MaterialComponents.MDCPalettes

extension SubforwardsViewController: MessagesDataSource {
    
    
    func currentSender() -> Sender {
        return self.ownerSender
    }
    
    func isFromCurrentSender(message: MessageType) -> Bool {
        return message.sender == currentSender()
    }
    
    func messageBottomPadding(at indexPath: IndexPath) -> CGFloat {
        return 4
    }
    
    func showTopLabel(for message: MessageType) -> Bool {
        return true
    }
    
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType {
        let item = subforwards[indexPath.section]
        let kind: MessageKind
        
        switch item.kind {
        case .text:
            kind = .attributedText(item.attributedBody, false, item.attributedAuthor)
        case .images:
            kind = .photos(Array(item.references.filter({ $0.kind == .media })))
        case .videos:
            kind = .videos(Array(item.references.filter({ $0.kind == .media && $0.mimeType == "video" })))
        case .files:
            kind = .files(Array(item.references.filter({ [.media, .voice].contains($0.kind) })))
        case .voice:
            kind = .audio(Array(item.references))
        case .quote:
            kind = .quote(item.attributedQuotes, item.attributedAuthor)
        }
        let isDownloaded = !item.references.filter { $0.isDownloaded }.isEmpty
        
        return ChatViewController.Datasource (
            primary: item.parentId, //TODO
            jid: self.jid,
            owner: self.owner,
            outgoing: item.isOutgoing,
            sender: item.isOutgoing ? self.ownerSender : self.opponentSender,
            messageId: item.messageId,
            sentDate: item.originalDate ?? Date(),
            editDate: nil,
            kind: kind,
            withAuthor: !item.isOutgoing,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: item.subforwards.sorted(by: { ($0.originalDate ?? Date()) > ($1.originalDate ?? Date()) }),
            isOutgoing: item.isOutgoing,
            isEdited: false,
            groupchatAuthorRole: item.groupchatMetadata?["role"] as? String ?? "member",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: isDownloaded,
//            isDownloaded: true,
            state: .none
        )
    }
    
    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int {
        return self.subforwards.count
    }
    
    func numberOfItems(inSection section: Int, in messagesCollectionView: MessagesCollectionView) -> Int {
        return 1
    }
    
    func isDateChange(from oldDate: Date?, to newDate: Date?) -> Bool {
        guard let oldDate = oldDate,
            let newDate = newDate else {
                return false
        }
        return NSCalendar.current.component(.day, from: oldDate) != NSCalendar.current.component(.day, from: newDate)
    }
    
    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        if indexPath.section < self.subforwards.countFromZero {
            if self.isDateChange(from: self.subforwards[indexPath.section + 1].originalDate, to: self.subforwards[indexPath.section].originalDate) {
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .long
                dateFormatter.timeStyle = .none
                if let date = self.subforwards[indexPath.section].originalDate {
                    let dateString = dateFormatter.string(from: date)
                    return NSAttributedString(string: dateString,
                                              attributes: [
                                                NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .caption1),
                                                NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint600 ])
                }
            }
        }
        return nil
    }
    
    func messageTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        return subforwards[indexPath.section].attributedAuthor
    }
    
    func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        guard let date = subforwards[indexPath.section].originalDate else { return nil }
        let dateString = self.messageDateFormatter.string(from: date)
        return NSAttributedString(string: dateString,
                                  attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)])
    }
    
    func showAvatar() -> Bool {
        return false
    }
    
    func audioMessageReference(at indexPath: IndexPath, messageId: String?, index: Int?) -> MessageReferenceStorageItem.Model? {
        let references: [MessageReferenceStorageItem.Model]?
        if let messageId = messageId {
            references = subforwards[indexPath.section].subforwards.first(where: { $0.messageId == messageId })?.references
        } else {
            references = subforwards[indexPath.section].references
        }
        if let index = index {
            return references?[index]
        } else {
            return references?.first
        }
    }
    
    func audioMessageState(at indexPath: IndexPath, messageId: String?, index: Int?) -> InlineAudioGridView.AudioCellPlayingState {
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            path.messageId == messageId,
            path.index == index,
            OpusAudio.shared.player?.isPlaying ?? false {
            return .pause
        }
        if let isDownloaded = audioMessageReference(at: indexPath,
                                                    messageId: messageId,
                                                    index: index)?.isDownloaded {
            return isDownloaded ? .play : .loading
        }
        return .loading
    }
    
    func audioMessageDurationString(at indexPath: IndexPath, messageId: String?, index: Int?) -> String? {
        let currentDuration: TimeInterval
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            path.messageId == messageId,
            path.index == index {
            currentDuration = OpusAudio.shared.player?.currentTime ?? 0
        } else {
            currentDuration = 0
        }
        if let commonDuration = audioMessageReference(at: indexPath, messageId: messageId, index: index)?.metadata?["duration"] as? Double {
            return "\(currentDuration.minuteFormatedString) / \(TimeInterval(commonDuration).minuteFormatedString)"
        } else {
            return ""
        }
    }
    
    func audioMessageCurrentGradientPercentage(at indexPath: IndexPath, messageId: String?, index: Int?) -> Float? {
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            path.index == index,
            path.messageId == messageId,
            let currentDuration = OpusAudio.shared.player?.currentTime,
            let commonDuration = OpusAudio.shared.player?.duration {
            return Float((currentDuration) / commonDuration )
        }
        return 0.0
    }
    
    func audioMessageDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval {
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            let duration = OpusAudio.shared.player?.duration {
            return duration
        }
        return TimeInterval(audioMessageReference(at: indexPath,
                                                  messageId: messageId,
                                                  index: index)?
            .metadata?["duration"] as? Double ?? 0)
    }
    
    func audioMessageCurrentDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval {
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            path.messageId == messageId,
            path.index == index,
            let currentTime = OpusAudio.shared.player?.currentTime {
            return currentTime
        }
        return 0.0
    }
    
    func showDeliveryIndicator() -> Bool {
        return false
    }
    
    func canPerformAction() -> Bool {
        return false
    }
    
}
