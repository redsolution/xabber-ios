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

class CommonChatStatesManager {
    open class var shared: CommonChatStatesManager {
        struct CommonChatStatesManagerSingleton {
            static let instance = CommonChatStatesManager()
        }
        return CommonChatStatesManagerSingleton.instance
    }
    
    class ChatStateMetadata: Hashable {
        
        static func == (lhs: ChatStateMetadata, rhs: ChatStateMetadata) -> Bool {
            return lhs.jid == rhs.jid && lhs.owner == rhs.owner
        }
        
        var jid: String
        var owner: String
        var state: ChatStatesManager.ComposingType
        var date: Date
        
        init(jid: String, owner: String, state: ChatStatesManager.ComposingType) {
            self.jid = jid
            self.owner = owner
            self.state = state
            self.date = Date()
        }

        func update(_ state: ChatStatesManager.ComposingType) {
            self.date = Date()
            self.state = state
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
            hasher.combine(owner)
        }
    }
    
    init() {
        observed
            .asObservable()
            .window(timeSpan: .seconds(2), count: 100, scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (_) in
                self.expire()
            })
            .disposed(by: bag)
    }
    
    internal var bag = DisposeBag()
    
    open var observed: BehaviorRelay<Set<ChatStateMetadata>> = BehaviorRelay(value: Set<ChatStateMetadata>())
    
    open func update(jid: String, owner: String, state: ChatStatesManager.ComposingType) {
        if let item = observed.value.first(where: { $0.jid == jid && $0.owner == owner }) {
            var value = observed.value
            value.remove(item)
            observed.accept(value)
        }
        let item = ChatStateMetadata(jid: jid, owner: owner, state: state)
        var value = observed.value
        value.insert(item)
        observed.accept(value)
    }
    
    open func clear(jid: String, owner: String) {
        if let index = observed.value.firstIndex(where: { $0.jid == jid && $0.owner == owner }) {
            var value = observed.value
            value.remove(at: index)
            observed.accept(value)
        }
    }
    
    open func expire() {
        let now = Date()
        observed
            .value
            .filter { now.timeIntervalSince($0.date) > 1 && $0.state == .none }
            .forEach {
                var value = observed.value
                value.remove($0)
                observed.accept(value)
            }
        observed
            .value
            .filter { now.timeIntervalSince($0.date) > 15 }
            .forEach { self.update(jid: $0.jid, owner: $0.owner, state: .none) }
    }
    
    open func state(for jid: String, owner: String) -> ChatStatesManager.ComposingType{
        if let item = observed.value.first(where: { $0.jid == jid && $0.owner == owner }) {
            return item.state
        }
        return .none
    }
    
    open func actionText(for jid: String, owner: String) -> String? {
        switch state(for: jid, owner: owner) {
        case .none:
            return nil
        case .typing:
            return "typing...".localizeString(id: "chat_state_composing", arguments: [])
        case .voice:
            return "recording a voice message...".localizeString(id: "chat_state_composing_voice", arguments: [])
        case .video:
            return "recording a video message...".localizeString(id: "chat_state_composing_video", arguments: [])
        case .uploadFile:
            return "sending a file...".localizeString(id: "chat_state_composing_upload", arguments: [])
        case .uploadImage:
            return "sending an image...".localizeString(id: "chat_state_composing_image", arguments: [])
        case .uploadAudio:
            return "sending an audio file...".localizeString(id: "chat_state_composing_audio", arguments: [])
        }
        
    }
    
}

class ChatStatesManager: AbstractXMPPManager {
    
    override func namespaces() -> [String] {
        return ["http://jabber.org/protocol/chatstates"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces()[0]
    }
    
    enum ComposingType: Int {
        case none
        case typing
        case voice
        case video
        case uploadFile
        case uploadImage
        case uploadAudio
    }
    
    func composing(_ xmppStream: XMPPStream, to jid: String, type: ComposingType) {
        let element = DDXMLElement.element(withName: "composing") as! DDXMLElement
        if type == .voice {
            let subtype = DDXMLElement(name: "subtype", xmlns: "https://xabber.com/protocol/extended-chatstates")
            subtype.addAttribute(withName: "type", stringValue: "voice")
            element.addChild(subtype)
        }
        element.setXmlns(getPrimaryNamespace())
        let message = XMPPMessage(messageType: .chat,
                                  to: XMPPJID(string: jid),
                                  elementID: nil,
                                  child: element)
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            stream.send(message)
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                stream.send(message)
            })
        }
//        AccountManager.shared.find(for: owner)?.messages.addStanzaToQueue(message)
    }
    
    func pause(_ xmppStream: XMPPStream, to jid: String) {
        let element = DDXMLElement(name: "paused")
        element.setXmlns(getPrimaryNamespace())
        let message = XMPPMessage(messageType: .chat,
                                  to: XMPPJID(string: jid),
                                  elementID: xmppStream.generateUUID,
                                  child: element)
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            stream.send(message)
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                stream.send(message)
            })
        }
//        AccountManager.shared.find(for: owner)?.messages.addStanzaToQueue(message)
//        xmppStream.send(message)
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        return false
    }
    
    open func read(withMessage message: XMPPMessage) -> Bool {
        var state: ComposingType = .none
        if let active = message.element(forName: "active"),
            active.xmlns() == getPrimaryNamespace() {
            return message.body?.isEmpty ?? true
        } else if let inactive = message.element(forName: "inactive"),
            inactive.xmlns() == getPrimaryNamespace() {
            return message.body?.isEmpty ?? true
        } else if let gone = message.element(forName: "gone"),
            gone.xmlns() == getPrimaryNamespace() {
            return message.body?.isEmpty ?? true
        } else if let composing = message.element(forName: "composing"),
            composing.xmlns() == getPrimaryNamespace() {
            if let subtype = composing.element(forName: "subtype")?.attributeStringValue(forName: "type") {
                switch subtype {
                case "voice": state = .voice
                case "video": state = .video
                case "upload": state = .uploadFile
                default: state = .typing
                }
            } else {
                state = .typing
            }
        } else if let paused = message.element(forName: "paused"),
            paused.xmlns() == getPrimaryNamespace() {
            state = .none
        } else {
            return false
        }
        
        
        guard let from = message.from?.bare,
            from != owner else { return message.body?.isEmpty ?? true }
        
        CommonChatStatesManager.shared.update(jid: from, owner: owner, state: state)
        
        return message.body?.isEmpty ?? true
    }
    
    override func clearSession() {
        self.queryIds.removeAll()
    }
    
    private func resetChatState(jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
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
                try realm.write {
                    instance.chatState = .none
                }
            }
        } catch {
            DDLogDebug("ChatStatesManager: \(#function). \(error.localizedDescription)")
        }
//        if let item = metadataItems.first(where: { $0.jid == jid }) {
//            metadataItems.remove(item)
//        }
    }
}
