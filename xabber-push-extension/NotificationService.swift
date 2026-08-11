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
import ImageIO
import Intents
import UIKit

private final class PushNotificationMediaSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              PushNotificationMediaURLPolicy.remoteURLString(url.absoluteString) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

class NotificationService: UNNotificationServiceExtension {
    static let suitName: String = "group.xabber.ios"
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
        private static let pushNamespace = "https://xabber.com/protocol/push"
        private static let dataFormNamespace = "jabber:x:data"
        private static let formType = "https://xabber.com/protocol/push#info"
        private static let stanzaIdNamespace = "urn:xmpp:sid:0"
        private static let maximumXMLSize = 512 * 1024
        
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
            guard body.utf8.count <= Self.maximumXMLSize,
                  !Self.containsForbiddenXML(body) else {
                return nil
            }
            let documentBody = "<root>\(body)</root>"
            guard let document = try? DDXMLDocument(xmlString: documentBody, options: 0),
                  let root = document.rootElement(),
                  root.elements(forName: "encrypted").count == 1,
                  let encryptedElement = root.elements(forName: "encrypted").first,
                  encryptedElement.xmlns() == Self.pushNamespace,
                  root.elements(forName: "x").count == 1,
                  let xForm = root.elements(forName: "x").first,
                  xForm.xmlns() == Self.dataFormNamespace,
                  xForm.attribute(forName: "type")?.stringValue == "result" else {
                return nil
            }

            let fields = xForm.elements(forName: "field")
            let formTypeValues = fields
                .filter { $0.attribute(forName: "var")?.stringValue == "FORM_TYPE" }
                .compactMap { $0.elements(forName: "value").first?.stringValue }
            let actionValues = fields
                .filter { $0.attribute(forName: "var")?.stringValue == "type" }
                .compactMap { $0.elements(forName: "value").first?.stringValue }
            guard formTypeValues == [Self.formType],
                  actionValues.count == 1,
                  let action = actionValues.first,
                  let parsedAction = Actions(rawValue: action),
                  parsedAction != .none else {
                return nil
            }

            self.encrypted = encryptedElement.xmlString
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
                encryptedParts?.iv[...]
            }
        }
        
        var encryptedData: Array<UInt8>? {
            get {
                encryptedParts?.ciphertext
            }
        }
        
        var encryptedLen: Int {
            get {
                encryptedParts?.ciphertext.count ?? 0
            }
        }

        private var encryptedParts: (iv: [UInt8], ciphertext: [UInt8])? {
            guard let root = rootElement,
                  root.xmlns() == Self.pushNamespace,
                  root.attribute(forName: "iv-length")?.stringValue == "16",
                  let encryptedString = root.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let data = Data(base64Encoded: encryptedString, options: []),
                  data.count > 16 else {
                return nil
            }
            let ciphertext = Array(data.dropFirst(16))
            guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: 16) else {
                return nil
            }
            return (Array(data.prefix(16)), ciphertext)
        }
        
        public func subscribtionRequestStanza(key: String) -> String? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let presenceElement = document.rootElement(),
                presenceElement.name == "presence",
                let presenceType = presenceElement.attribute(forName: "type")?.stringValue,
                presenceType == "subscribe" {
                return presenceElement.compactXMLString()
            }
            return nil
        }
        
        public func subscribtionRequestFrom(key: String) -> String? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let presenceElement = document.rootElement(),
                presenceElement.name == "presence",
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
                let stanzaIdElement = document.rootElement(),
                stanzaIdElement.name == "stanza-id",
                stanzaIdElement.xmlns() == Self.stanzaIdNamespace,
                let settedBy = stanzaIdElement.attribute(forName: "by")?.stringValue,
                let id = stanzaIdElement.attribute(forName: "id")?.stringValue {
                return StanzaId(id: id, by: settedBy)
            }
            return nil
        }
        
        public func updateStanzaID(key: String) -> StanzaId? {
            if let decrypted = decrypt(by: key),
                let document = try? DDXMLDocument(xmlString: decrypted, options: 0),
                let stanzaIdElement = document.rootElement(),
                stanzaIdElement.name == "stanza-id",
                stanzaIdElement.xmlns() == Self.stanzaIdNamespace,
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
                        if stanzaIdElement.xmlns() == Self.stanzaIdNamespace,
                            let settedBy = stanzaIdElement.attribute(forName: "by")?.stringValue,
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
                    let iv = iv,
                    key.utf8.count == 32 else {
                    return nil
                }
                let decrypted = try AES(key: Array(key.utf8),
                                        blockMode: CBC(iv: Array(iv)),
                                        padding: .noPadding).decrypt(encrypted)
                var plaintextLength = decrypted.count
                while plaintextLength > 0, decrypted[plaintextLength - 1] == 0 {
                    plaintextLength -= 1
                }
                guard plaintextLength > 0,
                      plaintextLength <= Self.maximumXMLSize,
                      let plaintext = String(
                        bytes: decrypted.prefix(plaintextLength),
                        encoding: .utf8
                      ),
                      !Self.containsForbiddenXML(plaintext) else {
                    return nil
                }
                return plaintext
            } catch {
                return nil
            }
        }

        private static func containsForbiddenXML(_ value: String) -> Bool {
            value.localizedCaseInsensitiveContains("<!DOCTYPE")
                || value.localizedCaseInsensitiveContains("<!ENTITY")
        }
    }
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent = UNMutableNotificationContent()
    private let completionQueue = DispatchQueue(label: "com.xabber.notification-service.completion")
    private var didCompleteContent = false
    private var requestGeneration: UInt = 0
    private var credentialRetryWorkItem: DispatchWorkItem?
    private var renderingTask: Task<Void, Never>?
    private var archiveManager: NetworkManager?
    private let mediaSessionDelegate = PushNotificationMediaSessionDelegate()
    private lazy var attachmentDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("xabber-notification-media", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    
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
        finishContent {
            (content.copy() as? UNNotificationContent) ?? content
        }
    }

    private func completeBestAttemptContent() {
        finishContent {
            (self.bestAttemptContent.copy() as? UNNotificationContent)
                ?? self.bestAttemptContent
        }
    }

    private func finishContent(_ makeSnapshot: () -> UNNotificationContent) {
        var handler: ((UNNotificationContent) -> Void)?
        var snapshot: UNNotificationContent?
        var retryWorkItem: DispatchWorkItem?
        var task: Task<Void, Never>?
        var manager: NetworkManager?
        completionQueue.sync {
            guard !didCompleteContent else {
                return
            }
            snapshot = makeSnapshot()
            didCompleteContent = true
            handler = contentHandler
            contentHandler = nil
            retryWorkItem = credentialRetryWorkItem
            credentialRetryWorkItem = nil
            task = renderingTask
            renderingTask = nil
            manager = archiveManager
            archiveManager = nil
        }
        retryWorkItem?.cancel()
        task?.cancel()
        manager?.cancel()
        if let snapshot {
            handler?(snapshot)
        }
    }

    private var hasCompletedContent: Bool {
        completionQueue.sync { didCompleteContent }
    }

    @discardableResult
    private func mutateBestAttemptContent(
        _ mutation: (UNMutableNotificationContent) -> Void
    ) -> Bool {
        completionQueue.sync {
            guard !didCompleteContent else {
                return false
            }
            mutation(bestAttemptContent)
            return true
        }
    }

    private func bestAttemptContentSnapshot() -> UNMutableNotificationContent {
        completionQueue.sync {
            (bestAttemptContent.mutableCopy() as? UNMutableNotificationContent)
                ?? bestAttemptContent
        }
    }

    private func cancelOutstandingWork() {
        let work: (DispatchWorkItem?, Task<Void, Never>?, NetworkManager?) = completionQueue.sync {
            let work = (credentialRetryWorkItem, renderingTask, archiveManager)
            credentialRetryWorkItem = nil
            renderingTask = nil
            archiveManager = nil
            return work
        }
        work.0?.cancel()
        work.1?.cancel()
        work.2?.cancel()
    }

    private func isActiveRequest(generation: UInt) -> Bool {
        completionQueue.sync {
            requestGeneration == generation && !didCompleteContent
        }
    }

    private func isCurrentArchiveManager(_ manager: NetworkManager) -> Bool {
        completionQueue.sync {
            archiveManager === manager && !didCompleteContent
        }
    }

    @discardableResult
    private func installArchiveManager(_ manager: NetworkManager) -> Bool {
        var previous: NetworkManager?
        let installed = completionQueue.sync {
            guard !didCompleteContent else {
                return false
            }
            previous = archiveManager
            archiveManager = manager
            return true
        }
        previous?.cancel()
        if !installed {
            manager.cancel()
        }
        return installed
    }

    private func installRenderingTask(_ task: Task<Void, Never>) {
        var previous: Task<Void, Never>?
        let installed = completionQueue.sync {
            guard !didCompleteContent else {
                return false
            }
            previous = renderingTask
            renderingTask = task
            return true
        }
        previous?.cancel()
        if !installed {
            task.cancel()
        }
    }

    internal func getAccounts(_ payload: [AnyHashable: Any]) -> [String: Any] {
        func convertCredionals(_ text: String) -> [String: String]? {
            if let data = text.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: String]
            }
            return nil
        }
        
        guard let target = payload["node"] as? String,
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
    
    func loadCredentials(
        for node: String,
        payload: PayloadData,
        retry: Int = 0,
        generation requestedGeneration: UInt? = nil
    ) {
        let generation = requestedGeneration ?? completionQueue.sync { requestGeneration }
        guard isActiveRequest(generation: generation) else {
            return
        }
        do {
            let pushSecrets = try CredentialsManager.staticGetPushCredentials(for: node)
            guard isActiveRequest(generation: generation) else {
                return
            }
            self.owner = pushSecrets.jid
            self.pushData = pushSecrets
            self.deviceId = CredentialsManager.getXabberDeviceId(for: self.owner)
            self.notificationType = payload.action
            self.action(for: payload)
        } catch {
            guard isActiveRequest(generation: generation) else {
                return
            }
            if retry >= Self.maxCredentialRetryCount {
                fallbackVisibleNotification(for: payload.action, reason: "credentials unavailable")
            } else {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.isActiveRequest(generation: generation) else {
                        return
                    }
                    self.loadCredentials(
                        for: node,
                        payload: payload,
                        retry: retry + 1,
                        generation: generation
                    )
                }
                var previous: DispatchWorkItem?
                let scheduled = completionQueue.sync {
                    guard requestGeneration == generation, !didCompleteContent else {
                        return false
                    }
                    previous = credentialRetryWorkItem
                    credentialRetryWorkItem = workItem
                    return true
                }
                previous?.cancel()
                if scheduled {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + Self.credentialRetryDelay,
                        execute: workItem
                    )
                }
            }
        }
    }
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent
        cancelOutstandingWork()
        let generation: UInt = completionQueue.sync {
            requestGeneration &+= 1
            self.contentHandler = contentHandler
            didCompleteContent = false
            let content = mutableContent ?? UNMutableNotificationContent()
            self.bestAttemptContent = content
            self.bestAttemptContent.sound = .default
            self.bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            self.bestAttemptContent.body = localizedNewMessage
            return requestGeneration
        }
        sweepStaleAttachmentDirectories()
        guard mutableContent != nil else {
            completeContent(request.content)
            return
        }
        identifier = request.identifier
        guard let body = request.content.userInfo["body"] as? String,
            let payload_decoded = parse(payload: body) else {
            completeBestAttemptContent()
            return
        }
        
        guard let node = request.content.userInfo["node"] as? String else {
            completeBestAttemptContent()
            return
        }
        self.loadCredentials(
            for: node,
            payload: payload_decoded,
            generation: generation
        )
//        self.action(for: payload_decoded)
    }
    
    override func serviceExtensionTimeWillExpire() {
        completeBestAttemptContent()
    }
    
    internal func action(for payload: PayloadData) {
        guard !hasCompletedContent else {
            return
        }
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
        mutateBestAttemptContent { content in
            content.title = CommonConfigManager.shared.config.app_name
            content.body = localizedNewMessage
        }
        completeBestAttemptContent()
    }

    private func fallbackVisibleNotification(for action: Actions, reason: String? = nil) {
        let body: String
        switch action {
        case .update, .message, .invite:
            body = localizedNewMessage
        case .subscribe:
            body = PushNotificationLocalization.string(
                "action_subscription_received",
                fallback: "Incoming contact request"
            )
        case .marker, .none:
            body = reason ?? ""
        }
        if action == .marker {
            suppressCurrentNotification()
        } else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = body
            }
            completeBestAttemptContent()
        }
    }

    private func suppressCurrentNotification() {
        guard mutateBestAttemptContent({ content in
            content.title = " "
            content.body = ""
            content.subtitle = ""
        }) else {
            return
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        completeBestAttemptContent()
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
        guard installArchiveManager(manager) else {
            return
        }
        manager.getMessage(host: pushData.host, messageId: stanzaId.id, by: remoteArchiveJid)
    }
    
    internal func onSubscribe(_ payload: PayloadData) {
        guard let from = payload.subscribtionRequestFrom(key: pushData?.secret ?? "")?.split(separator: "/").first.map(String.init) else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = PushNotificationLocalization.string(
                    "action_subscription_received",
                    fallback: "Incoming contact request"
                )
            }
            completeBestAttemptContent()
            return
        }
        let metadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: from)
        let route = PushNotificationRoutePayload.subscriptionRequest(
            owner: owner,
            contactJid: from,
            nickname: metadata.username
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.renderSubscriptionRequest(
                route: route,
                displayName: metadata.username ?? from
            )
        }
        installRenderingTask(task)
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
            mutateBestAttemptContent { content in
                content.title = "Xabber"
                content.body = "New \(payload.action.rawValue)"
            }
            completeBestAttemptContent()
            return
        }
        
        suppressCurrentNotification()
        
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
        guard installArchiveManager(manager) else {
            return
        }
        manager.getMessage(host: pushData.host, messageId: stanzaId.id, by: remoteArchiveJid)
    }
}

extension NotificationService: PushPayloadDelegate {
    func didReceiveSync(stanza: String) {
        let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup())
        defaults?.set(stanza, forKey: "com.xabber.sync.temporary.\(owner)")
    }
    
    func networkManager(_ manager: NetworkManager, didDisconnectWithError error: String) {
        guard isCurrentArchiveManager(manager) else {
            return
        }
        mutateBestAttemptContent { content in
            content.title = CommonConfigManager.shared.config.app_name
            content.body = localizedNewMessage
        }
        completeBestAttemptContent()
    }

    func networkManager(
        _ manager: NetworkManager,
        didUpdateContent preview: PushNotificationPreview
    ) async {
        guard !Task.isCancelled, isCurrentArchiveManager(manager) else {
            return
        }
        switch preview.route.kind {
        case .message:
            await renderMessage(preview)
        case .groupInvite:
            await renderGroupInvite(preview)
        case .verificationRequest:
            renderVerificationRequest(preview)
        case .subscriptionRequest:
            await renderSubscriptionRequest(
                route: preview.route,
                displayName: preview.route.senderNickname ?? preview.route.routeJid ?? "Someone"
            )
        }
    }

    @discardableResult
    private final func applyRoute(
        _ route: PushNotificationRoutePayload,
        mutation: (UNMutableNotificationContent) -> Void = { _ in }
    ) -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        let timestamp = Date().timeIntervalSinceReferenceDate
        let updated = mutateBestAttemptContent { content in
            route.userInfo(timestamp: timestamp).forEach {
                content.userInfo[$0.key] = $0.value
            }
            mutation(content)
        }
        guard updated else { return false }
        if let stanzaId = route.stanzaId {
            let notificationIdentifier = identifier
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                if notifications.first(where: { $0.request.content.userInfo["stanzaId"] as? String == stanzaId }) != nil {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(
                        withIdentifiers: [notificationIdentifier]
                    )
                }
            }
        }
        return true
    }

    private final func renderMessage(_ preview: PushNotificationPreview) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        guard let routeJid = preview.route.routeJid else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = preview.body
            }
            completeBestAttemptContent()
            return
        }

        let isGroup = preview.route.groupchat != nil || preview.route.conversationType == "group"
        let routeMetadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: routeJid)
        let senderMetadata = preview.route.senderJid.map {
            CommonContactsMetadataManager.shared.getItem(owner: owner, jid: $0)
        }
        let routeDisplayName = routeMetadata.username ?? preview.groupName ?? routeJid
        let senderDisplayName = isGroup
            ? (preview.route.senderNickname
                ?? senderMetadata?.username
                ?? preview.route.senderJid
                ?? "Group member")
            : (routeMetadata.username ?? routeJid)
        let conversationId = "xabber:\(owner.lowercased()):\(routeJid.lowercased())"
        let subtitle = [editMark, isGroup ? senderDisplayName : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard applyRoute(preview.route, mutation: { content in
            content.categoryIdentifier = PushNotificationCategory.pushMessage
            content.sound = .default
            content.body = preview.body
            content.threadIdentifier = conversationId
            content.title = isGroup ? routeDisplayName : senderDisplayName
            content.subtitle = subtitle
        }) else {
            return
        }

        let attachments = await imageAttachments(for: preview.imageURLs)
        guard !Task.isCancelled,
              mutateBestAttemptContent({ $0.attachments = attachments }) else {
            return
        }

        let handleValue = isGroup
            ? stableSenderHandle(
                route: preview.route,
                fallback: preview.route.senderJid
                    ?? preview.route.senderNickname
                    ?? routeJid
            )
            : routeJid
        let sender = INPerson(
            personHandle: INPersonHandle(value: handleValue, type: .unknown),
            nameComponents: nil,
            displayName: senderDisplayName,
            image: intentImage(
                route: preview.route,
                displayName: senderDisplayName,
                fallbackJid: preview.route.senderJid ?? routeJid
            ),
            contactIdentifier: nil,
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
        await completeContent(updatingFrom: intent, interaction: interaction)
    }

    private final func renderGroupInvite(_ preview: PushNotificationPreview) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        guard let groupchat = preview.route.groupchat ?? preview.route.routeJid else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = preview.body
            }
            completeBestAttemptContent()
            return
        }
        let groupMetadata = CommonContactsMetadataManager.shared.getItem(owner: owner, jid: groupchat)
        let inviterMetadataName = preview.route.inviterJid.flatMap {
            CommonContactsMetadataManager.shared.getItem(owner: owner, jid: $0).username
        }
        let inviterName = preview.route.inviterNickname
            ?? preview.route.senderNickname
            ?? inviterMetadataName
            ?? preview.route.inviterJid
            ?? preview.route.senderJid
        let groupName = groupMetadata.username ?? preview.groupName ?? groupchat
        let conversationId = "xabber:\(owner.lowercased()):group-invitations"
        let subtitle: String
        let body: String
        if let inviterName {
            subtitle = inviterName
            let localizationKey: String
            let fallback: String
            switch preview.route.inviteKind {
            case "incognito":
                localizationKey = "chat_incognito_chat_invitation"
                fallback = "%@ invited you to join this incognito group"
            case "peer-to-peer":
                localizationKey = "chat_private_chat_invitation"
                fallback = "%@ invited you to join private chat"
            default:
                localizationKey = "chat_group_invitation"
                fallback = "%@ invited you to join this group"
            }
            body = PushNotificationLocalization.string(
                localizationKey,
                fallback: fallback,
                inviterName
            )
        } else {
            subtitle = ""
            let localizationKey: String
            let fallback: String
            switch preview.route.inviteKind {
            case "incognito":
                localizationKey = "incognito_group_invitation"
                fallback = "You are invited to join this incognito group"
            case "peer-to-peer":
                localizationKey = "private_chat_invitation"
                fallback = "You are invited to join private chat"
            default:
                localizationKey = "public_group_invitation"
                fallback = "You are invited to join this public group"
            }
            body = PushNotificationLocalization.string(
                localizationKey,
                fallback: fallback
            )
        }
        guard applyRoute(preview.route, mutation: { content in
            content.title = groupName
            content.subtitle = subtitle
            content.body = body
            content.categoryIdentifier = PushNotificationCategory.invite
            content.threadIdentifier = conversationId
            content.sound = .default
        }) else {
            return
        }
        let senderName = inviterName ?? "Someone"
        let senderJid = preview.route.inviterJid ?? preview.route.senderJid ?? groupchat
        let sender = makeIntentPerson(
            route: preview.route,
            displayName: senderName,
            fallbackJid: senderJid
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: INSpeakableString(spokenPhrase: groupName),
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        await completeContent(updatingFrom: intent, interaction: interaction)
    }

    private final func renderSubscriptionRequest(
        route: PushNotificationRoutePayload,
        displayName: String
    ) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        let jid = route.routeJid ?? displayName
        let conversationId = "xabber:\(owner.lowercased()):contact-requests"
        let body = PushNotificationLocalization.string(
            "desktop_notifications_add_you_to_contact",
            fallback: "Contact %@ wants to add you to contact list",
            displayName
        )
        guard applyRoute(route, mutation: { content in
            content.title = displayName
            content.subtitle = jid == displayName ? "" : jid
            content.body = body
            content.categoryIdentifier = PushNotificationCategory.subscription
            content.threadIdentifier = conversationId
            content.sound = .default
        }) else {
            return
        }
        let sender = makeIntentPerson(
            route: route,
            displayName: displayName,
            fallbackJid: jid
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: nil,
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        await completeContent(updatingFrom: intent, interaction: interaction)
    }

    private final func renderVerificationRequest(_ preview: PushNotificationPreview) {
        let sender = preview.route.senderNickname ?? preview.route.senderJid ?? "Somebody"
        guard applyRoute(preview.route, mutation: { content in
            content.title = "New verification request"
            content.body = "\(sender) asks you to verify yourself"
            content.categoryIdentifier = PushNotificationCategory.verification
            content.sound = .default
        }) else {
            return
        }
        completeBestAttemptContent()
    }

    private final func makeIntentPerson(
        route: PushNotificationRoutePayload,
        displayName: String,
        fallbackJid: String
    ) -> INPerson {
        return INPerson(
            personHandle: INPersonHandle(
                value: stableSenderHandle(route: route, fallback: fallbackJid),
                type: .unknown
            ),
            nameComponents: nil,
            displayName: displayName,
            image: intentImage(
                route: route,
                displayName: displayName,
                fallbackJid: fallbackJid
            ),
            contactIdentifier: nil,
            customIdentifier: nil
        )
    }

    private final func intentImage(
        route: PushNotificationRoutePayload,
        displayName: String,
        fallbackJid: String
    ) -> INImage {
        var identities: [PushNotificationAvatarIdentity] = []
        if let routeIdentity = route.senderAvatarIdentity {
            identities.append(routeIdentity)
        }
        if let senderJid = route.senderJid ?? route.inviterJid {
            let regularIdentity = PushNotificationAvatarIdentity(
                owner: route.owner,
                contactJid: senderJid
            )
            if !identities.contains(regularIdentity) {
                identities.append(regularIdentity)
            }
        }
        for identity in identities {
            if let imageData = PushNotificationAvatarStore.shared.imageData(for: identity) {
                return INImage(imageData: imageData)
            }
        }
        let fallbackIdentity = stableSenderHandle(route: route, fallback: fallbackJid)
        let fallbackData = PushNotificationInitialsRenderer.imageData(
            displayName: displayName,
            jid: fallbackIdentity
        )
        return INImage(imageData: fallbackData)
    }

    private final func stableSenderHandle(
        route: PushNotificationRoutePayload,
        fallback: String
    ) -> String {
        guard route.senderJid == nil,
              route.inviterJid == nil,
              let groupchat = route.groupchat
                ?? (route.conversationType == "group" ? route.routeJid : nil),
              let senderUserId = route.senderUserId?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !senderUserId.isEmpty else {
            return fallback
        }
        let owner = normalizedBareJid(route.owner)
        let group = normalizedBareJid(groupchat)
        let participant = senderUserId.contains("@")
            ? normalizedBareJid(senderUserId)
            : senderUserId
        let canonical = ["v1", "groupParticipant", owner, group, participant]
            .joined(separator: "\u{0}")
        let digest = Array(canonical.utf8).sha256().toHexString()
        return "xabber-group-participant:\(digest)"
    }

    private final func normalizedBareJid(_ value: String) -> String {
        let bare = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        return bare.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private final func completeContent(
        updatingFrom intent: INSendMessageIntent,
        interaction: INInteraction
    ) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        let intendedContent = bestAttemptContentSnapshot()
        do {
            try await interaction.donate()
            guard !Task.isCancelled, !hasCompletedContent else { return }
            let updatedContent = try intendedContent.updating(from: intent)
            guard let merged = updatedContent.mutableCopy() as? UNMutableNotificationContent else {
                completeContent(intendedContent)
                return
            }
            merged.title = intendedContent.title
            merged.subtitle = intendedContent.subtitle
            merged.body = intendedContent.body
            merged.categoryIdentifier = intendedContent.categoryIdentifier
            merged.threadIdentifier = intendedContent.threadIdentifier
            merged.sound = intendedContent.sound
            merged.attachments = intendedContent.attachments
            var userInfo = merged.userInfo
            intendedContent.userInfo.forEach { userInfo[$0.key] = $0.value }
            merged.userInfo = userInfo
            completeContent(merged)
        } catch {
            completeContent(intendedContent)
        }
    }

    private final func imageAttachments(for urlStrings: [String]) async -> [UNNotificationAttachment] {
        var attachments: [UNNotificationAttachment] = []
        for source in urlStrings.prefix(3) {
            guard !Task.isCancelled,
                  let attachment = await imageAttachment(for: source) else {
                continue
            }
            attachments.append(attachment)
        }
        return attachments
    }

    private final func imageAttachment(for source: String) async -> UNNotificationAttachment? {
        if source.hasPrefix("data:image/") {
            guard let data = inlineImageData(from: source) else {
                return nil
            }
            return makeImageAttachment(from: data)
        }
        guard let remote = PushNotificationMediaURLPolicy.remoteURLString(source),
              let url = URL(string: remote) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3.0
        let session = URLSession(
            configuration: configuration,
            delegate: mediaSessionDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            let (downloadedURL, response) = try await session.download(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.url.flatMap({ PushNotificationMediaURLPolicy.remoteURLString($0.absoluteString) }) != nil,
                  response.mimeType?.lowercased().hasPrefix("image/") == true else {
                return nil
            }
            let maximumBytes: Int64 = 8 * 1024 * 1024
            if response.expectedContentLength > maximumBytes {
                return nil
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            guard let fileSize = attributes[.size] as? NSNumber,
                  fileSize.int64Value > 0,
                  fileSize.int64Value <= maximumBytes else {
                return nil
            }
            let data = try Data(contentsOf: downloadedURL, options: .mappedIfSafe)
            return makeImageAttachment(from: data)
        } catch {
            return nil
        }
    }

    private final func inlineImageData(from source: String) -> Data? {
        guard source.utf8.count <= 1_500_000,
              let markerRange = source.range(of: ";base64,"),
              source[..<markerRange.lowerBound].hasPrefix("data:image/") else {
            return nil
        }
        let encoded = String(source[markerRange.upperBound...])
        return Data(base64Encoded: encoded, options: [])
    }

    private final func makeImageAttachment(from data: Data) -> UNNotificationAttachment? {
        let maximumBytes = 8 * 1024 * 1024
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= 24_000_000 / height else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let image = UIImage(cgImage: thumbnail)
        let normalizedImage: (data: Data, fileExtension: String)?
        if let pngData = image.pngData(), pngData.count <= maximumBytes {
            normalizedImage = (pngData, "png")
        } else if let jpegData = image.jpegData(compressionQuality: 0.82),
                  jpegData.count <= maximumBytes {
            normalizedImage = (jpegData, "jpg")
        } else {
            normalizedImage = nil
        }
        guard let normalizedImage else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: attachmentDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let filename = "preview-\(UUID().uuidString).\(normalizedImage.fileExtension)"
            let destination = attachmentDirectory.appendingPathComponent(filename)
            try normalizedImage.data.write(to: destination, options: .atomic)
            return try UNNotificationAttachment(
                identifier: filename,
                url: destination,
                options: nil
            )
        } catch {
            return nil
        }
    }

    private final func sweepStaleAttachmentDirectories() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("xabber-notification-media", isDirectory: true)
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey
        ]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        func allocatedSize(of directory: URL) -> Int64 {
            let sizeKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                return 0
            }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: sizeKeys),
                      values.isRegularFile == true else {
                    continue
                }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                let addition = total.addingReportingOverflow(size)
                total = addition.overflow ? Int64.max : addition.partialValue
            }
            return total
        }

        struct AttachmentDirectoryInfo {
            let url: URL
            let modified: Date
            let allocatedSize: Int64
        }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var retained: [AttachmentDirectoryInfo] = []
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true else {
                continue
            }
            let modified = values.contentModificationDate ?? .distantPast
            if modified < cutoff,
               (try? fileManager.removeItem(at: directory)) != nil {
                continue
            }
            retained.append(
                AttachmentDirectoryInfo(
                    url: directory,
                    modified: modified,
                    allocatedSize: allocatedSize(of: directory)
                )
            )
        }

        let maximumDirectoryCount = 32
        let maximumAllocatedBytes: Int64 = 96 * 1024 * 1024
        retained.sort { $0.modified < $1.modified }
        var totalAllocatedBytes = retained.reduce(Int64(0)) { partial, item in
            let addition = partial.addingReportingOverflow(item.allocatedSize)
            return addition.overflow ? Int64.max : addition.partialValue
        }
        while !retained.isEmpty,
              retained.count > maximumDirectoryCount
                || totalAllocatedBytes > maximumAllocatedBytes {
            let oldest = retained.removeFirst()
            guard (try? fileManager.removeItem(at: oldest.url)) != nil else {
                continue
            }
            totalAllocatedBytes = max(0, totalAllocatedBytes - oldest.allocatedSize)
        }
    }

    private var localizedNewMessage: String {
        PushNotificationLocalization.string(
            "plurals.new_chat_messages.item_0",
            fallback: "New message"
        )
    }
}
