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

extension ChatViewController: MessagesDataSource {
    
    func showTopLabel(for message: MessageType) -> Bool {
        return false
    }
    
    func isFromCurrentSender(message: MessageType) -> Bool {
        return message.sender == currentSender()
    }

    func numberOfItems(inSection section: Int, in messagesCollectionView: MessagesCollectionView) -> Int {
        return 1
    }
    
    
    func currentSender() -> Sender {
        return self.ownerSender
    }
    
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType {
        if self.datasource.count < indexPath.section {
            fatalError("Fatal error: ChatViewController:\(#function):l46. Count \(self.datasource.count)")
        }
        return self.datasource[indexPath.section]
    }
    
    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int {
        return self.datasource.count
    }
    
    func numberOfMessages(in messagesCollectionView: MessagesCollectionView) -> Int {
        return self.datasource.count
    }
    
    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        if let unreadId = self.lastReadMessageId {
            if indexPath.section < ((self.messagesObserver?.count ?? 0) - 2) {
                if self.messagesObserver?[indexPath.section + 1].archivedId == unreadId {
                    return NSAttributedString(string: "New messages",
                                              attributes: [
                                                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                                NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint50 ])
                }
            }
        }
        var dateString: String = ""
        if indexPath.section < (self.datasource.count - 1) {
            if self.isDateChange(from: self.datasource[indexPath.section + 1].sentDate, to: self.datasource[indexPath.section].sentDate)  {
                dateString = sectionsDateFormatter.string(from: self.datasource[indexPath.section].sentDate)
            }
        } else if indexPath.section == (self.datasource.count - 1) {
            dateString = sectionsDateFormatter.string(from: self.datasource[indexPath.section].sentDate)
        }
        if dateString.isEmpty { return nil }
        return NSAttributedString(string: dateString,
                                  attributes: [
                                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                                    NSAttributedString.Key.foregroundColor: MDCPalette.grey.tint50 ])
    }
    
    func messageTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        let item = datasource[indexPath.section]
        return ContactChatMetadataManager
            .shared
            .get(item.groupchatAuthorNickname,
                 for: self.owner,
                 badge: item.groupchatAuthorBadge,
                 role: item.groupchatAuthorRole)
            .getAttributedNickname([.font: UIFont.preferredFont(forTextStyle: .caption1)])
    }
    
    
    
    func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        if self.showSkeletonObserver.value {
            return nil
        }
        let item = datasource[indexPath.section]
        switch item.kind {
            case .initial(let value):
                return nil
            case .system(let value):
                return nil
            default:
                break
        }
        if item.isHasAttachedMessages { return nil }
        let dateString = self.messageDateFormatter.string(from: item.sentDate)
        let attributedString: NSMutableAttributedString = NSMutableAttributedString()
        
        if item.editDate != nil {
            attributedString.append(NSAttributedString(string: "edited "))
        }
        if item.afterburnInterval > 0 {
            switch ChatMarkersManager.BurnMessagesTimerValues(rawValue: Int(item.afterburnInterval)) {
                case .off, .none:
                    break
                case .s5:
                    attributedString.append(NSAttributedString(string: "5s ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .s10:
                    attributedString.append(NSAttributedString(string: "10s ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .s15:
                    attributedString.append(NSAttributedString(string: "15s ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .s30:
                    attributedString.append(NSAttributedString(string: "30s ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .m1:
                    attributedString.append(NSAttributedString(string: "1m ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .m5:
                    attributedString.append(NSAttributedString(string: "5m ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .m10:
                    attributedString.append(NSAttributedString(string: "10m ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                case .m15:
                    attributedString.append(NSAttributedString(string: "15m ", attributes: [.foregroundColor: UIColor.systemBlue.cgColor]))
                
            }
        }
        let start = attributedString.string.count
        attributedString.append(NSAttributedString(string: dateString))
        attributedString.addAttribute(.font, value: UIFont.systemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: attributedString.string.count))

//        attributedString.addAttribute(.foregroundColor, value: UIColor.secondaryLabel.cgColor, range: NSRange(location: attributedString.string.count - dateString.count, length: dateString.count))
//        attributedString.addAttribute(.foregroundColor, value: UIColor.secondaryLabel.cgColor, range: NSRange(location: start, length: dateString.count - 1))
        
        return attributedString
    }
    
    func messageBottomPadding(at indexPath: IndexPath) -> CGFloat {
        return self.datasource[indexPath.section].isHasAttachedMessages ? -4 : 4
    }
    
    func showAvatar() -> Bool  {
        return groupchat
    }

    func audioMessageReference(at indexPath: IndexPath, messageId: String?, index: Int?) -> MessageReferenceStorageItem? {
        let references: [MessageReferenceStorageItem]?
        if let messageId = messageId {
            references = messagesObserver?[indexPath.section].inlineForwards.first(where: { $0.messageId == messageId })?.references.toArray().filter({ $0.kind == .voice })
        } else {
            references = messagesObserver?[indexPath.section].references.toArray().filter({ $0.kind == .voice })
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
        guard let item = messagesObserver?[indexPath.section] else {
            return .play
        }
        
        if let isDownloaded = audioMessageReference(at: indexPath,
                                                    messageId: messageId,
                                                    index: index)?.isDownloaded {
            return isDownloaded ? .play : (item.state == .error ? .play : .loading)
        }
        
        return item.state == .error ? .play : .loading
    }
    
    func audioMessageDurationString(at indexPath: IndexPath, messageId: String?, index: Int?) -> String? {
        let currentDuration: TimeInterval
//        print(playingMessageIndexPath)
//        print(OpusAudio.shared.player?.currentTime )
        if let path = playingMessageIndexPath,
            path.indexPath == indexPath,
            path.messageId == messageId,
            path.index == index {
            currentDuration = OpusAudio.shared.player?.currentTime ?? 0
        } else {
            currentDuration = 0
        }
//        print(currentDuration)
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
        return true
    }
    
    func canPerformAction() -> Bool {
        return true
    }
}
