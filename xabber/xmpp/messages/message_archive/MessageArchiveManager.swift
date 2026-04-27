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
import XMPPFramework
import KissXML
import RealmSwift
import RxSwift

/// TODO: fix wrong message count when response missed

struct MessageArchivePageEndState: Equatable {
    let queryExhausted: Bool
    let archiveEnded: Bool
    let persistedMessageCount: Int
    let requestCursorId: String?

    init(
        queryExhausted: Bool,
        archiveEnded: Bool,
        persistedMessageCount: Int,
        requestCursorId: String? = nil
    ) {
        self.queryExhausted = queryExhausted
        self.archiveEnded = archiveEnded
        self.persistedMessageCount = persistedMessageCount
        self.requestCursorId = requestCursorId
    }
}

protocol TemporaryMessageReceiverProtocol {
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String)
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int)
}

class MessageArchiveManager: AbstractXMPPManager {

    enum HistoryCursorPolicy {
        static func persistedOlderCursorId(
            purpose: MessageArchiveManager.RequestPurpose,
            first: String,
            last: String,
            current: String?
        ) -> String? {
            guard [.bootstrap, .pageOlder].contains(purpose) else {
                return current
            }

            // iOS older-history requests use flip-page, so RSM `last` is the
            // oldest archived id in the fetched page and is the correct cursor
            // for the next `before=` request.
            if last.isNotEmpty {
                return last
            }

            guard first.isNotEmpty else {
                return current
            }

            return first
        }
    }

    struct RequestCallbacks {
        let onMessage: ((MessageStorageItem, String) -> Void)?
        let onEndPage: ((String, MessageArchivePageEndState, String, String, Int) -> Void)?

        static let none = RequestCallbacks(
            onMessage: nil,
            onEndPage: nil
        )
    }

    enum SyncChatStartResult: Equatable {
        case bootstrapStarted(queryId: String)
        case gapRepairOnly
        case noop
    }
    
    enum Tags: String {
        case image = "image"
        case audio = "audio"
        case video = "video"
        case document = "document"
        case sticker = "sticker"
        case voice = "voice"
        case geo = "geo"
        case voip = "voip"
    }

    enum RequestPurpose: Equatable, Hashable {
        case bootstrap
        case pageOlder
        case pageNewer
        case jump
        case gapRepair
        case search
        case latest
        case media

        var marksInitialArchiveLoaded: Bool {
            self == .bootstrap
        }
    }

    struct PageRequestConfiguration: Equatable {
        let nextPage: String?
        let prevPage: String?
        let max: Int
    }

    static func newestBootstrapPageRequest(pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(nextPage: "", prevPage: nil, max: pageSize)
    }

    static func olderPageRequest(messageId: String?, pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(
            nextPage: (messageId?.isNotEmpty ?? false) ? messageId : "",
            prevPage: nil,
            max: pageSize
        )
    }

    static func newerPageRequest(messageId: String, pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(nextPage: nil, prevPage: messageId, max: pageSize)
    }
    
    struct GapItem: Hashable, Equatable {
        
        let left: String
        let right: String
        let leftDate: Date
        let rightDate: Date
        
        var verbose: String {
            get {
                return "left: \(left) | right: \(right) "
            }
        }
    }
        
    struct MAMRequestItem: Equatable, Hashable {
        let jid: String?
        let taskID: String
        let isGroupchat: Bool
        let messageId: String?
        let conversationType: ClientSynchronizationManager.ConversationType
        let isContinues: Bool
        let maxDate: Date?
        let searchText: String?
        let queryId: String?
        let afterId: String?
        let max: Int
        let tags: [Tags]
        let start: Date?
        let end: Date?
        let purpose: RequestPurpose
        let archiveEndEligibility: Bool
        let consumerManagesArchiveEnd: Bool
        let consumerManagesHistoryCursor: Bool
    }
    
    struct CallbackQueueItem: Equatable, Hashable {
        static func == (lhs: CallbackQueueItem, rhs: CallbackQueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        let jid: String
        let elementId: String
        let task: MAMRequestItem
        let callback: (() -> Void)?
        let requestCallbacks: RequestCallbacks
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    var callbacksQueue: Set<CallbackQueueItem> = Set<CallbackQueueItem>()
    
//    var delegate: MessageArchiveManagerDelegate? = nil
    var backgroundTaskDelegate: XMPPBackgroundTaskDelegate? = nil
    
    var interactiveQueue: SynchronizedArray<String> = SynchronizedArray<String>()
    
    internal var version: String? = nil
    public var isInitialArchiveRequested: Bool = false
    
    public var allowHistoryFixTask: Bool = false
    
    public var continuesTaskID: String? = nil
    
    internal let pageSize: Int = ChatHistoryPagingConfiguration.pageSize
    
    internal var searchResultsQueries: Set<String> = Set()
    
    open var temporaryMessageReceiverDelegate: TemporaryMessageReceiverProtocol? = nil
    private var persistedMessageCountsByQueryId: [String: Int] = [:]
    
    override init(withOwner owner: String) {
        self.isInitialArchiveRequested = SettingManager.shared.getKey(for: owner, scope: .messageArchive, key: "initial") == nil
        super.init(withOwner: owner)
    }
    
    private func completeCallback(_ callback: (() -> Void)?) {
        DispatchQueue.main.async {
            callback?()
        }
    }

    private func notifyDidReceiveEndPage(_ callbacks: RequestCallbacks, queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        DispatchQueue.main.async {
            callbacks.onEndPage?(queryId, state, first, last, count)
            self.temporaryMessageReceiverDelegate?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
        }
    }

    private func notifyDidReceiveMessage(_ item: MessageStorageItem, queryId: String, callbacks: RequestCallbacks) {
        self.persistedMessageCountsByQueryId[queryId, default: 0] += 1
        DispatchQueue.main.async {
            callbacks.onMessage?(item, queryId)
            self.temporaryMessageReceiverDelegate?.didReceiveMessage(item, queryId: queryId)
        }
    }

    private func makePageEndState(
        for task: MAMRequestItem,
        queryId: String,
        queryExhausted: Bool
    ) -> MessageArchivePageEndState {
        let persistedMessageCount = self.persistedMessageCountsByQueryId.removeValue(forKey: queryId) ?? 0
        return MessageArchivePageEndState(
            queryExhausted: queryExhausted,
            archiveEnded: queryExhausted && task.archiveEndEligibility,
            persistedMessageCount: persistedMessageCount,
            requestCursorId: task.messageId
        )
    }

    private func canMarkArchiveEnd(
        purpose: RequestPurpose,
        searchText: String?,
        ids: [String]?,
        beforeId: String?,
        afterId: String?,
        start: Date?,
        end: Date?,
        tags: [Tags],
        withCounter: Bool
    ) -> Bool {
        guard [.bootstrap, .pageOlder].contains(purpose) else {
            return false
        }

        // Only pure identity-based archive walks may update the chat's oldest-boundary state.
        // If requestArchive gains more MAM data-form filters in the future, they must be added here.
        return searchText == nil &&
            (ids?.isEmpty ?? true) &&
            (beforeId?.isEmpty ?? true) &&
            (afterId?.isEmpty ?? true) &&
            start == nil &&
            end == nil &&
            tags.isEmpty &&
            !withCounter
    }

    override func namespaces() -> [String] {
        return ["urn:xmpp:mam:2"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    func makeInitialMessageVisible(jid: String, conversationType: ClientSynchronizationManager.ConversationType, queryId: String) throws {
        if !queryId.contains("history") {
            return
        }
        let realm = try WRealm.safe()
        if let instance = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: self.owner,
                conversationType: conversationType
            )
        ) {
            try realm.write {
                instance.isAllHistoryLoaded = true
            }
        }
    }
    
    func read(_ stream: XMPPStream, withIQ iq: XMPPIQ) -> Bool {
        if iq.iqType == .error,
           let elementId = iq.elementID,
           let item = self.callbacksQueue.first(where: { $0.elementId == elementId }) {
            let queryId = item.task.queryId ?? elementId
            let pageEndState = self.makePageEndState(
                for: item.task,
                queryId: queryId,
                queryExhausted: true
            )
            self.completeCallback(item.callback)
            self.notifyDidReceiveEndPage(
                item.requestCallbacks,
                queryId: queryId,
                state: pageEndState,
                first: "",
                last: "",
                count: 0
            )
            self.callbacksQueue.remove(item)
            self.queryIds.remove(elementId)
            return true
        }

        guard iq.iqType == .result,
              let elementId = iq.elementID,
              let fin = iq.element(forName: "fin", xmlns: getPrimaryNamespace()),
              let queryId = fin.attributeStringValue(forName: "queryid"),
              let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            return false
        }
        let complete = fin.attributeBoolValue(forName: "complete")
        let first = set.element(forName: "first")?.stringValue ?? ""
        let last = set.element(forName: "last")?.stringValue ?? ""
//        DispatchQueue.global().async {
            if let item = self.callbacksQueue.first(where: { $0.elementId == elementId }) {
                if item.task.isContinues {
                    let nextPage = set.element(forName: "last")?.stringValue
                    do {
                        if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                            let realm = try Realm()
                            let pageEndState = self.makePageEndState(
                                for: item.task,
                                queryId: queryId,
                                queryExhausted: count == 0 || complete
                            )
                            
                            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                if count == 0 {
                                    if item.task.archiveEndEligibility && !item.task.consumerManagesArchiveEnd {
                                        try realm.write {
                                            instance.fullArchiveLoaded = pageEndState.archiveEnded
                                        }
                                    }
                                    self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                    self.completeCallback(item.callback)
                                    self.callbacksQueue.remove(item)
                                    return true
                                }
                                if complete {
//                                    try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                    try realm.write {
                                        if item.task.archiveEndEligibility && !item.task.consumerManagesArchiveEnd {
                                            instance.fullArchiveLoaded = pageEndState.archiveEnded
                                        }
                                        if !item.task.consumerManagesHistoryCursor {
                                            instance.lastLoadedMessageHistoryId = HistoryCursorPolicy.persistedOlderCursorId(
                                                purpose: item.task.purpose,
                                                first: first,
                                                last: last,
                                                current: instance.lastLoadedMessageHistoryId
                                            )
                                        }
                                    }
                                    self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                    self.completeCallback(item.callback)
                                    self.callbacksQueue.remove(item)
                                    return true
                                }
                            }
                            if count == 0 {
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                self.completeCallback(item.callback)
                                self.callbacksQueue.remove(item)
                                return true
                            }
                            if complete {
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                self.completeCallback(item.callback)
                                self.callbacksQueue.remove(item)
                                return true
                            }
                            self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: item.task.max)
                        }
                    } catch {
                        DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.continueLoadHistory(
                            stream,
                            task: item.task,
                            nextPage: nextPage,
                            requestCallbacks: item.requestCallbacks,
                            callback: item.callback
                        )
                    }
                } else {
                    self.completeCallback(item.callback)
                    if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                        do {
                            let realm = try Realm()
                            let pageEndState = self.makePageEndState(
                                for: item.task,
                                queryId: queryId,
                                queryExhausted: count == 0 || complete
                            )
                            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                try realm.write {
                                    if item.task.archiveEndEligibility && !item.task.consumerManagesArchiveEnd {
                                        instance.fullArchiveLoaded = pageEndState.archiveEnded
                                    }
                                    if item.task.purpose.marksInitialArchiveLoaded {
                                        instance.isInitialArchiveLoaded = true
                                        instance.isSynced = true
                                    }
                                    if !item.task.consumerManagesHistoryCursor {
                                        instance.lastLoadedMessageHistoryId = HistoryCursorPolicy.persistedOlderCursorId(
                                            purpose: item.task.purpose,
                                            first: first,
                                            last: last,
                                            current: instance.lastLoadedMessageHistoryId
                                        )
                                    }
                                }
                            }
                            if count == 0 {
//                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                self.callbacksQueue.remove(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                return true
                            }
                            if fin.attributeBoolValue(forName: "complete") {
//                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                self.callbacksQueue.remove(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count)
                                return true
                            }
                            self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: item.task.max)
//                            if try self.checkShouldLoadFullHistory(for: item.jid, conversationType: item.task.conversationType) {
//                                try self.startLoadHistory(stream, jid: item.jid, conversationType: item.task.conversationType)
//                            }
                        } catch {
                            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                }
                self.callbacksQueue.remove(item)
            }
//        }
        return true
    }
    
    public func getHistoryByDate(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, start: Date? = nil, end: Date? = nil, reversed: Bool = false, callback: @escaping (() -> Void)) {
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: "MAM untill rev=\(reversed ? "true" : "false") history: \(NanoID.new(6))",
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: start,
            end: end,
            nextPage: reversed ? "" : nil,//end == nil ? nil : "",
            prevPage: nil,
            max: 250,
            callback: callback
        )
    }
    
    public func searchText(_ stream: XMPPStream, jid: String? = nil, conversationType: ClientSynchronizationManager.ConversationType, text: String, max: Int = 250, loadFull: Bool = true, requestCallbacks: RequestCallbacks = .none) -> String {
        let taskId = [jid ?? "global_search", conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.callbacksQueue.remove(item)
                    }
                }
            }
        }
        let queryId = "MAM search: \(NanoID.new(8))"
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: loadFull,
            conversationType: conversationType,
            purpose: .search,
            queryId: queryId,
            searchText: text,
            flipPage: false,
            nextPage: "",
            max: max,
            callback: nil,
            requestCallbacks: requestCallbacks
        )
        self.continuesTaskID = taskId
        return queryId
    }
    
    public func getMedia(_ stream: XMPPStream, jid: String?, conversationType: ClientSynchronizationManager.ConversationType, media: [MessageMediaAttachmentStorageItem.Kind], after lastMessageId: String?, requestCallbacks: RequestCallbacks = .none) {
        let taskId = ["media", jid ?? "global", conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.callbacksQueue.remove(item)
                    }
                }
            }
        }
        let queryId = "MAM attach: \(NanoID.new(8))"
        let tags: [Tags] = media.compactMap { return Tags(rawValue: $0.rawValue) }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .media,
            queryId: queryId,
            flipPage: false,
            nextPage: lastMessageId,
            max: 150,
            tags: tags,
            callback: nil,
            requestCallbacks: requestCallbacks
        )
        self.searchResultsQueries.insert(queryId)
        self.continuesTaskID = taskId
    }
    
    
    internal func requestArchive(_ stream: XMPPStream, jid: String?, isContinues: Bool, conversationType: ClientSynchronizationManager.ConversationType, purpose: RequestPurpose, queryId: String? = nil, searchText: String? = nil, ids: [String]? = nil, flipPage: Bool = true, before: String? = nil, beforeId: String? = nil, afterId: String? = nil, start: Date? = nil, end: Date? = nil, nextPage: String? = nil, prevPage: String? = nil, max: Int? = nil, tags: [Tags] = [], withCounter: Bool = false, consumerManagesArchiveEnd: Bool = false, consumerManagesHistoryCursor: Bool = false, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none) {
        let isGroupchat = [.group, .channel].contains(conversationType)
        let elementId = queryId ?? "MAM: \(NanoID.new(8))"
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        query.addAttribute(withName: "queryid", stringValue: elementId)
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        let formType = DDXMLElement(name: "field")
        formType.addAttribute(withName: "var", stringValue: "FORM_TYPE")
        formType.addAttribute(withName: "type", stringValue: "hidden")
        formType.addChild(DDXMLElement(name: "value", stringValue: getPrimaryNamespace()))
        x.addChild(formType)
        if let beforeId = beforeId,
           beforeId.isNotEmpty {
            let beforeIdElement = DDXMLElement(name: "field")
            beforeIdElement.addAttribute(withName: "var", stringValue: "before-id")
            beforeIdElement.addChild(DDXMLElement(name: "value", stringValue: beforeId))
            x.addChild(beforeIdElement)
        }
        if let afterId = afterId,
           afterId.isNotEmpty {
            let afterIdElement = DDXMLElement(name: "field")
            afterIdElement.addAttribute(withName: "var", stringValue: "after-id")
            afterIdElement.addChild(DDXMLElement(name: "value", stringValue: afterId))
            x.addChild(afterIdElement)
        }
        if let start = start {
            let startElement = DDXMLElement(name: "field")
            startElement.addAttribute(withName: "var", stringValue: "start")
            startElement.addChild(DDXMLElement(name: "value", stringValue: start.XMPPFormattedDate))
            x.addChild(startElement)
        }
        if let end = end {
            let endElement = DDXMLElement(name: "field")
            endElement.addAttribute(withName: "var", stringValue: "end")
            endElement.addChild(DDXMLElement(name: "value", stringValue: end.XMPPFormattedDate))
            x.addChild(endElement)
        }
        if withCounter {
            let counterElement = DDXMLElement(name: "field")
            counterElement.addAttribute(withName: "var", stringValue: "rsm-counter")
            counterElement.addChild(DDXMLElement(name: "value", numberValue: 1))
            x.addChild(counterElement)
        }
        if !isGroupchat {
            if let jid = jid {
                let withElement = DDXMLElement(name: "field")
                withElement.addAttribute(withName: "var", stringValue: "with")
                withElement.addChild(DDXMLElement(name: "value", stringValue: jid))
                x.addChild(withElement)
            }
        }
        if !isGroupchat {
            let ctElement = DDXMLElement(name: "field")
            ctElement.addAttribute(withName: "var", stringValue: "conversation-type")
            ctElement.addChild(DDXMLElement(name: "value", stringValue: conversationType.rawValue))
            x.addChild(ctElement)
        }
        if tags.isNotEmpty {
            let tElement = DDXMLElement(name: "field")
            tElement.addAttribute(withName: "var", stringValue: "with-tags")
            tags.forEach {
                tElement.addChild(DDXMLElement(name: "value", stringValue: $0.rawValue))
            }
            x.addChild(tElement)
        }
        if let searchText = searchText {
            let stElement = DDXMLElement(name: "field")
            stElement.addAttribute(withName: "var", stringValue: "withtext")
            stElement.addChild(DDXMLElement(name: "value", stringValue: searchText))
            x.addChild(stElement)
            self.searchResultsQueries.insert(elementId)
        }
        if let ids,
           ids.isNotEmpty {
            let idsElement = DDXMLElement(name: "field")
            idsElement.addAttribute(withName: "var", stringValue: "ids")
            ids.filter { $0.isNotEmpty }.forEach {
                idsElement.addChild(DDXMLElement(name: "value", stringValue: $0))
            }
            x.addChild(idsElement)
        }
        
        
//        if [.omemo, .omemo1, .axolotl].contains(conversationType)
        query.addChild(x)
        let setElement = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        setElement.addChild(DDXMLElement(name: "max", numberValue: (max ?? pageSize) as NSNumber))
        if let nextPage = nextPage {
            setElement.addChild(DDXMLElement(name: "before", stringValue: nextPage))
        } else if nextPage == "" {
            setElement.addChild(DDXMLElement(name: "before"))
        }
        if let prevPage = prevPage {
            setElement.addChild(DDXMLElement(name: "after", stringValue: prevPage))
        }
        query.addChild(setElement)
        if flipPage {
            query.addChild(DDXMLElement(name: "flip-page"))
        }
        if isGroupchat {
            stream.send(XMPPIQ(iqType: .set, to: jid == nil ? nil : XMPPJID(string: jid ?? ""), elementID: elementId, child: query))
        } else {
            stream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
        }
        defer {
            autoreleasepool {
                self.queryIds.insert(elementId)
            }
        }
        let taskId = [jid ?? "global_search", conversationType.rawValue].prp()
        let archiveEndEligibility = self.canMarkArchiveEnd(
            purpose: purpose,
            searchText: searchText,
            ids: ids,
            beforeId: beforeId,
            afterId: afterId,
            start: start,
            end: end,
            tags: tags,
            withCounter: withCounter
        )
        
        self.callbacksQueue.update(with:
            CallbackQueueItem(
                jid: jid ?? "",
                elementId: elementId,
                task: MAMRequestItem(
                    jid: jid,
                    taskID: taskId,
                    isGroupchat: isGroupchat,
                    messageId: before,
                    conversationType: conversationType,
                    isContinues: isContinues,
                    maxDate: start,
                    searchText: searchText,
                    queryId: queryId,
                    afterId: afterId,
                    max: max ?? pageSize,
                    tags: tags,
                    start: start,
                    end: end,
                    purpose: purpose,
                    archiveEndEligibility: archiveEndEligibility,
                    consumerManagesArchiveEnd: consumerManagesArchiveEnd,
                    consumerManagesHistoryCursor: consumerManagesHistoryCursor
                ),
                callback: callback,
                requestCallbacks: requestCallbacks
            )
        )
    }

    @discardableResult
    internal func fetchAnchorMessage(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        archivedId: String,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String {
        let requestQueryId = queryId ?? "MAM jump exact: \(NanoID.new(6))"
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: requestQueryId,
            ids: [archivedId],
            flipPage: false,
            max: 1,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }

    @discardableResult
    internal func fetchAnchorWindow(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        start: Date,
        end: Date,
        max: Int,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String {
        let requestQueryId = queryId ?? "MAM jump window: \(NanoID.new(6))"
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: requestQueryId,
            ids: nil,
            flipPage: false,
            start: start,
            end: end,
            max: max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }
    
    public final func getLastMessage(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .latest,
            nextPage: "",
            max: 1
        )
    }
    
    public final func getLastMessages(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if (realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType))?.isSynced ?? false) == false {
                self.requestArchive(
                    stream,
                    jid: jid,
                    isContinues: false,
                    conversationType: conversationType,
                    purpose: .latest,
                    nextPage: "",
                    max: self.pageSize
                )
            }
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    
    class HistoryGap {
        var newestMessageId: String
        var oldestMessageId: String
        var startDate: Date
        var endDate: Date
        
        init(newestMessageId: String, oldestMessageId: String, startDate: Date, endDate: Date) {
            self.newestMessageId = newestMessageId
            self.oldestMessageId = oldestMessageId
            self.startDate = Date(timeIntervalSince1970: startDate.timeIntervalSince1970 + 600)
            self.endDate = Date(timeIntervalSince1970: endDate.timeIntervalSince1970 - 600)
        }
    }
    
    @discardableResult
    internal final func syncChat(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        pageSize: Int? = nil,
        callback: (() -> Void)?,
        requestCallbacks: RequestCallbacks = .none
    ) -> SyncChatStartResult {
        let effectivePageSize = pageSize ?? self.pageSize
        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)
            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) == nil {
                try realm.write {
                    let instance = LastChatsStorageItem()
                    instance.owner = owner
                    instance.jid = jid
                    instance.conversationType = conversationType
                    instance.messageDate = Date()
                    instance.setPrimary(withOwner: owner)
                    instance.isSynced = false
                    if let rosterItem = realm
                        .object(ofType: RosterStorageItem.self,
                                forPrimaryKey: [jid, owner].prp()) {
                        instance.rosterItem = rosterItem
                        rosterItem.associatedLastChat = instance
                    } else {
                        let rosterItem = RosterStorageItem()
                        rosterItem.owner = owner
                        rosterItem.jid = jid
                        rosterItem.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                        rosterItem.groups.append(RosterUtils.ungroupped)
                        rosterItem.associatedLastChat = instance
                        realm.add(rosterItem)
                        instance.rosterItem = rosterItem
                    }
                    instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
                    realm.add(instance, update: .modified)
                }
            }

            if let lastChatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) {
                if lastChatInstance.isSynced {
                    // Keep chat open deterministic: synced chats should render local state immediately
                    // and let explicit user paging own further archive loads.
                    return .noop
                } else {
                    var archiveStart: Date? = nil
                    if conversationType.isEncrypted {
                        if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                            archiveStart = instance.createdAt
                        }
                    }
                    let bootstrapRequest = Self.newestBootstrapPageRequest(pageSize: effectivePageSize)
                    let bootstrapQueryId = "MAM bootstrap history: \(NanoID.new(6))"
                    self.requestArchive(
                        stream, jid: jid,
                        isContinues: false,
                        conversationType: conversationType,
                        purpose: .bootstrap,
                        queryId: bootstrapQueryId,
                        start: archiveStart,
                        nextPage: bootstrapRequest.nextPage,
                        prevPage: bootstrapRequest.prevPage,
                        max: bootstrapRequest.max,
                        consumerManagesArchiveEnd: true,
                        callback: callback,
                        requestCallbacks: requestCallbacks
                    )
                    return .bootstrapStarted(queryId: bootstrapQueryId)
                }
            }
            
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
        }
        return .noop
    }
    
    @discardableResult
    internal func getPrevHistory(_ stream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType, messageId: String, pageSize: Int? = nil, queryId: String? = nil, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none) -> String {
        let effectivePageSize = pageSize ?? self.pageSize
        let pageRequest = Self.newerPageRequest(messageId: messageId, pageSize: effectivePageSize)
        let requestQueryId = queryId ?? "MAM prev history: \(NanoID.new(6))"
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .pageNewer,
            queryId: requestQueryId,
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: nil,//lastMsgDate,//modifiedDate,
            end: nil,
            nextPage: pageRequest.nextPage,
            prevPage: pageRequest.prevPage,
            max: pageRequest.max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }
    
    @discardableResult
    internal func getNextHistory(_ stream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType, messageId: String?, pageSize: Int? = nil, queryId: String? = nil, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none) -> String {
        let effectivePageSize = pageSize ?? self.pageSize
        let pageRequest = Self.olderPageRequest(messageId: messageId, pageSize: effectivePageSize)
        let requestQueryId = queryId ?? "MAM next history: \(NanoID.new(6))"
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .pageOlder,
            queryId: requestQueryId,
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: nil,
            end: nil,
            nextPage: pageRequest.nextPage,
            prevPage: pageRequest.prevPage,
            max: pageRequest.max,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }
    
    private final func checkShouldLoadFullHistory(for jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws -> Bool {
        
        let realm = try WRealm.safe()
        if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)) {
            let taskId = [jid, conversationType.rawValue].prp()
            if instance.isAllHistoryLoaded {
                return false
            }
            if self.continuesTaskID == nil {
                return true
            }
            if self.continuesTaskID == taskId {
                return false
            }
//            let msgCount = realm.objects(MessageStorageItem.self).filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", jid, self.owner, conversationType.rawValue).count
            
            if !instance.fullArchiveLoaded {
                return true
            }
        } else {
            return false
        }
        return false
    }
    
    public final func startLoadHistory(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws {
        let taskId = [jid, conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.callbacksQueue.remove(item)
                    }
                }
            }
        }
        
        let realm = try WRealm.safe()
        let messageId = realm
            .objects(MessageStorageItem.self)
            .filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", jid, self.owner, conversationType.rawValue)
            .sorted (byKeyPath: "date", ascending: false)
            .last?
            .archivedId
        
        var archiveStart: Date? = nil
        if conversationType.isEncrypted {
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                archiveStart = instance.createdAt
            }
        }
        
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: true,
            conversationType: conversationType,
            purpose: .pageOlder,
            before: messageId,
            start: archiveStart
        )
        self.continuesTaskID = taskId
    }
    
    public final func continueLoadHistory(_ stream: XMPPStream, task: MAMRequestItem, nextPage: String?, requestCallbacks: RequestCallbacks = .none, callback: (() -> Void)? = nil) {
//        guard continuesTaskID == task.taskID else { return }
        guard let nextPage = nextPage else {
            if let item = self.callbacksQueue.first(where: { $0.task.taskID == task.taskID }) {
                item.callback?()
                self.callbacksQueue.remove(item)
            }
            return
        }
        
//        if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
//            self.callbacksQueue.remove(item)
//        }
        
        self.requestArchive(
            stream,
            jid: task.jid,
            isContinues: true,
            conversationType: task.conversationType,
            purpose: task.purpose,
            queryId: task.queryId,
            searchText: task.searchText,
            before: task.messageId,
            afterId: task.afterId,
            start: task.start,
            end: task.end,
            nextPage: nextPage,
            max: task.max,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
    }
    
    public final func endLoadHistory(jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        let taskId = [jid, conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID, continuesTaskID == taskId {
            if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
                item.callback?()
                self.callbacksQueue.remove(item)
            }
            self.continuesTaskID = nil
        }
    }
    
    public func readMessage(_ message: XMPPMessage) -> Bool {
        guard let queryId = message.element(forName: "result")?.attributeStringValue(forName: "queryid") else {
            return false
        }
        if !self.searchResultsQueries.contains(queryId) {
            return false
        }
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
            let item = MessageManager.MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                     state: .deliver,
                                     queryId: getMAMQueryId(message))
            
            
            
            if isVoIPMessage(item.message) {
                return true
            }
            let instance: MessageStorageItem = MessageStorageItem()
            let from = item.message.from?.bare ?? item.archivedFrom ?? item.originalFrom
            guard let to = item.message.to?.bare else {
                    return true
            }
            if let formElement = item.message.element(forName: "x", xmlns: "jabber:x:data"),
                formElement.attributeStringValue(forName: "type") == "submit" {
                return true
            }
            let opponent = to != owner ? to : from
            
            var omemoError: Bool = !(item.message.element(forName: "omemo-result__system")?.attributeBoolValue(forName: "result") ?? false)
            var errorMetadata: [String: Any] = [:]
            var isEncryptedMessage: Bool = false
            if item.message.element(forName: "encrypted") != nil {
                isEncryptedMessage = true
                errorMetadata = SignatureManager.MessageError().errorMetadata
            }
            
            let afterburnInterval = item.message.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeDoubleValue(forName: "timer") ?? 0
            
            var hasSignElement: Bool = false
            var envelopeContainer: String? = nil
//            print("RECEIVER", #function, item.message.prettyXMLString!)
            if let sign = item.message.element(forName: "time-signature", xmlns: SignatureManager.xmlns){
                omemoError = false
                hasSignElement = true
                envelopeContainer = sign.xmlString
                do {
                    errorMetadata = try SignatureManager.shared.checkSignature(
                        owner: self.owner,
                        for: from,
                        signature: sign,
                        messageDate: item.date
                    ).errorMetadata
                } catch {
                    errorMetadata = SignatureManager.MessageError().errorMetadata
                }
            }
            
            if let userId = groupchatUserElement(from: item.message)?
                .attributeStringValue(forName: "id") {
                if let userCard = item.groupchatUserCard,
                    let myId = userCard.attributeStringValue(forName: "id") {
                    item.originalOutgoing = userId == myId
                } else {
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [userId, opponent, owner].prp()) {
                            item.originalOutgoing = instance.isMe
                        }
                    } catch {
                        DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                    }
                }
            } else if let groupchatRef = item.message
                    .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
                    .elements(forName: "reference"),
                      let groupchatAuthor = MessageManager.getMessageAuthorGroupchatStatic(groupchatRef, jid: opponent, owner: self.owner) {
                    item.originalOutgoing = groupchatAuthor == owner
            } else {
                item.originalOutgoing = from == owner
            }
            
//            if item.originalOutgoing || item.state == .read {
//                item.isRead = true
            let conversationType = conversationTypeByMessage(item.message)
            let readDate = item.readDate ??  nil
            if let readDate = readDate,
               item.date < readDate {
                item.isRead = true
            } else {
                item.isRead = item.state == .read
            }
            if parseSystemMessageMetadata(item.message) != nil {
                instance.configureSystemMessage(item.message,
                                                owner: owner,
                                                opponent: opponent,
                                                date: item.date)
                instance.state = .none
                instance.isRead = item.forceUnreadState ?? item.isRead
            } else {
                instance.configureIncomingMessage(item.message,
                                          owner: owner,
                                          opponent: opponent,
                                          outgoing: item.originalOutgoing,
                                          isRead: item.forceUnreadState ?? item.isRead,
                                          date: item.date, isEncrypted: isEncryptedMessage)
                instance.forceUnreadState = item.forceUnreadState
                instance.state = item.state
                
            }
            instance.envelopeContainer = envelopeContainer
            instance.updatePrimary()
            if afterburnInterval > 0 {
                instance.applyAutoDeleteTTL(afterburnInterval, startsAt: item.date)
            } else {
                instance.afterburnInterval = afterburnInterval
            }
            
            if hasSignElement {
                instance.errorMetadata = errorMetadata
            }
            
                      
            
            if isEncryptedMessage {
                if !errorMetadata.isEmpty {
                    if omemoError {
                        instance.messageError = "omemo"
                    } else {
                        if hasSignElement {
                            instance.messageError = "cert_error"
                        }
                    }
                }
            }
            
            if afterburnInterval > 0 {
                if isEncryptedMessage {
                    if !errorMetadata.isEmpty {
                        if omemoError {
                            instance.isDeleted = true
                        }
                    }
                }
            }
            if let readDate = readDate,
               afterburnInterval > 0 {
                instance.isRead = true
                if !item.originalOutgoing {
                    instance.state = .read
                }
                instance.readDate = readDate.timeIntervalSince1970
                if instance.autoDeleteExpiresAt <= 0 {
                    instance.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                }
                
                
                if instance.effectiveAutoDeleteExpiresAt > 0,
                   instance.effectiveAutoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                    instance.markAutoDeleted()
                }
            }
            if instance.autoDeleteExpiresAt > 0,
               instance.autoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                instance.markAutoDeleted()
            }
            
            let requestCallbacks = self.callbacksQueue.first(where: { $0.elementId == queryId })?.requestCallbacks ?? .none
            self.notifyDidReceiveMessage(instance, queryId: queryId, callbacks: requestCallbacks)
        }
        return true
    }
    
    func didResetState() {
        self.callbacksQueue.forEach { $0.callback?() }
        self.callbacksQueue.removeAll()
        self.queryIds.removeAll()
        self.persistedMessageCountsByQueryId.removeAll()
    }
}
