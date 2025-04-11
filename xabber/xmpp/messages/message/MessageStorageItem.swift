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
//import RxSwift
import UIKit
import MaterialComponents.MDCPalettes
import CryptoSwift
import CryptoKit


class MessageStorageItem: Object {
    
    static let addContactLocalArchivedId: String = "add-contact-local-archived-id"
    
    enum MessageDisplayType: String {
        case text = "text"
        case call = "call"
        case system = "system"
        case sticker = "sticker"
    }
    
    public enum MessageSendingState: Int {
        case sended
        case deliver
        case read
        case error
        case none
        case notSended
        case sending
        case uploading
    }
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    override static func indexedProperties() -> [String] {
        return ["opponent", "owner", "date", "conversationType_", "archivedId", "messageId"]
    }
    
    @objc dynamic var primary: String = ""
    
    @objc dynamic var owner: String = ""
    @objc dynamic var opponent: String = ""
    
    @objc dynamic var body: String = ""
    @objc dynamic var legacyBody: String = ""
    
    @objc dynamic var date: Date = Date()
    @objc dynamic var sentDate: Date = Date()
    @objc dynamic var editDate: Date? = nil
    @objc dynamic var outgoing: Bool = false
    @objc dynamic var isRead: Bool = false
    
    @objc dynamic var messageType: String = MessageDisplayType.text.rawValue
    
    @objc dynamic var messageId: String = ""
    
    @objc dynamic var trustedSource: Bool = false
    @objc dynamic var previousId: String? = nil
    @objc dynamic var queryIds: String? = nil
    
    @objc dynamic var archivedId: String = ""
    
    @objc dynamic var isDeleted: Bool = false
    @objc dynamic var state_: Int = 0
    
    @objc dynamic var groupchatCard: GroupchatUserStorageItem? = nil
    
    @objc dynamic var envelopeContainer: String? = nil
    @objc dynamic var afterburnInterval: Double = -1
    @objc dynamic var burnDate: Double = -1
    @objc dynamic var readDate: Double = -1
    
    @objc dynamic var errorMetadata_: String? = nil
    @objc dynamic var systemMetadata_: String? = nil
    
    var references: List<MessageReferenceStorageItem> = List<MessageReferenceStorageItem>()
    
    @objc dynamic var messageError: String? = nil
    @objc dynamic var messageErrorCode: String? = nil
    
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    
    var inlineForwards: List<MessageForwardsInlineStorageItem> = List<MessageForwardsInlineStorageItem>()
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: self.conversationType_) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var isHasAttachedMessages: Bool {
        get {
            return false
        }
    }
    
    final var groupchatMetadata: [String: Any]? {
        get {
            return references.first(where: { $0.kind == .groupchat })?.metadata
        }
    }
    
    final var groupchatAuthorId: String? {
        get {
            if displayAs == .system { return nil }
            return groupchatCard?.userId ?? groupchatMetadata?["id"] as? String
        }
    }
    
    final var groupchatAuthorNickname: String? {
        get {
            if displayAs == .system { return nil }
            return groupchatCard?.nickname ?? groupchatMetadata?["nickname"] as? String ?? groupchatMetadata?["jid"] as? String
        }
    }
    
    final var groupchatAuthorBadge: String? {
        get {
            let role = groupchatCard?.role.localized ??  (groupchatMetadata?["role"] as? String)
            let badge = groupchatCard?.badge ?? groupchatMetadata?["badge"] as? String ?? ""
            if role?.lowercased() == "member" {
                return badge
            } else {
                return badge.isNotEmpty ? badge : role?.capitalized
            }
        }
    }
    
    final var groupchatDisplayedNickname: String? {
        get {
            if let nick = groupchatAuthorNickname,
                self.displayAs != .system {
                return outgoing ? "You:" : nick
            }
            return nil
        }
    }
    
    final var groupchatUserAvatarPath: String? {
        get {
//            print(groupchatMetadata)
            if let avatarId = groupchatMetadata?["avatar_uri"] as? String {
                return [avatarId, opponent].prp()
            }
            return nil
        }
    }
    
    var errorMetadata: [String: Any]? {
        get {
            if let metadata = errorMetadata_,
                let data = metadata.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("cant create json object from reference metadata with id: \(messageId)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    errorMetadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode reference metadata with id: \(messageId)")
                }
            } else {
                errorMetadata_ = nil
            }
        }
    }
    
    var systemMetadata: [String: Any]? {
        get {
            if let metadata = systemMetadata_,
                let data = metadata.data(using: .utf8) {
                do {
                    return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                } catch {
                    DDLogDebug("cant create json object from reference metadata with id: \(messageId)")
                }
            }
            return nil
        } set {
            if let value = newValue {
                do {
                    let data = try JSONSerialization.data(withJSONObject: value, options: [])
                    systemMetadata_ = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    DDLogDebug("cant encode reference metadata with id: \(messageId)")
                }
            } else {
                systemMetadata_ = nil
            }
        }
    }
    
    var forceUnreadState: Bool? = nil
    var isInvite: Bool = false
    
    override static func ignoredProperties() -> [String] {
        return ["originalStanza", "forceUnreadState", "isInvite"]
    }
    
    var originalStanza: XMPPMessage? = nil
    
    var displayAs: MessageDisplayType {
        get {
            return MessageDisplayType(rawValue: self.messageType) ?? .text
        } set {
            messageType = newValue.rawValue
        }
    }
    
    var state: MessageSendingState {
        get {
            if displayAs == .system {
                return .none
            }
            return MessageSendingState(rawValue: self.state_) ?? .none
        } set {
            self.state_ = newValue.rawValue
        }
    }
    
    public final func displayedBody() -> String {
        switch displayAs {
            case .text, .system:
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        case .call:
            return "Call".localizeString(id: "chat_message_call", arguments: []) // TODO change text
        case .sticker:
            return "Sticker".localizeString(id: "chat_message_sticker", arguments: []) // TODO: fix to sticker
        }
    }
    
    //TODO: foreignKey to CallStorageItem
    var callMetadata: [String: Any]? {
        get {
            return references.first(where: { $0.kind == .call })?.metadata
        }
    }
    
    public static func messageIdForAuthRequest(jid: String) -> String {
        return ["subscribtion", jid].prp()
    }
    
    
    public static func messageIdForContact(owner: String, jid: String, ts: String) -> String {
        return ["contact", ts, jid, owner].prp()
    }
    
    public static func messageIdForVoIPCall(owner: String, jid: String, callId: String) -> String {
        return ["voip", owner, jid, callId].prp()
    }
    
    public static func messageIdForInitial(jid: String, conversationType: ClientSynchronizationManager.ConversationType) -> String {
        return [jid, conversationType.rawValue, "initial_message"].prp()
    }
    
    public static func genPrimary(messageId: String, owner: String) -> String {
        var primary: String = ""
        primary = messageId
        primary += "_\(owner)"
        return primary
    }
    
    func updatePrimary(system: Bool = false, auth: Bool = false) {
        if self.primary.isNotEmpty { return }
        self.primary = MessageStorageItem.genPrimary(messageId: messageId,
                                                     owner: owner)
        if system {
            self.primary += "_sys"
        }
        if auth {
            self.primary += "_auth"
        }
        if isInvite {
            self.primary += "_invite"
        }
    }
    
    func storeStanza() {
        guard let stanza = originalStanza,
            primary.isNotEmpty else {
                return
        }
        let instance = MessageStanzaStorageItem()
        instance.set(messageId, for: owner, with: stanza.xmlString, at: date, primary: self.primary)
        do {
            let realm = try  WRealm.safe()
            realm.add(instance, update: .modified)
        } catch {
            DDLogDebug("cant store stanza for message \(messageId)")
        }
    }
    
    func saveStanze(_ message: XMPPMessage, at date: Date) {
        if self.primary.isEmpty { return }
        let stanza = MessageStanzaStorageItem()
        stanza.set(messageId, for: owner, with: message.xmlString, at: date, primary: self.primary)
        do {
            let realm = try  WRealm.safe()
            if realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: stanza.primary) == nil {
                try realm.write {
                    realm.add(stanza, update: .modified)
                }
            }
        } catch {
            DDLogDebug("cant save message stanza for \(messageId)")
        }
    }
    
    internal func updateDisplayMode() {
        displayAs = .text
//        print(#function, self.references.toArray(), self.legacyBody, self.createReferences())
//        if !references.filter({ $0.kind == .call }).isEmpty {
//            displayAs = .call
//        } else if !references.filter({ $0.kind == .voice }).isEmpty {
//            if self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                if references.filter({ [.voice, .media].contains($0.kind) }).count == 1 {
//                    displayAs = .voice
//                } else {
//                    displayAs = .files
//                }
//            } else {
//                displayAs = .text
//            }
//            
//        } else if !references.filter({ [MimeIconTypes.file,
//                                        MimeIconTypes.archive,
//                                        MimeIconTypes.document,
//                                        MimeIconTypes.pdf,
//                                        MimeIconTypes.presentation,
//                                        MimeIconTypes.video,
//                                        MimeIconTypes.audio]
//            .map { return $0.rawValue}
//            .contains($0.mimeType) })
//            .isEmpty {
//            if self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                displayAs = .files
//            } else {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.mimeType == MimeIconTypes.image.rawValue }).isEmpty {
//            if references.filter({ $0.kind != .groupchat }).count == 1,
//                (references.filter({ $0.kind != .groupchat }).first?.metadata?["name"] as? String) == "Memoji" {
//                displayAs = .sticker
//            } else {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.mimeType == MimeIconTypes.file.rawValue }).isEmpty {
//            if references.filter({ $0.kind == .quote }).isEmpty {
//                displayAs = .text
//            }
//        } else if !references.filter({ $0.kind == .quote }).isEmpty {
//            displayAs = .quote
//        } else if !references.filter({ $0.kind == .systemMessage }).isEmpty {
//            displayAs = .system
//        }
    }

    
//    func configureInitialMessage(_ owner: String, opponent: String, conversationType: ClientSynchronizationManager.ConversationType, text: String?, date: Date, isRead: Bool) {
//        self.body = text ?? ""
//        self.owner = owner
//        self.opponent = opponent
//        self.date = date
//        self.isRead = isRead
//        self.outgoing = false
//        self.conversationType = conversationType
//        self.date = Date(timeIntervalSince1970: 0)
//        self.sentDate = date
//        self.messageId = MessageStorageItem.messageIdForInitial(jid: opponent, conversationType: conversationType)
//        self.displayAs = .initial
//        self.updatePrimary()
//    }
    
    func configureSystemMessage(_ messageContainer: XMPPMessage, owner: String, opponent: String, date: Date) {
        self.references.append(objectsIn: parseReferences(messageContainer, jid: opponent, owner: owner))
        self.legacyBody = messageContainer.body ?? ""
        self.body = messageContainer.body ?? ""
        self.systemMetadata = parseSystemMessageMetadata(messageContainer)
        self.owner = owner
        self.opponent = opponent
        self.displayAs = .system
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        self.previousId = getPreviousId(messageContainer)
        self.date = date
        self.sentDate = date
        self.outgoing = false
        self.conversationType = .group
        self.updatePrimary()
    }
    
    func editMessage(_ messageContainer: XMPPMessage, editDate: Date) {
        self.references.removeAll()
        self.references.append(objectsIn: parseReferences(messageContainer, jid: opponent, owner: owner))
        let groupchatRef = messageContainer
            .element(forName: "x",xmlns: "https://xabber.com/protocol/groups")?
            .element(forName: "reference",xmlns: "https://xabber.com/protocol/references")
        self.body = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(messageContainer.elements(forName: "reference"), groupchat: groupchatRef) ?? ""
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if messageContainer.from == nil {
            messageContainer.addAttribute(withName: "from", stringValue: outgoing ? owner : opponent)
        }
        self.inlineForwards.removeAll()
        self.inlineForwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: primary, jid: opponent, owner: owner))
        self.updateDisplayMode()
        self.editDate = editDate
        self.messageError = "Edit"
        if self.archivedId.isEmpty {
            self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        }
        self.originalStanza = messageContainer
    }
    
    func configureIncomingMessage(_ messageContainer: XMPPMessage, owner: String, opponent: String, outgoing: Bool, isRead: Bool, date: Date, isEncrypted: Bool = false) {
        self.references.append(objectsIn: parseReferences(messageContainer, jid: opponent, owner: owner))
        let groupchatRef = messageContainer
            .element(forName: "x",xmlns: "https://xabber.com/protocol/groups")?
            .element(forName: "reference",xmlns: "https://xabber.com/protocol/references")
        self.body = messageContainer
            .body?
            .xmlEscaping(reverse: false)
            .excludeFromBody(messageContainer.elements(forName: "reference"), groupchat: groupchatRef) ?? ""
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if messageContainer.from == nil {
            messageContainer.addAttribute(withName: "from", stringValue: outgoing ? owner : opponent)
        }
        if let editDate = messageContainer.element(forName: "replaced")?.attributeStringValue(forName: "stamp")?.xmppDate {
            self.editDate = editDate
            self.messageError = "Edit"
        }
        self.legacyBody = messageContainer.body ?? ""
        self.opponent = opponent
        self.owner = owner
        self.outgoing = outgoing
        self.isRead = isRead
        self.date = date
        self.sentDate = date
        self.messageId = getUniqueMessageId(messageContainer, owner: self.owner)
        self.archivedId = getStanzaId(messageContainer, owner: self.owner)
        self.previousId = getPreviousId(messageContainer)
        self.originalStanza = messageContainer
        
        self.conversationType = conversationTypeByMessage(messageContainer)
//        if isEncrypted {
//            self.conversationType = .omemo
//        }
        
//        if isEncrypted {
//            self.body = "Processing encrypted message..."
//            self.legacyBody = self.body
//            self.conversationType = .omemo
//        }
        
        updatePrimary()
        self.inlineForwards.append(objectsIn: parseInlineMessages(messageContainer, parentId: primary, jid: opponent, owner: owner))
        updateDisplayMode()
        self.references.forEach { $0.messageId = self.primary }
//        if self.displayAs == .text && self.createRefBody([:]).string.isEmpty {
//            self.isDeleted = true
//        }
        if !outgoing { return }
        do {
            let realm = try  WRealm.safe()
            self.groupchatCard = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isMe == true", [self.opponent, self.owner].prp()).first
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    func configureOutgoingMessage(_ body: String, legacy: String, messageId: String, owner: String, opponent: String, references: [MessageReferenceStorageItem], inlineForwards: [MessageForwardsInlineStorageItem]) {
        self.inlineForwards.append(objectsIn: inlineForwards)
        self.references.append(objectsIn: references)
        self.body = body
        self.legacyBody = legacy
        self.owner = owner
        self.opponent = opponent
        self.outgoing = true
        self.isRead = true
        self.messageId = messageId
        self.state = .notSended
        self.queryIds = "runtime_send"
        
        updatePrimary()
        updateDisplayMode()
        
        try? self.references.forEach {
            $0.messageId = self.primary
            $0.sentDate = Date()
            if CommonConfigManager.shared.config.use_file_enryption_by_default {
                
                if $0.conversationType.isEncrypted {
                    
                    var key = Data(count: 32)
                    
                    key.withUnsafeMutableBytes { (bytes) -> Void in
                        _ = SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
                    }
                    
                    let salt = Array<UInt8>(repeating: 0, count: 32)
                    
                    let hkdf = try HKDF(
                        password: key.bytes,
                        salt: salt,
                        info: Array("Files encryption".data(using: .utf8)!),
                        keyLength: key.bytes.count,
                        variant: .sha256
                    ).calculate()
                    
                    let encryptionKey: Array<UInt8> = Array(hkdf.prefix(16))
                    let iv: Array<UInt8> = Array(hkdf.suffix(16))
                    
                    $0.metadata?["encryption-key"] = encryptionKey.toBase64()
                    $0.metadata?["iv"] = iv.toBase64()
                }
            }
        }
        
        do {
            let realm = try WRealm.safe()
            self.groupchatCard = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isMe == true", [self.opponent, self.owner].prp()).first
            
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    func genBody(_ count: Int, name: String, verbose: String) -> String {
        if count == 1 {
            return name
        } else {
            return "\(count) \(verbose)"
        }
    }
    
    func configureAuthRequestMessage(withBody body: String, opponent: String, owner: String) {
        self.body = body
        self.opponent = opponent
        self.owner = owner
        self.isRead = true
        self.date = Date()
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.messageId = MessageStorageItem.messageIdForAuthRequest(jid: opponent)
        self.displayAs = .system
        self.sentDate = date
        self.outgoing = false
        self.state = .none
        self.systemMetadata = ["auth_message": true]
        self.updatePrimary()
    }
    
    func configureContactMessage(withBody body: String, opponent: String, owner: String) {
        self.body = body
        self.opponent = opponent
        self.owner = owner
        self.isRead = true
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.date = Date()
        self.messageId = MessageStorageItem.messageIdForContact(owner: owner,
                                                                jid: opponent,
                                                                ts: "\(self.date.timeIntervalSinceReferenceDate)")
        self.displayAs = .system
        self.primary = self.messageId
//        self.archivedId = MessageStorageItem.addContactLocalArchivedId
        self.displayAs = .system
        self.sentDate = date
        self.outgoing = false
        self.state = .none
    }
    
    enum VoIPCallState: String {
        case missed = "missed"
        case noanswer = "noanswer"
        case made = "made"
        case busy = "busy"
        case received = "received"
        case none = "none"
    }
    
    public final func configureVoIPCallMessage(opponent: String, owner: String, date: Date, isRead: Bool, callId: String, archivedId: String?, outgoing: Bool, duration: TimeInterval, callState: VoIPCallState) {
        self.opponent = opponent
        self.owner = owner
        self.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        self.messageId = MessageStorageItem.messageIdForVoIPCall(
            owner: owner,
            jid: opponent,
            callId: callId
        )
        self.primary = self.messageId
        self.date = date
        self.sentDate = date
        self.state = .none
        self.isRead = isRead
        self.outgoing = outgoing
        self.displayAs = .call
        if let archivedId = archivedId {
            self.archivedId = archivedId
        }
        let reference = MessageReferenceStorageItem()
        reference.messageId = self.messageId
        reference.primary = [owner, callId].prp()
        reference.owner = owner
        reference.kind = .call
        reference.metadata = [
            "duration": duration,
            "outgoing": outgoing,
            "callState": callState.rawValue,
            "date": date.timeIntervalSince1970
        ]
        self.references.removeAll()
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: reference.primary) {
                self.references.append(instance)
            } else {
                self.references.append(reference)
            }
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
        self.trustedSource = true
    }
    
    func isInStorage() -> Bool {
        do {
            let realm = try  WRealm.safe()
            return realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.primary) != nil
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
            return false
        }
    }
    
    public final func save(commitTransaction: Bool, silentNotifications: Bool = false) -> Bool {
//        print("BODY \(self.body)")
        if self.opponent.isEmpty {
            return false
        }
        if CommonConfigManager.shared.config.auto_delete_messages_interval > 0 {
            if self.date < Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(CommonConfigManager.shared.config.auto_delete_messages_interval)) {
                return false
            }
        }
        if let stanza = self.originalStanza {
            if let userCard = stanza
                .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
                .element(forName: "reference", xmlns: "https://xabber.com/protocol/references")?
                .element(forName: "user", xmlns: "https://xabber.com/protocol/groups") {
                self.groupchatCard = AccountManager
                    .shared
                    .find(for: owner)?
                    .groupchats
                    .updateUserCard(userCard,
                                    groupchat: opponent,
                                    trustedSource: false,
                                    messageAction: nil,
                                    commitTransaction: commitTransaction,
                                    cardDate: date)
            }
        }
        self.updatePrimary()
        do {
            let realm = try  WRealm.safe()
            
            func transaction(commit: Bool, callback: (() -> Void)) throws {
                if commit {
                    try realm.write {
                        callback()
                    }
                } else {
                    callback()
                }
            }
            
            if let instance = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: self.primary) {
                if self.trustedSource && !instance.trustedSource {
                    try transaction(commit: commitTransaction) {
                        if self.archivedId.isNotEmpty {
                            instance.archivedId = self.archivedId
                        }
                        instance.trustedSource = true//previousId = "id"//self.previousId
                        instance.previousId = self.previousId
                    }
                }
                try transaction(commit: commitTransaction) {
                    if (self.queryIds?.contains("history") ?? false) {
                        if let oldQueryIds = instance.queryIds {
                            if let newQueryIds = self.queryIds {
                                instance.queryIds = [oldQueryIds, newQueryIds].joined(separator: ",")
                            }
                        } else {
                            instance.queryIds = self.queryIds
                        }
                    }
                }
                return false
            } else {
                var notify: Bool = false
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: self.opponent,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                ) {
                    try transaction(commit: commitTransaction) {
                        if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int {
                            if instance.afterburnIntervalLastUpdate < self.date.timeIntervalSince1970 {
                                instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
                                instance.afterburnInterval = Double(timer)
                            }
                        } 
//                        else {
//                            if instance.afterburnInterval > 0 {
//                                if instance.afterburnIntervalLastUpdate < self.date.timeIntervalSince1970 {
//                                    instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
//                                    instance.afterburnInterval = Double(-1)
//                                }
//                            }
//                        }
                        if instance.isFreshNotEmptyEncryptedChat {
                            instance.isFreshNotEmptyEncryptedChat = false
                        }
                    }
                    if instance.lastMessage?.date ?? Date(timeIntervalSince1970: 1) > self.date {
                        self.isRead = true
                        if self.outgoing,
                            self.archivedId.isNotEmpty,
                            let timeInterval = TimeInterval(self.archivedId) {
                            if let delivered = instance.deliveredId,
                                let interval = TimeInterval(delivered),
                                interval > timeInterval {
                                self.state = .deliver
                            }
                            if let displayed = instance.displayedId,
                                let interval = TimeInterval(displayed),
                                interval > timeInterval {
                                self.state = .read
                            }
                        }
                        try transaction(commit: commitTransaction, callback: {
//                            instance.messagesCount += 1
                            realm.add(self, update: .modified)
                            
                            if let rosterItem = realm
                                .object(ofType: RosterStorageItem.self,
                                        forPrimaryKey: [self.opponent, owner].prp()) {
                                instance.rosterItem = rosterItem
                                
                            }
                        })
                    } else {
                        notify = true
                        
                        if instance.isArchived && !instance.isMuted {
                            instance.isArchived = false
                        }
                        
//                        let isFastSyncEnabled = false//SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: "version")?.isNotEmpty ?? false
                        
                        try transaction(commit: commitTransaction, callback: {
//                            instance.messagesCount += 1
                            instance.messageDate = self.sentDate
                            if !self.isDeleted {
                                instance.lastMessage = self
                            } else {
                                realm.add(instance)
                            }
                            instance.lastMessageId = self.messageId
                            if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int {
                                instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
                                instance.afterburnInterval = Double(timer)
                            } else {
//                                if instance.afterburnInterval > 0 && self.afterburnInterval < 1 {
//                                    instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
//                                    instance.afterburnInterval = 0
//                                } else 
                                if self.afterburnInterval > -1 && instance.afterburnIntervalLastUpdate < self.date.timeIntervalSince1970 {
                                    instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
                                    instance.afterburnInterval = self.afterburnInterval
                                }
                                
                            }
                            
                            if isInvite && !isRead {
                                if instance.rosterItem?.subscribtion != .both {
                                    instance.rosterItem?.ask = .in
                                }
                            }
                            
                            if !self.isRead && !self.outgoing && self.forceUnreadState == nil {
                                instance.unread += 1
                            } else if self.outgoing {
                                instance.unread = 0
                            }
                        })
                    }
                } else {
                    let instance = LastChatsStorageItem()
                    instance.jid = self.opponent
                    instance.conversationType = self.conversationType
                    instance.setPrimary(withOwner: owner)
                    var needGenAvatar: Bool = false
                    instance.messageDate = self.sentDate
                    instance.lastMessage = self
                    instance.isSynced = [.omemo, .omemo1, .axolotl].contains(self.conversationType)
                    instance.lastMessageId = self.messageId
                    
                    if let timer = self.references.first?.metadata?["ephemeral-timer"] as? Int {
                        instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
                        instance.afterburnInterval = Double(timer)
                    } else {
                        instance.afterburnIntervalLastUpdate = self.date.timeIntervalSince1970
                        instance.afterburnInterval = self.afterburnInterval
                    }
                    try transaction(commit: commitTransaction, callback: {
                        if instance.isInvalidated { return }
                        realm.add(instance, update: .modified)

                        if let rosterItem = realm
                            .object(ofType: RosterStorageItem.self,
                                    forPrimaryKey: [self.opponent, owner].prp()) {
                            instance.rosterItem = rosterItem
                            
                        } else {
//                            DefaultAvatarManager.shared.updateAvatar(jid: self.opponent, owner: self.owner)
                            let rosterItem = RosterStorageItem()
                            rosterItem.owner = self.owner
                            rosterItem.jid = self.opponent
                            rosterItem.subscribtion = .undefined
                            rosterItem.primary = RosterStorageItem.genPrimary(jid: self.opponent, owner: self.owner)
                            
                            if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.notInRosterGroupName, self.owner].prp()) {
                                if !group.contacts.contains(rosterItem) {
                                    group.contacts.append(rosterItem)
                                }
                            } else {
                                let group = RosterGroupStorageItem()
                                group.isSystemGroup = true
                                group.name = RosterGroupStorageItem.notInRosterGroupName
                                group.owner = owner
                                group.primary = RosterGroupStorageItem.genPrimary(name: RosterGroupStorageItem.notInRosterGroupName, owner: owner)
                                group.contacts.append(rosterItem)
                                realm.add(group, update: .modified)
                            }
                            
                            rosterItem.associatedLastChat = instance
                            realm.add(rosterItem, update: .modified)
                            instance.rosterItem = rosterItem
                            needGenAvatar = true
                        }
                    })
                    if needGenAvatar {
//                        DefaultAvatarManager.shared.updateAvatar(jid: self.opponent, owner: self.owner)
                    }
                }
                if !silentNotifications {
                    if self.date.timeIntervalSince1970 > (Date().timeIntervalSince1970 - 10) {
                        if notify && !self.isRead && !self.outgoing && self.archivedId.isNotEmpty && self.displayAs != .system {
//                            let imageUrl: String? = self.displayAs == .images ? references.filter({ $0.kind == .media }).first?.metadata?["uri"] as? String : nil
                            NotifyManager.shared.update(
                                withMessage: self.displayedBody(),
                                messageId: self.archivedId,
                                username: self.groupchatMetadata?["nickname"] as? String,
                                opponent: self.opponent,
                                owner: self.owner,
                                date: self.date,
                                displayName: realm
                                    .object(ofType: RosterStorageItem.self,
                                            forPrimaryKey: [self.opponent, owner].prp())?
                                    .displayName ?? self.opponent,
                                imageUrl: nil,//imageUrl,
                                conversationType: self.conversationType
                            )
                        }
                    }
                }
                realm.refresh()
                return true
            }
        } catch {
            DDLogDebug("MessageStorageItem: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    func createReferences() -> [DDXMLElement] {
        var out: [DDXMLElement] = []
        
        references.forEach {
            reference in
            let referenceElement = DDXMLElement(name: "reference",
                                                xmlns: "https://xabber.com/protocol/references")
            referenceElement.addAttribute(withName: "type", stringValue: reference.xmlType)
            referenceElement.addAttribute(withName: "begin", integerValue: reference.begin)
            referenceElement.addAttribute(withName: "end", integerValue: reference.end)
            switch reference.kind {
                case .media:
                    let fileSharing = DDXMLElement(name: "file-sharing",
                                                   xmlns: "https://xabber.com/protocol/files")
                    if let uri = reference.metadata?["uri"] as? String {
                        let sources = DDXMLElement(name: "sources")
                        sources.addChild(DDXMLElement(name: "uri", stringValue: uri))
                        fileSharing.addChild(sources)
                    }
                    let file = DDXMLElement(name: "file")
                    reference.metadata?.forEach {
                        if !["media-type", "name", "height", "width", "size", "desc", "duration", "hash", "orientation"].contains($0.key) { return }
                        if let value = $0.value as? String {
                            file.addChild(DDXMLElement(name: $0.key, stringValue: value))
                        } else if let value = $0.value as? Int {
                            file.addChild(DDXMLElement(name: $0.key, stringValue: "\(value)"))
                        }
                    }
                    if let iv = reference.metadata?["iv"] as? String,
                       let encryptionKey = reference.metadata?["encryption-key"] as? String {
                        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: "urn:xmpp:esfs:0")
                        let keyElement = DDXMLElement(name: "key")
                        keyElement.stringValue = encryptionKey
                        let ivElement = DDXMLElement(name: "iv")
                        ivElement.stringValue = iv
                        encryptedElement.addChild(keyElement)
                        encryptedElement.addChild(ivElement)
                        file.addChild(encryptedElement)
                    }
                    
                    fileSharing.addChild(file)
                    referenceElement.addChild(fileSharing)
                case .systemMessage:
                    let systemMessage = DDXMLElement(
                        name: "system-message",
                        xmlns: "https://xabber.com/protocol/system-message"
                    )
                    if let timer = reference.metadata?["ephemeral-timer"] as? Int {
                        let ephemeralElement = DDXMLElement(name: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")
                        ephemeralElement.addAttribute(withName: "timer", doubleValue: Double(timer))
                        systemMessage.addChild(ephemeralElement)
                    }
                    referenceElement.addChild(systemMessage)
                case .voice:
                    let voiceMessage = DDXMLElement(name: "voice-message",
                                                    xmlns: "https://xabber.com/protocol/voice-messages")
                    let fileSharing = DDXMLElement(name: "file-sharing",
                                                   xmlns: "https://xabber.com/protocol/files")
                    
                    if let uri = reference.metadata?["uri"] as? String {
                        let sources = DDXMLElement(name: "sources")
                        sources.addChild(DDXMLElement(name: "uri", stringValue: uri))
                        fileSharing.addChild(sources)
                    }
                    let file = DDXMLElement(name: "file")
                    
                    if let iv = reference.metadata?["iv"] as? String,
                       let encryptionKey = reference.metadata?["encryption-key"] as? String {
                        let encryptedElement = DDXMLElement(name: "encrypted", xmlns: "urn:xmpp:esfs:0")
                        let keyElement = DDXMLElement(name: "key")
                        keyElement.stringValue = encryptionKey
                        let ivElement = DDXMLElement(name: "iv")
                        ivElement.stringValue = iv
                        encryptedElement.addChild(keyElement)
                        encryptedElement.addChild(ivElement)
                        file.addChild(encryptedElement)
                    }
                    
                    file.addChild(DDXMLElement(name: "media-type", stringValue: "audio/ogg"))
                    file.addChild(DDXMLElement(name: "name", stringValue: "Voice message"))
                    file.addChild(DDXMLElement(name: "desc", stringValue: "Voice message"))
                    file.addChild(DDXMLElement(name: "duration", stringValue: "\(reference.duration ?? 0)"))
                    
                    if let url = reference.localFileUrl,
                       let data = try? Data(contentsOf: url) {
                        file.addChild(DDXMLElement(name: "size", stringValue: "\(data.bytes.count)"))
                        let hashed = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                        let hash = DDXMLElement(name: "hash", stringValue: hashed)
                        hash.setXmlns("urn:xmpp:hashes:2")
                        hash.addAttribute(withName: "algo", stringValue: "sha-256")
                        file.addChild(hash)
                    }
                    
                    file.addChild(DDXMLElement(name: "meters", stringValue: (reference.meteringLevels ?? []).compactMap({String($0)}).joined(separator: " ")))
    //                reference.metadata?.forEach {
    //                    if ["uriEmbded"].contains($0.key) { return }
    //                    if let value = $0.value as? String {
    //                        file.addChild(DDXMLElement(name: $0.key, stringValue: value))
    //                    } else if let value = $0.value as? Int {
    //                        file.addChild(DDXMLElement(name: $0.key, stringValue: "\(value)"))
    //                    }
    //                }
                    
                    fileSharing.addChild(file)
                    voiceMessage.addChild(fileSharing)
                    referenceElement.addChild(voiceMessage)
                    
                case .forward:
                    break
                case .markup:
                    break
                case .mention:
                    break
                case .quote:
                    break
                case .groupchat:
                    break
                case .call:
                    break
                case .none:
                    break
            }
            out.append(referenceElement)
        }
        
        return out
    }
    
    
    struct QuoteBodyItem {
        let body: NSAttributedString
        let isQuote: Bool
    }
    
    public final func createQuoteBody(_ attrs: [NSAttributedString.Key: Any]) -> [QuoteBodyItem] {
        let quoteRanges: [NSRange] = self.references
            .filter{ $0.kind == .quote }
            .compactMap { return $0.range }
            .sorted(by: { $0.lowerBound < $1.lowerBound })
        
        if quoteRanges.isEmpty {
            return []
        }
        
        let refBody = createRefBody(attrs)
        var ranges = quoteRanges
        if let first = quoteRanges.first?.lowerBound,
            first > 1 {
            ranges.append(NSRange(0..<first-1))
        }
        if let last = quoteRanges.last?.upperBound,
            last+1 < refBody.string.count {
            if refBody.string[String.Index(utf16Offset: last, in: refBody.string)] == "\n" {
                ranges.append(NSRange(last+1..<refBody.string.count))
            } else {
                ranges.append(NSRange(last..<refBody.string.count))
            }
        }
        
        if quoteRanges.count > 1 {
            quoteRanges.enumerated().forEach { (offset, element) in
                if offset >= quoteRanges.count - 1 { return }
                if quoteRanges[offset + 1].lowerBound != element.upperBound + 1,
                    element.upperBound+1 < quoteRanges[offset + 1].lowerBound-1 {
                    ranges.append(NSRange((element.upperBound+1)..<quoteRanges[offset + 1].lowerBound-1))
                }
            }
        }
        ranges = ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        return ranges.compactMap { (range) -> QuoteBodyItem? in
            let bodyCopy = NSMutableAttributedString(attributedString: refBody)
            if range.lowerBound != 0 {
                bodyCopy.deleteCharacters(in: NSRange(0..<range.lowerBound))
            }
            if (range.upperBound+1) != bodyCopy.string.count {
                bodyCopy.deleteCharacters(in: NSRange((range.length)..<(bodyCopy.string.count)))
            }
            return QuoteBodyItem(body: bodyCopy, isQuote: quoteRanges.contains(range))
        }
    }
    
    public final func createRefBody(_ attrs: [NSAttributedString.Key: Any], searchedText: String? = nil, searchedTextColor: UIColor? = nil) -> NSAttributedString {
        let string = NSMutableAttributedString(string: body.trimmingCharacters(in: .newlines))
//        let string = NSMutableAttributedString(string: "\(self.body), \(self.isRead), \(Date(timeIntervalSince1970: self.burnDate))")
        string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
//        paragraph.minimumLineHeight = 1.5
//        paragraph.maximumLineHeight = 1.5
        paragraph.lineSpacing = 1.5
        paragraph.allowsDefaultTighteningForTruncation = true
        for reference in references {
            if reference.end <= reference.begin { continue }
            if reference.end > body.count { continue }
            switch reference.kind {
            case .forward:
                break
            case .markup:
                if let styles = reference.metadata?["styles"] as? [String] {
                    for style in styles {
                        if style == "bold" {
                            string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).bold(), range: reference.range)
                        }
                        if style == "italic" {
                            if styles.contains("bold") {
                                string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).boldItalic(), range: reference.range)
                            } else {
                                string.addAttribute(NSAttributedString.Key.font, value: UIFont.systemFont(ofSize: 14, weight: .regular).italic(), range: reference.range)
                            }
                        }
                        if style == "underline" {
                            string.addAttribute(NSAttributedString.Key.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: reference.range)
                        }
                        if style == "strike" {
                            string.addAttribute(NSAttributedString.Key.strikethroughStyle, value: 1, range: reference.range)
//                            string.addAttribute(NSAttributedString.Key.strikethroughColor, value: MDCPalette.grey.tint900.cgColor, range: reference.range)
                        }
                        if style == "uri" {
                            if let url = reference.metadata?["uri"] as? String {
                                string.addAttribute(NSAttributedString.Key.link, value: url, range: reference.range)
                            }
                        }
                    }
                }
            case .mention:
                break
            case .quote:
                break
            case .groupchat:
                break
            default: break
            }
        }
        if let searchedText = searchedText {
            let range = (string.string as NSString).range(of: searchedText, options: [.caseInsensitive, .diacriticInsensitive])
            string.addAttribute(.backgroundColor, value: searchedTextColor ?? MDCPalette.blue.tint200, range: range)
        }
        string.addAttribute(NSAttributedString.Key.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        if string.string.starts(with: "\n") {
            string.deleteCharacters(in: NSRange(0..<"\n".count))
        }
        return string
    }
    
    open func createLegacyBody() {
        var out: String = legacyBody//.xmlEscaping(reverse: false)
//        print(legacyBody)
        references.forEach {
            reference in
            
            reference.owner = self.owner
            reference.jid = self.opponent
            reference.messageId = self.primary
            
            reference.begin = out.xmlEscaping(reverse: false).count
            switch reference.kind {
            case .media:
                out += "\(reference.metadata?["uri"] as? String ?? "")\n"
//                print("OUT: \(out)")
            case .voice:
                out += "Voice message (duration \(TimeInterval(reference.metadata?["duration"] as? Double ?? 0).minuteFormatedString) sec)\n\(reference.metadata?["uri"] as? String ?? "")\n"
            default: break
            }
            
            reference.end = out.xmlEscaping(reverse: false).count + 1
        }
//        out = [out, body].joined()
        references.forEach {
            reference in
            switch reference.kind {
            case .quote:
                out = body
                    .xmlEscaping(reverse: false)
                    .replacingOccurrences(of: "\n",
                                          with: "\n>".xmlEscaping(reverse: false),
                                          options: [],
                                          range: Range<String.Index>(NSRange(location: reference.begin,
                                                                             length: reference.end),
                                                                     in: body.xmlEscaping(reverse: false)))
            default: break
            }
        }
        legacyBody = out
    }
    
    
    public static func getGroupchatAuthorNickname(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return groupchatMetadata?["nickname"] as? String ?? groupchatMetadata?["jid"] as? String
    }
    
    public static func groupchatMessageAuthorJid(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return groupchatMetadata?["jid"] as? String
    }
    
    public static func groupchatMessageAuthorId(_ references: [MessageReferenceStorageItem]) -> String? {
        let groupchatMetadata = references.first(where: { $0.kind == .groupchat })?.metadata
        return groupchatMetadata?["id"] as? String
    }
}

extension UIFont {
    
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        let descriptor = self.fontDescriptor
            .withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits))
        return UIFont(descriptor: descriptor!, size: 0)
    }
    
    func boldItalic() -> UIFont {
        return withTraits(.traitBold, .traitItalic)
    }
    
    func bold() -> UIFont {
        return withTraits(.traitBold)
    }
    
    func italic() -> UIFont {
        return withTraits(.traitItalic)
    }
    
}
