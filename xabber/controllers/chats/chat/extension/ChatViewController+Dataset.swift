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

    private final func mapDataset(dataset: Array<MessageStorageItem>) -> [Datasource] {
        if self.showSkeletonObserver.value {
            return skeletonMessages.enumerated().compactMap {
                (offset, item) in
                let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(((self.skeletonMessages.count - offset) * 1000)))
                return Datasource(
                    primary: UUID().uuidString,
                    jid: self.jid,
                    owner: self.owner,
                    outgoing: false,
                    sender: self.opponentSender,
                    messageId: UUID().uuidString,
                    sentDate: date,
                    editDate: nil,
                    kind: .skeleton(item),
                    withAuthor: false,
                    withAvatar: false,
                    error: false,
                    errorType: "",
                    canPinMessage: false,
                    canEditMessage: false,
                    canDeleteMessage: false,
                    forwards: [],
                    isOutgoing: false,
                    isEdited: false,
                    groupchatAuthorRole: "",
                    groupchatAuthorId: "",
                    groupchatAuthorNickname: "",
                    groupchatAuthorBadge: "",
                    isHasAttachedMessages: false,
                    isDownloaded: true,
                    state: .read,
                    searchString: nil,
                    errorMetadata: [:],
                    burnDate: -1,
                    afterburnInterval: -1,
                    isRead: true
                )
            }
        }
        return dataset.enumerated().compactMap {
            (offset, item) -> Datasource? in
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
//                    kind = .attributedText(
//                        NSAttributedString(string: "\(offset)"),
//                        false,
//                        ContactChatMetadataManager
//                            .shared
//                            .get(item.groupchatAuthorNickname ?? "",
//                                 for: self.owner,
//                                 badge: item.groupchatAuthorBadge ?? "",
//                                 role: item.groupchatMetadata?["role"] as? String ?? "member")
//                            .getAttributedNickname([.font: UIFont.preferredFont(forTextStyle: .caption1)])
//                    )
                    kind = .attributedText(
                        item.createRefBody(
                            [
                                NSAttributedString.Key.foregroundColor: UIColor.label,
                                NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)//UIFont.systemFont(ofSize: 16, weight: .regular),
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
            } else if dataset.count > 1 && (offset + 1) < dataset.count {
                print(dataset.count, offset, dataset.count > 1, (offset + 1) < dataset.count, dataset.count > 1 && (offset + 1) < dataset.count)
                if dataset[offset + 1].groupchatAuthorNickname != item.groupchatAuthorNickname || self.isDateChange(from: dataset[offset + 1].sentDate, to: item.sentDate) {
                    withAuthor = self.groupchat ? (item.displayAs == .sticker ? false : (self.showMyNickname ? true : !item.outgoing)) : false
                } else {
                    withAuthor = false
                }
            } else {
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
                selectedSearchResultId: item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                references: item.references.toArray().compactMap { $0.loadModel() }
            )
        }
    }
    
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
    
    private final func apply(changes: ChangesWithIndexSet, shouldScrollToLastMessage: Bool = false, forceWithoutAnimations: Bool = false, addToEnd: Bool = false, addToStart: Bool = false, prepare: @escaping (() -> Void)) {
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.canUpdateDataset = true
            if let archived = self.scrollToMessageArchivedId {
                if let index = self.datasource.firstIndex(where: { $0.archivedId == archived }) {
                    self.scrollToMessageArchivedId = nil
                    self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .bottom, animated: true)
                    self.showLoadingIndicator.accept(false)
                }
            }
            return
        }
        
        func animationTransaction(_ block: () -> Void) {
            if addToEnd || addToStart || forceWithoutAnimations {
                UIView.performWithoutAnimation(block)
            } else {
                block()
            }
        }
        
        if (changes.inserts.count + changes.deletes.count) > 40 {
            (messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
        }
        
        
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
            .invalidateLastMessageCachedSize(primary: datasource.last?.primary)
        let heightBeforeUpdate = self.messagesCollectionView.contentSize.height
        let offsetBeforeUpdate = self.messagesCollectionView.contentOffset.y
        
        animationTransaction {
            self.messagesCollectionView.performBatchUpdates({
                prepare()
                if !changes.deletes.isEmpty {
                   self.messagesCollectionView.deleteSections(changes.deletes)
                }

                if !changes.inserts.isEmpty {
                   self.messagesCollectionView.insertSections(changes.inserts)
                }

                if changes.moves.isNotEmpty {
                   changes.moves.forEach {
                       (from, to) in
                       self.messagesCollectionView.moveItem(at: from, to: to)
                   }
                }
                if !changes.replaces.isEmpty {
                    self.messagesCollectionView.reloadItems(at: changes.replaces.compactMap { return IndexPath(row: 0, section: $0) })
                }
            }, completion: {
                result in
                
                
                if let archived = self.scrollToMessageArchivedId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let index = self.datasource.firstIndex(where: { $0.archivedId == archived  }) {//|| $0.messageId == archived
                            self.scrollToMessageArchivedId = nil
                            self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: self.searchSeekDirection == .down ? .centeredVertically : .bottom, animated: true)
                            self.showLoadingIndicator.accept(false)
                            self.searchSeekDirection = nil
                            print("SCROLL TO \(index) first")
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if let index = self.datasource.firstIndex(where: { $0.archivedId == archived }) {
                                    self.scrollToMessageArchivedId = nil
                                    self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: self.searchSeekDirection == .down ? .centeredVertically : .bottom, animated: true)
                                    self.showLoadingIndicator.accept(false)
                                    self.searchSeekDirection = nil
                                    print("SCROLL TO \(index) last")
                                }
                            }
                        }
                    }
                } else {
                    if addToEnd {
                        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: offsetBeforeUpdate), animated: false)
                    } else if addToStart {
                        let heightAfterUpdate = self.messagesCollectionView.contentSize.height
                        let newOffset = offsetBeforeUpdate + (heightAfterUpdate - heightBeforeUpdate)
                        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
                    }
                }
                self.canUpdateDataset = true
            })
        }
        
    }
    
    internal final func getMessageIdAtPostionOrLast(index unsafeIndex: Int) -> String {
        var index = unsafeIndex
        if unsafeIndex < 0 {
            index = 0
        }
        if (self.messagesObserver?.count ?? 0) == 0 {
            return "none"
        } else if (self.messagesObserver?.count ?? 0) < index {
            return self.messagesObserver?.last?.archivedId ?? self.messagesObserver?.last?.messageId ?? "none"
        } else {
            let item = self.messagesObserver?[index]
            return item?.archivedId ?? item?.messageId ?? "none"
        }
    }
    
    internal final func prepareDataset(oldestMessageId: String, newestMessageId: String) -> Slice<Results<MessageStorageItem>> {
        do {
            let realm = try  WRealm.safe()
            let dataset: Results<MessageStorageItem>
            if conversationType == .saved {
                dataset = realm
                    .objects(MessageStorageItem.self)
                    .filter ("owner == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, self.conversationType.rawValue)
                    .sorted (byKeyPath: "date", ascending: false)
            } else {
                dataset = realm
                    .objects(MessageStorageItem.self)
                    .filter ("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, self.jid, self.conversationType.rawValue)
                    .sorted (byKeyPath: "date", ascending: false)
            }
            let prefix = 0//dataset.firstIndex(where: { $0.archivedId == newestMessageId  }) ?? 0 // || $0.messageId == newestMessageId
            let suffix = (dataset.count - 1)//dataset.firstIndex(where: { $0.archivedId == oldestMessageId  }) ?? (dataset.count - 1) //|| $0.messageId == oldestMessageId
            if suffix < prefix {
                return dataset.prefix(dataset.count)
                
            }
            return dataset[prefix...suffix]
        } catch {
            fatalError()
        }
    }
    
    internal final func initializeDataset() {
        
        self.oldestMessageId = getMessageIdAtPostionOrLast(index: self.messagesCount)
        self.newestMessageId = "the most top message id \(NanoID.new(15))"//getMessageIdAtPostionOrLast(index: self.lastBottomIndex)
        let dataset = self.prepareDataset(
            oldestMessageId: self.oldestMessageId ?? "",
            newestMessageId: self.newestMessageId ?? ""
        )
        self.datasource = self.mapDataset(dataset: Array(dataset))
    }
    
    public final func runDatasetUpdateTask(shouldScrollToLastMessage: Bool = false, forceWithoutAnimations: Bool = false, addToEnd: Bool = false, addToStart: Bool = false) {
        autoreleasepool {
            self.preprocessDataset(shouldScrollToLastMessage: shouldScrollToLastMessage, forceWithoutAnimations: forceWithoutAnimations, addToEnd: addToEnd, addToStart: addToStart)
        }
        self.postprocessDataset()
    }
    
    private final func preprocessDataset(shouldScrollToLastMessage: Bool = false, forceWithoutAnimations: Bool = false, addToEnd: Bool = false, addToStart: Bool = false) {
        if !canUpdateDataset { return }
        self.canUpdateDataset = false
        
        var newestMessageId = self.newestMessageId
        if self.messagesObserver?.first?.archivedId == self.newestMessageId || self.messagesObserver?.first?.messageId == self.newestMessageId {
            newestMessageId = "the most top message id \(NanoID.new(15))"
            self.newestMessageId = newestMessageId
        }
        let dataset = prepareDataset(
            oldestMessageId: self.oldestMessageId ?? "",
            newestMessageId: newestMessageId ?? ""
        )
        let newDataset = self.mapDataset(dataset: Array(dataset))
        let changes = diff(old: self.datasource, new: newDataset)
        let indexSet = self.convertChangeset(changes: changes)
        self.apply(changes: indexSet, shouldScrollToLastMessage: shouldScrollToLastMessage, forceWithoutAnimations: forceWithoutAnimations, addToEnd: addToEnd, addToStart: addToStart) {
            self.datasource = newDataset
        }
    }
    
    private final func postprocessDataset() {
        
    }
    
    
    internal final func subscribeOnDatasetChanges() throws {
        self.messagesBag = DisposeBag()
        Observable
            .collection(from: self.messagesObserver!)
            .skip(1)
            .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
            .subscribe { (_) in
                if self.showSkeletonObserver.value { return }
                if self.hasActiveMamArchiveRequest { return }
                self.runDatasetUpdateTask()
            }
            .disposed(by: self.messagesBag)
    }
    
    final func addDatasourceToStart() {
        if self.isLoadNextPage {
            return
        }
        func scroll() {
            self.lastBottomIndex = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.newestMessageId || $0.messageId == self.newestMessageId }) ?? self.lastBottomIndex
            self.lastBottomIndex = self.lastBottomIndex - 200
            if self.lastBottomIndex < 0 {
                self.lastBottomIndex = 0
            }
            self.newestMessageId = self.getMessageIdAtPostionOrLast(index: self.lastBottomIndex)
            self.runDatasetUpdateTask(shouldScrollToLastMessage: false, addToStart: true)
        }
        func callback() {
            print("end")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                scroll()
                self.isLoadNextPage = false
            }
        }
        do {
            let realm = try WRealm.safe()
//            let chatInstance = realm.object(
//                ofType: LastChatsStorageItem.self,
//                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType)
//            )
//            let messagesCount = self.messagesObserver?.count ?? 0
//            let totalCount = chatInstance?.messagesCount ?? 0
            let newestMessageId = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.newestMessageId || $0.messageId == self.newestMessageId }) ?? 0
            if newestMessageId == 0 { return }
            if prevHasGap(before: newestMessageId, count: ChatViewController.datasourcePageSize * 2) {
                self.isLoadNextPage = true
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    session.mam?.getPrevHistory(stream, for: self.jid, conversationType: self.conversationType, messageId: self.newestMessageId ?? "", callback: callback)
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.mam.getPrevHistory(stream, for: self.jid, conversationType: self.conversationType, messageId: self.newestMessageId ?? "", callback: callback)
                    })
                }
            } else {
                scroll()
//                if let oldestItemIndex = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.oldestMessageId || $0.messageId == self.oldestMessageId }) {
//                    if oldestItemIndex == (messagesCount - 1) {
//                        print("should load histpry", messagesCount, oldestItemIndex, totalCount)
                        

//                    } else if oldestItemIndex < (messagesCount - 1) {
//                        self.messagesCount += ChatViewController.datasourcePageSize * 2
//                        self.lastBottomIndex = self.messagesCount - ChatViewController.datasourcePageSize
//                        if self.lastBottomIndex < 0 {
//                            self.lastBottomIndex = 0
//                        }
//                        self.oldestMessageId = self.getMessageIdAtPostionOrLast(index: self.messagesCount)
//                        self.newestMessageId = self.getMessageIdAtPostionOrLast(index: self.lastBottomIndex)
//                        self.runDatasetUpdateTask(shouldScrollToLastMessage: false, addToEnd: true)
//                    }
//                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func nextHasGap(after: Int, count: Int) -> Bool {
        let len = (self.messagesObserver?.count ?? 0) - after
        if len < 1 {
            return true
        }
        if let slice = self.messagesObserver?.suffix(len).prefix(count) {
            let arr = Array(slice)
            if arr.last?.displayAs != .initial && count > arr.count {
                return true
            }
            var shouldRequestArchive = false
            Array(slice).enumerated().forEach {
                offset, item in
                let nextIndex = offset + 1
                if nextIndex < slice.count {
                    let itemQueryIds = Set((item.queryIds ?? "").split(separator: ","))
                    let nextItemQueryIds = Set((arr[nextIndex].queryIds ?? "").split(separator: ","))
                    let intersection = itemQueryIds.intersection(nextItemQueryIds)
                    if intersection.isEmpty {
                        shouldRequestArchive = true
                    }
                }
            }
            return shouldRequestArchive
        }
        return true
    }
    
    func prevHasGap(before: Int, count: Int) -> Bool {
        if let slice = self.messagesObserver?.prefix(before).suffix(count) {
            let arr = Array(slice)
            var shouldRequestArchive = false
            Array(slice).enumerated().forEach {
                offset, item in
                let nextIndex = offset + 1
                if nextIndex < slice.count {
                    let itemQueryIds = Set((item.queryIds ?? "").split(separator: ","))
                    let nextItemQueryIds = Set((arr[nextIndex].queryIds ?? "").split(separator: ","))
                    let intersection = itemQueryIds.intersection(nextItemQueryIds)
                    if intersection.isEmpty {
                        shouldRequestArchive = true
                    }
                }
            }
            return shouldRequestArchive
        }
        return false
    }
    
    final func addDatasourceToEnd() {
        if self.isLoadNextPage {
            return
        }
        func scroll() {
            self.messagesCount += ChatViewController.datasourcePageSize * 2
            let oldestItemIndex = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.oldestMessageId || $0.messageId == self.oldestMessageId }) ?? 0
            let newestMessageIndex = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.newestMessageId || $0.messageId == self.newestMessageId }) ?? 0
            self.lastBottomIndex = newestMessageIndex
            self.oldestMessageId = self.getMessageIdAtPostionOrLast(index: ChatViewController.datasourcePageSize * 2 + oldestItemIndex)
            self.runDatasetUpdateTask(shouldScrollToLastMessage: false, addToEnd: true)
        }
        func callback() {
            print("end")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                scroll()
                self.isLoadNextPage = false
            }
        }
        do {
            let realm = try WRealm.safe()
            let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType)
            )
            let messagesCount = self.messagesObserver?.count ?? 0
            let totalCount = chatInstance?.messagesCount ?? 0
            if messagesCount < totalCount - 1 {
                if let oldestItemIndex = self.messagesObserver?.firstIndex(where: { $0.archivedId == self.oldestMessageId || $0.messageId == self.oldestMessageId }) {
                    if nextHasGap(after: oldestItemIndex, count: 200) || (self.messagesObserver?.count ?? 0) < (totalCount + ChatViewController.datasourcePageSize * 2) {
                        print("should load histpry", messagesCount, oldestItemIndex, totalCount)
                        self.isLoadNextPage = true
                        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                            session.mam?.getNextHistory(stream, for: self.jid, conversationType: self.conversationType, messageId: self.oldestMessageId ?? "none", callback: callback)
                        } fail: {
                            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                                user.mam.getNextHistory(stream, for: self.jid, conversationType: self.conversationType, messageId: self.oldestMessageId ?? "none", callback: callback)
                            })
                        }

                    } else if oldestItemIndex < (messagesCount - 1) {
                        scroll()
                    }
                }
            } else {
                scroll()
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
}
