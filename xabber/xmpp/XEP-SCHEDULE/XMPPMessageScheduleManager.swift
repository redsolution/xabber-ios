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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
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

class XMPPMessageScheduleManager: AbstractXMPPManager {
    internal var omemo2OptOutStorage: XabberOMEMO2Storage?
    internal func outgoingIQWasBlocked(_ iq: XMPPIQ) {
        guard let id = iq.elementID, Self.isRequest(iq) else { return }
        failRequest(id, error: .sendRejected)
    }

    static func isRequest(_ iq: XMPPIQ) -> Bool {
        switch iq.iqType {
        case .get: return iq.element(forName: "query", xmlns: namespace) != nil
        case .set: return iq.element(forName: "schedule", xmlns: namespace) != nil
            || iq.element(forName: "cancel", xmlns: namespace) != nil
        default: return false
        }
    }

    func canTransmit(_ iq: XMPPIQ) -> Bool {
        guard let id = iq.elementID else { return false }
        return stateLock.withLock { requests[id] != nil }
    }

    func rejectsTrackedReplyAuthority(_ iq: XMPPIQ) -> Bool {
        guard let id = iq.elementID else { return false }
        return stateLock.withLock {
            guard let request = requests[id] else { return false }
            return !hasReplyAuthority(iq, request: request)
        }
    }

    static let namespace = "https://xabber.com/protocol/schedule"
    static let metadataKey = "schedule"
    private static let settingsNodeKey = "node"

    enum ScheduleError: Error, Equatable {
        case unavailable
        case invalidFilter
        case malformedPayload
        case invalidResponse
        case timeout
        case disconnected
        case badRequest
        case notAcceptable
        case resourceConstraint
        case forbidden
        case itemNotFound
        case sendRejected
        case unknown(String?)
    }

    struct ScheduledEntry: Equatable {
        let scheduledId: String
        let conversation: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let deliverAt: Date
        let status: XMPPMessageScheduleStorageItem.Status
        let messageXML: String
    }

    typealias ScheduleCallback = (Result<ScheduledEntry, ScheduleError>) -> Void
    typealias ListCallback = (Result<[ScheduledEntry], ScheduleError>) -> Void
    typealias CancelCallback = (Result<String, ScheduleError>) -> Void

    private struct ListFilter: Hashable {
        let conversation: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }

    private struct ScheduleDraft: Equatable {
        let conversation: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let deliverAt: Date
        let messageXML: String
    }

    private struct Request {
        enum Kind {
            case schedule(ScheduleDraft, ScheduleCallback?)
            case list(ListFilter?, ListCallback?)
            case cancel(String, CancelCallback?)

            func fail(with error: ScheduleError) {
                switch self {
                case .schedule(_, let callback): callback?(.failure(error))
                case .list(_, let callback): callback?(.failure(error))
                case .cancel(_, let callback): callback?(.failure(error))
                }
            }
        }

        let kind: Kind
        let expectedRecipient: String?
        let revision: UInt64
        let timeout: DispatchWorkItem
    }

    private let stateLock = NSLock()
    private var available = false
    private var requests: [String: Request] = [:]
    private var revision: UInt64 = 0
    // Only outstanding requests need these revisions, including deleted IDs.
    private var mutationRevisions: [String: UInt64] = [:]
    private var fullSnapshotRevision: UInt64 = 0
    private var filteredSnapshotRevisions: [ListFilter: UInt64] = [:]
    private var automaticRefreshID: UUID?
    private var sessionRefreshRequested = false
    internal var requestTimeout: TimeInterval = 15
    internal var omemo2Previews = ScheduledOMEMO2PreviewStore.shared

    var isAvailable: Bool {
        get { stateLock.withLock { available } }
        set { stateLock.withLock { available = newValue } }
    }

    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        checkAvailability()
    }

    override func namespaces() -> [String] {
        return [getPrimaryNamespace()]
    }

    override func getPrimaryNamespace() -> String {
        return Self.namespace
    }

    static func availability(_ owner: String) -> Bool {
        return SettingManager.shared.getKey(
            for: owner,
            scope: .messageSchedule,
            key: settingsNodeKey
        ) == namespace
    }

    static func saveAvailability(owner: String, isAvailable: Bool) {
        if isAvailable {
            SettingManager.shared.saveItem(
                for: owner,
                scope: .messageSchedule,
                key: settingsNodeKey,
                value: namespace
            )
        } else {
            SettingManager.shared.removeItem(for: owner, scope: .messageSchedule, key: settingsNodeKey)
        }
    }

    open func checkAvailability() {
        isAvailable = Self.availability(owner)
    }

    @discardableResult
    func schedulePlaintextMessage(
        _ xmppStream: XMPPStream,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        body: String,
        references: [MessageReferenceStorageItem] = [],
        forwardedMessagePrimaries: [String] = [],
        additionalChildren: [DDXMLElement] = [],
        callback: ScheduleCallback? = nil
    ) -> String? {
        let payload = makePlaintextMessagePayload(
            to: conversation,
            body: body,
            conversationType: conversationType,
            references: references,
            forwardedMessagePrimaries: forwardedMessagePrimaries,
            additionalChildren: additionalChildren
        )
        return scheduleMessage(
            xmppStream,
            conversation: conversation,
            conversationType: conversationType,
            deliverAt: deliverAt,
            payload: payload,
            callback: callback
        )
    }

    @discardableResult
    func scheduleOMEMO2Message(
        _ xmppStream: XMPPStream,
        conversation: String,
        deliverAt: Date,
        plaintext: XMPPMessage,
        omemo: OmemoManager,
        callback: ScheduleCallback? = nil
    ) -> String? {
        guard isAvailable else { callback?(.failure(.unavailable)); return nil }
        guard deliverAt.timeIntervalSince1970.isFinite, ScheduledOMEMO2.wireDate(deliverAt) > Date() else {
            callback?(.failure(.notAcceptable))
            return nil
        }
        guard let account = AccountManager.shared.find(for: owner), account.messageSchedule === self,
              account.omemo === omemo, xmppCanSchedule(on: xmppStream, account: account) else {
            callback?(.failure(.sendRejected))
            return nil
        }
        let sealed: XMPPMessage
        do {
            sealed = try ScheduledOMEMO2.makeEncryptedMessage(
                plaintext: plaintext, conversation: conversation, deliverAt: deliverAt, omemo: omemo
            )
        } catch let error as ScheduleError {
            callback?(.failure(error))
            return nil
        } catch {
            callback?(.failure(.sendRejected))
            return nil
        }
        // A locked or full local cache can only hide the preview; it cannot
        // downgrade or substitute a plaintext stanza.
        let previews = omemo2Previews
        let owner = self.owner
        try? previews.save(plaintext: plaintext, sealed: sealed, owner: owner,
                           conversation: conversation, deliverAt: deliverAt)
        let id = scheduleMessage(xmppStream, conversation: conversation, conversationType: .omemo,
            deliverAt: deliverAt, payload: sealed) { result in
                if case .failure(let error) = result {
                    switch error {
                    case .disconnected, .timeout, .invalidResponse, .unknown:
                        break // The server may still list this exact packet later.
                    default:
                        previews.remove(owner: owner, conversation: conversation, sealed: sealed)
                    }
                }
                callback?(result)
            }
        if id == nil { omemo.abandonPreparedOMEMO2Transport(sealed) }
        return id
    }

    @discardableResult
    func scheduleMessage(
        _ xmppStream: XMPPStream,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        payload: XMPPMessage,
        callback: ScheduleCallback? = nil
    ) -> String? {
        guard OMEMO2OptOutPolicy.allowsMessage(owner: owner, jid: conversation, storage: omemo2OptOutStorage) else {
            callback?(.failure(.sendRejected))
            return nil
        }
        guard isAvailable else {
            callback?(.failure(.unavailable))
            return nil
        }
        guard let destination = XMPPJID(string: conversation),
              payload.to?.full == destination.bare else {
            callback?(.failure(.malformedPayload))
            return nil
        }
        if conversationType == .omemo {
            guard ScheduledOMEMO2.isSealedMessage(payload, owner: owner, conversation: destination.bare),
                  let account = AccountManager.shared.find(for: owner),
                  account.omemo.allowsPreparedOMEMO2Transport(payload) else {
                callback?(.failure(.sendRejected))
                return nil
            }
        } else if conversationType.isEncrypted || SCEReceivePolicy.containsOMEMO2(payload) {
            callback?(.failure(.forbidden))
            return nil
        }
        let elementId = xmppStream.generateUUID
        let iq = makeScheduleIQ(
            elementId: elementId,
            conversation: destination.bare,
            conversationType: conversationType,
            deliverAt: deliverAt,
            payload: payload
        )
        let draft = ScheduleDraft(
            conversation: destination.bare,
            conversationType: conversationType,
            deliverAt: deliverAt,
            messageXML: preparedInnerMessage(from: payload).xmlString
        )
        return sendTracked(iq, on: xmppStream, kind: .schedule(draft, callback))
    }

    @discardableResult
    func listScheduledMessages(
        _ xmppStream: XMPPStream,
        conversation: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType? = nil,
        callback: ListCallback? = nil
    ) -> String? {
        guard isAvailable else {
            callback?(.failure(.unavailable))
            return nil
        }
        let elementId = xmppStream.generateUUID
        let bareConversation = conversation.flatMap { XMPPJID(string: $0)?.bare }
        if conversation != nil && bareConversation == nil {
            callback?(.failure(.invalidFilter))
            return nil
        }
        let iq: XMPPIQ
        do {
            iq = try makeListIQ(elementId: elementId, conversation: bareConversation, conversationType: conversationType)
        } catch {
            callback?(.failure(.invalidFilter))
            return nil
        }
        let filter: ListFilter?
        if let bareConversation, let conversationType {
            filter = ListFilter(conversation: bareConversation, conversationType: conversationType)
        } else {
            filter = nil
        }
        return sendTracked(iq, on: xmppStream, kind: .list(filter, callback))
    }

    @discardableResult
    func cancelScheduledMessage(
        _ xmppStream: XMPPStream,
        scheduledId: String,
        callback: CancelCallback? = nil
    ) -> String? {
        guard isAvailable else {
            callback?(.failure(.unavailable))
            return nil
        }
        guard scheduledId.isNotEmpty else {
            callback?(.failure(.malformedPayload))
            return nil
        }
        let elementId = xmppStream.generateUUID
        let iq = makeCancelIQ(elementId: elementId, scheduledId: scheduledId)
        return sendTracked(iq, on: xmppStream, kind: .cancel(scheduledId, callback))
    }

    func makePlaintextMessagePayload(
        to conversation: String,
        body: String,
        messageId: String = NanoID.new(8),
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        references: [MessageReferenceStorageItem] = [],
        forwardedMessagePrimaries: [String] = [],
        additionalChildren: [DDXMLElement] = []
    ) -> XMPPMessage {
        let stanza = XMPPMessage(
            messageType: .chat,
            to: MessageManager.outboundDestinationJID(
                for: conversation,
                conversationType: conversationType,
                resource: nil
            ),
            elementID: messageId,
            child: nil
        )
        stanza.addAttribute(withName: "from", stringValue: owner)
        additionalChildren.forEach {
            if let copy = $0.copy() as? DDXMLElement {
                stanza.addChild(copy)
            }
        }
        MessageManager(withOwner: owner, activeStream: false)
            .formForwardedMessages(forwardedMessagePrimaries)
            .forEach {
                if let copy = $0.referenceElement.copy() as? DDXMLElement {
                    stanza.addChild(copy)
                }
            }
        if body.isNotEmpty {
            stanza.addBody(body)
        }
        if references.isNotEmpty {
            let item = MessageStorageItem()
            item.owner = owner
            item.opponent = conversation
            item.conversationType = conversationType
            references.forEach { item.references.append($0) }
            item.createReferences().forEach {
                if let copy = $0.copy() as? DDXMLElement {
                    stanza.addChild(copy)
                }
            }
        }
        stanza.addOriginId(messageId)
        if conversationType == .group {
            stanza.addChild(DDXMLElement(name: "private", xmlns: "urn:xmpp:carbons:2"))
        }
        return stanza
    }

    func makeScheduleIQ(
        elementId: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        payload: XMPPMessage
    ) -> XMPPIQ {
        let schedule = DDXMLElement(name: "schedule", xmlns: getPrimaryNamespace())
        schedule.addAttribute(withName: "conversation", stringValue: conversation)
        schedule.addAttribute(withName: "type", stringValue: conversationType.rawValue)
        schedule.addAttribute(withName: "deliver-at", stringValue: Self.formatTimestamp(deliverAt))
        schedule.addChild(preparedInnerMessage(from: payload))
        return XMPPIQ(
            iqType: .set,
            to: XMPPJID(string: owner)?.bareJID,
            elementID: elementId,
            child: schedule
        )
    }

    func makeListIQ(
        elementId: String,
        conversation: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType? = nil
    ) throws -> XMPPIQ {
        if (conversation == nil) != (conversationType == nil) {
            throw ScheduleError.invalidFilter
        }
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        if let conversation, let conversationType {
            query.addAttribute(withName: "conversation", stringValue: conversation)
            query.addAttribute(withName: "type", stringValue: conversationType.rawValue)
        }
        return XMPPIQ(
            iqType: .get,
            to: XMPPJID(string: owner)?.bareJID,
            elementID: elementId,
            child: query
        )
    }

    func makeCancelIQ(elementId: String, scheduledId: String) -> XMPPIQ {
        let cancel = DDXMLElement(name: "cancel", xmlns: getPrimaryNamespace())
        cancel.addAttribute(withName: "id", stringValue: scheduledId)
        return XMPPIQ(
            iqType: .set,
            to: XMPPJID(string: owner)?.bareJID,
            elementID: elementId,
            child: cancel
        )
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let id = iq.elementID, iq.iqType == .result || iq.iqType == .error else {
            return false
        }
        let completion: (() -> Void)? = stateLock.withLock {
            guard let request = requests[id],
                  hasReplyAuthority(iq, request: request) else { return nil }

            _ = takeRequestLocked(id)
            defer { discardUnusedRevisionsLocked() }
            if iq.iqType == .error {
                let error = mapError(iq.element(forName: "error"))
                if error == .itemNotFound, case .cancel(let scheduledID, _) = request.kind {
                    deleteScheduleLocked(scheduledId: scheduledID)
                }
                return { request.kind.fail(with: error) }
            }
            return handleResultLocked(iq, request: request)
        }
        completion?()
        return completion != nil
    }

    func read(headline message: XMPPMessage, localJID: String? = nil) -> Bool {
        guard message.type == "headline", hasScheduleAuthority(message.from, allowMissing: false),
              hasExpectedRecipient(message, fullJID: localJID) else { return false }

        if let scheduled = message.element(forName: "scheduled", xmlns: Self.namespace),
           let entry = parseScheduledElement(scheduled, fallbackMessageXML: nil) {
            stateLock.withLock { upsertLocked(entry) }
            return true
        }
        if let cancelled = message.element(forName: "cancelled", xmlns: Self.namespace),
           let scheduledId = cancelled.attributeStringValue(forName: "id"), scheduledId.isNotEmpty {
            stateLock.withLock { deleteScheduleLocked(scheduledId: scheduledId, purgePreview: true) }
            return true
        }
        if let failed = message.element(forName: "failed", xmlns: Self.namespace),
           let scheduledId = failed.attributeStringValue(forName: "id"), scheduledId.isNotEmpty {
            let marked = stateLock.withLock { markScheduleFailedLocked(scheduledId: scheduledId) }
            if !marked, isAvailable {
                AccountManager.shared.find(for: owner)?.action { account, stream in
                    guard stream.isAuthenticated else { return }
                    _ = account.messageSchedule.listScheduledMessages(stream)
                }
            }
            return true
        }
        return false
    }

    func requestSessionRefresh() {
        stateLock.withLock { sessionRefreshRequested = true }
    }

    func refreshScheduledMessages(_ stream: XMPPStream) {
        guard stream.isAuthenticated, let accountJID = XMPPJID(string: owner),
              stream.myJID?.bare == accountJID.bare else { return }
        let id = UUID()
        let shouldRefresh = stateLock.withLock {
            guard available, sessionRefreshRequested, automaticRefreshID == nil else { return false }
            automaticRefreshID = id
            return true
        }
        guard shouldRefresh else { return }
        listScheduledMessages(stream) { [weak self] result in
            guard let self else { return }
            self.stateLock.withLock {
                guard self.automaticRefreshID == id else { return }
                self.automaticRefreshID = nil
                if case .success = result { self.sessionRefreshRequested = false }
            }
        }
    }

    private func hasReplyAuthority(_ iq: XMPPIQ, request: Request) -> Bool {
        // On the authenticated primary stream an omitted response sender denotes the server.
        hasScheduleAuthority(iq.from, allowMissing: iq.attribute(forName: "from") == nil)
            && hasExpectedRecipient(iq, fullJID: request.expectedRecipient)
    }

    private func hasScheduleAuthority(_ sender: XMPPJID?, allowMissing: Bool) -> Bool {
        guard let sender else { return allowMissing }
        guard let ownJID = XMPPJID(string: owner) else { return false }
        return sender.full == ownJID.bare || sender.full == ownJID.domain
    }

    private func hasExpectedRecipient(_ stanza: DDXMLElement, fullJID: String?) -> Bool {
        guard let recipientAttribute = stanza.attributeStringValue(forName: "to") else { return true }
        guard let recipient = XMPPJID(string: recipientAttribute), let ownJID = XMPPJID(string: owner) else {
            return false
        }
        return recipient.full == ownJID.bare || recipient.full == fullJID
    }

    static func deliveredMarker(from message: XMPPMessage) -> (id: String, deliverAt: Date)? {
        let markers = SCEReceivePolicy.children(of: message, named: "deferred", xmlns: namespace)
        guard markers.count == 1, let deferred = markers.first,
              SCEReceivePolicy.isScheduledDeliveryMetadata(deferred),
              let scheduledId = deferred.attributeStringValue(forName: "id"),
              let deliverAtString = deferred.attributeStringValue(forName: "deliver-at"),
              let deliverAt = parseTimestamp(deliverAtString) else {
            return nil
        }
        return (scheduledId, deliverAt)
    }

    static func deliveredScheduleID(in message: MessageStorageItem) -> String? {
        (message.systemMetadata?[metadataKey] as? [String: String])?["id"]
    }

    @discardableResult
    static func applyDeferredMetadata(to storedMessage: MessageStorageItem, source message: XMPPMessage) -> Bool {
        guard let marker = deliveredMarker(from: message) else { return false }
        var metadata = storedMessage.systemMetadata ?? [:]
        metadata[metadataKey] = [
            "id": marker.id,
            "deliverAt": formatTimestamp(marker.deliverAt)
        ]
        storedMessage.systemMetadata = metadata
        return true
    }

    func reconcileDeliveredScheduleMarkers(from messages: [MessageStorageItem]) {
        let markers = messages.compactMap { message -> (id: String, deliverAt: String, conversation: String, type: ClientSynchronizationManager.ConversationType)? in
            guard message.outgoing, message.owner == owner,
                  let metadata = message.systemMetadata?[Self.metadataKey] as? [String: String],
                  let id = metadata["id"], id.isNotEmpty,
                  let deliverAt = metadata["deliverAt"],
                  let opponent = XMPPJID(string: message.opponent)?.bare else { return nil }
            return (id, deliverAt, opponent, message.conversationType)
        }
        guard !markers.isEmpty else { return }
        stateLock.withLock {
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    for marker in markers {
                        let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: marker.id)
                        if let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary) {
                            guard item.status == .pending, item.conversation == marker.conversation,
                                  item.conversationType == marker.type,
                                  Self.formatTimestamp(item.deliverAt) == marker.deliverAt else { continue }
                            realm.delete(item)
                        }
                        recordMutationLocked(scheduledId: marker.id)
                    }
                }
            } catch {
                DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
            }
        }
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        if let date = Date.parseXMPPFormattedString(string) {
            return date
        }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if format.hasSuffix("'Z'") {
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
            }
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    override func clearSession() {
        let pending = stateLock.withLock {
            let pending = Array(requests.values)
            requests.removeAll()
            queryIds.removeAll()
            mutationRevisions.removeAll()
            fullSnapshotRevision = 0
            filteredSnapshotRevisions.removeAll()
            automaticRefreshID = nil
            sessionRefreshRequested = false
            return pending
        }
        pending.forEach {
            $0.timeout.cancel()
            $0.kind.fail(with: .disconnected)
        }
    }

    private func preparedInnerMessage(from payload: XMPPMessage) -> DDXMLElement {
        let message = (payload.copy() as? DDXMLElement) ?? DDXMLElement(name: "message")
        message.setXmlns("jabber:client")
        return message
    }

    private func sendTracked(_ iq: XMPPIQ, on stream: XMPPStream, kind: Request.Kind) -> String? {
        guard let id = iq.elementID,
              OMEMO2OptOutPolicy.allowsOutgoing(iq, owner: owner, storage: omemo2OptOutStorage) else {
            kind.fail(with: .sendRejected)
            return nil
        }

        let sender = stream.myJID
        if let account = AccountManager.shared.find(for: owner) {
            guard xmppCanSchedule(on: stream, account: account) else {
                kind.fail(with: .sendRejected)
                return nil
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.failRequest(id, error: .timeout)
        }
        stateLock.withLock {
            revision += 1
            requests[id] = Request(kind: kind, expectedRecipient: sender?.full, revision: revision, timeout: timeout)
            queryIds.insert(id)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout, execute: timeout)

        switch sendPrimaryAware(iq, on: stream, replayPolicy: .notReplayable) {
        case .sent, .queued:
            return id
        case .rejected, .blockedByOptOut, .blockedByOMEMORecipient:
            failRequest(id, error: .sendRejected)
            return nil
        }
    }

    private func xmppCanSchedule(on stream: XMPPStream, account: Account) -> Bool {
        guard let accountJID = XMPPJID(string: owner) else { return false }
        return account.xmppStream === stream && stream.isAuthenticated &&
            stream.myJID?.bare == accountJID.bare &&
            account.sendReadiness.snapshot.canFlushApplicationStanzas && !account.isStartupBackgroundTrafficBlocked
    }

    private func failRequest(_ id: String, error: ScheduleError) {
        let request = stateLock.withLock {
            defer { discardUnusedRevisionsLocked() }
            return takeRequestLocked(id)
        }
        request?.kind.fail(with: error)
    }

    private func takeRequestLocked(_ id: String) -> Request? {
        guard let request = requests.removeValue(forKey: id) else { return nil }
        queryIds.remove(id)
        request.timeout.cancel()
        return request
    }

    private func handleResultLocked(_ iq: XMPPIQ, request: Request) -> () -> Void {
        let invalid = { request.kind.fail(with: .invalidResponse) }
        let elements = (iq.children ?? []).compactMap { $0 as? DDXMLElement }
        switch request.kind {
        case .schedule(let draft, let callback):
            guard elements.count == 1,
                  let scheduled = iq.element(forName: "scheduled", xmlns: Self.namespace),
                  let entry = parseScheduledElement(scheduled, fallbackMessageXML: draft.messageXML),
                  entry.conversation == draft.conversation,
                  entry.conversationType == draft.conversationType,
                  Self.formatTimestamp(entry.deliverAt) == Self.formatTimestamp(draft.deliverAt) else { return invalid }
            if (mutationRevisions[entry.scheduledId] ?? 0) < request.revision {
                upsertLocked(entry)
            }
            return { callback?(.success(entry)) }
        case .list(let filter, let callback):
            guard elements.count == 1,
                  let query = iq.element(forName: "query", xmlns: Self.namespace) else { return invalid }
            let entryElements = query.elements(forLocalName: "scheduled", uri: Self.namespace)
            let entries = entryElements.compactMap { parseScheduledElement($0, fallbackMessageXML: nil) }
            guard entries.count == entryElements.count, Set(entries.map(\.scheduledId)).count == entries.count else {
                return invalid
            }
            do {
                let stored = try reconcileListLocked(entries, filter: filter, requestRevision: request.revision)
                return { callback?(.success(stored)) }
            } catch {
                DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
                return { callback?(.failure(.unknown(nil))) }
            }
        case .cancel(let scheduledID, let callback):
            guard elements.isEmpty else { return invalid }
            deleteScheduleLocked(scheduledId: scheduledID, purgePreview: true)
            return { callback?(.success(scheduledID)) }
        }
    }

    private func mapError(_ error: DDXMLElement?) -> ScheduleError {
        guard let error else { return .invalidResponse }
        let stanzaNamespace = "urn:ietf:params:xml:ns:xmpp-stanzas"
        if error.element(forName: "bad-request", xmlns: stanzaNamespace) != nil { return .badRequest }
        if error.element(forName: "not-acceptable", xmlns: stanzaNamespace) != nil { return .notAcceptable }
        if error.element(forName: "resource-constraint", xmlns: stanzaNamespace) != nil { return .resourceConstraint }
        if error.element(forName: "forbidden", xmlns: stanzaNamespace) != nil { return .forbidden }
        if error.element(forName: "item-not-found", xmlns: stanzaNamespace) != nil { return .itemNotFound }
        return .unknown(error.element(forName: "text", xmlns: stanzaNamespace)?.stringValue)
    }

    private func parseScheduledElement(_ element: DDXMLElement, fallbackMessageXML: String?) -> ScheduledEntry? {
        let statusRaw = element.attributeStringValue(forName: "status") ?? XMPPMessageScheduleStorageItem.Status.pending.rawValue
        guard let scheduledId = element.attributeStringValue(forName: "id"), scheduledId.isNotEmpty,
              let conversation = element.attributeStringValue(forName: "conversation"),
              let conversationJID = XMPPJID(string: conversation), conversationJID.bare == conversationJID.full,
              let conversationTypeRaw = element.attributeStringValue(forName: "type"),
              let conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw),
              let status = XMPPMessageScheduleStorageItem.Status(rawValue: statusRaw),
              let deliverAtString = element.attributeStringValue(forName: "deliver-at"),
              let deliverAt = Self.parseTimestamp(deliverAtString) else {
            return nil
        }
        let messageElementName = "message"
        let raw = element.element(forName: messageElementName, xmlns: "jabber:client")?.xmlString
            ?? element.element(forName: messageElementName)?.xmlString
            ?? fallbackMessageXML
            ?? ""
        let messageXML: String
        if conversationType == .omemo {
            messageXML = ScheduledOMEMO2.sealedSnapshot(raw, owner: owner, conversation: conversationJID.bare) ?? ""
        } else if conversationType.isEncrypted {
            messageXML = ""
        } else {
            messageXML = raw
        }
        return ScheduledEntry(
            scheduledId: scheduledId,
            conversation: conversationJID.bare,
            conversationType: conversationType,
            deliverAt: deliverAt,
            status: status,
            messageXML: messageXML
        )
    }

    private func upsertLocked(_ entry: ScheduledEntry) {
        recordMutationLocked(scheduledId: entry.scheduledId)
        do {
            let realm = try WRealm.safe()
            try realm.write { upsert(entry, in: realm) }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func upsert(_ entry: ScheduledEntry, in realm: Realm) {
        let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: entry.scheduledId)
        let old = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary)
        // A late duplicate pending notification cannot undo a terminal failure.
        let status = old?.status == .failed ? .failed : entry.status
        let payload = entry.messageXML.isEmpty ? (old?.messageXML ?? "") : entry.messageXML
        let item = old ?? XMPPMessageScheduleStorageItem()
        item.configure(owner: owner, scheduledId: entry.scheduledId, conversation: entry.conversation,
                       conversationType: entry.conversationType, deliverAt: entry.deliverAt, status: status,
                       messageXML: payload)
        realm.add(item, update: .modified)
    }

    private func reconcileListLocked(
        _ entries: [ScheduledEntry],
        filter: ListFilter?,
        requestRevision: UInt64
    ) throws -> [ScheduledEntry] {
        func isCurrent(_ id: String, conversation: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
            let scope = ListFilter(conversation: conversation, conversationType: conversationType)
            return (filter == nil || scope == filter)
                && (mutationRevisions[id] ?? 0) < requestRevision
                && fullSnapshotRevision < requestRevision
                && (filteredSnapshotRevisions[scope] ?? 0) < requestRevision
        }

        let realm = try WRealm.safe()
        let ownerRows = realm.objects(XMPPMessageScheduleStorageItem.self).filter("owner == %@", owner)
        let rows = filter.map { ownerRows.filter("conversation == %@ AND conversationType_ == %@", $0.conversation, $0.conversationType.rawValue) }
            ?? ownerRows
        let accepted = entries.filter { isCurrent($0.scheduledId, conversation: $0.conversation, conversationType: $0.conversationType) }
        let ids = Set(entries.map(\.scheduledId))
        try realm.write {
            accepted.forEach { upsert($0, in: realm) }
            let stale = rows.filter { !ids.contains($0.scheduledId)
                && isCurrent($0.scheduledId, conversation: $0.conversation, conversationType: $0.conversationType) }
            realm.delete(stale)
        }

        if let filter {
            filteredSnapshotRevisions[filter] = max(filteredSnapshotRevisions[filter] ?? 0, requestRevision)
        } else {
            fullSnapshotRevision = max(fullSnapshotRevision, requestRevision)
        }
        return rows.sorted(byKeyPath: "deliverAt").map {
            ScheduledEntry(scheduledId: $0.scheduledId, conversation: $0.conversation,
                           conversationType: $0.conversationType, deliverAt: $0.deliverAt,
                           status: $0.status, messageXML: $0.messageXML)
        }
    }

    private func recordMutationLocked(scheduledId: String) {
        guard !requests.isEmpty else { return }
        revision += 1
        mutationRevisions[scheduledId] = revision
    }

    private func discardUnusedRevisionsLocked() {
        let oldestRequest = requests.values.map(\.revision).min() ?? revision
        mutationRevisions = mutationRevisions.filter { $0.value > oldestRequest }
        if fullSnapshotRevision < oldestRequest { fullSnapshotRevision = 0 }
        filteredSnapshotRevisions = filteredSnapshotRevisions.filter { $0.value >= oldestRequest }
    }

    private func deleteScheduleLocked(scheduledId: String, purgePreview: Bool = false) {
        recordMutationLocked(scheduledId: scheduledId)
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: scheduledId)
                if let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary) {
                    if purgePreview, item.conversationType == .omemo, let sealed = try? XMPPMessage(xmlString: item.messageXML) {
                        omemo2Previews.remove(owner: owner, conversation: item.conversation, sealed: sealed)
                    }
                    realm.delete(item)
                }
            }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func markScheduleFailedLocked(scheduledId: String) -> Bool {
        recordMutationLocked(scheduledId: scheduledId)
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(
                ofType: XMPPMessageScheduleStorageItem.self,
                forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: scheduledId)
            ) else { return false }
            try realm.write {
                item.status = .failed
                item.updatedAt = Date()
            }
            return true
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }
}
