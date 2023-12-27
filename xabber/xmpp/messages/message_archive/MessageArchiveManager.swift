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
        let maxDate: Date?
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
    
    func makeInitialMessageVisible(jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws {
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
        if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: MessageStorageItem.genPrimary(messageId: MessageStorageItem.messageIdForInitial(jid: jid, conversationType: conversationType), owner: self.owner)) {
            try realm.write {
                instance.isDeleted = false
            }
        } else {
            let initialMessage = MessageStorageItem()
            initialMessage.configureInitialMessage(
                self.owner,
                opponent: jid,
                conversationType: conversationType,
                text: "",
                date: Date(),
                isRead: true
            )
            if realm.object(ofType: MessageStorageItem.self, forPrimaryKey: initialMessage.primary) == nil {
                initialMessage.isDeleted = true
                _ = initialMessage.save(commitTransaction: true)
            }
        }
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
                    do {
                        if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                            let realm = try Realm()
                            
                            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                if count == 0 {
                                    try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType)
                                    self.callbacksQueue.remove(item)
                                    try realm.write {
                                        instance.messagesCount = count
                                        instance.isSynced = true
                                    }
                                    return
                                }
                                if fin.attributeBoolValue(forName: "complete") {
                                    try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType)
                                    self.callbacksQueue.remove(item)
                                    try realm.write {
                                        instance.messagesCount = count
                                        instance.isSynced = true
                                    }
                                    return
                                }
                                
                            }
                        }
                    } catch {
                        DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                    }
                    
                    self.continueLoadHistory(stream, task: item.task, nextPage: nextPage)
                } else {
                    item.callback?()
                    if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                try realm.write {
                                    instance.messagesCount = count
                                    instance.isSynced = true
                                }
                            }
                            if count == 0 {
                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType)
                                self.callbacksQueue.remove(item)
                                return
                            }
                            if fin.attributeBoolValue(forName: "complete") {
                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType)
                                self.callbacksQueue.remove(item)
                                return
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
    
    private func requestArchive(_ stream: XMPPStream, jid: String, isContinues: Bool, conversationType: ClientSynchronizationManager.ConversationType, before: String? = nil, start: Date? = nil, nextPage: String? = nil, max: Int? = nil, callback: (() -> Void)? = nil) {
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
        if let start = start {
            let beforeIdElement = DDXMLElement(name: "field")
            beforeIdElement.addAttribute(withName: "var", stringValue: "start")
            beforeIdElement.addChild(DDXMLElement(name: "value", stringValue: start.XMPPFormattedDate))
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
        setElement.addChild(DDXMLElement(name: "max", numberValue: (max ?? pageSize) as NSNumber))
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
                    isContinues: isContinues,
                    maxDate: start
                ),
                callback: callback
            )
        )
    }
    
    public final func getLastMessage(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.requestArchive(stream, jid: jid, isContinues: false, conversationType: conversationType, max: 1)
    }
    
    public final func syncChat(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            var archiveStart: Date? = nil
            if [.omemo, .axolotl, .omemo1].contains(conversationType) {
                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                    archiveStart = instance.createdAt
                }
            }
            if let instance = realm.object(ofType: LastChatsStorageItem.self,
                                           forPrimaryKey: LastChatsStorageItem.genPrimary(
                                            jid: jid,
                                            owner: owner,
                                            conversationType: conversationType)),
               !instance.isSynced {
                self.requestArchive(stream, jid: jid, isContinues: false, conversationType: conversationType, start: archiveStart) {
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
        
        var archiveStart: Date? = nil
        if [.omemo, .axolotl, .omemo1].contains(conversationType) {
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                archiveStart = instance.createdAt
            }
        }
        
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: true,
            conversationType: conversationType,
            before: messageId,
            start: archiveStart
        )
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
            start: task.maxDate,
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
    
    func didResetState() {
        self.callbacksQueue.forEach { $0.callback?() }
        self.callbacksQueue.removeAll()
        self.queryIds.removeAll()
    }
}
