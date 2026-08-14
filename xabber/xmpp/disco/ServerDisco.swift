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
import CryptoSwift
import XMPPFramework

extension Notification.Name {
    static let groupServiceDiscoveryDidChange = Notification.Name("groupServiceDiscoveryDidChange")
}

class ServerDiscoManager: AbstractXMPPManager {

    enum CloudDiscoveryTerminalKind: Equatable {
        case response
        case error
        case timeout
        case disconnect
    }

    private enum CloudDiscoveryRegistrationPhase: Equatable {
        case reserved
        case registered
    }

    private struct ActiveCloudDiscoveryQuery {
        let elementID: String
        let deadline: DispatchTime
        var onboardingCapabilityGeneration: UInt64?
        var phase: CloudDiscoveryRegistrationPhase
        var timeoutWorkItem: DispatchWorkItem?
    }

    private enum AccountOwnerCapabilityResult {
        case pending
        case resolved([String])
        case failed
    }

    private struct AccountOwnerCapabilityDiscovery {
        let generation: UInt64
        var elementID: String?
        var result: AccountOwnerCapabilityResult
        var pendingRootCapabilities: [String]?
        var graceWorkItem: DispatchWorkItem?
        var isTerminal: Bool
    }

    private struct AccountOwnerCapabilityResolution {
        let wasTracked: Bool
        let capabilitiesToPublish: [String]?
        let graceWorkItemToCancel: DispatchWorkItem?
    }

    static let clientName: String = CommonConfigManager.shared.config.app_name
    static var cloudDiscoveryTimeoutInterval: TimeInterval = 6
    static let defaultAccountOwnerCapabilityGraceInterval: TimeInterval = 0.1
    static let retryableServerCapabilitiesMarker = "__retryable_server_capabilities__"
    static var cloudDiscoveryWillRegisterQueryTestingHandler: ((ServerDiscoManager, String) -> Void)?
    static var cloudDiscoveryDidRegisterQueryTestingHandler: ((ServerDiscoManager) -> Void)?
    static var cloudDiscoveryDidConsumeTerminalTestingHandler: ((CloudDiscoveryTerminalKind) -> Void)?

    var hasCachedFeatures: Bool = false
    var features: SynchronizedArray<String> = SynchronizedArray<String>()
    private let cloudDiscoveryLock = NSRecursiveLock()
    private let groupServiceLock = NSLock()
    private var discoveredGroupServiceJID: String?
    private var groupServiceCandidateRanks: [String: Int] = [:]
    private var discoveredGroupServiceRank: Int?
    private var activeCloudDiscoveryQuery: ActiveCloudDiscoveryQuery?
    private var accountOwnerCapabilityGeneration: UInt64 = 0
    private var accountOwnerCapabilityDiscovery: AccountOwnerCapabilityDiscovery?

    var accountOwnerCapabilityGraceInterval = ServerDiscoManager.defaultAccountOwnerCapabilityGraceInterval

    var groupServiceJID: String? {
        groupServiceLock.lock()
        defer { groupServiceLock.unlock() }
        return discoveredGroupServiceJID
    }

    var activeCloudDiscoveryQueryIDForTesting: String? {
        cloudDiscoveryLock.lock()
        defer { cloudDiscoveryLock.unlock() }
        return activeCloudDiscoveryQuery?.elementID
    }

    var clientFeatures: [String] = []

    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        clientFeatures.append("http://jabber.org/protocol/disco#info")
        clientFeatures.append("http://jabber.org/protocol/disco#items")
//        clientFeatures.append("http://jabber.org/protocol/caps")
    }

    deinit {
        cloudDiscoveryLock.lock()
        let timeoutWorkItem = activeCloudDiscoveryQuery?.timeoutWorkItem
        let graceWorkItem = accountOwnerCapabilityDiscovery?.graceWorkItem
        activeCloudDiscoveryQuery = nil
        accountOwnerCapabilityDiscovery = nil
        cloudDiscoveryLock.unlock()
        timeoutWorkItem?.cancel()
        graceWorkItem?.cancel()
    }

    open func register(_ module: AbstractXMPPManager) {
        module.namespaces().forEach { feature in
            if !features.contains(feature) {
                clientFeatures.append(feature)
            }
        }
    }

    open func configure(_ xmppStream: XMPPStream) {
        _ = self.requestFeatures(xmppStream)
        self.requestServerFeatures(xmppStream)
        let hasCachedFeatures = self.loadFeatures()
        if hasCachedFeatures {
            self.hasCachedFeatures = true
//            AccountManager.shared.changeNewUserState(for: owner, to: .capsReceived([]))
        }
        // A group service is authoritative only when it is returned by root
        // disco#items and advertises the canonical Groups feature.
        requestItems(xmppStream)
    }


    open func generateVer() -> String {
        let featuresList: String = clientFeatures.sorted().compactMap { (item) -> String? in
            if item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return ["<", item.trimmingCharacters(in: .whitespacesAndNewlines)].joined()
        }.joined()
//        if !((SettingManager.shared.getString(for: "privacy_level") ?? "none") == SettingManager.PrivacyLevel.incognito.rawValue) {
            return "client/phone//\(ServerDiscoManager.clientName)\(featuresList)<"
                .data(using: String.Encoding.utf8)!
                .sha1()
                .base64EncodedString()
//        }
//        return "client/phone/en/\(featuresList)<"
//            .data(using: String.Encoding.utf8)!
//            .sha1()
//            .base64EncodedString()
    }

    @discardableResult
    func requestFeatures(_ xmppStream: XMPPStream) -> Bool {
        let elementId = xmppStream.generateUUID
        cloudDiscoveryLock.lock()
        if let discovery = accountOwnerCapabilityDiscovery,
           !discovery.isTerminal {
            activeCloudDiscoveryQuery?.onboardingCapabilityGeneration = discovery.generation
            cloudDiscoveryLock.unlock()
            return false
        }
        let previousGraceWorkItem = accountOwnerCapabilityDiscovery?.graceWorkItem
        accountOwnerCapabilityGeneration &+= 1
        let generation = accountOwnerCapabilityGeneration
        accountOwnerCapabilityDiscovery = AccountOwnerCapabilityDiscovery(
            generation: generation,
            elementID: elementId,
            result: .pending,
            pendingRootCapabilities: nil,
            graceWorkItem: nil,
            isTerminal: false
        )
        activeCloudDiscoveryQuery?.onboardingCapabilityGeneration = generation
        cloudDiscoveryLock.unlock()
        previousGraceWorkItem?.cancel()

        xmppStream.send(XMPPIQ(iqType: .get,
                               to: xmppStream.myJID?.bareJID,
                               elementID: elementId,
                               child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")))
        return true
    }

    func requestServerFeatures(_ xmppStream: XMPPStream) {
        let elementId = xmppStream.generateUUID
        cloudDiscoveryLock.lock()
        guard activeCloudDiscoveryQuery == nil else {
            cloudDiscoveryLock.unlock()
            return
        }
        if let discovery = accountOwnerCapabilityDiscovery,
           !discovery.isTerminal,
           discovery.pendingRootCapabilities != nil {
            cloudDiscoveryLock.unlock()
            return
        }
        let timeoutInterval = Self.cloudDiscoveryTimeoutInterval
        let deadline = DispatchTime.now() + timeoutInterval
        let onboardingCapabilityGeneration = accountOwnerCapabilityDiscovery.flatMap { discovery in
            discovery.isTerminal ? nil : discovery.generation
        }
        activeCloudDiscoveryQuery = ActiveCloudDiscoveryQuery(
            elementID: elementId,
            deadline: deadline,
            onboardingCapabilityGeneration: onboardingCapabilityGeneration,
            phase: .reserved,
            timeoutWorkItem: nil
        )
        AccountManager.shared.find(for: owner)?.cloudStorage.beginAvailabilityDiscovery()
        cloudDiscoveryLock.unlock()

        Self.cloudDiscoveryWillRegisterQueryTestingHandler?(self, elementId)

        cloudDiscoveryLock.lock()
        guard activeCloudDiscoveryQuery?.elementID == elementId,
              activeCloudDiscoveryQuery?.phase == .reserved else {
            cloudDiscoveryLock.unlock()
            return
        }
        activeCloudDiscoveryQuery?.phase = .registered
        Self.cloudDiscoveryDidRegisterQueryTestingHandler?(self)
        guard activeCloudDiscoveryQuery?.elementID == elementId,
              activeCloudDiscoveryQuery?.phase == .registered else {
            cloudDiscoveryLock.unlock()
            return
        }
        let timeoutWorkItem = makeCloudDiscoveryTimeoutWorkItem(for: elementId)
        activeCloudDiscoveryQuery?.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: deadline,
            execute: timeoutWorkItem
        )
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: xmppStream.myJID?.domainJID,
                               elementID: elementId,
                               child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")))
        cloudDiscoveryLock.unlock()
    }

    @discardableResult
    func cancelCloudDiscoveryForDisconnect() -> Bool {
        resetGroupServiceDiscovery()
        let activeCloudDiscovery = consumeActiveCloudDiscovery(
            elementID: nil,
            terminal: .disconnect,
            requiresRegisteredQuery: false
        )
        let capabilityResolution = terminateAccountOwnerCapabilityDiscovery(
            generation: nil,
            useCurrentGeneration: true
        )
        capabilityResolution.graceWorkItemToCancel?.cancel()

        guard activeCloudDiscovery != nil || capabilityResolution.wasTracked else {
            return false
        }
        completeServerCapabilitiesOnboarding(
            capabilityResolution.capabilitiesToPublish ?? [Self.retryableServerCapabilitiesMarker]
        )
        return true
    }

    func requestItems(_ xmppStream: XMPPStream) {
        resetGroupServiceDiscovery()
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: xmppStream.myJID?.domainJID,
                               elementID: elementId,
                               child: DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#items")))
        self.queryIds.insert(elementId)
    }

    func checkItem(_ xmppStream: XMPPStream, in jid: String, node: String?) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        if let node = node {
            query.addAttribute(withName: "node", stringValue: node)
        }
        xmppStream.send(XMPPIQ(iqType: .get, to: XMPPJID(string: jid), elementID: elementId, child: query))
        self.queryIds.insert(elementId)
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readIdentityRequest(withIQ: iq): return true
        case readFeatureError(withIQ: iq): return true
        case readFeatures(withIQ: iq): return true
        default: return false
        }
    }

    private func readFeatureError(withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let elementID = iq.elementID else {
            return false
        }

        if let generation = claimAccountOwnerCapabilityQuery(elementID: elementID) {
            let resolution = resolveAccountOwnerCapabilities(
                generation: generation,
                result: .failed
            )
            resolution.graceWorkItemToCancel?.cancel()
            if let capabilities = resolution.capabilitiesToPublish {
                completeServerCapabilitiesOnboarding(capabilities)
            }
            return true
        }

        guard let activeDiscovery = consumeActiveCloudDiscovery(
            elementID: elementID,
            terminal: .error,
            requiresRegisteredQuery: true
        ) else {
            return false
        }
        AccountManager.shared.find(for: owner)?.cloudStorage.markAvailabilityRetryableFailure(stage: .discovery)
        completeRetryableServerCapabilitiesOnboarding(for: activeDiscovery)
        return true
    }
    func readFeatures(withIQ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            iq.iqType == .result,
            let query = iq.element(forName: "query",
                                   xmlns: "http://jabber.org/protocol/disco#info") ??
                iq.element(forName: "query",
                           xmlns: "http://jabber.org/protocol/disco#items") else {
                return false
        }
        let activeServerDiscovery: ActiveCloudDiscoveryQuery?
        let accountOwnerCapabilityGeneration: UInt64?
        if query.xmlns() == "http://jabber.org/protocol/disco#info" {
            activeServerDiscovery = consumeActiveCloudDiscovery(
                elementID: elementId,
                terminal: .response,
                requiresRegisteredQuery: true
            )
            if activeServerDiscovery == nil {
                accountOwnerCapabilityGeneration = claimAccountOwnerCapabilityQuery(
                    elementID: elementId
                )
            } else {
                accountOwnerCapabilityGeneration = nil
            }
        } else {
            activeServerDiscovery = nil
            accountOwnerCapabilityGeneration = nil
        }
        let isServerFeatureResponse = activeServerDiscovery != nil
        let isAccountOwnerFeatureResponse = accountOwnerCapabilityGeneration != nil
        guard isServerFeatureResponse || isAccountOwnerFeatureResponse || queryIds.contains(elementId) else {
            return false
        }
        if !isServerFeatureResponse && !isAccountOwnerFeatureResponse {
            queryIds.remove(elementId)
        }

        switch query.xmlns() ?? "none" {
        case "http://jabber.org/protocol/disco#info":
            if isServerFeatureResponse {
                parseMessageScheduleSettings(query.elements(forName: "feature"), authoritative: true)
            }
            let discoveredGalleryEndpoint = parseAndStoreUrls(
                query: query,
                nspace: "urn:xabber:http:url",
                allowsGalleryMutation: isServerFeatureResponse
            )
            if isServerFeatureResponse {
                AccountManager.shared.find(for: owner)?.cloudStorage.resolveAuthoritativeDiscovery(
                    endpoint: discoveredGalleryEndpoint
                )
            }
            if !isServerFeatureResponse && !isAccountOwnerFeatureResponse {
                if parseClientIdentity(iq: iq) {
                    return true
                }
                if let jid = iq.from?.bare {
                    switch true {
                        case getGroupServiceNode(query, jid: jid): return true
                        case getNotificationServiceNode(query, jid: jid): return true
                        case getFavoritesServiceNode(query, jid: jid): return true
                        default: break
                    }
                }

                if let identity = query.element(forName: "identity") {
                    let type = identity.attributeStringValue(forName: "type")
                    let category = identity.attributeStringValue(forName: "category")

                    if category == "client" {
                        return true
                    } else if type == "file" && category == "store" {
                        self.parseHTTPSettings(query, node: iq.from?.full ?? "")
                        return true
                    }
//                else if type == "server" && category == "conference" && name == "Groupchat Service" {
//                    SettingManager.shared.saveItem(for: owner,
//                                                       scope: .globalIndex,
//                                                       key: "localJid",
//                                                       value: iq.from?.bare ?? "")
//                    SettingManager.shared.saveItem(for: owner,
//                                                       scope: .globalIndex,
//                                                       key: "localNode",
//                                                       value: query.attributeStringValue(forName: "node") ?? "")
//                    return true
//                }
                }
            }

            let features = query.elements(forName: "feature")
            var caps: [String] = []
            features.forEach {
                feature in
                if let node = feature.attributeStringValue(forName: "var") {
//                    print("NODE", node)
                    switch node {
                    case "urn:xmpp:mam:0":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:mam:1":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:mam:2":
                        let item = "mam"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/rewrite":
                        let item = "rewrite"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/auth-tokens":
                        let item = "xtokens"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "http://jabber.org/protocol/pubsub":
                        let item = "pubsub"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "urn:xmpp:push:0":
                        let item = "push"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "https://xabber.com/protocol/push":
                        let item = "xpush"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                    case "http://xabber.com/protocol/archive", "https://xabber.com/protocol/archive":
                        let item = "archive"
                        if !caps.contains(item) {
                            caps.append(item)
                        }
                        if AccountManager.shared.find(for: self.owner)?.mam.isExtendedArchiveAvailable != true {
                            AccountManager.shared.find(for: self.owner)?.mam.isExtendedArchiveAvailable = true
                            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                                user.mam.requestInviteRecovery(stream)
                            })
                        }
                    default: break
                    }
                }
            }
            if let activeServerDiscovery {
                parseReliableMessageDeliverySettings(query.elements(forName: "feature"))
                parseMessagesDeleteRewriteSettings(query.elements(forName: "feature"))
                completeRootServerCapabilities(
                    caps,
                    activeDiscovery: activeServerDiscovery
                )
            } else if let accountOwnerCapabilityGeneration {
                let resolution = resolveAccountOwnerCapabilities(
                    generation: accountOwnerCapabilityGeneration,
                    result: .resolved(accountOwnerPushCapabilities(from: caps))
                )
                resolution.graceWorkItemToCancel?.cancel()
                if let capabilities = resolution.capabilitiesToPublish {
                    completeServerCapabilitiesOnboarding(capabilities)
                }
            }
            return true
        case "http://jabber.org/protocol/disco#items":
            let items = query.elements(forName: "item")
            updateGroupServiceCandidates(
                items.compactMap { $0.attributeStringValue(forName: "jid") }
            )
            items.forEach { item in
                if let jid = item.attributeStringValue(forName: "jid") {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.disco.checkItem(stream, in: jid, node: item.attributeStringValue(forName: "node"))
                    })
                }
            }
            return true
        default: return false
        }
    }

    @discardableResult
    private func parseAndStoreUrls(
        query: DDXMLElement,
        nspace: String,
        allowsGalleryMutation: Bool
    ) -> URL? {
        var xDictionary: [String : String] = [:]
        var discoveredGalleryEndpoint: URL?

        for x in query.elements(forName: "x") {

            xDictionary = [:]
            let fields = x.elements(forName: "field")

            for field in fields {

                let fieldType = field.attributeStringValue(forName: "var")

                switch fieldType {
                    case "FORM_TYPE":
                        if let value = field.element(forName: "value"),
                            let namespace = value.stringValue {
                            xDictionary["namespace"] = namespace
                        }
                    case "urn:xabber:http:url:mediagallery":
                        if let value = field.element(forName: "value"),
                            let url = value.stringValue {
                            xDictionary["galleryURL"] = url
                        }
                    case "urn:xabber:http:url:clandestino:purchases:products:v1":
                        if let value = field.element(forName: "value"),
                            let url = value.stringValue {
                            xDictionary["productsUrl"] = url
                        }
                    case "abuse-addresses":
                        if let value = field.element(forName: "value"),
                           let jid = value.stringValue {
                            AccountManager.shared.find(for: self.owner)?.abuse.register(address: jid, for: self.owner, isGroup: false)
                        }
                    default:
                        continue
                }
            }

            if let namespace = xDictionary["namespace"], namespace == nspace {

                if allowsGalleryMutation, let galleryURL = xDictionary["galleryURL"] {
                    let galleryConfiguration = AccountGalleryConfiguration(owner: self.owner)
                    let normalizedEndpoint = AccountGalleryConfiguration.normalizedBaseURL(from: galleryURL)
                    let didStoreBasicGalleryURL = galleryConfiguration.storeBasicGalleryURL(galleryURL)
                    discoveredGalleryEndpoint = normalizedEndpoint
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, _ in
                        if didStoreBasicGalleryURL, let basicGalleryURL = galleryConfiguration.basicGalleryURL {
                            user.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: basicGalleryURL)
                        }
                        let currentURL = galleryConfiguration.currentGalleryURL?.absoluteString ?? galleryURL
                        user.cloudStorage.node = currentURL
                        user.avatarUploader.node = currentURL
                    })
                }

                if let productsUrl = xDictionary["productsUrl"] {
                    SettingManager.shared.saveItem(for: self.owner, scope: .products, key: "productsUrl", value: productsUrl)
                }
            }
        }
        return discoveredGalleryEndpoint
    }

    private func makeCloudDiscoveryTimeoutWorkItem(for elementID: String) -> DispatchWorkItem {
        let workItem = DispatchWorkItem { [weak self] in
            self?.cloudDiscoveryDidTimeout(elementID: elementID)
        }
        return workItem
    }

    private func cloudDiscoveryDidTimeout(elementID: String) {
        guard let activeDiscovery = consumeActiveCloudDiscovery(
            elementID: elementID,
            terminal: .timeout,
            requiresRegisteredQuery: true
        ) else { return }
        AccountManager.shared.find(for: owner)?.cloudStorage.markAvailabilityRetryableFailure(stage: .discovery)
        completeRetryableServerCapabilitiesOnboarding(for: activeDiscovery)
    }

    @discardableResult
    private func consumeActiveCloudDiscovery(
        elementID: String?,
        terminal: CloudDiscoveryTerminalKind,
        requiresRegisteredQuery: Bool
    ) -> ActiveCloudDiscoveryQuery? {
        cloudDiscoveryLock.lock()
        guard let activeQuery = activeCloudDiscoveryQuery,
              elementID == nil || activeQuery.elementID == elementID,
              !requiresRegisteredQuery || activeQuery.phase == .registered else {
            cloudDiscoveryLock.unlock()
            return nil
        }
        activeCloudDiscoveryQuery = nil
        cloudDiscoveryLock.unlock()

        activeQuery.timeoutWorkItem?.cancel()
        Self.cloudDiscoveryDidConsumeTerminalTestingHandler?(terminal)
        return activeQuery
    }

    private func claimAccountOwnerCapabilityQuery(elementID: String) -> UInt64? {
        cloudDiscoveryLock.lock()
        guard var discovery = accountOwnerCapabilityDiscovery,
              !discovery.isTerminal,
              discovery.elementID == elementID else {
            cloudDiscoveryLock.unlock()
            return nil
        }
        discovery.elementID = nil
        accountOwnerCapabilityDiscovery = discovery
        cloudDiscoveryLock.unlock()
        return discovery.generation
    }

    private func resolveAccountOwnerCapabilities(
        generation: UInt64,
        result: AccountOwnerCapabilityResult
    ) -> AccountOwnerCapabilityResolution {
        cloudDiscoveryLock.lock()
        guard var discovery = accountOwnerCapabilityDiscovery,
              discovery.generation == generation,
              !discovery.isTerminal else {
            cloudDiscoveryLock.unlock()
            return AccountOwnerCapabilityResolution(
                wasTracked: false,
                capabilitiesToPublish: nil,
                graceWorkItemToCancel: nil
            )
        }

        discovery.result = result
        var capabilitiesToPublish: [String]?
        var graceWorkItemToCancel: DispatchWorkItem?
        if let rootCapabilities = discovery.pendingRootCapabilities {
            capabilitiesToPublish = capabilities(
                rootCapabilities,
                mergedWith: result
            )
            discovery.pendingRootCapabilities = nil
            graceWorkItemToCancel = discovery.graceWorkItem
            discovery.graceWorkItem = nil
            discovery.isTerminal = true
        }
        accountOwnerCapabilityDiscovery = discovery
        cloudDiscoveryLock.unlock()

        return AccountOwnerCapabilityResolution(
            wasTracked: true,
            capabilitiesToPublish: capabilitiesToPublish,
            graceWorkItemToCancel: graceWorkItemToCancel
        )
    }

    private func completeRootServerCapabilities(
        _ capabilities: [String],
        activeDiscovery: ActiveCloudDiscoveryQuery
    ) {
        let rootCapabilities = rootScopedCapabilities(from: capabilities)
        guard let generation = activeDiscovery.onboardingCapabilityGeneration else {
            completeServerCapabilitiesOnboarding(rootCapabilities)
            return
        }

        let remainingCloudDiscoveryInterval = remainingInterval(until: activeDiscovery.deadline)
        let graceInterval = min(
            max(accountOwnerCapabilityGraceInterval, 0),
            remainingCloudDiscoveryInterval
        )
        var capabilitiesToPublish: [String]?
        var graceWorkItemToSchedule: DispatchWorkItem?
        var graceWorkItemToCancel: DispatchWorkItem?

        cloudDiscoveryLock.lock()
        guard var discovery = accountOwnerCapabilityDiscovery,
              discovery.generation == generation,
              !discovery.isTerminal else {
            cloudDiscoveryLock.unlock()
            return
        }

        switch discovery.result {
        case .resolved(_), .failed:
            capabilitiesToPublish = self.capabilities(
                rootCapabilities,
                mergedWith: discovery.result
            )
            discovery.elementID = nil
            discovery.isTerminal = true
        case .pending where graceInterval <= 0:
            capabilitiesToPublish = capabilitiesWithRetryableMarker(rootCapabilities)
            discovery.elementID = nil
            discovery.result = .failed
            discovery.isTerminal = true
        case .pending:
            graceWorkItemToCancel = discovery.graceWorkItem
            let workItem = makeAccountOwnerCapabilityGraceWorkItem(generation: generation)
            discovery.pendingRootCapabilities = rootCapabilities
            discovery.graceWorkItem = workItem
            graceWorkItemToSchedule = workItem
        }
        accountOwnerCapabilityDiscovery = discovery
        cloudDiscoveryLock.unlock()

        graceWorkItemToCancel?.cancel()
        if let graceWorkItemToSchedule {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + graceInterval,
                execute: graceWorkItemToSchedule
            )
        }
        if let capabilitiesToPublish {
            completeServerCapabilitiesOnboarding(capabilitiesToPublish)
        }
    }

    private func makeAccountOwnerCapabilityGraceWorkItem(generation: UInt64) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            self?.accountOwnerCapabilityGraceDidExpire(generation: generation)
        }
    }

    private func accountOwnerCapabilityGraceDidExpire(generation: UInt64) {
        cloudDiscoveryLock.lock()
        guard var discovery = accountOwnerCapabilityDiscovery,
              discovery.generation == generation,
              !discovery.isTerminal,
              case .pending = discovery.result,
              let rootCapabilities = discovery.pendingRootCapabilities else {
            cloudDiscoveryLock.unlock()
            return
        }
        discovery.elementID = nil
        discovery.result = .failed
        discovery.pendingRootCapabilities = nil
        discovery.graceWorkItem = nil
        discovery.isTerminal = true
        accountOwnerCapabilityDiscovery = discovery
        cloudDiscoveryLock.unlock()

        completeServerCapabilitiesOnboarding(
            capabilitiesWithRetryableMarker(rootCapabilities)
        )
    }

    private func terminateAccountOwnerCapabilityDiscovery(
        generation: UInt64?,
        useCurrentGeneration: Bool
    ) -> AccountOwnerCapabilityResolution {
        cloudDiscoveryLock.lock()
        guard var discovery = accountOwnerCapabilityDiscovery,
              !discovery.isTerminal,
              useCurrentGeneration || generation == discovery.generation else {
            cloudDiscoveryLock.unlock()
            return AccountOwnerCapabilityResolution(
                wasTracked: false,
                capabilitiesToPublish: nil,
                graceWorkItemToCancel: nil
            )
        }
        let rootCapabilities = discovery.pendingRootCapabilities ?? []
        let graceWorkItemToCancel = discovery.graceWorkItem
        discovery.elementID = nil
        discovery.result = .failed
        discovery.pendingRootCapabilities = nil
        discovery.graceWorkItem = nil
        discovery.isTerminal = true
        accountOwnerCapabilityDiscovery = discovery
        cloudDiscoveryLock.unlock()

        return AccountOwnerCapabilityResolution(
            wasTracked: true,
            capabilitiesToPublish: capabilitiesWithRetryableMarker(rootCapabilities),
            graceWorkItemToCancel: graceWorkItemToCancel
        )
    }

    private func completeRetryableServerCapabilitiesOnboarding(
        for activeDiscovery: ActiveCloudDiscoveryQuery
    ) {
        guard let generation = activeDiscovery.onboardingCapabilityGeneration else {
            completeServerCapabilitiesOnboarding([Self.retryableServerCapabilitiesMarker])
            return
        }
        let resolution = terminateAccountOwnerCapabilityDiscovery(
            generation: generation,
            useCurrentGeneration: false
        )
        resolution.graceWorkItemToCancel?.cancel()
        guard resolution.wasTracked,
              let capabilities = resolution.capabilitiesToPublish else {
            return
        }
        completeServerCapabilitiesOnboarding(capabilities)
    }

    private func completeServerCapabilitiesOnboarding(_ capabilities: [String]) {
        AccountManager.shared.changeNewUserState(
            for: owner,
            to: .capsReceived(capabilities)
        )
    }

    private func accountOwnerPushCapabilities(from capabilities: [String]) -> [String] {
        ["push", "xpush"].filter(capabilities.contains)
    }

    private func rootScopedCapabilities(from capabilities: [String]) -> [String] {
        capabilities.filter { $0 != "push" && $0 != "xpush" }
    }

    private func capabilities(
        _ rootCapabilities: [String],
        mergedWith accountOwnerResult: AccountOwnerCapabilityResult
    ) -> [String] {
        switch accountOwnerResult {
        case .resolved(let accountOwnerCapabilities):
            var mergedCapabilities = rootScopedCapabilities(from: rootCapabilities)
            accountOwnerPushCapabilities(from: accountOwnerCapabilities).forEach { capability in
                if !mergedCapabilities.contains(capability) {
                    mergedCapabilities.append(capability)
                }
            }
            return mergedCapabilities
        case .failed:
            return capabilitiesWithRetryableMarker(rootCapabilities)
        case .pending:
            return rootScopedCapabilities(from: rootCapabilities)
        }
    }

    private func capabilitiesWithRetryableMarker(_ rootCapabilities: [String]) -> [String] {
        var capabilities = rootScopedCapabilities(from: rootCapabilities)
        if !capabilities.contains(Self.retryableServerCapabilitiesMarker) {
            capabilities.append(Self.retryableServerCapabilitiesMarker)
        }
        return capabilities
    }

    private func remainingInterval(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0 }
        return TimeInterval(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private func getNotificationServiceNode(_ query: DDXMLElement, jid: String) -> Bool {
        if let identity = query.element(forName: "identity"),
           identity.attributeStringValue(forName: "type") == "notification",
           identity.attributeStringValue(forName: "category") == "component" {
            AccountManager.shared.find(for: self.owner)?.notifications.configure(for: jid)
            return true
        }
        return false
    }

    static func supportsGroupService(_ query: DDXMLElement) -> Bool {
        query.elements(forName: "feature").contains { feature in
            feature.attributeStringValue(forName: "var") == GroupProtocolNamespace.groups
        }
    }

    static func orderedGroupServiceRanks(_ jids: [String]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (rank, rawJID) in jids.enumerated() {
            guard let bare = XMPPJID(string: rawJID)?.bare.lowercased(),
                  ranks[bare] == nil else { continue }
            ranks[bare] = rank
        }
        return ranks
    }

    static func shouldSelectGroupService(
        candidateRank: Int,
        currentRank: Int?
    ) -> Bool {
        currentRank.map { candidateRank < $0 } ?? true
    }

    private func getGroupServiceNode(_ query: DDXMLElement, jid: String) -> Bool {
        guard Self.supportsGroupService(query),
              let normalizedJID = XMPPJID(string: jid)?.bare,
              !normalizedJID.isEmpty else {
            return false
        }
        selectGroupServiceJID(normalizedJID)
        return true
    }

    private func resetGroupServiceDiscovery() {
        groupServiceLock.lock()
        let didChange = discoveredGroupServiceJID != nil
        discoveredGroupServiceJID = nil
        discoveredGroupServiceRank = nil
        groupServiceCandidateRanks.removeAll()
        groupServiceLock.unlock()

        publishGroupServiceChangeIfNeeded(didChange)
    }

    private func updateGroupServiceCandidates(_ jids: [String]) {
        let ranks = Self.orderedGroupServiceRanks(jids)
        groupServiceLock.lock()
        groupServiceCandidateRanks = ranks
        groupServiceLock.unlock()
    }

    private func selectGroupServiceJID(_ rawJID: String) {
        let jid = rawJID.lowercased()
        groupServiceLock.lock()
        guard let rank = groupServiceCandidateRanks[jid] else {
            groupServiceLock.unlock()
            return
        }
        let shouldSelect = Self.shouldSelectGroupService(
            candidateRank: rank,
            currentRank: discoveredGroupServiceRank
        )
        let didChange = shouldSelect && discoveredGroupServiceJID != jid
        if shouldSelect {
            discoveredGroupServiceJID = jid
            discoveredGroupServiceRank = rank
        }
        groupServiceLock.unlock()

        publishGroupServiceChangeIfNeeded(didChange)
    }

    private func publishGroupServiceChangeIfNeeded(_ didChange: Bool) {
        guard didChange else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .groupServiceDiscoveryDidChange,
                object: self,
                userInfo: ["owner": self.owner]
            )
        }
    }

    private func getFavoritesServiceNode(_ query: DDXMLElement, jid: String)-> Bool {
        guard XMPPFavoritesManager.supportsService(query) else {
            return false
        }

        AccountManager.shared.find(for: self.owner)?.favorites.configure(for: jid)
        return true
    }

    private func parseHTTPSettings(_ query: DDXMLElement, node: String) {
        var namespace: String = ""
        for feature in query.elements(forName: "feature") {
            if let featureVar = feature.attributeStringValue(forName: "var") {
                if featureVar == "urn:xmpp:http:upload" {
                    namespace = "urn:xmpp:http:upload"
                } else if featureVar == "urn:xmpp:http:upload:0" {
                    namespace = "urn:xmpp:http:upload:0"
                    break
                }
            }
        }
        if namespace.isEmpty { return }
        var maxFileSize: Int32 = 0
        for x in query.elements(forName: "x") {
            var xNamespace: String = ""
            for field in x.elements(forName: "field") {
                let fieldType = field.attributeStringValue(forName: "var")
                if fieldType == "FORM_TYPE" {
                    xNamespace = field.element(forName: "value")?.stringValue ?? ""
                } else if fieldType == "max-file-size" {
                    maxFileSize = field.element(forName: "value")?.stringValueAsInt() ?? 0
                }
            }
            if xNamespace == namespace {
                break
            } else {
                maxFileSize = 0
            }
        }
        self.saveHTTPSettings(node, namespace: namespace, max: Int(maxFileSize))
    }

    private func saveHTTPSettings(_ node: String, namespace: String, max fileSize: Int) {
        if node.isEmpty { return }
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "node", value: node)
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "namespace", value: namespace)
        SettingManager.shared.saveItem(for: owner, scope: .httpUploader, key: "max_file_size", value: "\(fileSize)")

        //If XabberUploadManager will implemet disco in future
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "node", value: node)
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "namespace", value: namespace)
//        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "max_file_size", value: "\(fileSize)")
    }

    private func parseReliableMessageDeliverySettings(_ features: [DDXMLElement]) {
        if features.map({ //item in
            return $0.attributeStringValue(forName: "var")
        }).contains("https://xabber.com/protocol/delivery") {
            saveReliableMessageDeliverySettings("https://xabber.com/protocol/delivery")
        }
    }


    private func parseMessagesDeleteRewriteSettings(_ features: [DDXMLElement]) {
        if features.map({ //item in
            return $0.attributeStringValue(forName: "var")
        }).contains("https://xabber.com/protocol/rewrite") {
            saveMessagesDeleteRewriteSettings("https://xabber.com/protocol/rewrite")
        }
    }

    private func parseMessageScheduleSettings(_ features: [DDXMLElement], authoritative: Bool) {
        let hasSchedule = features.map {
            return $0.attributeStringValue(forName: "var")
        }.contains(XMPPMessageScheduleManager.namespace)
        if hasSchedule {
            XMPPMessageScheduleManager.saveAvailability(owner: owner, isAvailable: true)
        } else if authoritative {
            XMPPMessageScheduleManager.saveAvailability(owner: owner, isAvailable: false)
        }
        AccountManager.shared.find(for: owner)?.messageSchedule.checkAvailability()
    }

    private func saveReliableMessageDeliverySettings(_ node: String) {
        SettingManager.shared.saveItem(for: owner,
                                           scope: .reliableMessageDelivery,
                                           key: "node",
                                           value: node)
        AccountManager.shared.find(for: owner)?.action({ (user, _) in
            user.deliveryManager.checkAvailability()
        })
    }

    private func saveMessagesDeleteRewriteSettings(_ node: String) {
        SettingManager.shared.saveItem(for: owner,
                                           scope: .messageDeleteRewrite,
                                           key: "node",
                                           value: node)
        AccountManager.shared.find(for: owner)?.action({ (user, _) in
            user.msgDeleteManager.checkAvailability()
        })
    }

    func loadFeatures() -> Bool {
        if SettingManager
            .shared
            .getKey(for: owner, scope: .httpUploader, key: "node")?
//            .getKey(for: owner, scope: .xabberUploadManager, key: "node")?
            .isNotEmpty ?? false { return true}
        return false
    }

//    Identity block
    open func sendIdentity(_ xmppStream: XMPPStream, to jid: XMPPJID?, for elementId: String) {
        let query = DDXMLElement(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
        query.addAttribute(withName: "node", stringValue: "https://www.xabber.com/clients/xabber/ios")
        let identity = DDXMLElement.element(withName: "identity") as! DDXMLElement
        identity.addAttribute(withName: "category", stringValue: "client")
        identity.addAttribute(withName: "name", stringValue: ServerDiscoManager.clientName)
        identity.addAttribute(withName: "type", stringValue: "phone")
        for feature in clientFeatures.sorted() {
            if feature.isEmpty { continue }
            let element = DDXMLElement.element(withName: "feature") as! DDXMLElement
            element.addAttribute(withName: "var", stringValue: feature)
            query.addChild(element)
        }
        query.addChild(identity)
        xmppStream.send(XMPPIQ(iqType: .result, to: jid, elementID: elementId, child: query))
    }

    func readIdentityRequest(withIQ iq: XMPPIQ) -> Bool {
        if iq.iqType == .get {
            if iq.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info" {
                guard let from = iq.from else { return false }
                guard let elementId = iq.elementID else { return false }
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.disco.sendIdentity(stream, to: from, for: elementId)
                })
                return true
            }
        }
        return false
    }

    private func parseClientIdentity(iq: XMPPIQ) -> Bool {
        guard let from = iq.from,
            let resource = from.resource,
            let identity = iq.element(forName: "query")?.element(forName: "identity"),
            let category = identity.attributeStringValue(forName: "category"),
            category == "client" else { return false }
        return true
    }

    func requestIdentity(_ xmppStream: XMPPStream, by presence: XMPPPresence) {
        guard let jid = presence.from else {
            return
        }
        guard let caps = presence.element(forName: "c"),
            let node = caps.attributeStringValue(forName: "node"),
            let ver = caps.attributeStringValue(forName: "ver") else {
                requestIdentity(xmppStream, for: jid)
                return
        }
        requestIdentity(xmppStream, for: jid, node: [node, ver].joined(separator: "#"))
    }

    func requestIdentity(_ xmppStream: XMPPStream, for jid: XMPPJID, node: String? = nil) {
        if isResourseCached(for: jid) { return }
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement.element(withName: "query") as! DDXMLElement
        query.setXmlns("http://jabber.org/protocol/disco#info")
        if let node = node {
            query.addAttribute(withName: "node", stringValue: node)
        }
        let iq = XMPPIQ(iqType: .get, to: jid, elementID: elementId, child: query)
        xmppStream.send(iq)
        self.queryIds.insert(elementId)
    }

    func requestIdentityForAllResources(_ xmppStream: XMPPStream, for jid: String) {
        do {
            let realm = try WRealm.safe()
            realm.objects(ResourceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid).forEach {
                if let jid = XMPPJID(string: jid, resource: $0.resource) {
                    requestIdentity(xmppStream, for: jid) // fail when resources not found
                }
            }
        } catch {
            DDLogDebug("cant get roster item for jid \(jid), account: \(self.owner) to build list of resources")
        }
    }

    override func clearSession() {
        cancelCloudDiscoveryForDisconnect()
        queryIds.removeAll()
    }

    func parseClientFeatures(_ query: DDXMLElement?) -> ClientDiscoStorageItem {
        let item = ClientDiscoStorageItem()
        if query == nil { return item }
        for feature in query!.elements(forName: "feature") {
            if let value = feature.attributeStringValue(forName: "var") {
                item.features.append(value)
            }
        }
        return item
    }

    static func remove(for owner: String, commitTransaction: Bool) {

    }

    func isResourseCached(for jid: XMPPJID) -> Bool {
        do {
            let realm = try WRealm.safe()
            return !realm.objects(ClientDiscoStorageItem.self).filter("owner == %@ AND jid == %@ AND resource == %@", self.owner, jid.bare, jid.resource ?? "").isEmpty
        } catch {
            DDLogDebug("cant check cached resource. \(error.localizedDescription)")
        }
        return false
    }

    func isAnyClient(has feature: String, jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            let resources = realm.objects(ClientDiscoStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, jid)
            for resource in resources {
                if resource.features.contains(feature) {
                    return true
                }
            }
        } catch {
            DDLogDebug("cant check fature. \(error.localizedDescription)")
        }
        return false
    }
}
