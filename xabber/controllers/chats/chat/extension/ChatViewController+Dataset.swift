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
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack

public final class ChangesWithIndexSet {
    public let inserts: IndexSet
    public let deletes: IndexSet
    public var replaces: IndexSet
    public let moves: [(from: IndexPath, to: IndexPath)]

    public init(inserts: IndexSet, deletes: IndexSet, replaces: IndexSet, moves: [(from: IndexPath, to: IndexPath)]) {
        self.inserts = inserts
        self.deletes = deletes
        self.replaces = replaces
        self.moves = moves
    }
}

extension ChatViewController {
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexSet {
        let inserts = IndexSet(changes.compactMap({ return $0.insert?.index }))
        let deletes = IndexSet(changes.compactMap({ return $0.delete?.index }))
        let replaces = IndexSet(changes.compactMap({ return $0.replace?.index }))
//        if self.shouldUpdatePreviousMessage {
//            self.shouldUpdatePreviousMessage = false
//            replaces.insert(0)
//        }
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: 0, section: $0.fromIndex),
            to: IndexPath(item: 0, section: $0.toIndex)
          )
        })
        
        return ChangesWithIndexSet(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    internal final func initializeDataset() {
        let count = self.messagesObserver?.count ?? 0
        (0..<count).forEach { _ in self.proxyDatasource.append(nil) }
        var initialDTOCount = 50
        if count < initialDTOCount { initialDTOCount = count }
        (0..<initialDTOCount).forEach { index in self.proxyDatasource[index] = self.getDTO(for: index) }
    }
    
    internal final func populateMissedDatasource() {
        let count = self.messagesObserver?.count ?? 0
        var inserted: [Int] = []
        (0..<count).forEach {
            index in
            if self.proxyDatasource[index] == nil {
                inserted.append(index)
                self.proxyDatasource[index] = self.getDTO(for: index)
            }
        }
        self.messagesCollectionView.reloadData()
        
    }
    

    
    internal final func getDTO(for index: Int) -> Datasource? {
        guard self.messagesObserver != nil,
              self.messagesObserver!.count > index else {
            return nil
        }
        if let item = self.messagesObserver?[index] {
            let references = Array(item.references.toArray().compactMap { $0.loadModel() })
            let inlineForwards = Array(item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true).toArray().compactMap { $0.loadModel() })
            
            let isDownloaded = !item.references.filter { $0.isDownloaded }.isEmpty
            let kind: MessageKind
            switch item.displayAs {
                case .initial:
                    
                    var descriptionText: String = ""
    //                var descriptionText: NSAttributedString = NSAttributedString()
                    let aboutAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 15, weight: .regular)
                    ]
                   
                    switch self.conversationType {
                    case .regular:
                        descriptionText = "Messages in this chat are not encrypted. Servers often store transient messages in an archive. This allows easy device synchronization and server-side history search, but adds privacy risks."
                    case .group:
                        switch self.entity {
                        case .incognitoChat:
                            descriptionText = "Identities of users in this group are kept hidden from each other, only group admins can access your real XMPP ID. Be vigilant, do not disclose yourself by being careless."
                        case .privateChat:
                            descriptionText = "Private chat with incognito user. Messages are routed through group server and your identites are kept secret from each other. Be vigilant, do not disclose yourself by being careless."
                        default:
                            descriptionText = "Identities of users in this group are public, so any member can contact you using your real XMPP ID."
                        }
                    case .channel:
                        descriptionText = "Identities of users in this group are public, so any member can contact you using your real XMPP ID."
                    case .omemo, .omemo1, .axolotl:
                        descriptionText = "Messages in this chat are encrypted with end-to-end encryption. You must always confirm the identity of your contact by verifying encryption keys fingerprints."
                    case .notifications:
                        descriptionText = "fdg"
                    case .saved:
                        break
                    }
                    let modifiedDesccription = NSMutableAttributedString(
                        attributedString: NSAttributedString(string: descriptionText,
                                                             attributes: aboutAttrs)
                    )
                    let allRange = NSRange(location: 0, length:  modifiedDesccription.string.count)
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 1.5
                    style.alignment = .center
                    modifiedDesccription.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: allRange)
                    kind = .initial(modifiedDesccription)
    //                kind = .initial(NSAttributedString(string: descriptionText))
                case .quote:
                    kind = .quote(
                        item.createQuoteBody([NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)]),
                        ContactChatMetadataManager
                            .shared
                            .get(item.groupchatAuthorNickname ?? "",
                                 for: self.owner,
                                 badge: item.groupchatAuthorBadge ?? "",
                                 role: item.groupchatMetadata?["role"] as? String ?? "member")
                            .getAttributedNickname([.font: UIFont.preferredFont(forTextStyle: .caption1)])
                    )
                case .text:
                    kind = .attributedText(
                        item.createRefBody(
                            [
                                NSAttributedString.Key.foregroundColor: UIColor.label,
                                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 16, weight: .regular),
                            ],
                            searchedText: self.searchTextObserver.value,
                            searchedTextColor: item.archivedId == self.selectedSearchResultId ? AccountColorManager.shared.palette(for: self.owner).tint400.withAlphaComponent(0.5) :  AccountColorManager.shared.palette(for: self.owner).tint200.withAlphaComponent(0.5)
                        ),
                        false,
                        ContactChatMetadataManager
                            .shared
                            .get(item.groupchatAuthorNickname ?? "",
                                 for: self.owner,
                                 badge: item.groupchatAuthorBadge ?? "",
                                 role: item.groupchatMetadata?["role"] as? String ?? "member")
                            .getAttributedNickname([.font: UIFont.preferredFont(forTextStyle: .caption1)])
                    )
                case .files:
                    kind = .files(Array(references.filter { [.media, .voice].contains($0.kind) }))
                case .images:
                    kind = .photos(Array(references.filter({ $0.kind == .media })))
                case .voice:
                    kind = .audio(Array(references))
                case .call:
                    kind = .call(Array(references))
                case .system:
                    kind = .system(
                        NSAttributedString(
                            string: item.body,
                            attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1).italic(),
                                .foregroundColor: UIColor.white,
                            ]
                        )
                    )
                case .sticker:
                    if let reference = references.filter({ $0.kind == .media }).first {
                        kind = .sticker(reference)
                    } else {
                        kind = .photos(Array(references.filter({ $0.kind == .media })))
                    }
            }
            
            let withAuthor: Bool
            var date = item.date
            if conversationType == .saved {
                if item.groupchatCard != nil {
                    withAuthor = true
                } else {
                    withAuthor = false
                }
                
                date = item.sentDate
                
            } else if !self.groupchat {
                withAuthor = false
            } 
//            else if dataset.count > 1 && (offset + 1) < dataset.count {
//                if dataset[offset + 1].groupchatAuthorNickname != item.groupchatAuthorNickname || self.isDateChange(from: dataset[offset + 1].sentDate, to: item.sentDate) {
//                    withAuthor = self.groupchat ? (item.displayAs == .sticker ? false : (self.showMyNickname ? true : !item.outgoing)) : false
//                } else {
//                    withAuthor = false
//                }
//            } 
            else {
                withAuthor = self.groupchat ? (item.displayAs == .sticker ? false : (self.showMyNickname ? true : !item.outgoing)) : false
            }
            
            if item.editDate != nil {
                let primary = item.primary
                DispatchQueue.main.async {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.invalidateLastMessageCachedSize(primary: primary)
                }
            }
            var searchString: String? = nil
            
            if self.inSearchMode.value,
               item.displayAs == .text,
               let str = self.searchTextObserver.value,
               str.isNotEmpty,
               item.body.contains(str) {
                searchString = str
            }
            
            return Datasource(
                primary: item.primary,
                jid: self.jid,
                owner: self.owner,
                outgoing: item.outgoing,
                sender: item.outgoing ? self.ownerSender : self.opponentSender,
                messageId: item.messageId,
                sentDate: date,
                editDate: item.editDate,
                kind: kind,
                withAuthor: withAuthor,
                withAvatar: self.groupchat ? !item.outgoing : false,
                error: item.state == .error,
                errorType: item.messageError ?? "",
                canPinMessage: [.system, .sticker].contains(item.displayAs) ? false : self.canUnpinMessage.value,
                canEditMessage: item.archivedId.isNotEmpty ? item.displayAs == .text && item.outgoing : false,
                canDeleteMessage: [MessageStorageItem.MessageSendingState.deliver, MessageStorageItem.MessageSendingState.read].contains(item.state),
                forwards: inlineForwards,
                isOutgoing: item.outgoing,
                isEdited: item.editDate != nil,
                groupchatAuthorRole: item.groupchatMetadata?["role"] as? String ?? "member",
                groupchatAuthorId: item.groupchatAuthorId ?? "",
                groupchatAuthorNickname: item.groupchatAuthorNickname ?? "",
                groupchatAuthorBadge: item.groupchatAuthorBadge ?? "",
                isHasAttachedMessages: item.isHasAttachedMessages,
                isDownloaded: isDownloaded,
                state: item.displayAs == .call ? .none : item.state,
                searchString:  searchString,
                errorMetadata: item.errorMetadata,
                burnDate: item.burnDate,
                afterburnInterval: item.afterburnInterval,
                archivedId: item.archivedId,
                isRead: item.isRead,
                selectedSearchResultId: item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil
            )
        }
        return nil
    }
    
    internal func subscribeOnDataset() {
        guard self.messagesObserver != nil else {
            return
        }
        self.messagesBag = DisposeBag()
        
    }
}
