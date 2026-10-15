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
import dnssd
import Security
import XMPPFramework

class PushNotificationsManager: AbstractXMPPManager {
    enum EnableState: Equatable {
        case disabled
        case pending(queryId: String)
        case enabled
    }
    
    static let suitName: String = "group.com.xabber"

    typealias RegistrationTimeoutScheduler = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    private final class RegistrationRequest {
        let id: String
        let diagnosticID: UUID
        let owner: String
        let node: String
        let service: String
        let streamJID: String
        let domain: String
        let epoch: UInt64
        let wasEnabled: Bool
        weak var stream: XMPPStream?
        var callbacks: [(Bool) -> Void]
        var cancelTimeout: (() -> Void)?
        var keyBytes: [UInt8]?
        var payloadMode: PushPayloadMode?
        var hasBeenSent = false
        var didObserveSend = false

        init(id: String, owner: String, node: String, service: String, jid: XMPPJID,
             epoch: UInt64, wasEnabled: Bool, stream: XMPPStream, callback: @escaping (Bool) -> Void) {
            self.id = id
            self.diagnosticID = UUID(uuidString: id) ?? UUID()
            self.owner = owner
            self.node = node
            self.service = service
            self.streamJID = jid.full
            self.domain = jid.domain
            self.epoch = epoch
            self.wasEnabled = wasEnabled
            self.stream = stream
            self.callbacks = [callback]
        }
    }

    private final class HTTPArchiveRequest {
        let owner: String
        let node: String
        let domain: String
        let epoch: UInt64
        let streamJID: String
        let key: [UInt8]
        weak var stream: XMPPStream?
        var id = ""
        var endpoint: String?
        var cancelTimeout: (() -> Void)?

        init(owner: String, node: String, jid: XMPPJID, epoch: UInt64,
             stream: XMPPStream, key: [UInt8]) {
            self.owner = owner
            self.node = node
            self.domain = jid.domain
            self.epoch = epoch
            self.streamJID = jid.full
            self.stream = stream
            self.key = key
        }
    }

    private enum RegistrationError: Error {
        case invalidCredentials
        case randomGenerationFailed
    }

    private let stateLock = NSRecursiveLock()
    private var configuredNode = ""
    private var configuredService = ""
    private var configurationEpoch: UInt64 = 0
    private var registrationRequest: RegistrationRequest?
    private var registrationState: EnableState = .disabled
    private var acknowledgedPayloadMode: PushPayloadMode?
    private var httpArchiveRequest: HTTPArchiveRequest?
    // Account lifecycle explicitly defers full-auth registration until owner disco.
    // Direct managers retain the existing, server-confirmed profile by default.
    private var customPushSupported: Bool? = true

    var registrationTimeoutInterval: TimeInterval = 15
    var registrationTimeoutScheduler: RegistrationTimeoutScheduler = { interval, fire in
        let workItem = DispatchWorkItem(block: fire)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: workItem)
        return { workItem.cancel() }
    }
    var credentialReader: (String) throws -> CredentialsManager.PushSecretData = {
        try CredentialsManager.shared.getPushCredentials(for: $0)
    }
    var credentialWriter: (String, CredentialsManager.PushSecretData) throws -> Void = { node, record in
        try CredentialsManager.shared.storePushCredentials(
            node: node, jid: record.jid, host: record.host, secret: record.secret,
            service: record.service, jwt: record.jwt, keyEncoding: record.keyEncoding,
            grantRevision: record.grantRevision, httpArchive: record.httpArchive
        )
    }
    var tokenInvalidationStore: PushTokenInvalidationStore? = .live
    var payloadModeProvider: () -> PushPayloadMode = { PushPayloadPreferences.current }
    var httpArchiveNow: () -> Date = { Date() }
    var diagnostics: PushRegistrationDiagnosticLogger = .live
    
    var enable: Bool = true
    var node: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return configuredNode
        }
        set { updateConfiguration(node: newValue, service: nil) }
    }
    var service: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return configuredService
        }
        set { updateConfiguration(node: nil, service: newValue) }
    }
    var websocketUrl: String? = nil
    var enableState: EnableState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return registrationState
    }
    
    typealias DNSLookupHandler = ([String: String]?) -> Void

//    static public func WSLookup(for domainName: String) -> [String: String]? {
//        var result: [String: String] = [:]
//        var recordHandler: DNSLookupHandler = {
//            (record) -> Void in
//            if (record != nil) {
//                for (k, v) in record! {
//                    result.updateValue(v, forKey: k)
//                }
//            }
//        }
//
//        let callback: DNSServiceQueryRecordReply = {
//            (sdRef, flags, interfaceIndex, errorCode, fullname, rrtype, rrclass, rdlen, rdata, ttl, context) -> Void in
//            guard let handlerPtr = context?.assumingMemoryBound(to: DNSLookupHandler.self) else {
//                return
//            }
//            let handler = handlerPtr.pointee
//            if (errorCode != kDNSServiceErr_NoError) {
//                return
//            }
//            guard let txtPtr = rdata?.assumingMemoryBound(to: UInt8.self) else {
//                return
//            }
//            let txt = String(cString: txtPtr.advanced(by: 1))
//            var record: [String: String] = [:]
//            let parts = txt.components(separatedBy: "=")
//            print(parts)
//            record[parts[0]] = parts[1]
//            handler(record)
//        }
//
//        let serviceRef: UnsafeMutablePointer<DNSServiceRef?> = UnsafeMutablePointer.allocate(capacity: MemoryLayout<DNSServiceRef>.size)
//        let code = DNSServiceQueryRecord(serviceRef, kDNSServiceFlagsTimeout, 0, domainName, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), callback, &recordHandler)
//        if (code != kDNSServiceErr_NoError) {
//            return nil
//        }
//        DNSServiceProcessResult(serviceRef.pointee)
//        DNSServiceRefDeallocate(serviceRef.pointee)
//
//        return result
//    }
    
    static private func getDomainForLookup(_ domain: String) -> String {
        return "_xmppconnect.\(domain)"
    }
    
    override func namespaces() -> [String] {
        return ["https://xabber.com/protocol/push"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override init(withOwner owner: String) {
        
        super.init(withOwner: owner)
//        DispatchQueue.global(qos: .background).async {
//            if let domain = XMPPJID(string: owner)?.domain {
//                self.websocketUrl = PushNotificationsManager
//                    .WSLookup(for: PushNotificationsManager
//                                .getDomainForLookup(domain))?["_xmpp-client-websocket"]
//                if self.websocketUrl == nil {
//                    self.websocketUrl = PushNotificationsManager
//                        .WSLookup(for: PushNotificationsManager
//                                    .getDomainForLookup("xabber.com"))?["_xmpp-client-websocket"]
//                }
//            }
//        }
//        print("DNS LOOKUP", query(domainName: "_xmppconnect.xabber.com"))
        
    }
    
    internal func isAvailable(_ host: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return customPushSupported == true && XMPPJID(string: owner)?.domain == host
    }
    
    func configure(node: String, service: String) {
        updateConfiguration(node: node, service: service)
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.push.enable(xmppStream: stream) { _ in
                user.pushStatusMessage.accept(user.push.enabled)
            }
        })
    }
    
    var enabled: Bool {
        enableState == .enabled
    }

    /// The latest requested payload mode was acknowledged by the server.
    var isPayloadModeCurrent: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return registrationState == .enabled && acknowledgedPayloadMode == payloadModeProvider()
    }

    var isAwaitingCustomPushSupport: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return customPushSupported == nil
    }

    var httpPreviewReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let credentials = try? credentialReader(configuredNode),
              credentials.jid == owner,
              credentials.host == XMPPJID(string: owner)?.domain,
              credentials.keyBytes != nil, let grant = credentials.httpArchive,
              grant.isUsable(forAccount: owner, host: credentials.host, now: httpArchiveNow()),
              credentials.tokenExpiresAt.map({ $0 > httpArchiveNow() }) == true,
              let store = tokenInvalidationStore,
              (try? store.contains(node: configuredNode, generation: credentials.tokenGeneration)) == false else {
            return false
        }
        return true
    }

    var needsHTTPArchive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let isProvisioning = httpArchiveRequest.map(isCurrentHTTPArchiveRequestLocked) ?? false
        return payloadModeProvider() == .summary && !httpPreviewReady && !isProvisioning
    }

    func awaitCustomPushSupport() {
        stateLock.lock()
        customPushSupported = nil
        configurationEpoch &+= 1
        cancelHTTPArchiveRequestLocked()
        let callbacks = finishRequestLocked(success: false, preserveRegistration: false)
        registrationState = .disabled
        acknowledgedPayloadMode = nil
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }

    func setCustomPushSupport(_ supported: Bool, xmppStream: XMPPStream) {
        guard xmppStream.myJID?.bare == owner else { return }
        stateLock.lock()
        customPushSupported = supported
        var callbacks: [(Bool) -> Void] = []
        if !supported {
            cancelHTTPArchiveRequestLocked()
            if registrationRequest != nil {
                diagnostics.record(.blocked(reason: .unsupportedServer))
            }
            callbacks = finishRequestLocked(success: false, preserveRegistration: false)
            registrationState = .disabled
            acknowledgedPayloadMode = nil
        } else if let request = registrationRequest, !request.hasBeenSent {
            if request.stream === xmppStream, isCurrentRequestLocked(request) {
                callbacks = sendRequestLocked(request)
            } else {
                callbacks = finishRequestLocked(success: false, preserveRegistration: false)
            }
        }
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }
    
    func enable(xmppStream: XMPPStream, callback: @escaping (Bool)->Void) {
        beginRegistration(xmppStream: xmppStream, refresh: false, callback: callback)
    }

    func refresh(xmppStream: XMPPStream, callback: @escaping (Bool) -> Void) {
        beginRegistration(xmppStream: xmppStream, refresh: true, callback: callback)
    }

    private func beginRegistration(xmppStream: XMPPStream, refresh: Bool, callback: @escaping (Bool) -> Void) {
        stateLock.lock()
        guard let jid = xmppStream.myJID, jid.bare == owner,
              jid.user?.isEmpty == false else {
            diagnostics.record(.blocked(reason: .invalidAccount))
            stateLock.unlock()
            callback(false)
            return
        }
        guard configuredNode.isNotEmpty, configuredService.isNotEmpty else {
            diagnostics.record(.blocked(reason: .missingConfiguration))
            stateLock.unlock()
            callback(false)
            return
        }
        guard customPushSupported != false else {
            diagnostics.record(.blocked(reason: .unsupportedServer))
            stateLock.unlock()
            callback(false)
            return
        }
        if let request = registrationRequest {
            guard request.stream === xmppStream, isCurrentRequestLocked(request) else {
                stateLock.unlock()
                callback(false)
                return
            }
            request.callbacks.append(callback)
            stateLock.unlock()
            return
        }
        if registrationState == .enabled, !refresh, acknowledgedPayloadMode == payloadModeProvider() {
            if needsHTTPArchive { startHTTPArchiveRequestLocked(xmppStream) }
            stateLock.unlock()
            callback(true)
            return
        }
        let callbacks = startRegistrationLocked(xmppStream: xmppStream, jid: jid, callbacks: [callback])
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }

    private func startRegistrationLocked(
        xmppStream: XMPPStream, jid: XMPPJID, callbacks: [(Bool) -> Void]
    ) -> [(Bool) -> Void] {
        cancelHTTPArchiveRequestLocked()
        let request = RegistrationRequest(
            id: xmppStream.generateUUID, owner: owner, node: configuredNode,
            service: configuredService, jid: jid, epoch: configurationEpoch,
            wasEnabled: registrationState == .enabled, stream: xmppStream,
            callback: callbacks.first ?? { _ in }
        )
        request.callbacks = callbacks
        registrationRequest = request
        if !request.wasEnabled {
            registrationState = .pending(queryId: request.id)
        }
        request.cancelTimeout = registrationTimeoutScheduler(registrationTimeoutInterval) { [weak self, weak request] in
            guard let self, let request else { return }
            self.registrationDidTimeout(request)
        }
        if customPushSupported == true, registrationRequest === request {
            return sendRequestLocked(request)
        }
        if registrationRequest === request {
            diagnostics.record(.waiting(request: request.diagnosticID))
        }
        return []
    }

    private func sendRequestLocked(_ request: RegistrationRequest) -> [(Bool) -> Void] {
        guard isCurrentRequestLocked(request), let stream = request.stream,
              stream.myJID?.full == request.streamJID else {
            return finishRequestLocked(success: false, preserveRegistration: request.wasEnabled)
        }
        do {
            let credentials = try registrationCredentials(request)
            guard let keyBytes = credentials.keyBytes else {
                throw RegistrationError.invalidCredentials
            }
            request.keyBytes = keyBytes
            let mode = payloadModeProvider()
            request.payloadMode = mode
            let enableElement = DDXMLElement(name: "enable", xmlns: getPrimaryNamespace())
            enableElement.addAttribute(withName: "node", stringValue: request.node)
            enableElement.addAttribute(withName: "jid", stringValue: request.service)
            enableElement.addAttribute(withName: "mode", stringValue: mode.rawValue)
            let encryption = DDXMLElement(name: "encryption", xmlns: getPrimaryNamespace())
            encryption.addAttribute(withName: "algorithm", stringValue: "urn:xmpp:ciphers:aes-256-cbc")
            let key = DDXMLElement(name: "key", xmlns: getPrimaryNamespace())
            key.stringValue = Data(keyBytes).base64EncodedString()
            encryption.addChild(key)
            enableElement.addChild(encryption)

            publishNonsecretDefaults(request)
            request.hasBeenSent = true
            queryIds.insert(request.id)
            diagnostics.record(.queued(request: request.diagnosticID, mode: mode))
            stream.send(XMPPIQ(iqType: .set, elementID: request.id, child: enableElement))
            return []
        } catch {
            diagnostics.record(.blocked(reason: .credentialsUnavailable))
            return finishRequestLocked(success: false, preserveRegistration: request.wasEnabled)
        }
    }

    private func registrationCredentials(_ request: RegistrationRequest) throws -> CredentialsManager.PushSecretData {
        do {
            let credentials = try credentialReader(request.node)
            guard credentials.jid == request.owner, credentials.host == request.domain,
                  credentials.keyBytes != nil else {
                throw RegistrationError.invalidCredentials
            }
            return credentials
        } catch CredentialsManager.CredentialsError.itemNotFound {
            var keyBytes = [UInt8](repeating: 0, count: 32)
            let status = keyBytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
            }
            guard status == errSecSuccess else { throw RegistrationError.randomGenerationFailed }
            let candidate = CredentialsManager.PushSecretData(
                host: request.domain, secret: Data(keyBytes).base64EncodedString(), jid: request.owner,
                service: "", jwt: "", keyEncoding: .base64
            )
            try credentialWriter(request.node, candidate)
            let stored = try credentialReader(request.node)
            guard stored.jid == request.owner, stored.host == request.domain, stored.keyBytes == keyBytes else {
                throw RegistrationError.invalidCredentials
            }
            return stored
        }
    }

    private func publishNonsecretDefaults(_ request: RegistrationRequest) {
        guard let jid = XMPPJID(string: request.streamJID), let username = jid.user,
              let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()) else { return }
        var metadata = Self.getDefaultsForPush(for: request.node)
        metadata.removeValue(forKey: "secret")
        metadata["username"] = username
        metadata["host"] = request.domain
        metadata["resource"] = jid.resource ?? "xabber-push-service"
        metadata["websocket_url"] = websocketUrl ?? ""
        defaults.set(metadata, forKey: request.node)
    }
    
    func disable(xmppStream: XMPPStream) {
        stateLock.lock()
        configurationEpoch &+= 1
        cancelHTTPArchiveRequestLocked()
        let callbacks = finishRequestLocked(success: false, preserveRegistration: false)
        registrationState = .disabled
        acknowledgedPayloadMode = nil
        if xmppStream.myJID?.bare == owner {
            let disableElement = DDXMLElement(name: "disable", xmlns: getPrimaryNamespace())
            xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: xmppStream.generateUUID, child: disableElement))
        }
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }
    
    func didSend(_ iq: XMPPIQ, xmppStream: XMPPStream) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let request = registrationRequest, isCurrentRequestLocked(request),
              request.stream === xmppStream, request.streamJID == xmppStream.myJID?.full,
              request.hasBeenSent, !request.didObserveSend,
              iq.elementID == request.id, iq.iqType == .set,
              iq.element(forName: "enable", xmlns: getPrimaryNamespace()) != nil,
              let mode = request.payloadMode else { return }
        request.didObserveSend = true
        diagnostics.record(.sent(request: request.diagnosticID, mode: mode))
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        return readPushRegistrationResult(iq) || readHTTPArchiveResult(iq)
    }

    override func clearSession() {
        stateLock.lock()
        configurationEpoch &+= 1
        cancelHTTPArchiveRequestLocked()
        let callbacks = finishRequestLocked(success: false, preserveRegistration: false)
        registrationState = .disabled
        acknowledgedPayloadMode = nil
        queryIds.removeAll()
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }

    private func updateConfiguration(node: String?, service: String?) {
        stateLock.lock()
        let nextNode = node ?? configuredNode
        let nextService = service ?? configuredService
        guard nextNode != configuredNode || nextService != configuredService else {
            stateLock.unlock()
            return
        }
        configuredNode = nextNode
        configuredService = nextService
        configurationEpoch &+= 1
        cancelHTTPArchiveRequestLocked()
        let callbacks = finishRequestLocked(success: false, preserveRegistration: false)
        registrationState = .disabled
        acknowledgedPayloadMode = nil
        stateLock.unlock()
        callbacks.forEach { $0(false) }
    }

    private func isCurrentRequestLocked(_ request: RegistrationRequest) -> Bool {
        registrationRequest === request && request.epoch == configurationEpoch
            && request.owner == owner && request.node == configuredNode && request.service == configuredService
    }

    private func finishRequestLocked(success: Bool, preserveRegistration: Bool) -> [(Bool) -> Void] {
        guard let request = registrationRequest else { return [] }
        registrationRequest = nil
        request.cancelTimeout?()
        queryIds.remove(request.id)
        registrationState = success || preserveRegistration ? .enabled : .disabled
        let callbacks = request.callbacks
        request.callbacks.removeAll()
        return callbacks
    }

    private func registrationDidTimeout(_ request: RegistrationRequest) {
        stateLock.lock()
        guard isCurrentRequestLocked(request) else {
            stateLock.unlock()
            return
        }
        // A sent request may have applied on the server despite a lost response.
        if request.hasBeenSent { acknowledgedPayloadMode = nil }
        diagnostics.record(.timedOut(request: request.diagnosticID, sent: request.didObserveSend))
        let completion = finishRequestAndReconcileModeLocked(request, success: false)
        stateLock.unlock()
        completion.callbacks.forEach { $0(completion.success) }
    }

    private func finishRequestAndReconcileModeLocked(
        _ request: RegistrationRequest, success: Bool
    ) -> (callbacks: [(Bool) -> Void], success: Bool) {
        let callbacks = finishRequestLocked(success: success, preserveRegistration: request.wasEnabled)
        let latestMode = payloadModeProvider()
        // Consume the outstanding enable response before sending a successor.
        // A same-mode error/timeout stops here until a new explicit retry.
        guard let sentMode = request.payloadMode, request.hasBeenSent,
              sentMode != latestMode,
              !(registrationState == .enabled && acknowledgedPayloadMode == latestMode),
              request.epoch == configurationEpoch, request.node == configuredNode,
              request.service == configuredService, request.owner == owner,
              customPushSupported != false,
              let stream = request.stream, let jid = stream.myJID,
              jid.full == request.streamJID else {
            return (callbacks, success)
        }
        let failures = startRegistrationLocked(xmppStream: stream, jid: jid, callbacks: callbacks)
        return (failures, false)
    }

    private func readPushRegistrationResult(_ iq: XMPPIQ) -> Bool {
        stateLock.lock()
        guard let request = registrationRequest, isCurrentRequestLocked(request), request.hasBeenSent,
              iq.elementID == request.id, queryIds.contains(request.id),
              iq.iqType == .result || iq.iqType == .error,
              isExpectedSender(iq.from, request: request),
              isExpectedRecipient(iq.to, request: request) else {
            stateLock.unlock()
            return false
        }
        let success = iq.iqType == .result
        if success { acknowledgedPayloadMode = request.payloadMode }
        if success {
            diagnostics.record(.enabled(request: request.diagnosticID, httpReady: httpPreviewReady))
        } else {
            diagnostics.record(.rejected(request: request.diagnosticID,
                                         condition: PushRegistrationErrorCondition.classify(iq)))
        }
        let completion = finishRequestAndReconcileModeLocked(request, success: success)
        if success, registrationRequest == nil, request.payloadMode == .summary,
           let stream = request.stream {
            startHTTPArchiveRequestLocked(stream)
        }
        stateLock.unlock()
        completion.callbacks.forEach { $0(completion.success) }
        return true
    }

    private func isExpectedSender(_ sender: XMPPJID?, request: RegistrationRequest) -> Bool {
        guard let sender else { return true }
        guard sender.resource == nil || sender.resource?.isEmpty == true else { return false }
        return sender.bare == request.owner || sender.bare == request.domain
    }

    private func isExpectedRecipient(_ recipient: XMPPJID?, request: RegistrationRequest) -> Bool {
        guard let recipient else { return true }
        return recipient.full == request.streamJID
            || (recipient.bare == request.owner && (recipient.resource == nil || recipient.resource?.isEmpty == true))
    }

    private func startHTTPArchiveRequestLocked(_ stream: XMPPStream) {
        guard httpArchiveRequest == nil, registrationState == .enabled,
              acknowledgedPayloadMode == .summary, payloadModeProvider() == .summary,
              let jid = stream.myJID, jid.bare == owner,
              let credentials = try? credentialReader(configuredNode),
              credentials.jid == owner, credentials.host == jid.domain,
              let key = credentials.keyBytes else { return }
        let request = HTTPArchiveRequest(owner: owner, node: configuredNode, jid: jid,
                                         epoch: configurationEpoch, stream: stream, key: key)
        httpArchiveRequest = request
        sendHTTPArchiveRequestLocked(request)
    }

    private func sendHTTPArchiveRequestLocked(_ request: HTTPArchiveRequest) {
        guard isCurrentHTTPArchiveRequestLocked(request), let stream = request.stream,
              let jid = stream.myJID else { cancelHTTPArchiveRequestLocked(); return }
        request.cancelTimeout?()
        queryIds.remove(request.id)
        request.id = stream.generateUUID
        queryIds.insert(request.id)
        let id = request.id
        let cancel = registrationTimeoutScheduler(registrationTimeoutInterval) { [weak self, weak request] in
            guard let self, let request else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self.httpArchiveRequest === request, request.id == id else { return }
            DDLogInfo("HTTP_IQ_ARCHIVE event=timeout phase=\(request.endpoint == nil ? "endpoints" : "token")")
            self.cancelHTTPArchiveRequestLocked()
        }
        guard httpArchiveRequest === request, request.id == id else { cancel(); return }
        request.cancelTimeout = cancel
        let iq = request.endpoint == nil
            ? PushHTTPIQ.endpointsRequest(id: id, jid: jid)
            : PushHTTPIQ.tokenRequest(id: id, jid: jid)
        stream.send(iq)
    }

    private func isCurrentHTTPArchiveRequestLocked(_ request: HTTPArchiveRequest) -> Bool {
        httpArchiveRequest === request && request.epoch == configurationEpoch
            && request.owner == owner && request.node == configuredNode
            && registrationState == .enabled && acknowledgedPayloadMode == .summary
            && payloadModeProvider() == .summary && request.stream?.myJID?.full == request.streamJID
    }

    private func cancelHTTPArchiveRequestLocked() {
        guard let request = httpArchiveRequest else { return }
        httpArchiveRequest = nil
        request.cancelTimeout?()
        queryIds.remove(request.id)
    }

    private func readHTTPArchiveResult(_ iq: XMPPIQ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let request = httpArchiveRequest else { return false }
        guard isCurrentHTTPArchiveRequestLocked(request) else {
            cancelHTTPArchiveRequestLocked()
            return false
        }
        guard iq.elementID == request.id, queryIds.contains(request.id),
              iq.iqType == .result || iq.iqType == .error,
              iq.from == nil || (iq.from?.bare == request.domain && iq.from?.resource == nil),
              iq.to == nil || iq.to?.full == request.streamJID || iq.to?.full == request.owner else { return false }
        guard iq.iqType == .result else {
            DDLogInfo("HTTP_IQ_ARCHIVE event=rejected condition=\(PushRegistrationErrorCondition.classify(iq).rawValue)")
            cancelHTTPArchiveRequestLocked()
            return true
        }
        if request.endpoint == nil {
            guard let endpoint = PushHTTPIQ.archiveEndpoint(in: iq) else {
                DDLogInfo("HTTP_IQ_ARCHIVE event=invalid_endpoints")
                cancelHTTPArchiveRequestLocked()
                return true
            }
            request.endpoint = endpoint
            sendHTTPArchiveRequestLocked(request)
            return true
        }
        guard let endpoint = request.endpoint,
              let grant = PushHTTPIQ.archiveGrant(in: iq, endpoint: endpoint, owner: request.owner,
                                                 domain: request.domain, now: httpArchiveNow()),
              let credentials = try? credentialReader(request.node),
              credentials.jid == request.owner, credentials.host == request.domain,
              credentials.keyBytes == request.key else {
            DDLogInfo("HTTP_IQ_ARCHIVE event=invalid_token_context")
            cancelHTTPArchiveRequestLocked()
            return true
        }
        let refreshed = CredentialsManager.PushSecretData(
            host: credentials.host, secret: credentials.secret, jid: credentials.jid,
            service: "", jwt: "", keyEncoding: credentials.keyEncoding,
            grantRevision: UUID().uuidString, httpArchive: grant
        )
        guard refreshed.tokenExpiresAt.map({ $0 > httpArchiveNow() }) == true else {
            DDLogInfo("HTTP_IQ_ARCHIVE event=expired_token")
            cancelHTTPArchiveRequestLocked()
            return true
        }
        do {
            try credentialWriter(request.node, refreshed)
            let stored = try credentialReader(request.node)
            guard stored.jid == request.owner, stored.host == request.domain,
                  stored.keyBytes == request.key, stored.httpArchive == grant,
                  stored.grantRevision == refreshed.grantRevision else {
                cancelHTTPArchiveRequestLocked()
                return true
            }
            try? tokenInvalidationStore?.remove(node: request.node, generation: stored.tokenGeneration)
            DDLogInfo("HTTP_IQ_ARCHIVE event=grant_stored ready=\(httpPreviewReady)")
        } catch {
            DDLogInfo("HTTP_IQ_ARCHIVE event=credential_publication_failed")
        }
        cancelHTTPArchiveRequestLocked()
        return true
    }

    static public func removeDefaultsForPush(target: String, jid: String) {
        if let record = try? CredentialsManager.staticGetPushCredentials(for: target), record.jid == jid {
            CredentialsManager.shared.removePushCredentials(for: target)
        }
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.removeObject(forKey: target)
            defaults.removeObject(forKey: [jid, "state"].prp())
        }
    }
    
    static public func getDefaultsForPush(for target: String) -> [String: String] {
        if let defaults = UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup()),
           let dict = defaults.dictionary(forKey: target) as? [String: String] {
            return dict
        }
        return [:]
    }
     
    static public func updateDefaultsForPush(_ target: String, key: String, value: String) {
        var dict = PushNotificationsManager.getDefaultsForPush(for: target)
        dict[key] = value
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.set(dict, forKey: target)
        }
    }
    
    static public func setAccountStateForPush(jid: String, active: Bool) {
        if let defaults = UserDefaults.init(suiteName: CredentialsManager.uniqueAccessGroup()) {
            defaults.set(active, forKey: [jid, "state"].prp())
        }
    }
}
