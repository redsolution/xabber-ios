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

class GlobalIndexManager: AbstractXMPPManager {
    
    internal let globalIndexJid: XMPPJID? = XMPPJID(string: "index.xabber.com")
    
    struct SearchQueryItem {
        let field: String
        let value: String
        let isFormType: Bool
    }
    
    enum QueryType {
        case message
        case groupchat
    }
    
    enum IndexScope {
        case local
        case global
    }
    
    internal var lastSettedSearchQuery: [SearchQueryItem] = []
    internal var lastSettedQueryType: QueryType = .groupchat
    internal var lastPageForQuery: String = ""
    
    internal var localIndexJid: XMPPJID? = nil
    
    open func reset() {
        lastPageForQuery = ""
        lastSettedQueryType = .groupchat
        lastSettedSearchQuery = []
    }
    
    open func requestFields(_ xmppStream: XMPPStream) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement.element(withName: "query") as! DDXMLElement
        query.setXmlns("http://xabber.com/protocol/index#groupchat")
        xmppStream.send(XMPPIQ(iqType: .get, to: globalIndexJid, elementID: elementId, child: query))
        queryIds.insert(elementId)
    }
    
    open func requestNextPage(_ xmppStream: XMPPStream, scope: IndexScope) {
        requestList(xmppStream,
                    scope: scope,
                    type: lastSettedQueryType,
                    after: lastPageForQuery.isNotEmpty ? lastPageForQuery : nil,
                    searchFor: lastSettedSearchQuery)
    }
    
    open func requestList(_ xmppStream: XMPPStream, scope: IndexScope, type: QueryType, after: String? = nil, searchFor queryset: [SearchQueryItem] = []) {
        let elementId = xmppStream.generateUUID
        var modifiedQuery: [SearchQueryItem] = [SearchQueryItem(field: "", value: "", isFormType: true)]
        modifiedQuery.append(contentsOf: queryset)
        let x = DDXMLElement.element(withName: "x", children: modifiedQuery.map({ (item) -> DDXMLNode in
            let value = DDXMLElement.element(withName: "value") as! DDXMLElement
            if item.isFormType {
                switch type {
                case .message:
                    value.stringValue = "http://xabber.com/protocol/index#message"
                case .groupchat:
                    value.stringValue = "http://xabber.com/protocol/index#groupchat"
                }
                
                return DDXMLElement.element(withName: "field", children: [value], attributes: [
                    DDXMLNode.attribute(withName: "type", stringValue: "hidden") as! DDXMLNode,
                    DDXMLNode.attribute(withName: "var", stringValue: "FORM_TYPE") as! DDXMLNode,
                ]) as! DDXMLNode
            } else {
                value.stringValue = item.value//http://xabber.com/protocol/index#message
                return DDXMLElement.element(withName: "field", children: [value], attributes: [
                    DDXMLNode.attribute(withName: "var", stringValue: item.field) as! DDXMLNode
                ]) as! DDXMLNode
            }
            
        }), attributes: [
            DDXMLNode.attribute(withName: "xmlns", stringValue: "jabber:x:data") as! DDXMLNode,
            DDXMLNode.attribute(withName: "type", stringValue: "form") as! DDXMLNode
        ]) as! DDXMLElement
        
        let query = DDXMLElement.element(withName: "query", children: [x], attributes: nil) as! DDXMLElement
        switch type {
        case .message:
            query.setXmlns("http://xabber.com/protocol/index#message")
        case .groupchat:
            query.setXmlns("http://xabber.com/protocol/index#groupchat")
        }
        
        if let after = after {
            query.addChild(DDXMLElement.element(withName: "set",
                                           children: [DDXMLElement.element(withName: "after",
                                                                           stringValue: after) as! DDXMLNode],
                                           attributes: [DDXMLNode.attribute(withName: "xmlns",
                                                                            stringValue: "http://jabber.org/protocol/rsm") as! DDXMLNode]) as! DDXMLElement)
        }
        switch scope {
        case .local:
            if let localNode = SettingManager.shared.getKey(for: owner, scope: .globalIndex, key: "localNode") {
                query.addAttribute(withName: "node", stringValue: localNode)
            }
            if let localJid = SettingManager.shared.getKey(for: owner, scope: .globalIndex, key: "localJid") {
                guard let jid = XMPPJID(string: localJid) else {
                    return
                }
                xmppStream.send(XMPPIQ(iqType: .set, to: jid, elementID: elementId, child: query))
                queryIds.insert(elementId)
            }
        case .global:
            xmppStream.send(XMPPIQ(iqType: .set, to: globalIndexJid, elementID: elementId, child: query))
            queryIds.insert(elementId)
        }
        
        lastSettedSearchQuery = queryset
        lastSettedQueryType = type
    }
    
    func read(_ xmppStream: XMPPStream, withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result,
            let elementId = iq.elementID,
            queryIds.contains(elementId)
            else {
            return false
        }
        queryIds.remove(elementId)
        switch true {
        case readFields(iq): return true
        case readGroupchatList(iq, stream: xmppStream): return true
        case readMessagesList(iq, stream: xmppStream): return true
        default: return false
        }
    }
    
    internal func readFields(_ iq: XMPPIQ) -> Bool {
        
        return false
    }
    
    internal func readGroupchatList(_ iq: XMPPIQ, stream: XMPPStream) -> Bool {
        guard let query = iq.element(forName: "query"),
            query.xmlns() == "http://xabber.com/protocol/index#groupchat"
            else {
                return false
        }
        if let set = query.element(forName: "set") {
            if set.xmlns() == "http://jabber.org/protocol/rsm" {
                let count = set.element(forName: "count")?.stringValueAsInt()
                let first = set.element(forName: "first")?.stringValueAsInt()
                let last = set.element(forName: "last")?.stringValueAsInt()
            }
        }
        var items: Set<GroupChatIndexStorageItem> = Set<GroupChatIndexStorageItem>()
        func parse(_ item: DDXMLElement) {
            guard let itemId = item.attributeStringValue(forName: "id"),
                let groupchat = item.element(forName: "groupchat"),
                let jid = groupchat.attributeStringValue(forName: "jid"),
                let text = groupchat.element(forName: "description")?.stringValue,
                let membership = groupchat.element(forName: "membership")?.stringValue,
                let name = groupchat.element(forName: "name")?.stringValue,
                let privacy = groupchat.element(forName: "privacy")?.stringValue,
                let messagesCountUnwr = groupchat.element(forName: "message-count")?.stringValue,
                let membersUnwr = groupchat.element(forName: "members")?.stringValue,
                let messagesCount = Int(messagesCountUnwr),
                let members = Int(membersUnwr)
                else {
                    return
            }
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: GroupChatIndexStorageItem.self, forPrimaryKey: jid) {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            instance.itemId = itemId
                            instance.text = text
                            instance.name = name
                            instance.messagesCount = messagesCount
                            instance.members = members
                            switch membership {
                                case "member-only": instance.membership = .memberOnly
                                case "open": instance.membership = .open
                                default: instance.membership = .none
                            }
                            switch privacy {
                                case "public": instance.privacy = .isPublic
                                default: instance.privacy = .none
                            }
                        }
                    }
                } else {
                    let instance = GroupChatIndexStorageItem()
                    instance.jid = jid
                    instance.itemId = itemId
                    instance.text = text
                    instance.name = name
                    instance.messagesCount = messagesCount
                    instance.members = members
                    switch membership {
                        case "member-only": instance.membership = .memberOnly
                        case "open": instance.membership = .open
                        default: instance.membership = .none
                    }
                    switch privacy {
                        case "public": instance.privacy = .isPublic
                        default: instance.privacy = .none
                    }
                    items.insert(instance)
                }
            } catch {
                DDLogDebug("cant get instance of stored GI item")
            }
        }
        query.elements(forName: "item").forEach {
            parse($0)
        }
        if let after = query.element(forName: "set")?.element(forName: "last")?.stringValue {
            lastPageForQuery = after
        }
        do {
            let realm = try WRealm.safe()
            if !realm.isInWriteTransaction {
                try realm.write {
                    realm.add(items, update: .modified)
                }
            }
        } catch {
            DDLogDebug("cant save GI info")
        }
        return true
    }
    
    internal func readMessagesList(_ iq: XMPPIQ, stream: XMPPStream) -> Bool {
        guard let query = iq.element(forName: "query"),
            query.xmlns() == "http://xabber.com/protocol/index#messages"
            else {
                return false
        }
        return false
    }
}
