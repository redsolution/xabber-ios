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
    static let namespace = "https://xabber.com/protocol/schedule"
    static let metadataKey = "schedule"
    private static let settingsNodeKey = "node"

    enum ScheduleError: Error, Equatable {
        case unavailable
        case invalidFilter
        case malformedPayload
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

    private struct ListFilter: Equatable {
        let conversation: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }

    private struct ScheduleDraft: Equatable {
        let conversation: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let deliverAt: Date
        let messageXML: String
    }

    private final class Request: Equatable {
        enum Kind {
            case schedule(ScheduleDraft, ScheduleCallback?)
            case list(ListFilter?, ListCallback?)
            case cancel(String, CancelCallback?)
        }

        let iqId: String
        let kind: Kind

        init(iqId: String, kind: Kind) {
            self.iqId = iqId
            self.kind = kind
        }

        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.iqId == rhs.iqId
        }
    }

    open var isAvailable: Bool = false
    private var trackedRequests: SynchronizedArray<Request> = SynchronizedArray<Request>()

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
    func scheduleMessage(
        _ xmppStream: XMPPStream,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        deliverAt: Date,
        payload: XMPPMessage,
        callback: ScheduleCallback? = nil
    ) -> String? {
        guard isAvailable else {
            callback?(.failure(.unavailable))
            return nil
        }
        let elementId = xmppStream.generateUUID
        let iq = makeScheduleIQ(
            elementId: elementId,
            conversation: conversation,
            conversationType: conversationType,
            deliverAt: deliverAt,
            payload: payload
        )
        let draft = ScheduleDraft(
            conversation: conversation,
            conversationType: conversationType,
            deliverAt: deliverAt,
            messageXML: preparedInnerMessage(from: payload).xmlString
        )
        let request = Request(iqId: elementId, kind: .schedule(draft, callback))
        return sendTracked(iq, on: xmppStream, request: request)
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
        let iq: XMPPIQ
        do {
            iq = try makeListIQ(elementId: elementId, conversation: conversation, conversationType: conversationType)
        } catch {
            callback?(.failure(.invalidFilter))
            return nil
        }
        let filter: ListFilter?
        if let conversation, let conversationType {
            filter = ListFilter(conversation: conversation, conversationType: conversationType)
        } else {
            filter = nil
        }
        let request = Request(iqId: elementId, kind: .list(filter, callback))
        return sendTracked(iq, on: xmppStream, request: request)
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
        let elementId = xmppStream.generateUUID
        let iq = makeCancelIQ(elementId: elementId, scheduledId: scheduledId)
        let request = Request(iqId: elementId, kind: .cancel(scheduledId, callback))
        return sendTracked(iq, on: xmppStream, request: request)
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
        schedule.addAttribute(withName: "deliver-at", stringValue: deliverAt.XMPPFormattedDate)
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
        guard let elementId = iq.elementID,
              queryIds.contains(elementId) else {
            return false
        }
        if iq.iqType == .error {
            handleErrorIQ(iq, elementId: elementId)
            return true
        }

        guard iq.iqType == .result else {
            return false
        }

        queryIds.remove(elementId)
        let request = takeRequest(for: elementId)
        if let scheduled = iq.element(forName: "scheduled", xmlns: getPrimaryNamespace()) {
            handleScheduleResult(scheduled, request: request)
            return true
        }
        if let query = iq.element(forName: "query", xmlns: getPrimaryNamespace()) {
            handleListResult(query, request: request)
            return true
        }
        handleCancelResult(request: request)
        return true
    }

    func read(headline message: XMPPMessage) -> Bool {
        if let scheduled = message.element(forName: "scheduled", xmlns: getPrimaryNamespace()),
           let entry = parseScheduledElement(scheduled, fallbackMessageXML: nil) {
            _ = upsert(entry)
            return true
        }
        if let cancelled = message.element(forName: "cancelled", xmlns: getPrimaryNamespace()),
           let scheduledId = cancelled.attributeStringValue(forName: "id") {
            deleteSchedule(scheduledId: scheduledId)
            return true
        }
        if let failed = message.element(forName: "failed", xmlns: getPrimaryNamespace()),
           let scheduledId = failed.attributeStringValue(forName: "id") {
            let marked = markScheduleFailed(scheduledId: scheduledId)
            if !marked, isAvailable {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    _ = user.messageSchedule.listScheduledMessages(stream)
                })
            }
            return true
        }
        return false
    }

    @discardableResult
    static func applyDeferredMetadata(to storedMessage: MessageStorageItem, source message: XMPPMessage) -> Bool {
        guard let deferred = message.element(forName: "deferred", xmlns: namespace),
              let scheduledId = deferred.attributeStringValue(forName: "id"),
              let deliverAtString = deferred.attributeStringValue(forName: "deliver-at"),
              let deliverAt = parseTimestamp(deliverAtString) else {
            return false
        }
        var metadata = storedMessage.systemMetadata ?? [:]
        metadata[metadataKey] = [
            "id": scheduledId,
            "deliverAt": deliverAt.XMPPFormattedDate
        ]
        storedMessage.systemMetadata = metadata
        return true
    }

    func reconcileDeliveredScheduleMarkers(from messages: [MessageStorageItem]) {
        let scheduledIds = messages.compactMap { message -> String? in
            if message.owner.isNotEmpty, message.owner != owner {
                return nil
            }
            if let schedule = message.systemMetadata?[Self.metadataKey] as? [String: Any] {
                return schedule["id"] as? String
            }
            if let schedule = message.systemMetadata?[Self.metadataKey] as? [String: String] {
                return schedule["id"]
            }
            return nil
        }
        guard scheduledIds.isNotEmpty else { return }
        do {
            let realm = try WRealm.safe()
            try realm.write {
                scheduledIds.forEach { scheduledId in
                    let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: self.owner, scheduledId: scheduledId)
                    guard let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary),
                          item.status == .pending else {
                        return
                    }
                    realm.delete(item)
                }
            }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
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
        queryIds.removeAll()
        trackedRequests.removeAll()
    }

    private func preparedInnerMessage(from payload: XMPPMessage) -> DDXMLElement {
        let message = (payload.copy() as? DDXMLElement) ?? DDXMLElement(name: "message")
        message.setXmlns("jabber:client")
        return message
    }

    @discardableResult
    private func sendTracked(_ iq: XMPPIQ, on stream: XMPPStream, request: Request) -> String? {
        guard let elementId = iq.elementID else { return nil }
        queryIds.insert(elementId)
        trackedRequests.insert(request)
        let result = sendPrimaryAware(iq, on: stream, replayPolicy: .notReplayable)
        if case .rejected = result {
            queryIds.remove(elementId)
            trackedRequests.remove(request)
            switch request.kind {
            case .schedule(_, let callback):
                callback?(.failure(.sendRejected))
            case .list(_, let callback):
                callback?(.failure(.sendRejected))
            case .cancel(_, let callback):
                callback?(.failure(.sendRejected))
            }
            return nil
        }
        return elementId
    }

    private func takeRequest(for elementId: String) -> Request? {
        var request: Request?
        trackedRequests.remove(where: { $0.iqId == elementId }) {
            request = $0
        }
        return request
    }

    private func handleScheduleResult(_ scheduled: DDXMLElement, request: Request?) {
        let fallbackMessageXML: String?
        switch request?.kind {
        case .schedule(let draft, _):
            fallbackMessageXML = draft.messageXML
        default:
            fallbackMessageXML = nil
        }
        guard let entry = parseScheduledElement(scheduled, fallbackMessageXML: fallbackMessageXML) else {
            if case .schedule(_, let callback) = request?.kind {
                callback?(.failure(.malformedPayload))
            }
            return
        }
        let stored = upsert(entry)
        if case .schedule(_, let callback) = request?.kind {
            callback?(.success(stored))
        }
    }

    private func handleListResult(_ query: DDXMLElement, request: Request?) {
        let entries = query
            .elements(forName: "scheduled")
            .compactMap { parseScheduledElement($0, fallbackMessageXML: nil) }
        let filter: ListFilter?
        let callback: ListCallback?
        switch request?.kind {
        case .list(let requestFilter, let requestCallback):
            filter = requestFilter
            callback = requestCallback
        default:
            filter = nil
            callback = nil
        }
        let stored = reconcileList(entries, filter: filter)
        callback?(.success(stored))
    }

    private func handleCancelResult(request: Request?) {
        guard case .cancel(let scheduledId, let callback) = request?.kind else {
            return
        }
        deleteSchedule(scheduledId: scheduledId)
        callback?(.success(scheduledId))
    }

    private func handleErrorIQ(_ iq: XMPPIQ, elementId: String) {
        queryIds.remove(elementId)
        let request = takeRequest(for: elementId)
        let error = mapError(iq.element(forName: "error"))
        if error == .itemNotFound,
           case .cancel(let scheduledId, _) = request?.kind {
            deleteSchedule(scheduledId: scheduledId)
        }
        switch request?.kind {
        case .schedule(_, let callback):
            callback?(.failure(error))
        case .list(_, let callback):
            callback?(.failure(error))
        case .cancel(_, let callback):
            callback?(.failure(error))
        default:
            break
        }
    }

    private func mapError(_ error: DDXMLElement?) -> ScheduleError {
        guard let error else { return .unknown(nil) }
        if error.element(forName: "bad-request") != nil { return .badRequest }
        if error.element(forName: "not-acceptable") != nil { return .notAcceptable }
        if error.element(forName: "resource-constraint") != nil { return .resourceConstraint }
        if error.element(forName: "forbidden") != nil { return .forbidden }
        if error.element(forName: "item-not-found") != nil { return .itemNotFound }
        return .unknown(error.element(forName: "text")?.stringValue)
    }

    private func parseScheduledElement(_ element: DDXMLElement, fallbackMessageXML: String?) -> ScheduledEntry? {
        guard let scheduledId = element.attributeStringValue(forName: "id"),
              let conversation = element.attributeStringValue(forName: "conversation"),
              let conversationTypeRaw = element.attributeStringValue(forName: "type"),
              let deliverAtString = element.attributeStringValue(forName: "deliver-at"),
              let deliverAt = Self.parseTimestamp(deliverAtString) else {
            return nil
        }
        let conversationType = ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? .regular
        let statusRaw = element.attributeStringValue(forName: "status") ?? XMPPMessageScheduleStorageItem.Status.pending.rawValue
        let status = XMPPMessageScheduleStorageItem.Status(rawValue: statusRaw) ?? .pending
        let messageXML = element.element(forName: "message", xmlns: "jabber:client")?.xmlString
            ?? element.element(forName: "message")?.xmlString
            ?? fallbackMessageXML
            ?? ""
        return ScheduledEntry(
            scheduledId: scheduledId,
            conversation: conversation,
            conversationType: conversationType,
            deliverAt: deliverAt,
            status: status,
            messageXML: messageXML
        )
    }

    @discardableResult
    private func upsert(_ entry: ScheduledEntry) -> ScheduledEntry {
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: self.owner, scheduledId: entry.scheduledId)
                let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary)
                    ?? XMPPMessageScheduleStorageItem()
                item.configure(
                    owner: self.owner,
                    scheduledId: entry.scheduledId,
                    conversation: entry.conversation,
                    conversationType: entry.conversationType,
                    deliverAt: entry.deliverAt,
                    status: entry.status,
                    messageXML: entry.messageXML,
                    updatedAt: Date()
                )
                realm.add(item, update: .modified)
            }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
        return entry
    }

    @discardableResult
    private func reconcileList(_ entries: [ScheduledEntry], filter: ListFilter?) -> [ScheduledEntry] {
        let ids = Set(entries.map(\.scheduledId))
        do {
            let realm = try WRealm.safe()
            try realm.write {
                entries.forEach { entry in
                    let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: self.owner, scheduledId: entry.scheduledId)
                    let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary)
                        ?? XMPPMessageScheduleStorageItem()
                    item.configure(
                        owner: self.owner,
                        scheduledId: entry.scheduledId,
                        conversation: entry.conversation,
                        conversationType: entry.conversationType,
                        deliverAt: entry.deliverAt,
                        status: entry.status,
                        messageXML: entry.messageXML,
                        updatedAt: Date()
                    )
                    realm.add(item, update: .modified)
                }
                let stale: [XMPPMessageScheduleStorageItem]
                if let filter {
                    stale = Array(realm
                        .objects(XMPPMessageScheduleStorageItem.self)
                        .filter(
                            "owner == %@ AND conversation == %@ AND conversationType_ == %@",
                            self.owner,
                            filter.conversation,
                            filter.conversationType.rawValue
                        )
                        .filter { !ids.contains($0.scheduledId) })
                } else {
                    stale = Array(realm
                        .objects(XMPPMessageScheduleStorageItem.self)
                        .filter("owner == %@", self.owner)
                        .filter { !ids.contains($0.scheduledId) })
                }
                realm.delete(stale)
            }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
        return entries
    }

    private func deleteSchedule(scheduledId: String) {
        do {
            let realm = try WRealm.safe()
            try realm.write {
                let primary = XMPPMessageScheduleStorageItem.genPrimary(owner: self.owner, scheduledId: scheduledId)
                if let item = realm.object(ofType: XMPPMessageScheduleStorageItem.self, forPrimaryKey: primary) {
                    realm.delete(item)
                }
            }
        } catch {
            DDLogDebug("XMPPMessageScheduleManager: \(#function). \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func markScheduleFailed(scheduledId: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(
                ofType: XMPPMessageScheduleStorageItem.self,
                forPrimaryKey: XMPPMessageScheduleStorageItem.genPrimary(owner: owner, scheduledId: scheduledId)
            ) else {
                return false
            }
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
