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

extension ChatViewController: MessagesDisplayDelegate {
    
    func messageErrorIcon(for message: MessageType, at indexPath: IndexPath, on messagesCollectionView: MessagesCollectionView) -> String? {
        guard let meta = self.datasource[indexPath.section].errorMetadata else {
            return nil
        }
        let keys = [
            "certValid",
            "certConfirmed",
            "signed",
            "signDecrypted",
            "signValid"]
        var result = true
        keys.forEach {
            key in
            if let value = meta[key] as? Bool,
               value == false {
                result = false
            }
        }
        if result {
            return "shield.checkered"
        } else {
            return "exclamationmark.triangle.fill"
        }
    }
    
    func isSelected(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> Bool {
        let item = self.datasource[indexPath.section]
//        guard let item = self.messages?[indexPath.section] else { fatalError("found nil messages collection") }
        if isInSelectionMode.value {
            if forwardedIds.value.contains(item.primary) { return true }
        }
        return false
    }
        
    func detectorAttributes(for detector: DetectorType, and message: MessageType, at indexPath: IndexPath) -> [NSAttributedString.Key : Any] {
//        switch detector {
//        case .address, .date, .phoneNumber, .transitInformation:
//            return MessageLabel.defaultAttributes
//        case .url:
//            return MessageLabel.defaultURLAttributes
//        }
        return [:]
    }
    
    func isBurnedMessage(at indexPath: IndexPath) -> Bool {
        return self.datasource[indexPath.section].afterburnInterval > 0
    }
    
    func enabledDetectors(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> [DetectorType] {
        return [.url, .address, .phoneNumber, .date]
    }
    
    func backgroundColor(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {
        let item = self.datasource[indexPath.section]
        if item.isHasAttachedMessages {
            return .clear
        }
        return item.outgoing ? UIColor.white : self.accountPallete.tint50
    }
    
    func deliveryState(at indexPath: IndexPath) -> MessageStorageItem.MessageSendingState {
//        if (messagesObserver?.count ?? 0) < indexPath.section { return datasource[indexPath.section].state }
//        guard let item = self.messagesObserver?[indexPath.section] else { return .none }
//        let state = item.messageError == "Editing" ? .sending : item.state
//        return item.outgoing ? state : .none
        let item = self.datasource[indexPath.section]
//        let state = item.isEdited ? .sending : item.state
        return item.outgoing ? item.state : .none
    }
    
    func messageStyle(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageStyle {
        let corner: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft
        let item = datasource[indexPath.section]
        switch message.kind {
        case .text(_), .attributedText(_, _, _):
            if indexPath.section > 0 {
                if self.groupchat {
                    if self.datasource[indexPath.section - 1].groupchatAuthorId == item.groupchatAuthorId {
                        return .bubble(corner)
                    }
                } else {
                    if self.datasource[indexPath.section - 1].outgoing == item.outgoing {
                        return .bubble(corner)
                    }
                }
            }
            return .bubbleTail(corner)
        default:
            return .bubble(corner)
        }
    }
    
    func mediaSendString(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        return nil
    }
    
    func shouldShowLoadingIndicator(for message: MessageType, at indexPath: IndexPath) -> Bool {
        let item = self.datasource[indexPath.section]
        return item.state == .uploading
    }
    
    func urlForAvatarView(at indexPath: IndexPath) -> URL? {
        if self.conversationType != .group { return nil }
        if indexPath.section > 1 && indexPath.section < self.datasource.count - 1 {
            guard indexPath.section < self.messagesObserver?.count ?? 0,
                  let item = self.messagesObserver?[indexPath.section] else {
                return nil
            }
            if self.datasource[indexPath.section - 1].groupchatAuthorNickname != item.groupchatAuthorNickname || self.isDateChange(from: self.datasource[indexPath.section + 1].sentDate, to: self.datasource[indexPath.section].sentDate) {
                guard let path = messagesObserver?[indexPath.section].groupchatUserAvatarPath else { return nil }
                return URL(string: path)
            }
        } else {
            guard indexPath.section < self.messagesObserver?.count ?? 0,
                  let path = messagesObserver?[indexPath.section].groupchatUserAvatarPath else { return nil }
            return URL(string: path)
        }
        return nil
    }
    
    func metadataForAvatarView(at indexPath: IndexPath) -> MessageAvatarMetadata?  {
        if !self.groupchat { return nil }
        if indexPath.section > 1 && indexPath.section < self.datasource.count - 1 {
            guard indexPath.section < self.messagesObserver?.count ?? 0,
                  let item = self.messagesObserver?[indexPath.section] else {
                return nil
            }
            if self.datasource[indexPath.section - 1].groupchatAuthorNickname != item.groupchatAuthorNickname || self.isDateChange(from: self.datasource[indexPath.section + 1].sentDate, to: self.datasource[indexPath.section].sentDate) {
                guard let userId = messagesObserver?[indexPath.section].groupchatAuthorId else { return nil }
                return MessageAvatarMetadata(jid: self.jid, owner: self.owner, userId: userId)
            }
        } else {
            guard indexPath.section < self.messagesObserver?.count ?? 0,
                  let userId = messagesObserver?[indexPath.section].groupchatAuthorId else { return nil }
              return MessageAvatarMetadata(jid: self.jid, owner: self.owner, userId: userId)
        }
        return nil
    }
    
    func inlineAccountColor() -> UIColor {
        return accountPallete.tint100
    }
    
    func accountPalette() -> MDCPalette {
        return accountPallete
    }
    
    func pairedAccountPalette() -> MDCPalette {
        return AccountColorManager.shared.pairedPalette(jid: owner)
    }
    
    func initialMessageIcon() -> UIImage? {
        switch self.conversationType {
        
        case .omemo, .omemo1, .axolotl:
            return UIImage(named: "56dp-chat-encrypted")
        default:
            switch self.entity {
            case .contact:
                return imageLiteral( "56dp-chat")
            case .groupchat:
                return imageLiteral( "56dp-group-public")
            case .bot:
                return imageLiteral( "56dp-chat")
            case .server:
                return imageLiteral( "56dp-chat")
            case .incognitoChat:
                return imageLiteral( "56dp-group-incognito")
            case .privateChat:
                return imageLiteral( "56dp-group-private")
            case .encryptedChat:
                return imageLiteral( "56dp-chat-encrypted")
            case .issue:
                return nil
            }
        }
        
    }
    
    func initialMessageTitle() -> String? {
        switch self.conversationType {
        case .regular:
            switch entity {
            case .contact:
                return "Regular chat".localizeString(id: "intro_regular_chat", arguments: [])
            case .bot:
                return "Bot".localizeString(id: "chat_resource_bot", arguments: [])
            case .server:
                return "Server".localizeString(id: "account_server_name", arguments: [])
            case .issue:
                return "Issue".localizeString(id: "issue", arguments: [])
            default: return nil
            }
        case .group, .channel:
            switch entity {
            case .groupchat:
                return "Public group".localizeString(id: "intro_public_group", arguments: [])
            case .incognitoChat:
                return "Incognito group".localizeString(id: "intro_incognito_group", arguments: [])
            case .privateChat:
                return "Private chat".localizeString(id: "intro_private_chat", arguments: [])
            default: return nil
            }
        case .omemo, .omemo1, .axolotl:
            return "Encrypted chat"
            case .notifications:
                return "Notificastions"
        }
        
        
    }
    
    func initialMessageSubtitle() -> String? {
        return self.jid
    }
    
    func initialMessageFooter() -> String? {
        return nil
//        switch conversationType {
//        case .regular:
//            switch entity {
//            case .contact:
//                return "Regular chat. Learn more.".localizeString(id: "intro_regular_learn_more", arguments: [])
//            case .bot:
//                return "Bot. Learn more.".localizeString(id: "intro_bot_learn_more", arguments: [])
//            case .server:
//                return "XMPP server. Learn more.".localizeString(id: "intro_xmpp_learn_more", arguments: [])
//            case .issue:
//                return "Chat for issue. Learn more.".localizeString(id: "intro_issue_learn_more", arguments: [])
//            default: return nil
//            }
//        case .group, .channel:
//            switch entity {
//            case .groupchat:
//                return "Public group. Learn more.".localizeString(id: "intro_public_learn_more", arguments: [])
//            case .incognitoChat:
//                return "Incognito group. Learn more.".localizeString(id: "intro_incognito_learn_more", arguments: [])
//            case .privateChat:
//                return "Private chat. Learn more.".localizeString(id: "intro_private_learn_more", arguments: [])
//            default: return nil
//            }
//        case .omemo, .omemo1, .axolotl:
//            return "Encrypted chat. Learn more.".localizeString(id: "intro_encrypted_learn_more", arguments: [])
//        }
    }
}
