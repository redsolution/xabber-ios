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

    internal final func updateDateLabels(afterIndex: Int = 0) {
        self.previousContentOffsetY = 0
        let layout = self.messagesCollectionView.collectionViewLayout as! MessagesCollectionViewFlowLayout
        self.nextPinnedDateIndex = nil
        self.pinnedDateIndex = nil
        self.pinnedDateFrame = .zero
        var indexPaths: [IndexPath] = []
        self.dateViews.forEach { $0.removeFromSuperview() }
        autoreleasepool {
            self.dateViews = []
            self.originalFrames = []
            self.realDateFrames = []
        }
        let maxVisible = ([(self.messagesCollectionView.indexPathsForVisibleItems.compactMap { $0.section }.max() ?? 0), afterIndex - 1].max() ?? 0 ) - 1
        let firstPinned: Int = self.datasource.enumerated().compactMap {
            switch $1.kind {
                case .date(_):
                    if maxVisible < $0 {
                        return $0
                    } else {
                        return nil
                    }
                default:
                    return nil
            }
        }.min() ?? 0
        
        
        var largestDateFrame: CGRect = .zero
        self.datasource.enumerated().forEach {
            (offset, item) in
            switch item.kind {
                case .date(_):
                    let path = IndexPath(row: 0, section: offset)
                    indexPaths.append(path)
                    let attrib = layout.layoutAttributesForItem(at: path)
                    guard let frame = attrib?.frame else { return }
                    var convertedPoint = self.messagesCollectionView.convert(frame.origin, to: self.view)
                    var inset: CGFloat = 0
                    if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.vertical {
                        inset += topInset
                    }
                    convertedPoint.y = convertedPoint.y + inset
                    let newFrame = CGRect(origin: convertedPoint, size: frame.size)
                    self.originalFrames.append(newFrame)
                    if largestDateFrame.width < newFrame.width {
                        largestDateFrame = newFrame
                    }
                default:
                    break
            }
        }
        
        var pinnedFrame = CGRect(origin: .zero, size: largestDateFrame.size)
        var offsetY: CGFloat = self.navbarOverlayView.frame.height
        
        
        self.originalFrames.enumerated().forEach {
            (offset, item) in
            if item.maxY < pinnedFrame.maxY && self.pinnedDateIndex == nil {
                self.realDateFrames.append(item)
                self.pinnedDateIndex = offset
            } else {
                if let index = self.pinnedDateIndex {
                    print("\(offset) - \(index) pos123")
                    let frame = pinnedFrame.offsetBy(dx: 0, dy: -16 - (CGFloat(offset - index - 1) * (pinnedFrame.height)))
                    self.realDateFrames.append(frame)
                } else {
                    self.realDateFrames.append(item)
                }
            }
        }
//        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
//            offsetY += topInset
//        }
        pinnedFrame = pinnedFrame.offsetBy(dx: 0, dy: offsetY + 8)
        self.pinnedDateIndex = nil
        self.originalFrames.enumerated().forEach {
            (offset, _) in
            self.originalFrames[offset].size = largestDateFrame.size
        }
        
        var dateItemIndex: Int = 0
        print(pinnedFrame, "pinnedFrame")
        self.datasource.enumerated().forEach {
            (offset, item) in
            switch item.kind {
                case .date(let text):
                    let newFrame = self.originalFrames[dateItemIndex]
                    let view = FloatDateView(frame: newFrame)
                    view.primary = item.primary
                    view.configure(text)
                    view.isPinned = false
                    view.naturalIndex = offset
                    if newFrame.maxY < pinnedFrame.maxY && self.pinnedDateIndex == nil{
                        
                        self.pinnedDateFrame = pinnedFrame
                        self.pinnedDateIndex = dateItemIndex
                        view.frame = pinnedFrame
                        view.isPinned = true
                    }
                    
                    self.dateListContainerView.addSubview(view)
                    self.dateViews.append(view)
                    dateItemIndex += 1
                default:
                    break
            }
        }
        let contentOffsetY = self.messagesCollectionView.contentOffset.y
        let prevScrollDirection: ChatDirection = self.chatScrollDirection ?? .up
        if contentOffsetY > self.previousContentOffsetY {
            self.chatScrollDirection = .up
        } else {
            self.chatScrollDirection = .down
        }
        self.updateDateViews(contentOffsetY: contentOffsetY, prevScrollDirection: prevScrollDirection)
        self.contentOffsetObserver.accept(contentOffsetY)
//        }
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
                    isRead: true
                )
            }
        }
        var out: [Datasource] = []
        var unreadId: String? = nil
        do {
            let realm = try WRealm.safe()
            unreadId = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastReadId
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
                    
                    var descriptionText: String = ""
    //                var descriptionText: NSAttributedString = NSAttributedString()
                    let aboutAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 15, weight: .regular)
                    ]
                   
                    switch self.conversationType {
                    case .regular:
                        descriptionText = "Messages in this chat are not encrypted. Servers often store transient messages in an archive. This allows easy device synchronization and server-side history search, but adds privacy risks."
                    case .group:
//                        switch self.entity {
//                        case .incognitoChat:
//                            descriptionText = "Identities of users in this group are kept hidden from each other, only group admins can access your real XMPP ID. Be vigilant, do not disclose yourself by being careless."
//                        case .privateChat:
//                            descriptionText = "Private chat with incognito user. Messages are routed through group server and your identites are kept secret from each other. Be vigilant, do not disclose yourself by being careless."
//                        default:
                            descriptionText = "Identities of users in this group are public, so any member can contact you using your real XMPP ID."
//                        }
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
                withAvatar: false,//self.groupchat ? !item.outgoing : false,
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
                        isHadHistoryGap: false
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
                        isHadHistoryGap: false
                    ))
                }
                
            }
        }
        return out
    }
    
    
    func reloadDataWithFixedPosition() {
        let contentOffset = self.messagesCollectionView.contentOffset.y
        let contentHeight = self.messagesCollectionView.contentSize.height
//        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: contentOffset), animated: false)
        self.messagesCollectionView.reloadData()
        let newContentHeight = self.messagesCollectionView.contentSize.height
        print(contentOffset, contentHeight, "cont HEIGHT")
        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: contentOffset + (newContentHeight - contentHeight)), animated: false)
    }
    
    internal final func onTouchStartPage(direction: ChatDirection) {
        print(#function)
        self.currentPage.prevPage(autoUnlock: false) {
            self.loadDatasource(direction: direction) { addditional in
                (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
                self.datasource.insert(contentsOf: self.mapDataset(dataset: addditional), at: 0)
                self.messagesCollectionView.reloadDataAndKeepOffset()
                self.messagesCollectionView.layoutIfNeeded()
                self.updateDateLabels(afterIndex: self.pinnedDateIndex ?? 0)
                do {
                    self.currentPage.unlock()
                }
            }
        }
    }
    
    internal final func onTouchEndPage(direction: ChatDirection) {
        print(#function)
        FeedbackManager.shared.generate(feedback: .success)
        DispatchQueue.main.async {
            self.messageLoadingActivityIndicator.isHidden = false
        }
        self.currentPage.nextPage(autoUnlock: false) {
            self.loadDatasource(direction: direction) { addditional in
                DispatchQueue.main.async {
                    self.messageLoadingActivityIndicator.isHidden = true
                }
                (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
                self.datasource.append(contentsOf: self.mapDataset(dataset: addditional))
                self.messagesCollectionView.reloadData()
                self.messagesCollectionView.layoutIfNeeded()
                self.updateDateLabels(afterIndex: self.pinnedDateIndex ?? 0)
                do {
                    self.currentPage.unlock()
                }
            }
        }
    }
    
    internal final func loadDatasource(direction: ChatDirection, ignoreGaps: Bool = false, samePage: Bool = false, callback: @escaping ((Array<MessageStorageItem>) -> Void)) {
        func onLoadingDone() {
            DispatchQueue.main.async {
                let (minIndex, maxIndex) = getIndexes()
                let slice = Array(self.messagesObserver.prefix(maxIndex).suffix(maxIndex - minIndex))
                self.currentPage.minIndex = minIndex
                self.currentPage.maxIndex = maxIndex
                callback(slice)
                
            }
        }
        
        func getIndexes() -> (Int, Int){
            let pageStartIndex: Int // = self.c//self.currentPage.page * self.datasourcePageSize
            let pageEndIndex: Int
            
            if samePage {
                pageStartIndex = currentPage.minIndex
                pageEndIndex = currentPage.maxIndex
            } else {
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
            return
        }
        if direction == .down && self.currentPage.minIndex < 0 {
            return
        }
        let (minIndex, maxIndex) = getIndexes()
        print(minIndex, maxIndex)
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
            if !(isArchiveEnded) {
                hasGap = !ignoreGaps
                archivedId = self.messagesObserver.last?.archivedId ?? ""
            }
        }
        if !hasGap {
            let slice = Array(self.messagesObserver!.prefix(maxIndex).suffix(maxIndex - minIndex))
            
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
                self.currentPage.minIndex = minIndex
                self.currentPage.maxIndex = maxIndex
                callback(slice)
            }
            switch direction {
                case .up:
                    if minIndex == 0 {
                        archivedId = ""
                    } else {
                        archivedId = slice.first?.archivedId ?? ""
                    }
                case .down: 
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
        if self.currentPage.locked {
            return
        }
        self.loadDatasource(direction: self.chatScrollDirection ?? .up, ignoreGaps: true, samePage: true) { array in
            let newDatasource = self.mapDataset(dataset: array)
            let diff = diff(old: self.datasource, new: newDatasource)
            let updated = diff.compactMap { $0.replace }
            let inserted = diff.compactMap { $0.insert }
            let deleted = diff.compactMap { $0.delete }
            let moved = diff.compactMap { $0.move }
            if updated.isEmpty && inserted.isEmpty && deleted.isEmpty && moved.isEmpty { return }
            print("updated",updated.compactMap { return $0.index })
            print("inserted", inserted.compactMap { return $0.index })
            print("deleted", deleted.compactMap { return $0.index })
//            print("moved", moved.compactMap { return $0.index })
            self.messagesCollectionView.performBatchUpdates {
                self.datasource = newDatasource
                self.messagesCollectionView.deleteSections(IndexSet(deleted.compactMap { return $0.index }) )
                self.messagesCollectionView.insertSections(IndexSet(inserted.compactMap { return $0.index }) )
                moved.forEach {
                    self.messagesCollectionView.moveItem(at: IndexPath(row: 0, section: $0.fromIndex), to: IndexPath(row: 0, section: $0.toIndex))
                }
                self.messagesCollectionView.reconfigureItems(at: updated.compactMap { return IndexPath(row: 0, section: $0.index) })
                
            } completion: { _ in
                self.updateDateLabels(afterIndex: self.pinnedDateIndex ?? 0)
            }
        }
        
    }
    
    internal func scrollToLastOrUnreadItem() {
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
