//
//  DeliveryReceiptsManager.swift
//  xabber
//
//  Created by Игорь Болдин on 25.07.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import XMPPFramework
import RealmSwift
import CocoaLumberjack

class MessageDeliveryReceipts: AbstractXMPPManager {
    
    override func namespaces() -> [String] {
        return [
            "urn:xmpp:receipts"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        self.namespaces().first!
    }
    
    private func setReceived(_ message: XMPPMessage) -> Bool {
        guard message.element(forName: "request", xmlns: getPrimaryNamespace()) != nil,
              let toJid = message.from?.bareJID,
              let messageId = message.elementID ?? message.originId else {
            return false
        }
        let elementId = "Receipts: \(NanoID.new(8))"
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
        return true
    }
    
    private func onReceived(_ message: XMPPMessage) -> Bool {
        guard let fromJid = message.from?.bare,
              let received = message.element(forName: "received", xmlns: getPrimaryNamespace()),
              let messageId = received.attributeStringValue(forName: "id") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND messageId == %@",
                        owner,
                        fromJid,
                        messageId).first {
                try realm.write {
                    if instance.isInvalidated { return }
                    if instance.state != .read {
                        instance.state = .deliver
                    }
                }
            }
        } catch {
            DDLogDebug("MessageDeleteManager, \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    public func read(withMessage message: XMPPMessage) -> Bool {
        switch true {
            case self.onReceived(message): return true
            case self.setReceived(message): return true
            default: return false
        }
    }
}
