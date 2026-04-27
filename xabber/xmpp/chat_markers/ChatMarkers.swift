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
    
    enum BurnMessagesTimerValues: Int {
        case off = 0
        case s5 = 5
        case s10 = 10
        case s15 = 15
        case s30 = 30
        case m1 = 60
        case m5 = 300
        case m10 = 600
        case m15 = 900
        
        static func verbose(_ value: BurnMessagesTimerValues) -> String {
            switch value {
                case .off: return "Off"
                case .s5: return "5 seconds"
                case .s10: return "10 seconds"
                case .s15: return "15 seconds"
                case .s30: return "30 seconds"
                case .m1: return "1 minute"
                case .m5: return "5 minutes"
                case .m10: return "10 minutes"
                case .m15: return "15 minutes"
            }
        }
        
        static func values() -> [BurnMessagesTimerValues] {
            return [.off, .s5, .s10, .s15, .s30, .m1, .m5, .m10, .m15]
        }
        
        static func allVerboseValues() -> [String] {
            return BurnMessagesTimerValues
                .values()
                .compactMap { return BurnMessagesTimerValues.verbose($0) }
        }
    }
    
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
    
    private lazy var afterburnCleanupQueue = DispatchQueue(
        label: "xabber.chatmarkers.afterburn.\(self.owner)"
    )
    private let cleanupStateLock = NSLock()
    private var afterburnTimer: DispatchSourceTimer?
    private var isCleanupRunning = false
    private var needsAnotherPass = false

    internal var afterburnCleanupInterval: DispatchTimeInterval { .seconds(1) }
    internal var afterburnCleanupLeeway: DispatchTimeInterval { .milliseconds(250) }
    internal var afterburnCleanupIntervalSeconds: TimeInterval { 1.0 }
    internal var afterburnCleanupLeewayMilliseconds: Int { 250 }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        updateDeleteEphemeralMessagesTimer()
    }
    
    init(withOwner owner: String, withoutAfterburnTimer: Bool) {
        super.init(withOwner: owner)
    }

    deinit {
        self.invalidateAfterburnTimer()
    }
    
    public func updateDeleteEphemeralMessagesTimer() {
        self.deleteEphemeralMessages()
        self.afterburnCleanupQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateAfterburnTimer()
            guard CommonConfigManager.shared.config.afterburn_at_default else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.afterburnCleanupQueue)
            timer.schedule(
                deadline: .now() + self.afterburnCleanupInterval,
                repeating: self.afterburnCleanupInterval,
                leeway: self.afterburnCleanupLeeway
            )
            timer.setEventHandler { [weak self] in
                self?.deleteEphemeralMessages()
            }
            self.afterburnTimer = timer
            timer.resume()
        }
    }
    
    public func deleteEphemeralMessages() {
        self.cleanupStateLock.lock()
        if self.isCleanupRunning {
            self.needsAnotherPass = true
            self.cleanupStateLock.unlock()
            return
        }
        self.isCleanupRunning = true
        self.needsAnotherPass = false
        self.cleanupStateLock.unlock()

        self.afterburnCleanupQueue.async { [weak self] in
            self?.runEphemeralCleanupLoop()
        }
    }

    internal func hasAfterburnTimerForTests() -> Bool {
        self.afterburnCleanupQueue.sync {
            self.afterburnTimer != nil
        }
    }

    internal func afterburnTimerDebugIdentifierForTests() -> ObjectIdentifier? {
        self.afterburnCleanupQueue.sync {
            self.afterburnTimer.map { ObjectIdentifier($0 as AnyObject) }
        }
    }

    internal func stopAfterburnTimerForTests() {
        self.afterburnCleanupQueue.sync {
            self.invalidateAfterburnTimer()
        }
    }

    private func runEphemeralCleanupLoop() {
        while true {
            autoreleasepool {
                self.runEphemeralCleanup()
            }
            self.cleanupStateLock.lock()
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.cleanupStateLock.unlock()
                continue
            }
            self.isCleanupRunning = false
            self.cleanupStateLock.unlock()
            return
        }
    }

    private func invalidateAfterburnTimer() {
        guard let timer = self.afterburnTimer else {
            return
        }
        timer.setEventHandler {}
        timer.cancel()
        self.afterburnTimer = nil
    }

    internal func runEphemeralCleanup() {
        do {
            let realm = try WRealm.safe()
            let now = Date().timeIntervalSince1970
            let collection = realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND isDeleted == false AND ((autoDeleteExpiresAt > 0 AND autoDeleteExpiresAt < %@) OR (autoDeleteExpiresAt <= 0 AND afterburnInterval > 0 AND isRead == true AND burnDate < %@ AND burnDate > 0))",
                    self.owner,
                    now,
                    now
                )
            
            guard collection.first != nil else {
                return
            }
            let jids = Set(collection.compactMap { return $0.opponent })
            let archivedIds = Set(collection.compactMap { $0.archivedId.isNotEmpty ? $0.archivedId : nil })
            let messageIds = Set(collection.compactMap { $0.messageId.isNotEmpty ? $0.messageId : nil })
            
            
            
            
            let chats = realm.objects(LastChatsStorageItem.self).filter("owner == %@ AND jid IN %@", self.owner, Array(jids))
            
            try realm.write {
                collection.forEach {
                    $0.markAutoDeleted()
                }

                if archivedIds.isNotEmpty || messageIds.isNotEmpty {
                    realm
                        .objects(NotificationStorageItem.self)
                        .filter("owner == %@", self.owner)
                        .forEach {
                            if archivedIds.contains($0.stanzaId)
                                || archivedIds.contains($0.sourceArchivedId ?? "")
                                || messageIds.contains($0.messageId)
                                || messageIds.contains($0.sourceMessageId ?? "") {
                                $0.text = nil
                                $0.fallbackText = nil
                                $0.shouldShow = false
                                $0.isRead = true
                                $0.mentionLinkStatus = .missing
                            }
                        }
                }
                
                chats.forEach {
                    let lastMessage = realm
                        .objects(MessageStorageItem.self)
                        .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, $0.jid, $0.conversationType_)
                        .sorted(byKeyPath: "date", ascending: false)
                        .first
                    $0.lastMessage = lastMessage
//                    $0.lastMessageId = lastMessage?.messageId ?? ""
                }
            }
        } catch {
            DDLogDebug("ChatMarkersManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func setReceived(_ message: XMPPMessage) -> Bool {
        guard message.element(forName: "markable", xmlns: getPrimaryNamespace()) != nil,
              let toJid = message.from?.bareJID,
              let messageId = message.elementID ?? message.originId else {
            return false
        }
        
        let elementId = "ChatMarkers: \(NanoID.new(8))"
        let received = DDXMLElement(name: "received", xmlns: getPrimaryNamespace())
        received.addAttribute(withName: "id", stringValue: messageId)
        let response = XMPPMessage(messageType: .chat, to: toJid, elementID: elementId, child: received)
        let conversationType = conversationTypeByMessage(message)
        let conversation = DDXMLElement(name: "conversation", xmlns: "https://xabber.com/protocol/synchronization")
        conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
        conversation.addAttribute(withName: "jid", stringValue: toJid.bare)
        response.addChild(conversation)
        
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ _, stream in
            stream.send(response)
        })
        
        return false
    }
    
    private func onReceived(_ message: XMPPMessage) -> Bool {
        guard let received = message.element(forName: "received", xmlns: getPrimaryNamespace()),
              let jid = message.from?.bare,
              let messageId = received.attributeStringValue(forName: "id") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageId == %@ AND state_ < %@",
                        self.owner,
                        jid,
                        messageId,
                        MessageStorageItem.MessageSendingState.deliver.rawValue).first {
                try realm.write {
                    if instance.isInvalidated { return }
                    instance.state = .deliver
                }
            }
        } catch {
            DDLogDebug("ChatMarkersManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    
    private func onDisplayed(_ message: XMPPMessage, date archivedDate: Date? = nil, delayed: Bool = false) -> Bool {
        guard let displayed = message.element(forName: "displayed", xmlns: getPrimaryNamespace()),
              let jid = message.from?.bare == self.owner ? message.to?.bare : message.from?.bare,
              let messageId = displayed.attributeStringValue(forName: "id") else {
            return false
        }
        var date: Date? = archivedDate
        
        if date == nil {
            date = getDelayedDate(message)
        }
        if date == nil {
            date = getDeliveryDate(message)
        }
        if date == nil {
            date = Date()
        }
        let stanzaId = displayed
            .elements(forName: "stanza-id")
            .first(where: { $0.attributeStringValue(forName: "by") == self.owner })?
            .attributeStringValue(forName: "id") ?? "no-stanza-id"
        
        if !delayed {
            AccountManager.shared.find(for: self.owner)?.messages.updateReadDate(for: messageId, stanzaId: stanzaId, jid: jid, date: date ?? Date())
        }
        do {
            let realm = try WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageId == %@",
                        self.owner,
                        jid,
                        messageId).first {
                let collection = realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND date <= %@ AND burnDate < 1 AND state_ != %@",
                            self.owner,
                            jid,
                            instance.date,
                            MessageStorageItem.MessageSendingState.error.rawValue)
                
                try realm.write {
                    if instance.isInvalidated { return }
                    if let chatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: instance.conversationType)) {
                        if chatInstance.lastMessage?.primary == instance.primary {
                            chatInstance.unread = 0
                        }
//                        chatInstance.updateTS = Date().timeIntervalSince1970
                    }
                    
//                    if instance.readDate <= 1 && instance.burnDate <= 1 {
//                        if instance.afterburnInterval > 0 {
//                            instance.readDate = (date ?? Date()).timeIntervalSince1970
//                            instance.burnDate = (date ?? Date()).timeIntervalSince1970 + instance.afterburnInterval
//                        }
//                    }
//                    instance.state = .read
//                    instance.isRead = true
                    if instance.readDate < 1 {
                        instance.readDate = (date ?? Date()).timeIntervalSince1970
                    }
                    if instance.afterburnInterval > 0 && instance.autoDeleteExpiresAt <= 0 {
                        if instance.burnDate < 1 {
                            instance.burnDate = (date ?? Date()).timeIntervalSince1970 + instance.afterburnInterval
                        }
                    }
                    instance.state = .read
                    instance.isRead = true
                    collection.forEach {
                        if $0.readDate < 1 {
                            $0.readDate = (date ?? Date()).timeIntervalSince1970
                        }
                        if $0.afterburnInterval > 0 && $0.autoDeleteExpiresAt <= 0 {
                            if $0.burnDate < 1 {
                                $0.burnDate = (date ?? Date()).timeIntervalSince1970 + $0.afterburnInterval
                            }
                        }
                        $0.state = .read
                        $0.isRead = true
                    }
                }
            }
            if !delayed {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    _ = self.onDisplayed(message, date: archivedDate, delayed: true)
                }
            }
        } catch {
            DDLogDebug("ChatMarkersManager: \(#function). \(error.localizedDescription)")
        }
        self.deleteEphemeralMessages()
        
        return true
    }
    
    private func onCarbonsSentDisplayed(_ message: XMPPMessage) -> Bool {
        guard isCarbonCopy(message),
              let bareMessage = getCarbonCopyMessageContainer(message) else {
            return false
        }
        let date = message.delayedDeliveryDate as Date?// getDelayedDate(message)
        return self.onDisplayed(bareMessage, date: date)
    }
    
    
    private func onCarbonsForwardedDisplayed(_ message: XMPPMessage) -> Bool {
        guard isCarbonForwarded(message),
              let bareMessage = getCarbonForwardedMessageContainer(message) else {
            return false
        }
        let date = getDelayedDate(message)
        return self.onDisplayed(bareMessage, date: date)
    }
    
    private func onArchivedDisplayed(_ message: XMPPMessage) -> Bool {
        guard isArchivedMessage(message),
              let bareMessage = getArchivedMessageContainer(message),
              let date = getDelayedDate(message) else {
                  return false
              }
        
        return self.onDisplayed(bareMessage, date: date)
    }
    
    private func onCarbonsSentReceived(_ message: XMPPMessage) -> Bool {
        guard isCarbonCopy(message),
              let bareMessage = getCarbonCopyMessageContainer(message) else {
            return false
        }
        return self.onReceived(bareMessage)
    }
    
    
    private func onCarbonsForwardedReceived(_ message: XMPPMessage) -> Bool {
        guard isCarbonForwarded(message),
              let bareMessage = getCarbonForwardedMessageContainer(message) else {
            return false
        }
        return self.onReceived(bareMessage)
    }
    
    private func onArchivedReceived(_ message: XMPPMessage) -> Bool {
        guard isArchivedMessage(message),
              let bareMessage = getArchivedMessageContainer(message) else {
                  return false
              }
        
        return self.onReceived(bareMessage)
    }
    
    public func read(withMessage message: XMPPMessage) -> Bool {
        switch true {
            case self.onCarbonsSentDisplayed(message): return true
            case self.onCarbonsForwardedDisplayed(message): return true
            case self.onArchivedDisplayed(message): return true
            case self.onCarbonsSentReceived(message): return true
            case self.onCarbonsForwardedReceived(message): return true
            case self.onArchivedReceived(message): return true
            case self.onReceived(message): return true
            case self.onDisplayed(message): return true
            case self.onArchivedDisplayed(message): return true
            case self.setReceived(message): return true
            default: return false
        }
    }
    
    func displayedById(_ xmppStream: XMPPStream, jid: String, messageId: String) {
        let displayed = DDXMLElement(name: "displayed", xmlns: getPrimaryNamespace())
        displayed.addAttribute(withName: "id", stringValue: messageId)
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: jid), elementID: "ChatMarkers: \(NanoID.new(8))", child: displayed)
        xmppStream.send(message)
    }
    
    func displayed(_ xmppStream: XMPPStream, message primaryKey: String) {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primaryKey) {
                if instance.outgoing {
                    return
                }
                let elementId = "ChatMarkers: \(NanoID.new(8))"
                let displayed = DDXMLElement(name: "displayed", xmlns: getPrimaryNamespace())
                displayed.addAttribute(withName: "id", stringValue: instance.messageId)
                if let stanzaInstance = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: [primaryKey, "stanza"].prp()) {
                    let document = try DDXMLDocument(xmlString: stanzaInstance.stanza, options: 0)
                    if let message = document.rootElement() {
                        message
                            .elements(forName: "stanza-id")
                            .forEach { displayed.addChild($0.copy() as! DDXMLElement) }
                    }
                }
                let response = XMPPMessage(messageType: .chat, to: XMPPJID(string: instance.opponent), elementID: elementId, child: displayed)
                let conversationType = instance.conversationType
                if conversationType.isEncrypted {
                    let encryptionElement = DDXMLElement(name: "encryption", xmlns: "urn:xmpp:eme:0")
                    encryptionElement.addAttribute(withName: "namespace", stringValue: conversationType.rawValue)
                    response.addChild(encryptionElement)
                    response.addStorageHint(.store)
                }
                let conversation = DDXMLElement(name: "conversation", xmlns: "https://xabber.com/protocol/synchronization")
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                conversation.addAttribute(withName: "jid", stringValue: instance.opponent)
                response.addChild(conversation)
                xmppStream.send(response)
                let collection = realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND date < %@ AND burnDate < 0",
                            self.owner,
                            instance.opponent,
                            instance.date)
                try realm.write {
                    if instance.isInvalidated { return }
                    if instance.readDate <= 1 && instance.burnDate <= 1 {
                        if instance.afterburnInterval > 0 && instance.autoDeleteExpiresAt <= 0 {
                            instance.readDate = Date().timeIntervalSince1970
                            instance.burnDate = Date().timeIntervalSince1970 + instance.afterburnInterval
                        }
                    }
                    collection.forEach {
                        if $0.readDate <= 1 && $0.burnDate <= 1 {
                            if $0.afterburnInterval > 0 && $0.autoDeleteExpiresAt <= 0 {
                                $0.readDate = Date().timeIntervalSince1970
                                $0.burnDate = Date().timeIntervalSince1970 + $0.afterburnInterval
                            }
                        }
                    }
                }
                
            }
        } catch {
            DDLogDebug("ChatMarkersManager: \(#function). \(error.localizedDescription)")
        }
    }
}
