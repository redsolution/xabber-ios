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

import UserNotifications
import SwiftKeychainWrapper
import KissXML
import CryptoSwift

class NotificationService: UNNotificationServiceExtension {
    static let suitName: String = "group.com.xabber.push"
    
    enum InviteKind: String {
        case group = "group"
        case incognito = "incognito"
        case peerToPeer = "peer-to-peer"
    }
    
    enum Actions: String {
        case message = "message"
        case marker = "displayed"
        case update = "update"
        case subscribe = "subscribe"
        case invite = "invite"
        case none = "none"
    }
    
    class PayloadData {
        
        struct StanzaId {
            let id: String
            let by: String
        }
        
        let actionElement: String
        let encrypted: String?
        
        /*
         <encrypted iv-length='16' xmlns='https://xabber.com/protocol/push'>FLseKbZ+lBteKbuakiw2e2YPtXGdbSNLkV1hXre2JrGswI7MX+4c79LjKr6gsXhKpYPgyiubH6mA/HFAvqIDaBvTgN1ewwsqdCzqV3rwGaPM1QkhkM76ZWycaURmVGdAhAc03stxtW6FdcAREZwAVQ==</encrypted><x type='result' xmlns='jabber:x:data'><field var='FORM_TYPE' type='hidden'><value>https://xabber.com/protocol/push#info</value></field><field var='type'><value>message</value></field></x>
         */
        init(_ body: String) {
            let documentBody = "<root>\(body)</root>"
            guard let document = try? DDXMLDocument(xmlString: documentBody, options: 0),
                  let root = document.rootElement(),
                  let encrypted = root.elements(forName: "encrypted").first?.xmlString,
                  let xForm = root.elements(forName: "x").first,
                  let action = xForm.elements(forName: "field").first(where: { $0.attribute(forName: "var")?.stringValue == "type"})?.elements(forName: "value").first?.stringValue else {
                fatalError()
            }
            self.encrypted = encrypted
            self.actionElement = action
        }
        
        var action: Actions {
            get {
                return Actions(rawValue: actionElement) ?? .none
            }
        }
        
        var rootElement: DDXMLElement? {
            get {
                guard let encrypted = encrypted,
                    let document = try? DDXMLDocument(xmlString: encrypted, options: 0),
                    let root = document.rootElement() else {
                        return nil
                }
                return root
            }
        }
        
        var iv: ArraySlice<UInt8>? {
            get {
                guard let encrypted = encrypted,
                    let document = try? DDXMLDocument(xmlString: encrypted, options: 0),
                    let root = document.rootElement(),
                    let encryptedStr = root.stringValue,
                    let data = Data(base64Encoded: encryptedStr, options: .ignoreUnknownCharacters),
                    let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                    let ivCount = Int(ivCountRaw),
                    ivCount < data.count else {
                    return nil
                }
                return data.bytes.prefix(upTo: ivCount)
            }
        }
        
        var encryptedData: Array<UInt8>? {
            get {
                guard let root = rootElement,
                    let encryptedStr = root.stringValue,
                    let data = Data(base64Encoded: encryptedStr),
                    let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                    let ivCount = Int(ivCountRaw),
                    ivCount < data.count else {
                    return nil
                }
                return Padding.zeroPadding.add(to: Array(data.bytes.suffix(from: ivCount)), blockSize: 16)
            }
        }
        
        var encryptedLen: Int {
            get {
                guard let root = rootElement,
                    let encryptedStr = root.stringValue,
                    let data = Data(base64Encoded: encryptedStr),
                    let ivCountRaw = root.attribute(forName: "iv-length")?.stringValue,
                    let ivCount = Int(ivCountRaw),
                    ivCount < data.count else {
                    return 0
                }
                return data.bytes.suffix(from: ivCount).count
            }
        }
        
        public func subscribtionRequestStanza(key: String) -> String? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let presenceElement = document.rootElement(),
                let presenceType = presenceElement.attribute(forName: "type")?.stringValue,
                presenceType == "subscribe" {
                return presenceElement.compactXMLString()
            }
            return nil
        }
        
        public func subscribtionRequestFrom(key: String) -> String? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let presenceElement = document.rootElement(),//?.elements(forName: "stanza-id").first,
                let from = presenceElement.attribute(forName: "from")?.stringValue,
                let presenceType = presenceElement.attribute(forName: "type")?.stringValue,
                presenceType == "subscribe" {
                return from
            }
            return nil
        }
        
        public func messageStanzaID(key: String) -> StanzaId? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let stanzaIdElement = document.rootElement(),//?.elements(forName: "stanza-id").first,
                let settedBy = stanzaIdElement.attribute(forName: "by")?.stringValue,
                let id = stanzaIdElement.attribute(forName: "id")?.stringValue {
                return StanzaId(id: id, by: settedBy)
            }
            return nil
        }
        
        public func updateStanzaID(key: String) -> StanzaId? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let stanzaIdElement = document.rootElement(),//?.elements(forName: "stanza-id").first,
                let settedBy = stanzaIdElement.attribute(forName: "by")?.stringValue,
                let id = stanzaIdElement.attribute(forName: "id")?.stringValue {
                return StanzaId(id: id, by: settedBy)
            }
            return nil
        }
        
        public func markerStanzaIDs(key: String, owner: String) -> [StanzaId] {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let displayedElement = document.rootElement() {
                return displayedElement
                    .elements(forName: "stanza-id")
                    .compactMap {
                        stanzaIdElement in
                        if let settedBy = stanzaIdElement.attribute(forName: "by")?.stringValue,
                            let id = stanzaIdElement.attribute(forName: "id")?.stringValue {
                            return StanzaId(id: id, by: settedBy)
                        }
                        return nil
                    }
            }
            return []
        }
        
        public func decrypt(by key: String) -> String? {
            do {
                guard let encrypted = encryptedData,
                    let iv = iv else {
                    return nil
                }
                let decrypted = try AES(key: Array(key.utf8),
                                        blockMode: CBC(iv: Array(iv)),
                                        padding: .zeroPadding).decrypt(encrypted)
//                print(decrypted)
//                print("decrypted:", String(bytes: decrypted.prefix(upTo: encryptedLen), encoding: .utf8))
                
//                print(decrypted)
//                print(String(bytes: decrypted.prefix(upTo: encryptedLen), encoding: .utf8))
                return String(bytes: decrypted.prefix(upTo: encryptedLen), encoding: .utf8)
            } catch {
//                print(error.localizedDescription)
            }
            return nil
        }
    }
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    var creditionals: [String: Any] = [:]
    var owner: String = ""
    var identifier: String = ""
    var deviceId: String? = nil
    
    var notificationType: Actions = .none
    
    var payload: String = ""
    
    var hasActiveSession: Bool = false
    
    var editMark: String = ""
    
    var ws: WebsocketManager? = nil
    var retryCount: Int = 0
    

    
    internal func getAccounts(_ payload: [AnyHashable: Any]) -> [String: Any] {
        func convertCredionals(_ text: String) -> [String: String]? {
            if let data = text.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String]
            }
            return nil
        }
        
        guard let target = payload["target"] as? String,
              let defaults  = UserDefaults.init(suiteName: NotificationService.suitName) else {
            return [:]
        }
        
        if let creditionals = defaults.dictionary(forKey: target) {
            self.creditionals = creditionals
            if let username = creditionals["username"] as? String,
                let host = creditionals["host"] as? String {
                hasActiveSession = defaults.bool(forKey: ["\(username)@\(host)", "state"].joined(separator: "_"))
            }
            return creditionals
        }
        
        
        return [:]
    }
    
    internal func updateActiveSession() {
        if let defaults  = UserDefaults.init(suiteName: NotificationService.suitName) {
            hasActiveSession = defaults.bool(forKey: [owner, "state"].joined(separator: "_"))
        }
    }
    
    internal func parse(payload: String) -> PayloadData? {
//        guard let JSONData = base64EncodedString.data(using: .utf8) else {//.fromBase64()?.data(using: .utf8) else {
//            return nil
//        }
//        return try? JSONDecoder().decode(PayloadData.self, from: JSONData)
        return PayloadData(payload)
    }
    
    private func retrieveCreditionals(for key: String) -> String? {
//        let uniqueServiceName = "clandestino.keychain"
//        let uniqueAccessGroup = "group.clandestino"
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        return keychain.string(forKey: key)
//        return nil
    }
    
    var pushData: CredentialsManager.PushSecretData? = nil
    
    func loadCredentials(for node: String, payload: PayloadData, retry: Int = 0) {
        do {
            let pushSecrets = try CredentialsManager.staticGetPushCredentials(for: node)
            self.owner = pushSecrets.jid
            self.pushData = pushSecrets
            self.deviceId = CredentialsManager.getXabberDeviceId(for: self.owner)
            self.notificationType = payload.action
            self.action(for: payload)
        } catch {
            if retry > 100 {
                if let bestAttemptContent = bestAttemptContent {
                    bestAttemptContent.title = CommonConfigManager.shared.config.app_name
                    bestAttemptContent.body = "node:\(node), bad secret: \(error)"
                    self.contentHandler?(bestAttemptContent)
                }
                return
            } else {
                self.loadCredentials(for: node, payload: payload, retry: retry + 1)
            }
            
        }
    }
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
//        print(request)
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        identifier = request.identifier
        bestAttemptContent?.sound = .default
        bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
        bestAttemptContent?.body = "New message"
//        contentHandler(bestAttemptContent!)
//        return
        payload = "\(request.content.userInfo)"
//        print(payload)
//        print(bestAttemptContent)

        if let bestAttemptContent = bestAttemptContent {
            guard let body = request.content.userInfo["body"] as? String,
                let payload = parse(payload: body) else {
                bestAttemptContent.title = CommonConfigManager.shared.config.app_name
                bestAttemptContent.body = "fail to parse"
                contentHandler(bestAttemptContent)
                return
            }
            
            guard let node = request.content.userInfo["target"] as? String else {
                bestAttemptContent.title = CommonConfigManager.shared.config.app_name
                bestAttemptContent.body = "bad node: \(request.content.userInfo["target"] as? String ?? "")"
                contentHandler(bestAttemptContent)
                return
            }
            self.loadCredentials(for: node, payload: payload)
            
        } else {
            return
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttemptContent {
            contentHandler?(content)
        }
    }
    
    internal func action(for payload: PayloadData) {
        switch payload.action {
        case .message: onMessage(payload)
        case .marker: onMarker(payload)
        case .update: onUpdate(payload)
        case .subscribe: onSubscribe(payload)
        case .invite: onMessage(payload)
        case .none: onHide(payload)
        }
    }
    
    internal func onHide(_ payload: PayloadData) {
        bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
        bestAttemptContent?.body = "New \(payload.action.rawValue)"
        contentHandler?(bestAttemptContent!)
    }
    
    internal func onMessage(_ payload: PayloadData) {
        guard let pushData = self.pushData else {
            bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent?.body = "ERROR \(payload.action.rawValue)"
            contentHandler?(bestAttemptContent!)
            return
        }
        let hotp = HOTPAuth(jid: owner)
        let token = hotp.getTOTPValueForTest()
        let stanzaId = payload.messageStanzaID(key: pushData.secret)
        let remoteArchiveJid = stanzaId?.by == pushData.jid ? nil : stanzaId?.by
        let manager = NetworkManager(
            service: pushData.service,
            jid: pushData.jid,
            deviceId: self.deviceId ?? "",
            token: token!
        )
        manager.delegate = self
        manager.getMessage(host: pushData.host, messageId: stanzaId!.id, by: remoteArchiveJid)
    }
    
    internal func onSubscribe(_ payload: PayloadData) {
        bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
        if let from = payload.subscribtionRequestFrom(key: pushData?.secret ?? "") {
            bestAttemptContent?.body = "Incoming chat request from \(from)"
        } else {
            bestAttemptContent?.body = "Incoming chat request"
        }
        contentHandler?(bestAttemptContent!)
        return
//        guard password.isNotEmpty || token.isNotEmpty,
//            let content = self.bestAttemptContent,
//            let secret = creditionals["secret"] as? String else {
//            bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
//            bestAttemptContent?.body = "Incoming chat request"
//            contentHandler?(bestAttemptContent!)
//            return
//        }
//        guard let from = payload.subscribtionRequestFrom(key: secret) else {
////            content.subtitle = "Error on decrypt"
//            contentHandler?(content)
//            return
//        }
////        if let stanza = payload.subscribtionRequestStanza(key: secret) {
////            let defaults  = UserDefaults.init(suiteName: NotificationService.suitName)
////            var stanzas: [String] = defaults?.object(forKey: "com.xabber.presences.temporary.\(owner)") as? [String] ?? []
////            stanzas.append(stanza)
////            defaults?.set(stanzas, forKey: "com.xabber.presences.temporary.\(owner)")
////        }
//        ws = WebsocketManager(
//            self.owner,
//            resource: self.creditionals["resource"] as? String ?? "xabber-push-service",
//            password: password,
//            token: "",//token,
//            stanzaId: nil,
//            websocketUrl: creditionals["websocket_url"] as? String,
//            remoteArchiveJid: nil,
//            isVcardRequest: true,
//            vcardJid: from
//        )
//        ws?.connect()
//        ws?.delegate = self
        
    }
    
    internal func onMarker(_ payload: PayloadData) {
        bestAttemptContent?.title = " "
        bestAttemptContent?.body = ""
        bestAttemptContent?.subtitle = ""
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter
            .current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        if let content = bestAttemptContent {
            content.body = self.payload
            content.subtitle = "Chat marker"//.localizeString(id: "chat_marker", arguments: [])
            contentHandler?(content)
        }
    }
    
    internal func onMarkerSmart(_ payload: PayloadData) {
        guard let secret = creditionals["secret"] as? String else {
            bestAttemptContent?.title = "Xabber"
            bestAttemptContent?.body = "New \(payload.action.rawValue)"
            contentHandler?(bestAttemptContent!)
            return
        }
        
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        
        self.contentHandler = nil
        
        let stanzaIds = payload.markerStanzaIDs(key: secret, owner: owner)
        
        UNUserNotificationCenter.current().getDeliveredNotifications { (notifications) in
            stanzaIds.forEach {
                stanzaId in
                if let userInfo = notifications.first(where: { return $0.request.content.userInfo["stanzaId"] as? String == stanzaId.id })?.request.content.userInfo,
                    let timestamp = userInfo["timestamp"] as? TimeInterval,
                    let jid = userInfo["jid"] as? String,
                    let owner = userInfo["owner"] as? String {
                    UNUserNotificationCenter
                        .current()
                        .removeDeliveredNotifications(
                            withIdentifiers: notifications
                                .filter({ $0.request.content.userInfo["jid"] as? String == jid && $0.request.content.userInfo["owner"] as? String == owner })
                                .filter({ $0.request.content.userInfo["timestamp"] as? TimeInterval ?? 0 <= timestamp })
                                .compactMap({ $0.request.identifier })
                    )
                }
            }
        }
    }
    
    internal func onUpdate(_ payload: PayloadData) {
        self.editMark = "✏️"
        guard let pushData = self.pushData else {
            bestAttemptContent?.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent?.body = "ERROR \(payload.action.rawValue)"
            contentHandler?(bestAttemptContent!)
            return
        }
        let hotp = HOTPAuth(jid: owner)
        let token = hotp.getTOTPValueForTest()
        let stanzaId = payload.messageStanzaID(key: pushData.secret)
        let remoteArchiveJid = stanzaId?.by == pushData.jid ? nil : stanzaId?.by
        UNUserNotificationCenter
            .current()
            .getDeliveredNotifications { (notifications) in
                if let identifier = notifications
                    .first(where: { return $0.request.content.userInfo["stanzaId"] as? String == stanzaId?.id })?
                    .request
                    .identifier {
                        UNUserNotificationCenter
                            .current()
                            .removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            }
        let manager = NetworkManager(
            service: pushData.service,
            jid: pushData.jid,
            deviceId: self.deviceId ?? "",
            token: token!
        )
        manager.delegate = self
        manager.getMessage(host: pushData.host, messageId: stanzaId!.id, by: remoteArchiveJid)
    }
}

extension NotificationService: PushPayloadDelegate {
    func didReceiveSync(stanza: String) {
        let defaults  = UserDefaults.init(suiteName: NotificationService.suitName)
        defaults?.set(stanza, forKey: "com.xabber.sync.temporary.\(owner)")
    }
    
    func didDisconnectWithError(_ error: String) {
//        if retryCount < 5 {
//            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
//                self.ws?.connect()
//                self.retryCount += 1
//            }
//        } else {
            if let bestAttemptContent = bestAttemptContent {
                bestAttemptContent.body = error
                bestAttemptContent.title = "st4"//.localizeString(id: "new_chat_messages", arguments: [])
//                if owner.isNotEmpty {
//                    bestAttemptContent.body = "To \(self.owner)"
//                }
                contentHandler?(bestAttemptContent)
            }
//        }
    }
    
    private final func updateContentFor(message payload: [String : String]) {
        if let bestAttemptContent = bestAttemptContent {
            bestAttemptContent.userInfo["timestamp"] = Date().timeIntervalSinceReferenceDate
            if let stanzaId = payload["stanzaId"] {
                bestAttemptContent.userInfo["stanzaId"] = stanzaId
                UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                    if notifications
                        .first(where: { $0.request.content.userInfo["stanzaId"] as? String == stanzaId }) != nil {
                        self.contentHandler = nil
                        UNUserNotificationCenter
                            .current()
                            .removePendingNotificationRequests(withIdentifiers: [self.identifier])
                    }
                }
            }
            if payload["invite"] != nil {
                self.notificationType = .invite
                var inviteKind: InviteKind = .group
                if let kind = payload["invite_kind"] {
                    inviteKind = InviteKind(rawValue: kind) ?? .group
                    bestAttemptContent.userInfo["invite_kind"] = inviteKind.rawValue
                }
                if let from = payload["from"],
                   let inviteToJid = payload["invite_to_jid"] {
                    var displayName: String = from
//                    let realm = try? Realm(configuration: realmConfig)
//                    if let instance = realm?.object(ofType: RosterDisplayNameStorageItem.self,
//                                                   forPrimaryKey: [from, owner].joined(separator: "_")) {
//                        displayName = instance.displayName
//                    }
                    bestAttemptContent.title = inviteToJid
                    switch inviteKind {
                    case .group:
                        bestAttemptContent.body = "Invitation to public group from \(displayName)"//.localizeString(id: "public_group_invitation", arguments: ["\(displayName)"])
                    case .incognito:
                        bestAttemptContent.body = "Invitation to incognito group from \(displayName)"//.localizeString(id: "incognito_group_invitation", arguments: [])
                    case .peerToPeer:
                        bestAttemptContent.body = "Invitation to private chat"//.localizeString(id: "chat_message_private_invitation", arguments: [])
                    }
                    self.bestAttemptContent = bestAttemptContent
                    self.ws?.prevPayload = payload
                    _ = self.ws?.getVCard(jid: inviteToJid)
                    self.notificationType = .invite
                    return
                }
                self.bestAttemptContent = bestAttemptContent
            } else {
                if let body = payload["body"] {
                    bestAttemptContent.body = body
                }
                if let nickname = payload["nickname"] {
                    if editMark.isNotEmpty {
                        
                    } else {
                        bestAttemptContent.subtitle = ["💨", nickname].joined(separator: " ")
                    }
                    bestAttemptContent.subtitle = nickname
                }
                if let groupchatFrom = payload["groupchatFrom"] {
                    if groupchatFrom == owner {
                        bestAttemptContent.subtitle = "Group carbons"//.localizeString(id: "group_carbons", arguments: [])
                    }
                }
                if let from = payload["from"] {
                    bestAttemptContent.userInfo["jid"] = from
                    bestAttemptContent.userInfo["owner"] = owner
                    bestAttemptContent.threadIdentifier = [owner, from].joined(separator: "_")
                    if from == owner {
                        bestAttemptContent.subtitle = "Carbon message"//.localizeString(id: "carbon_message", arguments: [])
                    }
                    bestAttemptContent.title = from
//                    do {
//                        let realm = try Realm(configuration: realmConfig)
//                        if let instance = realm.object(ofType: RosterDisplayNameStorageItem.self,
//                                                       forPrimaryKey: [from, owner].joined(separator: "_")) {
//                            bestAttemptContent.title = instance.displayName
//                        } else {
//                            bestAttemptContent.title = from
//                        }
//                    } catch {
                        bestAttemptContent.title = from
//                    }
                    if editMark.isNotEmpty {
                        bestAttemptContent.title = [editMark, bestAttemptContent.title].joined(separator: " ")
                    } else {
                        bestAttemptContent.title = ["💨", bestAttemptContent.title].joined(separator: " ")
                    }
                }
                if let imageUrls = payload["imageUrls"] {
                    let urls = imageUrls
                        .split(separator: " ")
                        .compactMap{ return "\($0)" }
                        .compactMap{ return URL(string: $0) }
                    let attaches = urls.compactMap { url -> UNNotificationAttachment? in
//                        `if let data = try? Data(contentsOf: url),
//                            let image = UIImage(data: data) {
//                            return UNNotificationAttachment(
//                                identifier: url.lastPathComponent,
//                                image: image,
//                                options: nil
//                            )
//                        }`
                        return nil
                    }
                    bestAttemptContent.attachments = attaches
                }
                
                bestAttemptContent.sound = .default
                bestAttemptContent.categoryIdentifier = "com.xabber.ios.message.push"
                
//                if let stanza = payload["stanza"] {
//                    let defaults  = UserDefaults.init(suiteName: NotificationService.suitName)
//                    var stanzas: [String] = defaults?.object(forKey: "com.xabber.messages.temporary.\(owner)") as? [String] ?? []
//                    stanzas.append(stanza)
//                    defaults?.set(stanzas, forKey: "com.xabber.messages.temporary.\(owner)")
//                    bestAttemptContent.userInfo["stanza"] = stanza
//                }
                bestAttemptContent.badge = 0
                self.ws?.closeSocket()
//                print(bestAttemptContent.userInfo)
                contentHandler?(bestAttemptContent)
            }
        } else {
            self.contentHandler = nil
            UNUserNotificationCenter
                .current()
                .removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter
                .current()
                .removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }
    
    private final func updateContentFor(invite payload: [String : String]) {
        guard let content = bestAttemptContent else {
            self.contentHandler?(bestAttemptContent!)
            return
        }
        if let nickname = payload["nickname"] {
            content.title = nickname
        }
        if let from = payload["invite_to_jid"] {
            content.userInfo["jid"] = from
            content.userInfo["owner"] = owner
        }
        
        content.categoryIdentifier = "com.xabber.ios.invite"
        content.sound = .default
        if let base64String = payload["avatarBase64"] {
//            if let image = base64ToImage(base64String),
//                let attach = UNNotificationAttachment(
//                    identifier: payload["nickname"] ?? payload["from"] ?? "avatar",
//                    image: image,
//                    options: nil
//                ) {
//                content.attachments = [attach]
//            }
        }
        self.contentHandler?(content)
    }
    
    private final func updateContentFor(subscribtion payload: [String : String]) {
        /*
         if let avatarBase64String = vcard.elements(forName: "PHOTO").first?.elements(forName: "BINVAL").first?.stringValue {
             payload["avatarBase64"] = avatarBase64String
         }
         */
        guard let content = bestAttemptContent else {
            return
        }
        var nickname = payload["nickname"]
        if nickname == nil {
            nickname = [payload["given"], payload["family"]]
                .compactMap({ return $0 })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if nickname?.isEmpty ?? false {
                nickname = nil
            }
        }
        if nickname == nil {
            nickname = payload["fn"]
        }
        if nickname == nil {
            nickname = payload["from"]
        }
        content.title = ""
        content.subtitle = "PUSH"
        if let nickname = nickname,
            let from = payload["from"] {
            content.body = "\(nickname) (\(from)) asks to see your presence information"//.localizeString(id: "chat_contact_asks_presence_information", arguments: ["\(nickname)", "\(from)"])
        } else {
            content.body = "\(payload["from"] ?? "Someone") asks to see your presence information"//.localizeString(id: "person_asks_to_see_presence", arguments: ["\(payload["from"] ?? "Someone")"])
        }
        
        content.userInfo["owner"] = owner
        if let from = payload["from"] {
            content.userInfo["jid"] = from
            content.categoryIdentifier = "com.xabber.ios.subscribtion"
            content.sound = .default
        }
        
        if let base64String = payload["avatarBase64"] {
//            if let image = base64ToImage(base64String),
//                let attach = UNNotificationAttachment(
//                    identifier: payload["nickname"] ?? payload["from"] ?? "avatar",
//                    image: image,
//                    options: nil
//                ) {
//                content.attachments = [attach]
//            }
        }
        
        content.sound = .default
        self.contentHandler?(content)
    }
    
    func didUpdateContent(payload: [String : String]) {
//        print(#function, notificationType, payload)
        switch notificationType {
        case .invite: updateContentFor(invite: payload)
        case .message: updateContentFor(message: payload)
        case .subscribe: updateContentFor(subscribtion: payload)
        case .update: updateContentFor(message: payload)
        default:
            self.contentHandler = nil
            UNUserNotificationCenter
                .current()
                .removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter
                .current()
                .removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }
}
