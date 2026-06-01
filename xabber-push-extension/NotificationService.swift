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
import Intents

class NotificationService: UNNotificationServiceExtension {
    static let suitName: String = "group.com.xabber"
    private static let maxCredentialRetryCount = 5
    private static let credentialRetryDelay: TimeInterval = 0.1
    
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
        init?(_ body: String) {
            let documentBody = "<root>\(body)</root>"
            guard let document = try? DDXMLDocument(xmlString: documentBody, options: 0),
                  let root = document.rootElement(),
                  let encrypted = root.elements(forName: "encrypted").first?.xmlString,
                  let xForm = root.elements(forName: "x").first,
                  let action = xForm.elements(forName: "field").first(where: { $0.attribute(forName: "var")?.stringValue == "type"})?.elements(forName: "value").first?.stringValue else {
                return nil
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
        
        public func decryptedPayload(key: String) -> String? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let rootElement = document.rootElement()?.stringValue {
                return rootElement
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
    var bestAttemptContent: UNMutableNotificationContent = UNMutableNotificationContent()
    private let completionQueue = DispatchQueue(label: "com.xabber.notification-service.completion")
    private var didCompleteContent = false
    
    var creditionals: [String: Any] = [:]
    var owner: String = ""
    var identifier: String = ""
    var deviceId: String? = nil
    
    var notificationType: Actions = .none
    
    var payload: String = ""
    
    var hasActiveSession: Bool = false
    
    var editMark: String = ""
    
    var retryCount: Int = 0
    

    private func completeContent(_ content: UNNotificationContent) {
        var handler: ((UNNotificationContent) -> Void)?
        completionQueue.sync {
            guard !didCompleteContent else {
                return
            }
            didCompleteContent = true
            handler = contentHandler
            contentHandler = nil
        }
        handler?(content)
    }

    internal func getAccounts(_ payload: [AnyHashable: Any]) -> [String: Any] {
        func convertCredionals(_ text: String) -> [String: String]? {
            if let data = text.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String]
            }
            return nil
        }
        
        guard let target = payload["target"] as? String,
              let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) else {
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
        if let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
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
            if retry >= Self.maxCredentialRetryCount {
                fallbackVisibleNotification(for: payload.action, reason: "credentials unavailable")
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.credentialRetryDelay) {
                    self.loadCredentials(for: node, payload: payload, retry: retry + 1)
                }
            }
        }
    }
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        print("NOTIFICATIONREC", request)
        self.contentHandler = contentHandler
        guard let bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent) else {
            completeContent(request.content)
            return
        }
        identifier = request.identifier
        self.bestAttemptContent = bestAttemptContent
        self.bestAttemptContent.sound = .default
        self.bestAttemptContent.title = CommonConfigManager.shared.config.app_name
        self.bestAttemptContent.body = "New message"
        guard let body = bestAttemptContent.userInfo["body"] as? String,
            let payload_decoded = parse(payload: body) else {
            self.bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            self.bestAttemptContent.body = "fail to parse"
            completeContent(bestAttemptContent)
            return
        }
        
        guard let node = bestAttemptContent.userInfo["target"] as? String else {
            bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent.body = "bad node: \(request.content.userInfo["target"] as? String ?? "")"
            completeContent(bestAttemptContent)
            return
        }
        self.loadCredentials(for: node, payload: payload_decoded)
//        self.action(for: payload_decoded)
    }
    
    override func serviceExtensionTimeWillExpire() {
        completeContent(bestAttemptContent)
    }
    
    internal func action(for payload: PayloadData) {
        switch payload.action {
        case .message:      onMessage(payload)
        case .marker:       onMarker(payload)
        case .update:       onUpdate(payload)
        case .subscribe:    onSubscribe(payload)
        case .invite:       onMessage(payload)
        case .none:         onHide(payload)
        }
    }
    
    internal func onHide(_ payload: PayloadData) {
        bestAttemptContent.title = CommonConfigManager.shared.config.app_name
        bestAttemptContent.body = "New \(payload.action.rawValue)"
        completeContent(bestAttemptContent)
    }

    private func fallbackVisibleNotification(for action: Actions, reason: String? = nil) {
        bestAttemptContent.title = CommonConfigManager.shared.config.app_name
        switch action {
        case .update, .message, .invite:
            bestAttemptContent.body = "New message"
        case .subscribe:
            bestAttemptContent.body = "Incoming chat request"
        case .marker, .none:
            bestAttemptContent.body = reason ?? ""
        }
        if action == .marker {
            suppressCurrentNotification()
        } else {
            completeContent(bestAttemptContent)
        }
    }

    private func suppressCurrentNotification() {
        bestAttemptContent.title = " "
        bestAttemptContent.body = ""
        bestAttemptContent.subtitle = ""
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        completeContent(bestAttemptContent)
    }
    
    internal func onMessage(_ payload: PayloadData) {
        guard let pushData = self.pushData else {
            fallbackVisibleNotification(for: payload.action, reason: "missing push data")
            return
        }
        guard let stanzaId = payload.messageStanzaID(key: pushData.secret) else {
            fallbackVisibleNotification(for: payload.action, reason: "missing stanza id")
            return
        }
        let remoteArchiveJid = stanzaId.by == pushData.jid ? nil : stanzaId.by
        guard let manager = NetworkManager(
            service: pushData.service,
            jid: pushData.jid,
            jwt: pushData.jwt
        ) else {
            fallbackVisibleNotification(for: payload.action, reason: "invalid archive service")
            return
        }
        manager.delegate = self
        manager.getMessage(host: pushData.host, messageId: stanzaId.id, by: remoteArchiveJid)
    }
    
    internal func onSubscribe(_ payload: PayloadData) {
        guard let from = payload.subscribtionRequestFrom(key: pushData?.secret ?? "")?.split(separator: "/").first.map(String.init) else {
            bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent.body = "Incoming chat request"
            completeContent(bestAttemptContent)
            return
        }
        let metadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: from)
        let route = PushNotificationRoutePayload.subscriptionRequest(
            owner: owner,
            contactJid: from,
            nickname: metadata.username
        )
        renderSubscriptionRequest(route: route, displayName: metadata.username ?? from)
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
        suppressCurrentNotification()
    }
    
    internal func onMarkerSmart(_ payload: PayloadData) {
        guard let secret = creditionals["secret"] as? String else {
            bestAttemptContent.title = "Xabber"
            bestAttemptContent.body = "New \(payload.action.rawValue)"
            completeContent(bestAttemptContent)
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
            fallbackVisibleNotification(for: payload.action, reason: "missing push data")
            return
        }
        guard let stanzaId = payload.messageStanzaID(key: pushData.secret) else {
            fallbackVisibleNotification(for: payload.action, reason: "missing stanza id")
            return
        }
        let remoteArchiveJid = stanzaId.by == pushData.jid ? nil : stanzaId.by
        UNUserNotificationCenter
            .current()
            .getDeliveredNotifications { (notifications) in
                if let identifier = notifications
                    .first(where: { return $0.request.content.userInfo["stanzaId"] as? String == stanzaId.id })?
                    .request
                    .identifier {
                        UNUserNotificationCenter
                            .current()
                            .removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            }
        guard let manager = NetworkManager(
            service: pushData.service,
            jid: pushData.jid,
            jwt: pushData.jwt
        ) else {
            fallbackVisibleNotification(for: payload.action, reason: "invalid archive service")
            return
        }
        manager.delegate = self
        manager.getMessage(host: pushData.host, messageId: stanzaId.id, by: remoteArchiveJid)
    }
}

extension NotificationService: PushPayloadDelegate {
    func didReceiveSync(stanza: String) {
        let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup())
        defaults?.set(stanza, forKey: "com.xabber.sync.temporary.\(owner)")
    }
    
    func didDisconnectWithError(_ error: String) {
        bestAttemptContent.title = CommonConfigManager.shared.config.app_name
        bestAttemptContent.body = "New message"
        completeContent(bestAttemptContent)
    }

    func didUpdateContent(preview: PushNotificationPreview) async {
        switch preview.route.kind {
        case .message:
            await renderMessage(preview)
        case .groupInvite:
            renderGroupInvite(preview)
        case .verificationRequest:
            renderVerificationRequest(preview)
        case .subscriptionRequest:
            renderSubscriptionRequest(
                route: preview.route,
                displayName: preview.route.senderNickname ?? preview.route.routeJid ?? "Someone"
            )
        }
    }

    private final func applyRoute(_ route: PushNotificationRoutePayload) {
        let timestamp = Date().timeIntervalSinceReferenceDate
        route.userInfo(timestamp: timestamp).forEach {
            bestAttemptContent.userInfo[$0.key] = $0.value
        }
        if let stanzaId = route.stanzaId {
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                if notifications.first(where: { $0.request.content.userInfo["stanzaId"] as? String == stanzaId }) != nil {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [self.identifier])
                }
            }
        }
    }

    private final func renderMessage(_ preview: PushNotificationPreview) async {
        guard let routeJid = preview.route.routeJid else {
            bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent.body = preview.body
            completeContent(bestAttemptContent)
            return
        }

        applyRoute(preview.route)
        bestAttemptContent.categoryIdentifier = PushNotificationCategory.pushMessage
        bestAttemptContent.sound = .default
        bestAttemptContent.body = preview.body
        bestAttemptContent.attachments = await imageAttachments(for: preview.imageURLs)

        let isGroup = preview.route.groupchat != nil || preview.route.conversationType == "group"
        let routeMetadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: routeJid)
        let routeDisplayName = routeMetadata.username ?? preview.groupName ?? routeJid
        let senderDisplayName = isGroup
            ? (preview.route.senderNickname ?? preview.route.senderJid ?? routeDisplayName)
            : (routeMetadata.username ?? routeJid)
        let conversationId = "xabber:\(owner.lowercased()):\(routeJid.lowercased())"

        bestAttemptContent.threadIdentifier = conversationId
        bestAttemptContent.title = isGroup ? routeDisplayName : senderDisplayName
        bestAttemptContent.subtitle = isGroup ? senderDisplayName : editMark
        if !editMark.isEmpty {
            bestAttemptContent.subtitle = [editMark, bestAttemptContent.subtitle].filter { !$0.isEmpty }.joined(separator: " ")
        }

        let handleValue = isGroup
            ? (preview.route.senderJid ?? preview.route.senderNickname ?? routeJid)
            : routeJid
        let sender = INPerson(
            personHandle: INPersonHandle(value: handleValue, type: .unknown),
            nameComponents: nil,
            displayName: senderDisplayName,
            image: intentImage(avatarURL: routeMetadata.avatarUrl),
            contactIdentifier: routeMetadata.contactID,
            customIdentifier: nil
        )
        let groupName = isGroup ? INSpeakableString(spokenPhrase: routeDisplayName) : nil
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: preview.body,
            speakableGroupName: groupName,
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            let updatedContent = try bestAttemptContent.updating(from: intent)
            completeContent(updatedContent)
        } catch {
            completeContent(bestAttemptContent)
        }
    }

    private final func renderGroupInvite(_ preview: PushNotificationPreview) {
        applyRoute(preview.route)
        guard let groupchat = preview.route.groupchat ?? preview.route.routeJid else {
            bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            bestAttemptContent.body = preview.body
            completeContent(bestAttemptContent)
            return
        }
        let groupMetadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: groupchat)
        let inviterName = preview.route.inviterNickname
            ?? preview.route.senderNickname
            ?? preview.route.inviterJid
            ?? preview.route.senderJid
        let groupName = groupMetadata.username ?? preview.groupName ?? groupchat
        bestAttemptContent.title = groupName
        if let inviterName {
            bestAttemptContent.subtitle = inviterName
            bestAttemptContent.body = "\(preview.body) from \(inviterName)"
        } else {
            bestAttemptContent.body = preview.body
        }
        bestAttemptContent.categoryIdentifier = PushNotificationCategory.invite
        bestAttemptContent.sound = .default
        completeContent(bestAttemptContent)
    }

    private final func renderSubscriptionRequest(route: PushNotificationRoutePayload, displayName: String) {
        applyRoute(route)
        let jid = route.routeJid ?? displayName
        bestAttemptContent.title = displayName
        bestAttemptContent.subtitle = jid == displayName ? "" : jid
        bestAttemptContent.body = "\(displayName) asks to see your presence information"
        bestAttemptContent.categoryIdentifier = PushNotificationCategory.subscription
        bestAttemptContent.sound = .default
        completeContent(bestAttemptContent)
    }

    private final func renderVerificationRequest(_ preview: PushNotificationPreview) {
        applyRoute(preview.route)
        let sender = preview.route.senderNickname ?? preview.route.senderJid ?? "Somebody"
        bestAttemptContent.title = "New verification request"
        bestAttemptContent.body = "\(sender) asks you to verify yourself"
        bestAttemptContent.categoryIdentifier = PushNotificationCategory.verification
        bestAttemptContent.sound = .default
        completeContent(bestAttemptContent)
    }

    private final func intentImage(avatarURL: String?) -> INImage {
        if let avatarURL,
           let url = URL(string: avatarURL),
           let image = INImage(url: url) {
            return image
        }
        return INImage(named: "person.2.circle.fill")
    }

    private final func imageAttachments(for urlStrings: [String]) async -> [UNNotificationAttachment] {
        var attachments: [UNNotificationAttachment] = []
        for urlString in urlStrings.prefix(2) {
            guard let url = URL(string: urlString),
                  let attachment = await imageAttachment(for: url) else {
                continue
            }
            attachments.append(attachment)
        }
        return attachments
    }

    private final func imageAttachment(for url: URL) async -> UNNotificationAttachment? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (downloadedURL, response) = try await session.download(for: request)
            if let expectedLength = (response as? HTTPURLResponse)?.expectedContentLength,
               expectedLength > 10 * 1024 * 1024 {
                return nil
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xabber-notification-media", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let filename = localAttachmentFilename(for: url)
            let destination = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: downloadedURL, to: destination)
            return try UNNotificationAttachment(identifier: filename, url: destination, options: nil)
        } catch {
            return nil
        }
    }

    private final func localAttachmentFilename(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? UUID().uuidString : base
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return "\(safeBase)-\(UUID().uuidString).\(ext)"
    }
}
