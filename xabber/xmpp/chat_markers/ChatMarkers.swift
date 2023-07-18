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
import RealmSwift
import XMPPFramework

class ChatMarkersManager: AbstractXMPPManager {
    
    var checkMarkersAvailabilityCallback: ((String) -> Bool)?
    
    private func isAvailable(for jid: String) -> Bool {
        return true
    }
    
    override func namespaces() -> [String] {
        return ["urn:xmpp:chat-markers:0"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    var child: DDXMLElement {
        get {
            return DDXMLElement(name: "markable", xmlns: "urn:xmpp:chat-markers:0")
        }
    }
    // Fallback to XEP-0184
    func receipts(_ xmppStream: XMPPStream, for message: XMPPMessage) {
        
        func send() {
            guard let to = message.from else { return }
            let bareJid = to.bare
            let id: String
            if let origin = getOriginId(message) {
                id = origin
            } else if message.elementID != nil {
                id = message.elementID!
            } else {
                id = ""
            }
            if !id.isEmpty {
                let received = DDXMLElement(name: "received", xmlns: "urn:xmpp:receipts")
                received.addAttribute(withName: "id", stringValue: id)
                let response = XMPPMessage(messageType: .chat, to: to, elementID: id, child: received)
                let conversationType = conversationTypeByMessage(message)
                let conversation = DDXMLElement(name: "conversation", xmlns: "https://xabber.com/protocol/synchronization")
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                conversation.addAttribute(withName: "jid", stringValue: bareJid)
                response.addChild(conversation)
                xmppStream.send(response)
//                AccountManager.shared.find(for: owner)?.messages.addStanzaToQueue(response)
//                xmppStream.send(response)
            }
        }
        
        for request in message.elements(forName: "request") {
            if request.xmlns() == "urn:xmpp:receipts" {
                send()
                break
            }
        }
    }
    
    func received(_ xmppStream: XMPPStream, for message: XMPPMessage) {
        if isCarbonCopy(message) { return }
        func send() {
            guard let to = message.from else { return }
            let bareJid = to.bare
            let id: String
            if let origin = getOriginId(message) {
                id = origin
            } else if message.elementID != nil {
                id = message.elementID!
            } else {
                id = ""
            }
            if id.isNotEmpty {
                let received = DDXMLElement(name: "received", xmlns: "urn:xmpp:chat-markers:0")
                received.addAttribute(withName: "id", stringValue: id)
                let response = XMPPMessage(messageType: .chat, to: to, elementID: id, child: received)
                let conversationType = conversationTypeByMessage(message)
                let conversation = DDXMLElement(name: "conversation", xmlns: "https://xabber.com/protocol/synchronization")
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                conversation.addAttribute(withName: "jid", stringValue: bareJid)
                response.addChild(conversation)
                xmppStream.send(response)
            }
        }
        for markable in message.elements(forName: "markable") {
            if markable.xmlns() == "urn:xmpp:chat-markers:0" {
                send()
                break
            }
        }
        
    }
    
    func displayed(_ xmppStream: XMPPStream, for jid: String, primary: String) {
        if isAvailable(for: jid) {
            let displayed = DDXMLElement(name: "displayed", xmlns: "urn:xmpp:chat-markers:0")
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: [primary, "stanza"].prp()) {
                    let document = try DDXMLDocument(xmlString: instance.stanza, options: 0)
                    if let message = document.rootElement() {
                        
                        let stanzaId = message
                            .elements(forName: "stanza-id")
                            .first(where: { $0.attributeStringValue(forName: "by") == jid })?
                            .attributeStringValue(forName: "id")
                        if let id = message.attributeStringValue(forName: "id") ?? stanzaId {
                            displayed.addAttribute(withName: "id", stringValue: id)
                        } else {
                            return
                        }
                        message
                            .elements(forName: "stanza-id")
                            .forEach { displayed.addChild($0.copy() as! DDXMLElement) }
                    }
                }
                let response = XMPPMessage(messageType: .chat,
                                           to: XMPPJID(string: jid),
                                           elementID: xmppStream.generateUUID,
                                           child: displayed)
                
                xmppStream.send(response)
            } catch {
                DDLogDebug(error.localizedDescription)
            }
            
        }
    }
    
    func forceReadChat(_ xmppStream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            ) {
                
                let collection = realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND isRead == false", owner, jid)
                    .sorted(byKeyPath: "date", ascending: true)
                try realm.write {
                    instance.unread = 0
                    collection
//                        .compactMap { return $0.isRead ? nil : $0 }
                        .forEach { $0.isRead = true }
                    
                }
                if let lastItemPrimary = instance.lastMessage?.primary {
                    self.displayed(xmppStream, for: jid, primary: lastItemPrimary)
                }
            }
        } catch {
            DDLogDebug("ChatMarkersManager: \(#function). \(#function)")
        }
    }
    
    func displayedLast(_ xmppStream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            ),
                let primary = instance.lastMessage?.primary,
                instance.unread > 0 {
                AccountManager
                    .shared
                    .find(for: owner)?
                    .messages
                    .readMessage(primary, jid: jid, last: true)
                self.displayed(xmppStream,
                               for: jid,
                               primary: primary)
            }
        } catch {
            DDLogDebug("cant get last message to send display chat marker for \(jid). \(error.localizedDescription)")
        }
    }
}

