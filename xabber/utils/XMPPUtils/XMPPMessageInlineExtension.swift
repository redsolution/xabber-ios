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


func getStanzaId(_ message: XMPPMessage, owner: String) -> String {
    let isGroupchat = message.element(forName: "x", xmlns: "https://xabber.com/protocol/groups") != nil
    var resultId: String? = nil
    if !isGroupchat,
        let received = message.element(forName: "received",
                                       xmlns: "https://xabber.com/protocol/delivery") {
        if received.elements(forName: "stanza-id").count == 1 {
            resultId = received.element(forName: "stanza-id")?.attributeStringValue(forName: "id")
        } else {
            received
            .elements(forName: "stanza-id")
            .forEach {
                if let by = $0.attributeStringValue(forName: "by"),
                    by == owner {
                    resultId = $0.attributeStringValue(forName: "id")
                }
            }
        }
        if resultId?.isNotEmpty ?? false {
            return resultId ?? ""
        }
    }
    
    var ids = message.elements(forName: "stanza-id")
    if ids.isEmpty {
        ids = message.elements(forName: "archived")
    }
    if ids.count == 1 {
        resultId = ids.first?.attributeStringValue(forName: "id")
    } else if ids.count > 1 {
        ids.forEach {
            if isGroupchat {
                if let from = message.from?.bare,
                    let by = $0.attributeStringValue(forName: "by"),
                    by == from {
                    resultId = $0.attributeStringValue(forName: "id")
                }
            } else {
                if let by = $0.attributeStringValue(forName: "by"),
                    by == owner {
                    resultId = $0.attributeStringValue(forName: "id")
                }
            }
        }
    }
    return resultId ?? ""
}

func getOriginId(_ message: XMPPMessage) -> String? {
    return message
        .element(forName: "origin-id")?
        .attributeStringValue(forName: "id") ?? message.elementID
}

func getStanzaIdAuthor(_ message: XMPPMessage) -> String? {
    return message
        .element(forName: "stanza-id")?
        .attributeStringValue(forName: "by")
}

func getMAMQueryId(_ message: XMPPMessage) -> String? {
//    print(#function, message.prettyXMLString!)
    return message
        .element(forName: "result")?
        .attributeStringValue(forName: "queryid")
}

func getPreviousId(_ message: XMPPMessage) -> String? {
//    print(message.prettyXMLString!)
    return message
        .element(forName: "previous-id", xmlns: "http://xabber.com/protocol/previous")?
        .attributeStringValue(forName: "id")
}

func getUniqueMessageId(_ message: XMPPMessage, owner: String) -> String {
    var Id: String = getStanzaId(message, owner: owner)
    if let messageId = message.elementID {
        Id = messageId
    }
    if let originId = getOriginId(message) {
        Id = originId
    }
    return Id
}

func getOriginOrMessageId(_ message: XMPPMessage) -> String {
    var Id: String = ""
    if let messageId = message.elementID {
        Id = messageId
    }
    if let originId = getOriginId(message) {
        Id = originId
    }
    return Id
}

func getArchivedMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    if let container = message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "message") {
        return XMPPMessage(from: container)
    }
    return nil
}

func getPriorityMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    if let container = message.element(forName: "priority-message")?.element(forName: "forwarded")?.element(forName: "message") {
        return XMPPMessage(from: container)
    }
    return nil
}

func getCarbonCopyMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    guard let from = message.from?.bare,
          let to = message.to?.bare,
          from == to,
          let container = message
            .element(forName: "sent")?
            .element(forName: "forwarded")?
            .element(forName: "message") else {
        return nil
    }
    return XMPPMessage(from: container)
}

func getCarbonForwardedMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    guard let from = message.from?.bare,
          let to = message.to?.bare,
          from == to,
          let container = message
            .element(forName: "received")?
            .element(forName: "forwarded")?
            .element(forName: "message") else {
        return nil
    }
    return XMPPMessage(from: container)
}

func getForwardedMessage(_ message: XMPPMessage) -> XMPPMessage? {
    if let container = message.element(forName: "forwarded")?.element(forName: "message") {
        return XMPPMessage(from: container)
    }
    return nil
}

func isArchivedMessage(_ message: XMPPMessage) -> Bool {
    if let namespace = message.element(forName: "result")?.xmlns() {
        return ["urn:xmpp:mam:0", "urn:xmpp:mam:1", "urn:xmpp:mam:2", "urn:xmpp:mam:3"].contains(namespace)
    }
    return false
}
 
func isPriorityMessage(_ message: XMPPMessage) -> Bool {
    if let namespace = message.element(forName: "priority-message")?.xmlns() {
        return "https://xabber.com/protocol/priority" == namespace
    }
    return false
}

func isCarbonCopy(_ message: XMPPMessage) -> Bool {
    if let namespace = message.element(forName: "sent")?.xmlns() {
        return ["urn:xmpp:carbons:0", "urn:xmpp:carbons:1", "urn:xmpp:carbons:2"].contains(namespace)
    }
    return false
}

func isCarbonForwarded(_ message: XMPPMessage) -> Bool {
    if let namespace = message.element(forName: "received")?.xmlns() {
        return ["urn:xmpp:carbons:0", "urn:xmpp:carbons:1", "urn:xmpp:carbons:2"].contains(namespace)
    }
    return false
}

func isVoIPMessage(_ message: XMPPMessage) -> Bool {
    switch true {
    case message.element(forName: "propose") != nil: return true
    case message.element(forName: "accept") != nil: return true
    case message.element(forName: "reject") != nil: return true
    default: return false
    }
    
}

func isForwardedMessage(_ message: XMPPMessage) -> Bool {
    if let forwarded = message.element(forName: "forwarded")?.xmlns() {
        return forwarded == "urn:xmpp:forward:0"
    }
    return false
}

func isForwardedMessageOld(_ message: XMPPMessage) -> Bool {
    return message
            .elements(forName: "reference")
            .filter({ $0.attributeStringValue(forName: "type", withDefaultValue: "none") == "forward" })
            .isNotEmpty
}

func isModernForwardedMessage(_ message: XMPPMessage) -> Bool {
    if message
        .elements(forName: "reference")
        .filter({ $0.attributeStringValue(forName: "type", withDefaultValue: "none") == "forward" })
        .isNotEmpty {
        return true
    }
    return false
}

func getQueryId(_ message: XMPPMessage) -> String? {
    return message.element(forName: "result")?.attributeStringValue(forName: "queryid")
}

func getDeliveryTime(_ message: XMPPMessage, owner: String) -> Date? {
    guard let dateString = message
        .elements(forName: "time")
        .first(where: { $0.xmlns() == "https://xabber.com/protocol/delivery"
            && $0.attributeStringValue(forName: "by", withDefaultValue: "none") == owner})?
        .attributeStringValue(forName: "stamp", withDefaultValue: "0")
        else {
            return nil
    }
    var date: Date? = nil
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    date = dateFormatter.date(from: dateString)
    if date == nil {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        date = dateFormatter.date(from: dateString)
    }
    return date
}

func getDelayedDate(_ message: XMPPMessage) -> Date? {
    var date: Date? = nil
    if let dateString = message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "time")?.attributeStringValue(forName: "stamp") {
        date = dateString.xmppDate
    }
    if date == nil {
        if let dateString = message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "time")?.attributeStringValue(forName: "stamp") {
            date = dateString.xmppDate
        }
    }
    if let dateString = message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "delay")?.attributeStringValue(forName: "stamp") {
        date = dateString.xmppDate
    }
    if date == nil {
        if let dateString = message.element(forName: "result")?.element(forName: "forwarded")?.element(forName: "delay")?.attributeStringValue(forName: "stamp") {
            date = dateString.xmppDate
        }
    }
    if date == nil {
        date = getDeliveryDate(message)
    }
    return date
}

func getDeliveryDate(_ message: XMPPMessage) -> Date? {
    var date: Date? = nil
    if date == nil {
        if let dateString = message.element(forName: "time")?.attributeStringValue(forName: "stamp") {
            date = dateString.xmppDate
        }
    }
    if date == nil {
        if let dateString = message.element(forName: "delay")?.attributeStringValue(forName: "stamp") {
            date = dateString.xmppDate
        }
    }
    return date
}

func getDateFrom(_ tag: DDXMLElement) -> Date? {
    if let dateString = tag.element(forName: "delay")?.attributeStringValue(forName: "stamp") {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let date = dateFormatter.date(from: dateString) {
            return date
        }
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return dateFormatter.date(from: dateString)
    }
    return nil
}

func isMySendedCarbons(_ message: XMPPMessage) -> Bool {
    guard isCarbonCopy(message) else { return false }
    guard let to = message.to else { return false }
    guard let container = getCarbonCopyMessageContainer(message) else { return false }
    guard let containerFrom = container.from else { return false }
    if to.full == containerFrom.full {
        return true
    }
    return false
}

func isArchivedByMe(_ message: XMPPMessage) -> Bool {
    guard isArchivedMessage(message) else { return false }
    guard let to = message.to else { return false }
    guard let container = getArchivedMessageContainer(message) else { return false }
    guard let containerFrom = container.from else { return false }
    if to.full == containerFrom.full {
        return true
    }
    return false
}

func conversationTypeByMessage(_ message: XMPPMessage) -> ClientSynchronizationManager.ConversationType {
    if message.elements(forXmlns: "https://xabber.com/protocol/groups").count > 0 {
        return .group
    }
    if message.elements(forXmlns: "https://xabber.com/protocol/groups#system-message").count > 0 {
        return .group
    }
    if let xmlns = message.element(forName: "encrypted")?.xmlns {
        return ClientSynchronizationManager.ConversationType(rawValue: xmlns) ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    }
    if let owner = message.from?.bare,
       let account = AccountManager.shared.find(for: owner),
       let to = message.to?.bare,
       to == account.favorites.node {
        return .saved
    }
    return .regular
}
