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
    private static let maxCredentialRetryCount = 5
    private static let credentialRetryDelay: TimeInterval = 0.1
    
    enum InviteKind: String {
        case group = "group"
        case incognito = "incognito"
        case peerToPeer = "peer-to-peer"
    }
    
    typealias Actions = PushPayloadAction
    typealias PayloadData = PushPayloadEnvelope

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent = UNMutableNotificationContent()
    private let completionQueue = DispatchQueue(label: "com.xabber.notification-service.completion")
    private var didCompleteContent = false
    private var requestGeneration: UInt = 0
    @TaskLocal private static var handlingGeneration: UInt?
    private var archiveGeneration: UInt?
    private var donatedInteractionIDs: [String] = []
    private var wipeStartGeneration: String?
    private var wipeStartedPending = false
    private var credentialRetryWorkItem: DispatchWorkItem?
    private var renderingTask: Task<Void, Never>?
    private var archiveManager: NetworkManager?
    private let richAttachmentLoader = RichNotificationAttachmentLoader()
    
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

    private func passcodeWipeNeutralContent() -> UNNotificationContent {
        let neutral = UNMutableNotificationContent()
        neutral.title = CommonConfigManager.shared.config.app_name
        neutral.body = localizedNewMessage
        neutral.userInfo = [:]
        neutral.sound = nil
        return neutral
    }

    private func finishContent(_ makeSnapshot: () -> UNNotificationContent) {
        var handler: ((UNNotificationContent) -> Void)?
        var snapshot: UNNotificationContent?
        var retryWorkItem: DispatchWorkItem?
        var task: Task<Void, Never>?
        var manager: NetworkManager?
        var startGeneration: String?
        var startedPending = false
        var credentialSnapshot: (String?, CredentialsManager.PushSecretData?) = (nil, nil)
        var discardedInteractions: [String] = []
        var capturedInteractions: [String] = []
        completionQueue.sync {
            guard !didCompleteContent, Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true else {
                return
            }
            startGeneration = wipeStartGeneration
            startedPending = wipeStartedPending
            credentialSnapshot = (currentNode, pushData)
            capturedInteractions = donatedInteractionIDs
            // A wipe can begin while a previously accepted push is being
            // decrypted. Check again at delivery so no rich content escapes.
            if PasscodeWipeMarkerStore.live().shouldNeutralizeRequest(
                startGeneration: startGeneration,
                startedPending: startedPending
            ) || (pushData != nil && !ownsCredentialSnapshot(node: currentNode, record: pushData)) {
                snapshot = passcodeWipeNeutralContent()
                discardedInteractions = donatedInteractionIDs
            } else {
                snapshot = makeSnapshot()
            }
            didCompleteContent = true
            handler = contentHandler
            contentHandler = nil
            retryWorkItem = credentialRetryWorkItem
            credentialRetryWorkItem = nil
            task = renderingTask
            renderingTask = nil
            manager = archiveManager
            archiveManager = nil
            archiveGeneration = nil
        }
        if !discardedInteractions.isEmpty { INInteraction.delete(with: discardedInteractions, completion: nil) }
        retryWorkItem?.cancel()
        task?.cancel()
        manager?.cancel()
        if let snapshot {
            let invalidated = PasscodeWipeMarkerStore.live().shouldNeutralizeRequest(
                startGeneration: startGeneration, startedPending: startedPending
            ) || (credentialSnapshot.1 != nil && !ownsCredentialSnapshot(node: credentialSnapshot.0, record: credentialSnapshot.1))
            if invalidated, !capturedInteractions.isEmpty {
                INInteraction.delete(with: capturedInteractions, completion: nil)
            }
            handler?(invalidated ? passcodeWipeNeutralContent() : snapshot)
        }
    }

    private var hasCompletedContent: Bool {
        completionQueue.sync { didCompleteContent || (Self.handlingGeneration.map { $0 != requestGeneration } ?? false) }
    }

    @discardableResult
    private func mutateBestAttemptContent(
        _ mutation: (UNMutableNotificationContent) -> Void
    ) -> Bool {
        completionQueue.sync {
            guard !didCompleteContent, Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true else {
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
            archiveGeneration = nil
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
            guard !didCompleteContent, Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true else {
                return false
            }
            previous = archiveManager
            archiveManager = manager
            archiveGeneration = requestGeneration
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
            guard !didCompleteContent, Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true else {
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
                                       accessGroup: CredentialsManager.uniqueKeychainAccessGroup())
        return keychain.string(forKey: key)
//        return nil
    }
    
    var pushData: CredentialsManager.PushSecretData? = nil
    private var currentNode: String?

    // Late network/render callbacks may not expose content after logout or key replacement.
    private func ownsCurrentCredentialSnapshot() -> Bool {
        let snapshot = completionQueue.sync { (currentNode, pushData) }
        return ownsCredentialSnapshot(node: snapshot.0, record: snapshot.1)
    }

    private func ownsCredentialSnapshot(node: String?, record: CredentialsManager.PushSecretData?) -> Bool {
        guard let node, let snapshot = record,
              let current = try? CredentialsManager.staticGetPushCredentials(for: node),
              current.jid == snapshot.jid, let key = snapshot.keyBytes,
              current.keyBytes == key else { return false }
        return true
    }

    private func canFetchArchive(_ record: CredentialsManager.PushSecretData) -> Bool {
        let now = Date()
        guard let node = currentNode, let grant = record.httpArchive,
              grant.isUsable(forAccount: record.jid, host: record.host, now: now),
              record.tokenExpiresAt.map({ $0 > now }) == true,
              let store = PushTokenInvalidationStore.live,
              let invalid = try? store.contains(node: node, generation: record.tokenGeneration) else { return false }
        return !invalid
    }
    
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
            Self.$handlingGeneration.withValue(generation) {
                let installed = completionQueue.sync {
                    guard requestGeneration == generation, !didCompleteContent else { return false }
                    self.currentNode = node
                    self.owner = pushSecrets.jid
                    self.pushData = pushSecrets
                    self.deviceId = CredentialsManager.getXabberDeviceId(for: pushSecrets.jid)
                    return true
                }
                if installed { self.action(for: payload) }
            }
        } catch {
            guard isActiveRequest(generation: generation) else {
                return
            }
            if retry >= Self.maxCredentialRetryCount {
                Self.$handlingGeneration.withValue(generation) { fallbackVisibleNotification(for: .message) }
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
        let wipeMarker = PasscodeWipeMarkerStore.live()
        let initialWipeGeneration = try? wipeMarker.readGeneration()
        let wipePendingAtStart = wipeMarker.isPendingOrUnavailable
        let appGroupSuiteName = CredentialsManager.uniqueAccessGroup()
        PushNotificationLocalization.prepareForIncomingRequest(
            appGroupSuiteName: appGroupSuiteName.isEmpty ? nil : appGroupSuiteName
        )
        let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent
        completeBestAttemptContent()
        cancelOutstandingWork()
        let generation: UInt = completionQueue.sync {
            requestGeneration &+= 1
            wipeStartGeneration = initialWipeGeneration
            wipeStartedPending = wipePendingAtStart
            self.contentHandler = contentHandler
            didCompleteContent = false
            let content = mutableContent ?? UNMutableNotificationContent()
            self.donatedInteractionIDs = []
            self.currentNode = nil
            self.pushData = nil
            self.owner = ""
            self.notificationType = .none
            self.identifier = request.identifier
            self.editMark = ""
            self.bestAttemptContent = content
            self.bestAttemptContent.sound = NotificationSoundPreferences.current.isEnabled(for: .message) ? .default : nil
            self.bestAttemptContent.title = CommonConfigManager.shared.config.app_name
            self.bestAttemptContent.body = localizedNewMessage
            return requestGeneration
        }
        guard mutableContent != nil else {
            completeContent(request.content)
            return
        }
        guard !wipeMarker.shouldNeutralizeRequest(
            startGeneration: initialWipeGeneration,
            startedPending: wipePendingAtStart
        ) else {
            completeBestAttemptContent()
            return
        }
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
        guard !hasCompletedContent, let key = pushData?.keyBytes,
              ownsCurrentCredentialSnapshot(), let event = payload.event(key: key) else {
            fallbackVisibleNotification(for: .message)
            return
        }
        // The encrypted server stanza owns dispatch. Metadata is an unauthenticated hint.
        switch event {
        case .message:
            guard !payload.outgoing else { suppressCurrentNotification(); return }
            notificationType = .message
            applySoundPreference(for: .message)
            onMessage(payload)
        case .fullMessage(let message):
            guard !payload.outgoing else {
                suppressCurrentNotification()
                return
            }
            notificationType = .message
            applySoundPreference(for: .message)
            guard let preview = PushNotificationArchiveParser.parseArchivedMessage(message, owner: owner) else {
                fallbackVisibleNotification(for: .message)
                return
            }
            // Full content needs the current decryption key, not an HTTP grant.
            // Use the same typed renderer as HTTP previews without starting an archive request.
            let task = Task { [weak self] in
                guard let self else { return }
                await self.renderPreview(preview)
            }
            installRenderingTask(task)
        case .displayed:
            notificationType = .marker
            onMarker(payload)
        case .subscription:
            notificationType = .subscribe
            applySoundPreference(for: .subscribe)
            onSubscribe(payload)
        case .reconciliation:
            guard !payload.outgoing, let message = payload.payloadStanza(key: key),
                  let preview = PushNotificationArchiveParser.parsePushHeadline(message, owner: owner) else {
                suppressCurrentNotification()
                return
            }
            notificationType = preview.route.kind == .groupInvite ? .invite : .message
            applySoundPreference(for: notificationType)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.renderPreview(preview)
            }
            installRenderingTask(task)
        case .call, .callUpdate:
            // Calls have a separate app/PushKit ingress. Never render their XML as a message.
            suppressCurrentNotification()
        }
    }

    private func applySoundPreference(for action: Actions) {
        let routeKind: PushNotificationRoutePayload.Kind?
        switch action {
        case .message, .update:
            routeKind = .message
        case .invite:
            routeKind = .groupInvite
        case .subscribe:
            routeKind = .subscriptionRequest
        case .marker, .none, .call, .data:
            routeKind = nil
        }
        guard let routeKind else { return }
        let enabled = NotificationSoundPreferences.current.isEnabled(for: routeKind)
        mutateBestAttemptContent { $0.sound = enabled ? .default : nil }
    }
    
    internal func onHide(_ payload: PayloadData) {
        mutateBestAttemptContent { content in
            content.title = CommonConfigManager.shared.config.app_name
            content.body = localizedNewMessage
        }
        completeBestAttemptContent()
    }

    private func fallbackVisibleNotification(for action: Actions, reason: String? = nil) {
        applySoundPreference(for: action)
        let body: String
        switch action {
        case .update, .message, .invite:
            body = localizedNewMessage
        case .subscribe:
            body = PushNotificationLocalization.string(
                "action_subscription_received",
                fallback: "Incoming contact request"
            )
        case .marker, .none, .call, .data:
            body = ""
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
        var requestIdentifier = ""
        guard mutateBestAttemptContent({ content in
            requestIdentifier = identifier
            content.title = " "
            content.body = ""
            content.subtitle = ""
            content.sound = nil
        }) else {
            return
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        completeBestAttemptContent()
    }
    
    internal func onMessage(_ payload: PayloadData) {
        guard let pushData = self.pushData else {
            fallbackVisibleNotification(for: notificationType, reason: "missing push data")
            return
        }
        guard let key = pushData.keyBytes, let stanzaId = payload.messageStanzaID(key: key),
              canFetchArchive(pushData) else {
            fallbackVisibleNotification(for: notificationType, reason: "missing stanza id")
            return
        }
        let remoteArchiveJid = stanzaId.by == pushData.jid ? nil : stanzaId.by
        guard let manager = NetworkManager(credentials: pushData) else {
            fallbackVisibleNotification(for: notificationType, reason: "invalid archive service")
            return
        }
        manager.delegate = self
        guard installArchiveManager(manager) else {
            return
        }
        manager.getMessage(messageId: stanzaId.id, by: remoteArchiveJid)
    }
    
    internal func onSubscribe(_ payload: PayloadData) {
        guard let from = payload.subscribtionRequestFrom(key: pushData?.keyBytes ?? [])?.split(separator: "/").first.map(String.init) else {
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
        let preview = PushNotificationPreview(
            route: route,
            body: PushNotificationLocalization.string(
                "action_subscription_received",
                fallback: "Incoming contact request"
            ),
            groupName: nil,
            mediaItems: []
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.renderSubscriptionRequest(preview)
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
        let context = completionQueue.sync { () -> (UInt, String, String, CredentialsManager.PushSecretData)? in
            let generation = Self.handlingGeneration ?? requestGeneration
            guard requestGeneration == generation, !didCompleteContent,
                  let node = currentNode, let record = pushData else { return nil }
            return (generation, owner, node, record)
        }
        guard let context, let key = context.3.keyBytes,
              ownsCredentialSnapshot(node: context.2, record: context.3),
              case .displayed(let marker)? = payload.event(key: key) else {
            fallbackVisibleNotification(for: .message)
            return
        }
        let generation = context.0
        let requestOwner = context.1
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
            guard let self else { return }
            Self.$handlingGeneration.withValue(generation) {
                guard self.isActiveRequest(generation: generation), self.ownsCredentialSnapshot(node: context.2, record: context.3) else { return }
                let records = notifications.compactMap { notification -> PushDeliveredNotification? in
                    let content = notification.request.content
                    guard [PushNotificationCategory.message, PushNotificationCategory.pushMessage].contains(content.categoryIdentifier) else { return nil }
                    let info = content.userInfo
                    guard let owner = info["owner"] as? String, let jid = info[PushNotificationUserInfoKey.routeJid] as? String ?? info[PushNotificationUserInfoKey.legacyJid] as? String,
                          let timestamp = info["timestamp"] as? TimeInterval else { return nil }
                    return PushDeliveredNotification(identifier: notification.request.identifier,
                        owner: owner, jid: jid, timestamp: timestamp, stanzaID: info["stanzaId"] as? String,
                        messageID: info[PushNotificationUserInfoKey.messageId] as? String ?? info["messageId"] as? String)
                }
                let ids = PushDisplayedPolicy.removalIDs(marker: marker, owner: requestOwner, notifications: records)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                self.suppressCurrentNotification()
            }
        }
    }

    internal func onMarkerSmart(_ payload: PayloadData) { onMarker(payload) }

    internal func onUpdate(_ payload: PayloadData) { onMessage(payload) }

}

extension NotificationService: PushPayloadDelegate {
    func didReceiveSync(stanza: String) {
        let defaults  = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup())
        defaults?.set(stanza, forKey: "com.xabber.sync.temporary.\(owner)")
    }
    
    private func generation(for manager: NetworkManager) -> UInt? {
        completionQueue.sync { archiveManager === manager && !didCompleteContent ? archiveGeneration : nil }
    }

    func networkManager(_ manager: NetworkManager, didDisconnectWithError error: String) {
        guard let generation = generation(for: manager) else { return }
        Self.$handlingGeneration.withValue(generation) {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = localizedNewMessage
            }
            completeBestAttemptContent()
        }
    }

    func networkManagerDidRejectAuthorization(_ manager: NetworkManager) {
        let context = completionQueue.sync { () -> (UInt, String, CredentialsManager.PushSecretData)? in
            guard archiveManager === manager, !didCompleteContent, let generation = archiveGeneration,
                  let node = currentNode, let record = pushData else { return nil }
            return (generation, node, record)
        }
        guard let context else { return }
        Self.$handlingGeneration.withValue(context.0) {
            let currentGeneration = (try? CredentialsManager.staticGetPushCredentials(for: context.1))?.tokenGeneration
            try? PushTokenInvalidationStore.live?.invalidate(node: context.1, generation: context.2.tokenGeneration,
                                                             preservingGeneration: currentGeneration)
            networkManager(manager, didDisconnectWithError: "archive unavailable")
        }
    }

    func networkManager(_ manager: NetworkManager, didUpdateContent preview: PushNotificationPreview) async {
        guard let generation = generation(for: manager) else { return }
        await Self.$handlingGeneration.withValue(generation) {
            await renderPreview(preview)
        }
    }

    private func renderPreview(_ preview: PushNotificationPreview) async {
        guard !Task.isCancelled, !hasCompletedContent, ownsCurrentCredentialSnapshot() else { return }
        switch preview.route.kind {
        case .message: await renderMessage(preview)
        case .groupInvite: await renderGroupInvite(preview)
        case .verificationRequest: renderVerificationRequest(preview)
        case .subscriptionRequest: await renderSubscriptionRequest(preview)
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
        var notificationIdentifier = ""
        let updated = mutateBestAttemptContent { content in
            notificationIdentifier = identifier
            route.userInfo(timestamp: timestamp).forEach {
                content.userInfo[$0.key] = $0.value
            }
            mutation(content)
        }
        guard updated else { return false }
        if let stanzaId = route.stanzaId {
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                if notifications.first(where: {
                    $0.request.content.userInfo["stanzaId"] as? String == stanzaId
                        && $0.request.content.userInfo["owner"] as? String == route.owner
                }) != nil {
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
        guard preview.route.routeJid != nil else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = preview.body
            }
            completeBestAttemptContent()
            return
        }
        let plan = RichNotificationPresentationPolicy.plan(
            for: preview,
            overrides: RichNotificationNameOverrides(editMark: editMark)
        )
        guard apply(plan: plan) else {
            return
        }
        let candidates = RichNotificationAttachmentPolicy.candidates(
            for: plan.mediaItems,
            includePlayableMedia: false
        )
        let attachmentLease = await richAttachmentLoader.attachmentLease(for: candidates)
        defer { attachmentLease.release() }
        let attachments = attachmentLease.attachments
        guard !Task.isCancelled,
              mutateBestAttemptContent({ $0.attachments = attachments }) else {
            return
        }
        await completeCommunicationNotification(plan: plan)
    }

    private final func renderGroupInvite(_ preview: PushNotificationPreview) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        guard (preview.route.groupchat ?? preview.route.routeJid) != nil else {
            mutateBestAttemptContent { content in
                content.title = CommonConfigManager.shared.config.app_name
                content.body = preview.body
            }
            completeBestAttemptContent()
            return
        }
        let plan = RichNotificationPresentationPolicy.plan(
            for: preview,
            overrides: RichNotificationNameOverrides()
        )
        guard apply(plan: plan) else {
            return
        }
        await completeCommunicationNotification(plan: plan)
    }

    private final func renderSubscriptionRequest(_ preview: PushNotificationPreview) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        let plan = RichNotificationPresentationPolicy.plan(
            for: preview,
            overrides: RichNotificationNameOverrides()
        )
        guard apply(plan: plan) else {
            return
        }
        await completeCommunicationNotification(plan: plan)
    }

    private final func renderVerificationRequest(_ preview: PushNotificationPreview) {
        let plan = RichNotificationPresentationPolicy.plan(
            for: preview,
            overrides: RichNotificationNameOverrides()
        )
        guard apply(plan: plan) else {
            return
        }
        completeBestAttemptContent()
    }

    @discardableResult
    private final func apply(plan: RichNotificationPresentationPlan) -> Bool {
        let soundIsEnabled = NotificationSoundPreferences.current.isEnabled(for: plan.route.kind)
        return applyRoute(plan.route) { content in
            content.title = plan.title
            content.subtitle = plan.subtitle
            content.body = plan.body
            content.categoryIdentifier = plan.categoryIdentifier
            content.threadIdentifier = plan.threadIdentifier
            content.sound = soundIsEnabled ? .default : nil
        }
    }

    private final func completeCommunicationNotification(
        plan: RichNotificationPresentationPlan
    ) async {
        let sender = makeIntentPerson(plan: plan)
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: plan.body,
            speakableGroupName: plan.speakableGroupName.map {
                INSpeakableString(spokenPhrase: $0)
            },
            conversationIdentifier: plan.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        await completeContent(updatingFrom: intent, interaction: interaction)
    }

    private final func makeIntentPerson(
        plan: RichNotificationPresentationPlan
    ) -> INPerson {
        return INPerson(
            personHandle: INPersonHandle(
                value: plan.senderHandle,
                type: .unknown
            ),
            nameComponents: nil,
            displayName: plan.senderDisplayName,
            image: intentImage(
                route: plan.route,
                displayName: plan.senderDisplayName,
                fallbackJid: plan.senderHandle
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
        for identity in route.senderAvatarLookupIdentities {
            if let imageData = PushNotificationAvatarStore.shared.imageData(for: identity) {
                return INImage(imageData: imageData)
            }
        }
        let fallbackData = PushNotificationInitialsRenderer.imageData(
            displayName: displayName,
            jid: fallbackJid
        )
        return INImage(imageData: fallbackData)
    }

    private final func completeContent(
        updatingFrom intent: INSendMessageIntent,
        interaction: INInteraction
    ) async {
        guard !Task.isCancelled, !hasCompletedContent else { return }
        guard mayExposePrivateContent else { completeBestAttemptContent(); return }
        let interactionID = interaction.identifier
        let admitted = completionQueue.sync {
            guard !didCompleteContent, Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true else { return false }
            donatedInteractionIDs.append(interactionID)
            return true
        }
        guard admitted else { return }
        let intendedContent = bestAttemptContentSnapshot()
        do {
            try await interaction.donate()
            guard !Task.isCancelled, mayExposePrivateContent else {
                INInteraction.delete(with: [interactionID], completion: nil)
                completeBestAttemptContent()
                return
            }
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
            if mayExposePrivateContent { completeContent(intendedContent) }
            else {
                INInteraction.delete(with: [interactionID], completion: nil)
                completeBestAttemptContent()
            }
        }
    }

    private var mayExposePrivateContent: Bool {
        let state = completionQueue.sync { () -> (Bool, String?, Bool, String?, CredentialsManager.PushSecretData?) in
            let active = !didCompleteContent && (Self.handlingGeneration.map({ $0 == requestGeneration }) ?? true)
            return (active, wipeStartGeneration, wipeStartedPending, currentNode, pushData)
        }
        return state.0 && ownsCredentialSnapshot(node: state.3, record: state.4)
            && !PasscodeWipeMarkerStore.live().shouldNeutralizeRequest(startGeneration: state.1, startedPending: state.2)
    }

    private var localizedNewMessage: String {
        PushNotificationLocalization.newMessage()
    }
}
