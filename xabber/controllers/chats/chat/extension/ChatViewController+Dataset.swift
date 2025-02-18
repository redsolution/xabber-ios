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



extension ChatViewController {

    internal func updateFloatingDate() {
        guard let topVisibleReasonableMessageIndex = self.messagesCollectionView.indexPathsForVisibleItems.compactMap ({
            return $0.section
        }).max() else {
            return
        }
        var pinnOffset: CGFloat = 54
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            pinnOffset += topInset
        }
        let frame = CGRect(
            origin: CGPoint(
                x: 0,
                y: pinnOffset
            ),
            size: CGSize(
                width: self.view.bounds.width,
                height: 34
            )
        )
        let index = [topVisibleReasonableMessageIndex, self.datasource.count - 1].min() ?? 0
        if self.datasource.count < 5 {
            self.pinnedDateView.isHidden = true
        } else {
            self.pinnedDateView.isHidden = false
            let text = NSAttributedString(
                string: sectionsDateFormatter.string(from: self.datasource[index].sentDate),
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.white,
                ]
            )
            self.pinnedDateView.frame = frame
            self.pinnedDateView.configure(text)
        }
    }
    
    internal final func mapDataset(dataset: Array<MessageStorageItem>) -> [Datasource] {
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
                    isRead: true,
                    isFakeMessage: true
                )
            }
        }
        var out: [Datasource] = []
        var unreadId: String? = nil
        do {
            let realm = try WRealm.safe()
            let lastChatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))
            unreadId = lastChatInstance?.lastReadId
            unreadId = (lastChatInstance?.unread ?? 0) == 0 ? nil : unreadId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
                
        dataset.enumerated().forEach {
            (offset, item) in
            let references = Array(item.references.toArray().compactMap { $0.loadModel() })
            let inlineForwards = Array(item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true).toArray().compactMap { $0.loadModel() })
            
            let isDownloaded = !item.references.filter { $0.isDownloaded }.isEmpty
            let kind: MessageKind
            switch item.displayAs {
                case .initial:
                    
                    kind = .initial(NSAttributedString(string: ""))
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
                                NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)//UIFont.systemFont(ofSize: 16, weight: .regular),
                            ],
                            searchedText: self.searchTextObserver.value,
                            searchedTextColor: .systemGreen//item.archivedId == self.selectedSearchResultId ? AccountColorManager.shared.palette(for: self.owner).tint400.withAlphaComponent(0.5) :  AccountColorManager.shared.palette(for: self.owner).tint200.withAlphaComponent(0.5)
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
            
            var withAuthor: Bool = false
            var tailed: Bool = true
            var date = item.date
            let prevMessage = offset - 1
            if prevMessage >= 0 {
                let prevItem = dataset[prevMessage]
                if self.conversationType == .group {
                    withAuthor = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                    tailed = !(item.outgoing == prevItem.outgoing)
                } else {
                    tailed = !(item.outgoing == prevItem.outgoing)
                }
                if isDateChange(from: item.date, to: prevItem.date) {
                    tailed = true
                }
            }
//            if conversationType == .saved {
//                if item.groupchatCard != nil {
//                    withAuthor = true
//                } else {
//                    withAuthor = false
//                }
//                
//                date = item.sentDate
//                
//            } else if !self.groupchat {
//                withAuthor = false
//            } else if dataset.count > 1 && (offset + 1) < dataset.count {
//                print(dataset.count, offset, dataset.count > 1, (offset + 1) < dataset.count, dataset.count > 1 && (offset + 1) < dataset.count)
//                if dataset[offset + 1].groupchatAuthorNickname != item.groupchatAuthorNickname || self.isDateChange(from: dataset[offset + 1].sentDate, to: item.sentDate) {
//                    withAuthor = self.groupchat ? (item.displayAs == .sticker ? false : (self.showMyNickname ? true : !item.outgoing)) : false
//                } else {
//                    withAuthor = false
//                }
//            } else {
//                withAuthor = self.groupchat ? (item.displayAs == .sticker ? false : (self.showMyNickname ? true : !item.outgoing)) : false
//            }
            
            
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
            
            out.append(Datasource(
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
                withAvatar: self.conversationType == .group ? !item.outgoing : false,
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
                queryIds: item.queryIds,
                isRead: item.isRead,
                selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                references: item.references.toArray().compactMap { $0.loadModel() },
                isHadHistoryGap: false,
                tailed: tailed
            ))
            if (dataset.count > 1 && (offset + 1) < dataset.count) || (offset + 1 == dataset.count) {
                if item.archivedId == unreadId {
                    let kind: MessageKind = .unread(
                        NSAttributedString(
                            string: "Unread messages",
                            attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                .foregroundColor: UIColor.white,
                            ]
                        )
                    )
                    self.unreadMessagePositionId = offset
                    out.append(Datasource(
                        primary: "\(item.primary) unread",
                        jid: self.jid,
                        owner: self.owner,
                        outgoing: item.outgoing,
                        sender: item.outgoing ? self.ownerSender : self.opponentSender,
                        messageId: item.messageId,
                        sentDate: date,
                        editDate: nil,
                        kind: kind,
                        withAuthor: false,
                        withAvatar: false,//self.groupchat ? !item.outgoing : false,
                        error: item.state == .error,
                        errorType: "",
                        canPinMessage: false,
                        canEditMessage: false,
                        canDeleteMessage: false,
                        forwards: [],
                        isOutgoing: item.outgoing,
                        isEdited: false,
                        groupchatAuthorRole: "",
                        groupchatAuthorId: "",
                        groupchatAuthorNickname: "",
                        groupchatAuthorBadge: "",
                        isHasAttachedMessages: false,
                        isDownloaded: true,
                        state: .none,
                        searchString:  "",
                        errorMetadata: nil,
                        burnDate: 0,
                        afterburnInterval: 0,
                        archivedId: "\(item.archivedId) unread",
                        queryIds: "\(item.queryIds ?? "") unread",
                        isRead: item.isRead,
                        selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                        references: [],
                        isHadHistoryGap: false,
                        isFakeMessage: true
                    ))
                }
                if (offset + 1 == dataset.count) || self.isDateChange(from: item.sentDate, to: dataset[offset + 1].sentDate) {
                    let kind: MessageKind = .date(
                        NSAttributedString(
                            string: sectionsDateFormatter.string(from: item.sentDate),
                            attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1),
                                .foregroundColor: UIColor.white,
                            ]
                        )
                    )
                    out.append(Datasource(
                        primary: "\(item.primary) date changed",
                        jid: self.jid,
                        owner: self.owner,
                        outgoing: item.outgoing,
                        sender: item.outgoing ? self.ownerSender : self.opponentSender,
                        messageId: item.messageId,
                        sentDate: date,
                        editDate: nil,
                        kind: kind,
                        withAuthor: false,
                        withAvatar: false,//self.groupchat ? !item.outgoing : false,
                        error: item.state == .error,
                        errorType: "",
                        canPinMessage: false,
                        canEditMessage: false,
                        canDeleteMessage: false,
                        forwards: [],
                        isOutgoing: item.outgoing,
                        isEdited: false,
                        groupchatAuthorRole: "",
                        groupchatAuthorId: "",
                        groupchatAuthorNickname: "",
                        groupchatAuthorBadge: "",
                        isHasAttachedMessages: false,
                        isDownloaded: true,
                        state: .none,
                        searchString:  "",
                        errorMetadata: nil,
                        burnDate: 0,
                        afterburnInterval: 0,
                        archivedId: "\(item.archivedId) date changed",
                        queryIds: "\(item.queryIds ?? "") date changed",
                        isRead: item.isRead,
                        selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                        references: [],
                        isHadHistoryGap: false,
                        isFakeMessage: true
                    ))
                }
                
            }
        }
        if self.shouldShowInitialMessage && !self.inSearchMode.value {
            var descriptionText: String = ""
            let aboutAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .regular)
            ]
            switch self.conversationType {
            case .regular:
                descriptionText = "Messages in this chat are not encrypted. Servers often store transient messages in an archive. This allows easy device synchronization and server-side history search, but adds privacy risks."
            case .group:
                    do {
                        let realm = try WRealm.safe()
                        if let group = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                            if group.peerToPeer {
                                descriptionText = "Private chat with incognito user. Messages are routed through group server and your identites are kept secret from each other. Be vigilant, do not disclose yourself by being careless."
                            } else if group.privacy == .incognito {
                                descriptionText = "Identities of users in this group are kept hidden from each other, only group admins can access your real XMPP ID. Be vigilant, do not disclose yourself by being careless."
                            } else {
                                descriptionText = "Identities of users in this group are public, so any member can contact you using your real XMPP ID."
                            }
                        } else {
                            descriptionText = "Identities of users in this group are public, so any member can contact you using your real XMPP ID."
                        }
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
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
            let kind: MessageKind = .initial(modifiedDesccription)
            out.append(Datasource(
                primary: "initial",
                jid: self.jid,
                owner: self.owner,
                outgoing: true,
                sender: self.ownerSender,
                messageId: "initial",
                sentDate: Date(),
                editDate: nil,
                kind: kind,
                withAuthor: false,
                withAvatar: false,//self.groupchat ? !item.outgoing : false,
                error: false,
                errorType: "",
                canPinMessage: false,
                canEditMessage: false,
                canDeleteMessage: false,
                forwards: [],
                isOutgoing: true,
                isEdited: false,
                groupchatAuthorRole: "",
                groupchatAuthorId: "",
                groupchatAuthorNickname: "",
                groupchatAuthorBadge: "",
                isHasAttachedMessages: false,
                isDownloaded: true,
                state: .none,
                searchString:  "",
                errorMetadata: nil,
                burnDate: 0,
                afterburnInterval: 0,
                archivedId: "initial",
                queryIds: "initial",
                isRead: true,
                selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                references: [],
                isHadHistoryGap: false,
                isFakeMessage: true
            ))
        }
        return out
    }
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexSet {
        let inserts = IndexSet(changes.compactMap({ return $0.insert?.index }))
        let deletes = IndexSet(changes.compactMap({ return $0.delete?.index }))
        let replaces = IndexSet(changes.compactMap({ return $0.replace?.index }))
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
    
    internal final func onTouchStartPage(direction: ChatDirection) {
        print(#function)
        FeedbackManager.shared.generate(feedback: .success)
        self.showLoadingIndicator.accept(true)
        self.messagesCollectionView.isUserInteractionEnabled = false
        self.currentPage.prevPage {
            self.loadDatasource(direction: direction) { addditional in
                self.showLoadingIndicator.accept(false)
                if addditional.isNotEmpty {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
                    self.datasource.insert(contentsOf: self.mapDataset(dataset: addditional), at: 0)
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                }
                self.messagesCollectionView.isUserInteractionEnabled = true
                self.loadDatasourceObserver.accept(true)
                self.currentPage.unlock()
            }
        }
    }
    
    internal final func onTouchEndPage(direction: ChatDirection) {
        print(#function)
        FeedbackManager.shared.generate(feedback: .success)
//        DispatchQueue.main.async {
//            self.messageLoadingActivityIndicator.isHidden = false
//        }
        self.showLoadingIndicator.accept(true)
        self.currentPage.nextPage {
            self.loadDatasource(direction: direction) { addditional in
//                DispatchQueue.main.async {
//                    self.messageLoadingActivityIndicator.isHidden = true
//                }
                self.showLoadingIndicator.accept(false)
                if addditional.isNotEmpty {
                    let newDatasource = self.mapDataset(dataset: addditional)
                    if newDatasource.isNotEmpty {
                        let _ = self.datasource.popLast()
                        self.datasource.append(contentsOf: newDatasource)
                    }
                    self.messagesCollectionView.reloadData()
                }
                self.loadDatasourceObserver.accept(true)
                self.currentPage.unlock()
            }
        }
    }
    
    internal final func loadInitialDatasource(_ callback: @escaping ((Array<MessageStorageItem>) -> Void)) {
        func update() {
            let minIndex: Int = 0
            var maxIndex: Int = self.datasourcePageSize
            if maxIndex >= self.messagesObserver.count {
                maxIndex = self.messagesObserver.count - 1
            }
            if maxIndex <= 0 {
                maxIndex = 0
            }
            self.currentPage.minIndex = minIndex
            self.currentPage.maxIndex = maxIndex
            let slice = self.messagesObserver.prefix(upTo: maxIndex)
            callback(Array(slice))
        }
        
        func onLoadingDone() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showSkeletonObserver.accept(false)
                update()
            }
        }
        
        do {
            let realm = try WRealm.safe()
            guard let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid,
                                                               owner: self.owner,
                                                               conversationType: self.conversationType)) else {
                callback([])
                return
            }
            if !chatInstance.isSynced {
                self.showSkeletonObserver.accept(true)
                self.datasource = self.mapDataset(dataset: [])
                self.messagesCollectionView.reloadData()
                var dateLimit: Date? = nil
                if !self.messagesObserver.isEmpty {
                    let slice = self.messagesObserver.prefix(self.datasourcePageSize)
                    slice.enumerated().reversed().forEach {
                        (offset, item) in
                        if offset > 0 && dateLimit == nil {
                            let prevQueryIDs = Set((slice[offset - 1].queryIds ?? "").split(separator: ","))
                            if prevQueryIDs.intersection(Set((item.queryIds ?? "").split(separator: ","))).isEmpty {
                                dateLimit = slice[offset -  1].date
                                return
                            }
                        }
                    }
                }
                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                    session.mam?.getHistoryByDate(
                        stream,
                        jid: self.jid,
                        conversationType: self.conversationType,
                        start: dateLimit,
                        end: nil,
                        reversed: true,
                        callback: onLoadingDone
                    )
                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.mam.getHistoryByDate(
                            stream,
                            jid: self.jid,
                            conversationType: self.conversationType,
                            start: dateLimit,
                            end: nil,
                            reversed: true,
                            callback: onLoadingDone
                        )
                    })
                }

            } else {
                update()
            }
            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal final func loadDatasource(direction: ChatDirection, first: Bool = false, ignoreGaps: Bool = false, samePage: Bool = false, callback: @escaping ((Array<MessageStorageItem>) -> Void)) {
        func onLoadingDone() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var (minIndex, maxIndex) = getIndexes()
                if maxIndex > self.messagesObserver.count {
                    maxIndex = self.messagesObserver.count
                }
                if maxIndex < 0 {
                    maxIndex = 0
                }
                let slice = Array(self.messagesObserver.prefix(upTo: maxIndex).suffix(maxIndex - minIndex))
//                self.currentPage.minIndex = minIndex
//                self.currentPage.maxIndex = maxIndex
                switch direction {
                    case .down:
                        self.currentPage.minIndex = minIndex
                    case .up:
                        self.currentPage.maxIndex = maxIndex
                }
                self.messageLoadingActivityIndicator.isHidden = true
                callback(slice)
            }
        }
        
        func getIndexes() -> (Int, Int){
            let pageStartIndex: Int // = self.c//self.currentPage.page * self.datasourcePageSize
            let pageEndIndex: Int
            
            if samePage {
//                guard let currentIndexMin = self.datasource.filter {  }
                pageStartIndex = currentPage.minIndex
                pageEndIndex = currentPage.maxIndex
            } else {
                print(direction)
                switch direction {
                    case .down:
                        pageStartIndex = currentPage.minIndex
                        pageEndIndex = pageStartIndex - self.datasourcePageSize
                    case .up:
                        pageStartIndex = currentPage.maxIndex
                        pageEndIndex = pageStartIndex + self.datasourcePageSize
                }
            }
            let maxIndex = [pageStartIndex, pageEndIndex].max() ?? 0
            let minIndex = [[pageStartIndex, pageEndIndex].min() ?? 0, 0].max() ?? 0
            
            return (minIndex, maxIndex)
        }
        
        guard self.messagesObserver != nil else {
            self.loadDatasourceObserver.accept(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        if direction == .down && self.currentPage.minIndex < 0 {
            self.loadDatasourceObserver.accept(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        if self.currentPage.minIndex == 0 && self.currentPage.maxIndex >= self.messagesObserver.count - 1 && !first{
            self.loadDatasourceObserver.accept(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        if direction == .up && self.currentPage.maxIndex >= self.messagesObserver.count - 1 {
            self.loadDatasourceObserver.accept(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        var (minIndex, maxIndex) = getIndexes()
        if minIndex == 0 && maxIndex == 0 && !first {
            self.loadDatasourceObserver.accept(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        print(minIndex, maxIndex, "INDEXES", self.messagesObserver.count, "count")
        print(1)
        var hasGap: Bool = false
        var archivedId: String = ""
        var isArchiveEnded: Bool = false
        do {
            let realm = try WRealm.safe()
            isArchiveEnded = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.fullArchiveLoaded ?? false
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        if minIndex >= self.messagesObserver.count && isArchiveEnded {
            callback([])
            return
        } else if maxIndex > self.messagesObserver.count {
            maxIndex = self.messagesObserver.count
            if !(isArchiveEnded) {
                hasGap = !ignoreGaps
                archivedId = self.messagesObserver.last?.archivedId ?? ""
            }
        }
        if !hasGap {
            if maxIndex > self.messagesObserver.count {
                maxIndex = self.messagesObserver.count - 1
            }
            if minIndex < 0 {
                minIndex = 0
            }
            let slice = Array(self.messagesObserver.prefix(upTo: maxIndex).suffix(maxIndex - minIndex))
            
            slice.enumerated().forEach {
                (offset, item) in
                let newIndex = offset + 1
                if newIndex < slice.count {
                    let currentQueryIds: Set<String> = Set((slice[offset].queryIds ?? "").split(separator: ",").compactMap { return String($0) })
                    if currentQueryIds.intersection(["runtime_send", "runtime_send"]).isEmpty {
                        let nextQueryIds: Set<String> = Set((slice[newIndex].queryIds ?? "").split(separator: ",").compactMap { return String($0) })
                        let intersection = currentQueryIds.intersection(nextQueryIds)
                        if intersection.isEmpty {
                            hasGap = !ignoreGaps
                        }
                    }
                }
            }
            if !hasGap {
                switch direction {
                    case .down:
                        self.currentPage.minIndex = minIndex
                    case .up:
                        self.currentPage.maxIndex = maxIndex
                }
//                self.currentPage.minIndex = minIndex
//                self.currentPage.maxIndex = maxIndex
                callback(slice)
            }
            switch direction {
                case .down:
                    if minIndex == 0 {
                        archivedId = ""
                    } else {
                        archivedId = slice.first?.archivedId ?? ""
                    }
                case .up: 
                    archivedId = slice.last?.archivedId ?? ""
            }
        }
        if hasGap {
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                switch direction {
                    case .up:
                        session.mam?.getNextHistory(
                            stream,
                            for: self.jid,
                            conversationType: self.conversationType,
                            messageId: archivedId,
                            callback: onLoadingDone
                        )
                    case .down:
                        session.mam?.getPrevHistory(
                            stream,
                            for: self.jid,
                            conversationType: self.conversationType,
                            messageId: archivedId,
                            callback: onLoadingDone
                        )
                }
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    switch direction {
                        case .up:
                            user.mam.getNextHistory(
                                stream,
                                for: self.jid,
                                conversationType: self.conversationType,
                                messageId: archivedId,
                                callback: onLoadingDone
                            )
                        case .down:
                            user.mam.getPrevHistory(
                                stream,
                                for: self.jid,
                                conversationType: self.conversationType,
                                messageId: archivedId,
                                callback: onLoadingDone
                            )
                    }
                })
            }
        }
    }
    
    
    func didReceiveChangeset() {
        if self.canLoadDatasource {
//            self.loadDatasource(direction: self.chatScrollDirection ?? .up, ignoreGaps: true, samePage: true) { array in
            guard let minPrimary = self.datasource.filter({ !$0.isFakeMessage }).first?.primary,
                  let maxPrimary = self.datasource.filter({ !$0.isFakeMessage }).last?.primary,
                  let maxIndexRaw = self.messagesObserver.firstIndex(where: { $0.primary == maxPrimary }) else {
                return
            }
            var maxIndex = maxIndexRaw
            if self.currentPage.minIndex == 0 {
                if self.messagesObserver.count < self.datasourcePageSize {
                    maxIndex = self.messagesObserver.count
                }
            }
            let minIndex = self.currentPage.minIndex
            let array = Array(self.messagesObserver.prefix(upTo: maxIndex).suffix(maxIndex - minIndex))
            let newDatasource = self.mapDataset(dataset: array)
            let diff = diff(old: self.datasource, new: newDatasource)
            let updated = diff.compactMap { $0.replace }
            let inserted = diff.compactMap { $0.insert }
            let deleted = diff.compactMap { $0.delete }
            let moved = diff.compactMap { $0.move }
            if updated.isEmpty && inserted.isEmpty && deleted.isEmpty && moved.isEmpty { return }
            self.messagesCollectionView.performBatchUpdates {
                self.datasource = newDatasource
                self.messagesCollectionView.deleteSections(IndexSet(deleted.compactMap { return $0.index }) )
                self.messagesCollectionView.insertSections(IndexSet(inserted.compactMap { return $0.index }) )
                moved.forEach {
                    self.messagesCollectionView.moveItem(at: IndexPath(row: 0, section: $0.fromIndex), to: IndexPath(row: 0, section: $0.toIndex))
                }
                
            } completion: { _ in
                
            }
            UIView.performWithoutAnimation {
                self.messagesCollectionView.reconfigureItems(at: updated.compactMap { return IndexPath(row: 0, section: $0.index) })
            }
        }
        
    }
    
    internal func scrollToLastOrUnreadItem() {
        if self.currentPage.minIndex > 0 {
            self.currentPage.setCustomPage(0) {
                var maxIndex = self.datasourcePageSize / 2
                let minIndex =  0
                if maxIndex > self.messagesObserver.count {
                    maxIndex = self.messagesObserver.count
                }
                
                let slice = Array(self.messagesObserver.prefix(upTo: maxIndex).suffix(from: minIndex))
                self.currentPage.minIndex = minIndex
                self.currentPage.maxIndex = maxIndex
                
                self.currentPage.unlock()
                self.datasource = self.mapDataset(dataset: slice)
                self.messagesCollectionView.reloadData()
                self.messagesCollectionView.layoutIfNeeded()
                if let index = self.unreadMessagePositionId {
                    if Set(self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section })).contains(index) {
                        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
                    } else {
                        self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: false)
                    }
                } else {
                    self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
                }
                self.showFloatingDateObserver.accept(true)
            }
        }
        if let index = self.unreadMessagePositionId {
            if Set(self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section })).contains(index) {
                self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
            } else {
                self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: true)
            }
        } else {
            self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }
    }
}
