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
import RealmSwift
import RxSwift
import RxCocoa
import CocoaLumberjack


class ReliableMessageDeliveryManager: AbstractXMPPManager {
    
    open var isAvailable: Bool = false
    
    internal var bag: DisposeBag = DisposeBag()
    internal var echoQueue: BehaviorRelay<Set<XMPPMessage>> = BehaviorRelay(value: Set<XMPPMessage>())
    
    open func checkAvailability() {
        guard let node = SettingManager
            .shared
            .getKey(for: owner, scope: .reliableMessageDelivery, key: "node"),
            node == getPrimaryNamespace() else {
            isAvailable = false
            return
        }
        isAvailable = true
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        checkAvailability()
        subscribe()
    }
    
    override func namespaces() -> [String] {
        return ["https://xabber.com/protocol/delivery"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    public func xmlns(_ category: String?) -> String {
        guard let category = category,
              category.isNotEmpty else {
            return getPrimaryNamespace()
        }
        return [getPrimaryNamespace(), "#", category].joined()
    }
    
    open func apply(to message: XMPPMessage, retry: Bool = false, missRetryElement: Bool = false) -> XMPPMessage {
        if retry && !missRetryElement {
            message.addChild(DDXMLElement(name: "retry", xmlns: getPrimaryNamespace()))
        }
        return message
    }
    
    
    open func read(headline message: XMPPMessage) -> Bool {
        switch true {
        case readNotification(message): return true
        case readEcho(message): return true
        case readRealtimeNotification(message): return true
        default: return false
        }
    }
    
    open func read(error message: XMPPMessage) -> Bool {
        return readNotificationError(message)
    }
    
    internal func getErrorDescription(_ error: DDXMLElement) -> String? {
        if error.element(forName: "remote-server-not-found") != nil { return "Remote server not found".localizeString(id: "error_server_not_found", arguments: []) }
        if error.element(forName: "policy-violation") != nil { return "Internal server error".localizeString(id: "error_internal_server", arguments: []) }
        if error.element(forName: "not-allowed") != nil { return "You are not allowed to send messages to this chat".localizeString(id: "error_not_allowed", arguments: []) }
        return nil
    }
    
    internal func getErrorCode(_ error: DDXMLElement) -> String? {
        if error.element(forName: "remote-server-not-found") != nil { return "404" }
        if error.element(forName: "policy-violation") != nil { return "403" }
        if error.element(forName: "not-allowed") != nil { return "405" }
        return nil
    }
    
    internal func readNotificationError(_ message: XMPPMessage) -> Bool {
        guard let elementId = message.elementID,
            let error = message.element(forName: "error"),
            let errorMessage = getErrorDescription(error) else { return false }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND outgoing == %@", owner, elementId, true)
                .first {
                try realm.write {
                    instance.state = .error
                    instance.messageError = errorMessage
                    instance.messageErrorCode = getErrorCode(error)
                    instance.references.forEach({
                        $0.hasError = true
                    })
                }
                return true
            }
        } catch {
            DDLogDebug("\(#function). Cant load message for messageId: \(elementId). \(error.localizedDescription)")
        }
        return false
    }
    
    /*
     <message xmlns="jabber:client" to="igor.boldin@redsolution.com/xabber-ios-3F02F22F" from="test-group-ios-301020-01@xmppdev01.xabber.com/Groupchat" type="headline" id="3453128220472810953">
       <retract-message xmlns="https://xabber.com/protocol/rewrite#notify" by="igor.boldin@redsolution.com" symmetric="true" conversation="test-group-ios-301020-01@xmppdev01.xabber.com" version="3" id="1604396219156505"/>
     </message>
     */
    //TODO bring to rrr
    internal func readRealtimeNotification(_ message: XMPPMessage) -> Bool {
        guard let retractElement = message.element(forName: "retract-message",
                                                   xmlns: xmlns("notify")),
              let conversation = retractElement.attributeStringValue(forName: "conversation"),
              let id = retractElement.attributeStringValue(forName: "id") else {
            return false
        }
        do {
            let realm = try  WRealm.safe()
            try realm.write {
                realm.delete(
                    realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND archivedId == %@",
                                self.owner,
                                conversation,
                                id)
                )
            }
        } catch {
            DDLogDebug("ReliableMessageDeliveryManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    internal func readNotification(_ message: XMPPMessage) -> Bool {
        guard let received = message.element(forName: "received", xmlns: getPrimaryNamespace()),
            let elementId = received.element(forName: "origin-id")?.attributeStringValue(forName: "id") else {
                return false
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@", owner, elementId)
                .first {
                    try realm.write {
                        if instance.state == .sending {
                            instance.state = .sended
                        }
                        if let stamp = received.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate {
                            instance.date = stamp
                            instance.sentDate = stamp
                        }
                        instance.archivedId = getStanzaId(message, owner: owner)
                    }
            }
        } catch {
            DDLogDebug("\(#function). Cant load message for messageId: \(elementId). \(error.localizedDescription)")
        }
        return true
    }
    
    internal func readEcho(_ message: XMPPMessage) -> Bool {
        guard let x = message.element(forName: "x", xmlns: getPrimaryNamespace()),
            let messageElement = x.element(forName: "message"),
            messageElement.element(forName: "x", xmlns: "https://xabber.com/protocol/groups") != nil else {
                return false
        }
        var value = echoQueue.value
        value.insert(message)
        echoQueue.accept(value)
        return true
    }
    
    internal func parseEcho(_ message: XMPPMessage) {
        guard let from = message.from?.bare,
            let x = message.element(forName: "x",
                                      xmlns: getPrimaryNamespace()),
            let messageContainer = x.element(forName: "message"),
            let elementId = messageContainer.element(forName: "origin-id")?.attributeStringValue(forName: "id"),
                let stamp = messageContainer.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate else {
                    return
            }
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND outgoing == %@", owner, elementId, true)
                .first {
                    try realm.write {
                        instance.state = .deliver
                        instance.date = stamp
                        instance.sentDate = stamp
                        instance.references.removeAll()
                        instance.references
                            .append(objectsIn: parseReferences(XMPPMessage(from: messageContainer),
                                                               jid: from,
                                                               owner: owner,
                                                               echo: true))
                        let stanzaId = getStanzaId(XMPPMessage(from: messageContainer), owner: from)
                        if stanzaId.isNotEmpty {
                            instance.archivedId = stanzaId
                        }
                        realm
                            .object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: instance.primary)?
                            .stanza = messageContainer.compactXMLString()
                    }
                }
        } catch {
            DDLogDebug("\(#function). Cant load message for messageId: \(elementId). \(error.localizedDescription)")
        }
        return
    }
    
    
    internal func subscribe() {
        bag = DisposeBag()
        
        echoQueue
            .asObservable()
            .debounce(.seconds(1), scheduler: SerialDispatchQueueScheduler(qos: .default))
            .subscribe(onNext: { (results) in
                results.forEach {
                    self.parseEcho($0)
                }
                self.echoQueue.accept(Set<XMPPMessage>())
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
   static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager
            .shared
            .saveItem(for: owner,
                      scope: .reliableMessageDelivery,
                      key: "node",
                      value: "")
    }
    
    deinit {
        unsubscribe()
    }
}
