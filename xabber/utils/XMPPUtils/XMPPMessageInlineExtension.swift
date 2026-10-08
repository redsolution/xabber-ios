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

func compareArchiveIds(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
    guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          lhs.isNotEmpty,
          rhs.isNotEmpty else {
        return nil
    }

    if let lhsNumeric = Int64(lhs), let rhsNumeric = Int64(rhs) {
        if lhsNumeric == rhsNumeric {
            return .orderedSame
        }
        return lhsNumeric < rhsNumeric ? .orderedAscending : .orderedDescending
    }

    if lhs == rhs {
        return .orderedSame
    }

    return lhs < rhs ? .orderedAscending : .orderedDescending
}

func isArchiveId(_ candidate: String?, newerThan boundary: String?) -> Bool? {
    guard let comparison = compareArchiveIds(candidate, boundary) else {
        return nil
    }
    return comparison == .orderedDescending
}

func getStanzaId(_ message: XMPPMessage, owner: String) -> String {
    let isGroupchat = ["chat", "headline"].contains(message.attributeStringValue(forName: "type") ?? "")
        && message.element(forName: "x", xmlns: "https://xabber.com/protocol/groups") != nil
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
    return SCEReceivePolicy.children(of: message, named: "origin-id", xmlns: "urn:xmpp:sid:0").first?
        .attributeStringValue(forName: "id") ?? message.elementID
}

func getStanzaIdAuthor(_ message: XMPPMessage) -> String? {
    return message
        .element(forName: "stanza-id")?
        .attributeStringValue(forName: "by")
}

func getMAMQueryId(_ message: XMPPMessage) -> String? {
    guard isArchivedMessage(message) else {
        return nil
    }
    return getMAMResultElement(message)?.attributeStringValue(forName: "queryid")
}

/// The outer XEP-0313 result ID is the archive/RSM cursor. It must not be
/// conflated with the forwarded stanza's `stanza-id`, which remains a protocol
/// identity for mutations and receipts.
func getMAMResultID(_ message: XMPPMessage) -> String? {
    guard isArchivedMessage(message) else {
        return nil
    }
    let resultID = getMAMResultElement(message)?
        .attributeStringValue(forName: "id")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return resultID?.isNotEmpty == true ? resultID : nil
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

func getMAMResultElement(_ message: XMPPMessage) -> DDXMLElement? {
    let results = (message.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
        $0.localName == "result" && SCEReceivePolicy.mamNamespaces.contains($0.uri ?? "")
    }
    return results.count == 1 ? results[0] : nil
}

private func transportForwardedMessage(_ wrapper: DDXMLElement) -> XMPPMessage? {
    let forwarded = SCEReceivePolicy.children(of: wrapper, named: "forwarded", xmlns: "urn:xmpp:forward:0")
    guard forwarded.count == 1 else { return nil }
    let messages = SCEReceivePolicy.children(of: forwarded[0], named: "message", xmlns: "jabber:client")
    guard messages.count == 1 else { return nil }
    return XMPPMessage(from: messages[0])
}

func getArchivedMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    getMAMResultElement(message).flatMap { transportForwardedMessage($0) }
}

func getPriorityMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    if let container = message.element(forName: "priority-message")?.element(forName: "forwarded")?.element(forName: "message") {
        return XMPPMessage(from: container)
    }
    return nil
}

private func carbonMessageContainer(_ message: XMPPMessage, name: String) -> XMPPMessage? {
    guard let from = message.from?.bare, let to = message.to?.bare, from == to else { return nil }
    let wrappers = (message.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
        ["sent", "received"].contains($0.localName ?? "") && SCEReceivePolicy.carbonNamespaces.contains($0.uri ?? "")
    }
    guard wrappers.count == 1, wrappers[0].localName == name else { return nil }
    return transportForwardedMessage(wrappers[0])
}

func getCarbonCopyMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    carbonMessageContainer(message, name: "sent")
}

func getCarbonForwardedMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    carbonMessageContainer(message, name: "received")
}

func getForwardedMessage(_ message: XMPPMessage) -> XMPPMessage? {
    if let container = message.element(forName: "forwarded")?.element(forName: "message") {
        return XMPPMessage(from: container)
    }
    return nil
}

func getGroupchatHeadlineForwardedMessageContainer(_ message: XMPPMessage) -> XMPPMessage? {
    guard let container = message
        .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
        .element(forName: "forwarded", xmlns: "urn:xmpp:forward:0")?
        .element(forName: "message") else {
        return nil
    }
    return XMPPMessage(from: container)
}

func isArchivedMessage(_ message: DDXMLElement) -> Bool {
    let results = (message.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
        $0.localName == "result" && SCEReceivePolicy.mamNamespaces.contains($0.uri ?? "")
    }
    return results.count == 1
}

func isPriorityMessage(_ message: XMPPMessage) -> Bool {
    if let namespace = message.element(forName: "priority-message")?.xmlns() {
        return "https://xabber.com/protocol/priority" == namespace
    }
    return false
}

func isCarbonCopy(_ message: XMPPMessage) -> Bool {
    (message.children?.compactMap { $0 as? DDXMLElement } ?? []).contains {
        $0.localName == "sent" && SCEReceivePolicy.carbonNamespaces.contains($0.uri ?? "")
    }
}

func isCarbonForwarded(_ message: XMPPMessage) -> Bool {
    (message.children?.compactMap { $0 as? DDXMLElement } ?? []).contains {
        $0.localName == "received" && SCEReceivePolicy.carbonNamespaces.contains($0.uri ?? "")
    }
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
    return getMAMResultElement(message)?.attributeStringValue(forName: "queryid")
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
    guard let result = getMAMResultElement(message) else {
        return getDeliveryDate(message)
    }
    let forwarded = SCEReceivePolicy.children(of: result, named: "forwarded", xmlns: "urn:xmpp:forward:0")
    guard forwarded.count == 1 else { return nil }

    // Use the same owned MAM wrapper as payload extraction. A foreign result
    // or date lookalike must not change an accepted carrier's archive date.
    let delays = SCEReceivePolicy.children(of: forwarded[0], named: "delay", xmlns: "urn:xmpp:delay")
    let times = SCEReceivePolicy.children(of: forwarded[0], named: "time", xmlns: "https://xabber.com/protocol/delivery")
    guard delays.count <= 1, times.count <= 1 else { return nil }
    if let date = delays.first?.attributeStringValue(forName: "stamp")?.xmppDate {
        return date
    }
    if let date = times.first?.attributeStringValue(forName: "stamp")?.xmppDate {
        return date
    }

    // Keep the existing outer delivery-time fallback, qualified and singular.
    let outerTimes = SCEReceivePolicy.children(of: message, named: "time", xmlns: "https://xabber.com/protocol/delivery")
    let outerDelays = SCEReceivePolicy.children(of: message, named: "delay", xmlns: "urn:xmpp:delay")
    guard outerTimes.count <= 1, outerDelays.count <= 1 else { return nil }
    return outerTimes.first?.attributeStringValue(forName: "stamp")?.xmppDate
        ?? outerDelays.first?.attributeStringValue(forName: "stamp")?.xmppDate
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
    let stanzaType = message.attributeStringValue(forName: "type") ?? ""
    guard stanzaType != "groupchat" else {
        return .regular
    }
    if ["chat", "headline"].contains(stanzaType),
       (try? GroupStanzaRouter.route(message)) != nil {
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
