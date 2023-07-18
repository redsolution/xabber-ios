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

class MessageArchiveManager: AbstractXMPPManager {
    
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
        let jid: String
        let taskID: String
        let isGroupchat: Bool
        let messageId: String?
        let conversationType: ClientSynchronizationManager.ConversationType
        let isContinues: Bool
    }
    
    struct CallbackQueueItem: Equatable, Hashable {
        static func == (lhs: CallbackQueueItem, rhs: CallbackQueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        let jid: String
        let elementId: String
        let task: MAMRequestItem
        let callback: (() -> Void)?
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    var callbacksQueue: Set<CallbackQueueItem> = Set<CallbackQueueItem>()
    
    var delegate: MessageArchiveManagerDelegate? = nil
    var backgroundTaskDelegate: XMPPBackgroundTaskDelegate? = nil
    
    var interactiveQueue: SynchronizedArray<String> = SynchronizedArray<String>()
    
    internal var version: String? = nil
    public var isInitialArchiveRequested: Bool = false
    
    public var allowHistoryFixTask: Bool = false
    
    public var continuesTaskID: String? = nil
    
    internal let pageSize: Int = 50
    
    override init(withOwner owner: String) {
        self.isInitialArchiveRequested = SettingManager.shared.getKey(for: owner, scope: .messageArchive, key: "initial") == nil
        super.init(withOwner: owner)
    }
    
    override func namespaces() -> [String] {
        return ["urn:xmpp:mam:2"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    func read(_ stream: XMPPStream, withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result,
              let elementId = iq.elementID,
              let fin = iq.element(forName: "fin", xmlns: getPrimaryNamespace()),
              let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            return false
        }
        DispatchQueue.global().async {
            if let item = self.callbacksQueue.first(where: { $0.elementId == elementId }) {
                if item.task.isContinues {
                    let nextPage = set.element(forName: "last")?.stringValue
                    self.continueLoadHistory(stream, task: item.task, nextPage: nextPage)
                } else {
                    item.callback?()
                    if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                try realm.write {
                                    instance.messagesCount = count
                                }
                            }
                            if try self.checkShouldLoadFullHistory(for: item.jid, conversationType: item.task.conversationType) {
                                try self.startLoadHistory(stream, jid: item.jid, conversationType: item.task.conversationType)
                            }
                        } catch {
                            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                }
                self.callbacksQueue.remove(item)
            }
        }
        return true
    }
    
    private func requestArchive(_ stream: XMPPStream, jid: String, isContinues: Bool, conversationType: ClientSynchronizationManager.ConversationType, before: String? = nil, nextPage: String? = nil, callback: (() -> Void)? = nil) {
        let isGroupchat = [.group, .channel].contains(conversationType)
        let elementId = "MAM: \(NanoID.new(8))"
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        query.addAttribute(withName: "queryid", stringValue: elementId)
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        let formType = DDXMLElement(name: "field")
        formType.addAttribute(withName: "var", stringValue: "FORM_TYPE")
        formType.addAttribute(withName: "type", stringValue: "hidden")
        formType.addChild(DDXMLElement(name: "value", stringValue: getPrimaryNamespace()))
        x.addChild(formType)
        if let beforeId = before,
           beforeId.isNotEmpty {
            let beforeIdElement = DDXMLElement(name: "field")
            beforeIdElement.addAttribute(withName: "var", stringValue: "before-id")
            beforeIdElement.addChild(DDXMLElement(name: "value", stringValue: beforeId))
            x.addChild(beforeIdElement)
        }
        if !isGroupchat {
            let withElement = DDXMLElement(name: "field")
            withElement.addAttribute(withName: "var", stringValue: "with")
            withElement.addChild(DDXMLElement(name: "value", stringValue: jid))
            x.addChild(withElement)
        }
        
        let ctElement = DDXMLElement(name: "field")
        ctElement.addAttribute(withName: "var", stringValue: "conversation-type")
        ctElement.addChild(DDXMLElement(name: "value", stringValue: conversationType.rawValue))
        x.addChild(ctElement)
        
//        if [.omemo, .omemo1, .axolotl].contains(conversationType)
        query.addChild(x)
        let setElement = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        setElement.addChild(DDXMLElement(name: "max", numberValue: pageSize as NSNumber))
        if let nextPage = nextPage {
            setElement.addChild(DDXMLElement(name: "before", stringValue: nextPage))
        } else {
            setElement.addChild(DDXMLElement(name: "before"))
        }
        query.addChild(setElement)
        query.addChild(DDXMLElement(name: "flip-page"))
        if isGroupchat {
            stream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: jid), elementID: elementId, child: query))
        } else {
            stream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
        }
        self.queryIds.insert(elementId)
        let taskId = [jid, conversationType.rawValue].prp()
        
        self.callbacksQueue.update(with:
            CallbackQueueItem(
                jid: jid,
                elementId: elementId,
                task: MAMRequestItem(
                    jid: jid,
                    taskID: taskId,
                    isGroupchat: isGroupchat,
                    messageId: before,
                    conversationType: conversationType,
                    isContinues: isContinues
                ),
                callback: callback
            )
        )
    }
    
    public final func syncChat(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: LastChatsStorageItem.self,
                                           forPrimaryKey: LastChatsStorageItem.genPrimary(
                                            jid: jid,
                                            owner: owner,
                                            conversationType: conversationType)),
               !instance.isSynced {
                self.requestArchive(stream, jid: jid, isContinues: false, conversationType: conversationType) {
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: LastChatsStorageItem.self,
                                                       forPrimaryKey: LastChatsStorageItem.genPrimary(
                                                        jid: jid,
                                                        owner: self.owner,
                                                        conversationType: conversationType)) {
                            try realm.write {
                                if instance.isInvalidated { return }
                                instance.isSynced = true
                            }
                        }
                    } catch {
                        DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                    }
                }
            } else {
                if try self.checkShouldLoadFullHistory(for: jid, conversationType: conversationType) {
                    try self.startLoadHistory(stream, jid: jid, conversationType: conversationType)
                }
            }
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func checkShouldLoadFullHistory(for jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws -> Bool {
        let taskId = [jid, conversationType.rawValue].prp()
        if self.continuesTaskID == nil {
            return true
        }
        if self.continuesTaskID == taskId {
            return false
        }
        let realm = try WRealm.safe()
        if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)) {
            let msgCount = realm.objects(MessageStorageItem.self).filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", jid, self.owner, conversationType.rawValue).count
            if instance.messagesCount > msgCount {
                return true
            }
            if instance.messagesCount < 2 {
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
        
        self.requestArchive(stream, jid: jid, isContinues: true, conversationType: conversationType, before: messageId)
        self.continuesTaskID = taskId
    }
    
    public final func continueLoadHistory(_ stream: XMPPStream, task: MAMRequestItem, nextPage: String?) {
        guard continuesTaskID == task.taskID else { return }
        guard let nextPage = nextPage else {
            if let continuesTaskID = self.continuesTaskID {
                if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    self.callbacksQueue.remove(item)
                }
            }
            self.continuesTaskID = nil
            return
        }
        
        if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
            self.callbacksQueue.remove(item)
        }
        
        self.requestArchive(
            stream,
            jid: task.jid,
            isContinues: true,
            conversationType: task.conversationType,
            before: task.messageId,
            nextPage: nextPage
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
    
    
    //override
//    func readT(withIQ iq: XMPPIQ) -> Bool {
//        guard let elementId = iq.elementID,
//            self.queryIds.contains(elementId) else {
//                return false
//        }
//        if let item = self.fullChatLoadingTask {
//            if item.elementId == elementId,
//               let last = iq.element(forName: "fin")?.element(forName: "set")?.element(forName: "last")?.stringValue {
//                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                    _ = session.mam?.loadFullChatHistory(stream, jid: item.jid, conversationType: item.conversationType, nextPage: last)
//                } fail: {
//                    
//                }
//
//                
//            }
//        }
//        if let callbackIndex = callbacksQueue.index(where: { $0.elementId == elementId }){
//            callbacksQueue[callbackIndex]?.callback?()
//        }
//        if self.readBackgroundLoaderResponse(iq) {
//            return true
//        }
//        if let set = iq.element(forName: "fin")?.element(forName: "set"),
//            self.interactiveQueue.isNotEmpty,
//            self.interactiveQueue.contains(elementId) {
//            let count = set.element(forName: "count")?.stringValueAsNSInteger()
//            let first = set.element(forName: "first")?.stringValue
//            let last = set.element(forName: "last")?.stringValue
//            self.delegate?.didReceiveEnd(count: count, first: first, last: last)
//            self.interactiveQueue.remove(elementId)
//        }
//        queryIds.remove(elementId)
//        if queryIds.isEmpty {
//            self.backgroundTaskDelegate?.backgroundTaskDidEnd(shouldContinue: false)
//        }
//        return true
//    }
//    
//    open func requestMessagesForGroupchatUserT(_ xmppStream: XMPPStream, groupchat: String, user id: String, before: String?, count: Int) {
//        let elementId = xmppStream.generateUUID
//        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
//        query.addAttribute(withName: "queryid", stringValue: elementId)
//        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
//        x.addAttribute(withName: "type", stringValue: "submit")
//        let form: [[String: String]] = [
//            ["var": "FORM_TYPE", "type": "hidden", "value": getPrimaryNamespace()],
//            ["var": "with", "value": id],
//        ]
//        form.compactMap { item in
//            let field = DDXMLElement(name: "field")
//            if let fieldName = item["var"] {
//                field.addAttribute(withName: "var", stringValue: fieldName)
//            }
//            if let fieldType = item["type"] {
//                field.addAttribute(withName: "type", stringValue: fieldType)
//            }
//            if let val = item["value"] {
//                let value = DDXMLElement(name: "value", stringValue: val)
//                field.addChild(value)
//            }
//            return field
//        }.forEach { element in
//            x.addChild(element)
//        }
//        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
//        set.addChild(DDXMLElement(name: "set", stringValue: "\(count)"))
//        if let before = before {
//            set.addChild(DDXMLElement(name: "before", stringValue: before))
//        }
//        query.addChild(x)
//        query.addChild(set)
//        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat), elementID: elementId, child: query))
//        queryIds.insert(elementId)
//        interactiveQueue.insert(elementId)
//    }
//    
//    internal func requestSearchResultsT(_ xmppStream: XMPPStream, jid: String?, groupchat: String?, query text: String, count: Int, before: String?) {
//        let elementId = xmppStream.generateUUID
//        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
//        query.addAttribute(withName: "queryid", stringValue: elementId)
//        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
//        x.addAttribute(withName: "type", stringValue: "submit")
//        var form: [[String: String]] = [
//            ["var": "FORM_TYPE", "type": "hidden", "value": getPrimaryNamespace()],
//            ["var": "withtext", "value": text],
//        ]
//        if let jid = jid {
//            form.append(["var": "with", "value": jid])
//        }
//        form.compactMap { item in
//            let field = DDXMLElement(name: "field")
//            if let fieldName = item["var"] {
//                field.addAttribute(withName: "var", stringValue: fieldName)
//            }
//            if let fieldType = item["type"] {
//                field.addAttribute(withName: "type", stringValue: fieldType)
//            }
//            if let val = item["value"] {
//                let value = DDXMLElement(name: "value", stringValue: val)
//                field.addChild(value)
//            }
//            return field
//        }.forEach { element in
//            x.addChild(element)
//        }
//        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
//        set.addChild(DDXMLElement(name: "set", stringValue: "\(count)"))
//        if let before = before {
//            set.addChild(DDXMLElement(name: "before", stringValue: before))
//        }
//        query.addChild(x)
//        query.addChild(set)
//        
//        if let groupchat = groupchat {
//            xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat), elementID: elementId, child: query))
//        } else {
//            xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
//        }
//        
//        queryIds.insert(elementId)
//    }
//    
////    open
//    open func receiveMessage(_ message: XMPPMessage) -> Bool {
//        guard interactiveQueue.isNotEmpty,
//            let from = message.from?.bare,
//            let bareMessage = getArchivedMessageContainer(message),
//            let queryId = message.element(forName: "result")?.attributeStringValue(forName: "queryid"),
//            interactiveQueue.contains(queryId) else {
//                return false
//        }
//        let messageDate = getDelayedDate(message) ?? Date()
//        
//        let item = MessageForwardsInlineStorageItem()
//        item.canCheckRealmAccessedLinks = false
//        item.configureInline(bareMessage,
//                             parentId: getUniqueMessageId(message, owner: owner),
//                             owner: owner,
//                             jid: from,
//                             outgoing: true,
//                             date: messageDate,
//                             forwardJid: nil)
//        let model = item.loadModel()
//        item.isOutgoing = model?.groupchatAuthorJid == owner
//        if let model = item.loadModel() {
//            self.delegate?.didReceiveMessage(model)
//            return true
//        } else {
//            return false
//        }
//    }
//    
//    open func loadHistoryForChatTestT(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, after: String?) {
//        
//    }
//    
//    open func requestHistoryT(_ xmppStream: XMPPStream, to externalServerJid: String? = nil, jid: String? = nil, count: Int = 0, start: Date? = nil, end: Date? = nil, after: String? = nil, beforeId: String? = nil, afterId: String? = nil, filter: Filter? = nil, before: String? = nil, callback: (() -> Void)? = nil) -> String? {
//
//        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
//        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
//        x.addAttribute(withName: "type", stringValue: "submit")
//        let formType = DDXMLElement(name: "field")
//        formType.addAttribute(withName: "var", stringValue: "FORM_TYPE")
//        formType.addAttribute(withName: "type", stringValue: "hidden")
//        formType.addChild(DDXMLElement(name: "value", stringValue: getPrimaryNamespace()))
//        x.addChild(formType)
//        if let jid = jid {
//            let with = DDXMLElement(name: "field")
//            with.addAttribute(withName: "var", stringValue: "with")
//            with.addChild(DDXMLElement(name: "value", stringValue: jid))
//            x.addChild(with)
//        }
//        if let start = start {
//            let startElement = DDXMLElement(name: "field")
//            startElement.addAttribute(withName: "var", stringValue: "start")
//            startElement.addChild(DDXMLElement(name: "value", stringValue: start.xmppDateTimeString))
//            x.addChild(startElement)
//        }
//        if let end = end {
//            let endElement = DDXMLElement(name: "field")
//            endElement.addAttribute(withName: "var", stringValue: "end")
//            endElement.addChild(DDXMLElement(name: "value", stringValue: end.xmppDateTimeString))
//            x.addChild(endElement)
//        }
//        query.addChild(x)
//        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
//        if count > 0 {
//            set.addChild(DDXMLElement(name: "max", stringValue: "\(count)"))
//        }
//        if let afterId = afterId {
//            let endElement = DDXMLElement(name: "field")
//            endElement.addAttribute(withName: "var", stringValue: "after-id")
//            endElement.addChild(DDXMLElement(name: "value", stringValue: afterId))
//            x.addChild(endElement)
//        }
//        if let beforeId = beforeId {
//            let endElement = DDXMLElement(name: "field")
//            endElement.addAttribute(withName: "var", stringValue: "before-id")
//            endElement.addChild(DDXMLElement(name: "value", stringValue: beforeId))
//            x.addChild(endElement)
//        }
//        
//        if let after = after {
//            set.addChild(DDXMLElement(name: "after", stringValue: after.isEmpty ? nil : after))
//        }
//        if let before = before {
//            set.addChild(DDXMLElement(name: "before", stringValue: before.isEmpty ? nil : before))
//        }
//        
//        query.addChild(DDXMLElement(name: "flip-page"))
//        
//        if set.children?.isNotEmpty ?? false {
//           query.addChild(set)
//        }
//        if let filter = filter {
//            let endElement = DDXMLElement(name: "field")
//            endElement.addAttribute(withName: "var", stringValue: filter.rawValue)
//            endElement.addChild(DDXMLElement(name: "value", stringValue: "true"))
//            x.addChild(endElement)
//        }
//        let elementId = xmppStream.generateUUID
//        query.addAttribute(withName: "queryid", stringValue: elementId)
//        if let externalServerJid = externalServerJid {
//            xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: externalServerJid), elementID: elementId, child: query))
//        } else {
//            xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
//        }
//        if callback != nil {
//            self.callbacksQueue.insert(CallbackQueueItem(jid: jid ?? externalServerJid ?? "none", elementId: elementId, callback: callback))
//        } else {
//            self.callbacksQueue.insert(CallbackQueueItem(jid: jid ?? externalServerJid ?? "none", elementId: elementId, callback: nil))
//        }
//        queryIds.insert(elementId)
//        return elementId
//    }
//    
//    func requestForMediaGalleryT(xmppStream: XMPPStream, isRemote: Bool, jid: String, filter: Filter) {
//        do {
//            let realm = try  WRealm.safe()
//            let archiveId = realm.objects(MessageStorageItem.self)
//                .filter("opponent == %@ AND owner == %@ AND archivedId != %@", jid, owner, "")
//                .sorted(byKeyPath: "date", ascending: false)
//                .first?
//                .archivedId
//                
//            if isRemote {
//                _ = requestHistory(xmppStream, to: jid, count: pageSize, beforeId: archiveId, filter: filter)
//            } else {
//                _ = requestHistory(xmppStream, jid: jid, count: pageSize, beforeId: archiveId, filter: filter)
//            }
//        } catch {
//            DDLogDebug("MAM: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    open func requestForRosterT(_ xmppStream: XMPPStream) {
//        _ = requestHistory(xmppStream, count: 1, before: "")
//        do {
//            let realm = try  WRealm.safe()
//            let groupchats = realm
//                .objects(GroupChatStorageItem.self)
//                .filter("owner == %@", owner)
//                .compactMap { return $0.jid }
//            
//            realm
//                .objects(RosterStorageItem.self)
//                .filter("owner == %@", owner)
//                .compactMap { return groupchats.contains($0.jid) ? nil : $0.jid }
//                .forEach { _ = requestHistory(xmppStream, jid: $0, count: 1, before: "") }
//            
//            groupchats.forEach { _ = requestHistory(xmppStream, to: $0, jid: nil, count: 1, before: "")}
//            self.isInitialArchiveRequested = true
//            SettingManager.shared.saveItem(for: self.owner, scope: .messageArchive, key: "initial", value: "true")
//        } catch {
//            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    open func requestAfterLastMessageT(_ xmppStream: XMPPStream, sync: Bool, groupchat jid: XMPPJID? = nil) {
//        do {
//            let realm = try  WRealm.safe()
//            if let date = realm
//                .objects(MessageStorageItem.self)
//                .filter("owner == %@ AND archivedId != %@", owner, "")
//                .sorted(byKeyPath: "date", ascending: false)
//                .first?
//                .date {
//                _ = requestHistory(xmppStream, start: date)
//                if sync {
//                    realm
//                        .objects(LastChatsStorageItem.self)
//                        .filter("owner == %@ AND isSynced == %@", owner, false)
//                        .forEach { _ = requestHistory(xmppStream, jid: $0.jid, count: 1, before: $0.lastMessage?.archivedId) }
//                }
//                realm
//                    .objects(GroupChatStorageItem.self)
//                    .filter("owner == %@", owner)
//                    .compactMap { return $0.jid }
//                    .forEach { _ = requestHistory(xmppStream, to: $0 , jid: nil, count: 1, before: "") }
//            } else {
//                requestForRoster(xmppStream)
//            }
//        } catch {
//            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//        }
//    }
//    
//    open func requestMessageByStanzaIdT(_ xmppStream: XMPPStream, groupchat: String, stanzaId: String) {
//        func getField(formVar: String?, formType: String?, value: String) -> DDXMLElement {
//            let field = DDXMLElement(name: "field")
//            if let formVar = formVar {
//                field.addAttribute(withName: "var", stringValue: formVar)
//            }
//            if let formType = formType {
//                field.addAttribute(withName: "type", stringValue: formType)
//            }
//            field.addChild(DDXMLElement(name: "value", stringValue: value))
//            return field
//        }
//        let elementId = xmppStream.generateUUID
//        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
//        x.addAttribute(withName: "type", stringValue: "submit")
//        x.addChild(getField(formVar: "FORM_TYPE", formType: "hidden", value: "urn:xmpp:mam:2"))
//        x.addChild(getField(formVar: "{urn:xmpp:sid:0}stanza-id", formType: nil, value: stanzaId))
//        let query = DDXMLElement(name: "query", xmlns: "urn:xmpp:mam:2")
//        query.addAttribute(withName: "queryid", stringValue: elementId)
//        query.addChild(x)
//        xmppStream.send(XMPPIQ(iqType: .set, to: XMPPJID(string: groupchat), elementID: elementId, child: query))
//        queryIds.insert(elementId)
//    }
//    
//    public final func loadMissedChatHistoryT(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
//                
//        func callback() {
////            DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + 2) {
//                do {
//                    let realm = try WRealm.safe()
//                    try realm.write {
//                        realm.object(ofType: LastChatsStorageItem.self,
//                                     forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType))?.isSynced = true
//                    }
//                } catch {
//                    DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//                }
////            }
//        }
//        
//        switch conversationType {
//        case .omemo, .omemo1, .axolotl:
//            _ = self.requestHistory(
//                xmppStream,
//                to: nil,
//                jid: jid,
//                count: 20,
//                start: nil,
//                end: nil,
//                after: nil,
//                filter: .encrypted,
//                before: "",
//                callback: callback
//            )
//        case .group, .channel:
//            _ = self.requestHistory(
//                xmppStream,
//                to: jid,
//                jid: nil,
//                count: 20,
//                start: nil,
//                end: nil,
//                after: nil,
//                filter: nil,
//                before: "",
//                callback: callback
//            )
//        default:
//            _ = self.requestHistory(
//                xmppStream,
//                to: nil,
//                jid: jid,
//                count: 20,
//                start: nil,
//                end: nil,
//                after: nil,
//                filter: nil,
//                before: "",
//                callback: callback
//            )
//        }
//        
//    }
//    
//    public final func fixHistory(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
//        self.allowHistoryFixTask = true
//        do {
//            let realm = try WRealm.safe()
//            let chat = realm.object(
//                ofType: LastChatsStorageItem.self,
//                forPrimaryKey: LastChatsStorageItem.genPrimary(
//                    jid: jid,
//                    owner: owner,
//                    conversationType: conversationType
//                )
//            )
//            let collection = realm
//                .objects(MessageStorageItem.self)
//                .filter("opponent == %@ AND owner == %@ AND messageType != %@", jid, self.owner, MessageStorageItem.MessageDisplayType.initial.rawValue)
//                .sorted(byKeyPath: "date", ascending: false)
//                .toArray()
////                    .compactMap { return $0.archivedId.isNotEmpty ? $0 : nil }
//            if collection.count <= 2,
//                chat == nil {
//                return
//            }
//            let groupchat = (chat?.conversationType ?? .omemo) == .group
//            var gaps: [GapItem] = []
//            
//            collection.enumerated().forEach {
//                (offset, element) in
//                if offset < collection.count - 1 {
//                    if !element.trustedSource {
//                        gaps.append(GapItem(left: element.archivedId,
//                                            right: collection[offset + 1].archivedId,
//                                            leftDate: element.date,
//                                            rightDate: collection[offset + 1].date))
//                    }
//                }
//            }
//            
//            var outGaps: [GapItem] = gaps
//            var gapsCleaned: Bool = false
//            while !gapsCleaned {
//                gaps = []
//                gapsCleaned = true
//                outGaps.enumerated().forEach {
//                    (offset, element) in
//                    if offset < outGaps.count - 1 {
//                        if element.right == outGaps[offset + 1].left {
//                            gaps.append(GapItem(left: element.left,
//                                                right: outGaps[offset + 1].right,
//                                                leftDate: element.leftDate,
//                                                rightDate: outGaps[offset + 1].rightDate))
//                            gapsCleaned = false
//                        } else {
//                            gaps.append(element)
//                        }
//                    }
//                }
//                outGaps = gaps
//            }
//            
//            outGaps = outGaps.reversed()
//            
//            if outGaps.isEmpty {
//                try realm.write {
//                    realm
//                        .object(
//                            ofType: LastChatsStorageItem.self,
//                            forPrimaryKey: LastChatsStorageItem.genPrimary(
//                                jid: jid,
//                                owner: owner,
//                                conversationType: conversationType
//                            )
//                        )?
//                        .isHistoryGapFixedForSession = true
//                }
//                self.backgroundTaskDelegate?.backgroundTaskDidEnd(shouldContinue: false)
//                return
//            }
//            
//            outGaps.enumerated().forEach {
//                (offset, element) in
//                
//                if !self.allowHistoryFixTask { return }
//                if conversationType == .omemo {
//                    _ = self.requestHistory(
//                        xmppStream,
//                        to: groupchat ? jid : nil,
//                        jid: groupchat ? nil : jid,
//                        start: element.rightDate,
//                        end: element.leftDate,
//                        filter: .encrypted
//                    )
//                } else {
//                    _ = self.requestHistory(
//                        xmppStream,
//                        to: groupchat ? jid : nil,
//                        jid: groupchat ? nil : jid,
//                        start: element.rightDate,
//                        end: element.leftDate
//                    )
//                }
//            }
//        } catch {
//            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
//        }
//        
//    }
    
    func didResetState() {
        self.callbacksQueue.forEach { $0.callback?() }
        self.callbacksQueue.removeAll()
        self.queryIds.removeAll()
    }
}
