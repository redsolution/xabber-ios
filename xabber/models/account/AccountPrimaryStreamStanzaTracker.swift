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
import XMPPFramework

enum PrimaryStreamStanzaKind: String, Equatable {
    case message
    case iq
    case presence
}

enum PrimaryStreamReplayPolicy: Equatable {
    case notReplayable
    case iqResponse
    case durableRegularMessage(originId: String)
    case latestPresence(scope: String)
    case safeIdempotentIQ(retainedXML: String)
    case bootstrapClientSyncIQ
    case longRunningBackgroundIQ

    var retainedXMLByteCount: Int {
        switch self {
        case .safeIdempotentIQ(let retainedXML):
            return retainedXML.utf8.count
        case .notReplayable, .iqResponse, .durableRegularMessage, .latestPresence, .bootstrapClientSyncIQ, .longRunningBackgroundIQ:
            return 0
        }
    }

    var latestPresenceScope: String? {
        if case .latestPresence(let scope) = self {
            return scope
        }
        return nil
    }

    fileprivate var trackingPriority: Int {
        switch self {
        case .durableRegularMessage:
            return 100
        case .latestPresence:
            return 20
        case .safeIdempotentIQ, .bootstrapClientSyncIQ:
            return 10
        case .longRunningBackgroundIQ:
            return 5
        case .notReplayable, .iqResponse:
            return 0
        }
    }

    var requiresAckTimeout: Bool {
        switch self {
        case .iqResponse, .bootstrapClientSyncIQ, .longRunningBackgroundIQ:
            return false
        case .notReplayable, .durableRegularMessage, .latestPresence, .safeIdempotentIQ:
            return true
        }
    }

    var requiresOutboundHealthConfirmation: Bool {
        switch self {
        case .iqResponse, .bootstrapClientSyncIQ, .longRunningBackgroundIQ:
            return false
        case .notReplayable, .durableRegularMessage, .latestPresence, .safeIdempotentIQ:
            return true
        }
    }

    fileprivate var isUserCritical: Bool {
        if case .durableRegularMessage = self {
            return true
        }
        return false
    }
}

enum PrimaryStreamStanzaTrackingPolicy {
    static func replayPolicy(
        for stanza: XMPPElement,
        requestedPolicy: PrimaryStreamReplayPolicy
    ) -> PrimaryStreamReplayPolicy {
        guard stanza.name?.lowercased() == "iq",
              let type = stanza.attributeStringValue(forName: "type")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              type == "result" || type == "error" else {
            return requestedPolicy
        }
        return .iqResponse
    }
}

struct PrimaryStreamTrackedStanza: Equatable {
    let stanzaId: String
    let kind: PrimaryStreamStanzaKind
    let sentAt: TimeInterval
    let attemptCount: Int
    let replayPolicy: PrimaryStreamReplayPolicy
    let retainedXMLByteCount: Int
    let generation: UInt64
}

enum PrimaryStreamTrackingLimitViolation: Equatable {
    case countLimit(max: Int)
    case retainedXMLByteLimit(max: Int, attempted: Int)
}

enum PrimaryStreamTrackingResult: Equatable {
    case tracked(stanzaId: String)
    case rejected(PrimaryStreamTrackingLimitViolation)
}

enum PrimaryStreamSendResult: Equatable {
    case sent(stanzaId: String)
    case queued(stanzaId: String)
    case rejected(PrimaryStreamTrackingLimitViolation)
}

final class AccountPrimaryStreamBootstrapSendGate {
    enum Decision: Equatable {
        case allowed
        case queued(stanzaId: String)
    }

    struct QueuedStanza: Equatable {
        let stanzaId: String
        let kind: PrimaryStreamStanzaKind
        let replayPolicy: PrimaryStreamReplayPolicy
        let xmlString: String
        let queuedAt: TimeInterval
        let queuedAge: TimeInterval
        let stanzaType: String?
        let childNamespace: String?

        func makeElement() -> XMPPElement? {
            guard let document = try? DDXMLDocument(xmlString: xmlString, options: 0),
                  let root = document.rootElement() else {
                return nil
            }

            switch root.name {
            case "iq":
                return XMPPIQ(from: root)
            case "message":
                return XMPPMessage(from: root)
            case "presence":
                return XMPPPresence(from: root)
            default:
                return nil
            }
        }
    }

    private struct QueuedRecord {
        let stanzaId: String
        let kind: PrimaryStreamStanzaKind
        let replayPolicy: PrimaryStreamReplayPolicy
        let xmlString: String
        let queuedAt: TimeInterval
        let stanzaType: String?
        let childNamespace: String?
    }

    private let queue = DispatchQueue(label: "com.xabber.account.primary-stream-bootstrap-send-gate")
    private let now: () -> TimeInterval
    private var queuedRecords: [QueuedRecord] = []

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var queuedCount: Int {
        queue.sync {
            queuedRecords.count
        }
    }

    static func allowsDuringBootstrap(
        _ stanza: XMPPElement,
        replayPolicy: PrimaryStreamReplayPolicy,
        ownerBareJID: String? = nil
    ) -> Bool {
        if ClientSynchronizationManager.isClientSyncPaginationIQ(stanza) {
            return true
        }

        if case .durableRegularMessage = replayPolicy {
            return true
        }

        if isLoginCriticalSelfDiscoInfo(stanza, ownerBareJID: ownerBareJID) {
            return true
        }

        if stanza.name == "iq" {
            let type = stanza.attributeStringValue(forName: "type")?.lowercased()
            return type == "result" || type == "error"
        }

        if stanza.name == "presence" {
            return stanza.attributeStringValue(forName: "type")?.lowercased() == "unavailable"
        }

        return false
    }

    static func isLoginCriticalSelfDiscoInfo(_ stanza: XMPPElement, ownerBareJID: String?) -> Bool {
        guard stanza.name == "iq",
              stanza.attributeStringValue(forName: "type")?.lowercased() == "get",
              let ownerBareJID = normalizedBareJID(ownerBareJID),
              let toBareJID = normalizedBareJID(stanza.attributeStringValue(forName: "to")),
              ownerBareJID == toBareJID,
              let query = stanza.element(forName: "query", xmlns: "http://jabber.org/protocol/disco#info") else {
            return false
        }

        let node = query.attributeStringValue(forName: "node")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return node?.isEmpty ?? true
    }

    func prepareForSend(
        _ stanza: XMPPElement,
        replayPolicy: PrimaryStreamReplayPolicy,
        isBootstrapActive: Bool,
        ownerBareJID: String? = nil
    ) -> Decision {
        guard isBootstrapActive,
              !Self.allowsDuringBootstrap(stanza, replayPolicy: replayPolicy, ownerBareJID: ownerBareJID) else {
            return .allowed
        }

        let stanzaId = PrimaryStreamStanzaIdentifier.ensureID(on: stanza)
        let record = QueuedRecord(
            stanzaId: stanzaId,
            kind: Self.kind(for: stanza),
            replayPolicy: replayPolicy,
            xmlString: stanza.xmlString,
            queuedAt: now(),
            stanzaType: stanza.attributeStringValue(forName: "type"),
            childNamespace: Self.childNamespace(for: stanza)
        )

        queue.sync {
            if let latestPresenceScope = replayPolicy.latestPresenceScope {
                queuedRecords.removeAll {
                    $0.replayPolicy.latestPresenceScope == latestPresenceScope
                }
            }
            queuedRecords.append(record)
        }

        return .queued(stanzaId: stanzaId)
    }

    func drainQueuedStanzas() -> [QueuedStanza] {
        queue.sync {
            let drained = queuedRecords
            queuedRecords.removeAll()
            let drainTime = now()
            return drained.map { record in
                QueuedStanza(
                    stanzaId: record.stanzaId,
                    kind: record.kind,
                    replayPolicy: record.replayPolicy,
                    xmlString: record.xmlString,
                    queuedAt: record.queuedAt,
                    queuedAge: max(0, drainTime - record.queuedAt),
                    stanzaType: record.stanzaType,
                    childNamespace: record.childNamespace
                )
            }
        }
    }

    func removeAll() {
        queue.sync {
            queuedRecords.removeAll()
        }
    }

    private static func kind(for stanza: XMPPElement) -> PrimaryStreamStanzaKind {
        if stanza is XMPPIQ || stanza.name == "iq" {
            return .iq
        }
        if stanza is XMPPPresence || stanza.name == "presence" {
            return .presence
        }
        return .message
    }

    private static func childNamespace(for stanza: XMPPElement) -> String? {
        stanza.children?
            .compactMap { $0 as? DDXMLElement }
            .first?
            .xmlns()
    }

    private static func normalizedBareJID(_ jid: String?) -> String? {
        guard let jid = jid?.trimmingCharacters(in: .whitespacesAndNewlines),
              jid.isNotEmpty,
              let bare = XMPPJID(string: jid)?.bare.lowercased(),
              bare.isNotEmpty else {
            return nil
        }
        return bare
    }
}

enum PrimaryStreamStanzaIdentifier {
    static func ensureID(on element: XMPPElement) -> String {
        if let existing = element.attributeStringValue(forName: "id"),
           existing.isEmpty == false {
            return existing
        }

        let stanzaId = UUID().uuidString
        element.addAttribute(withName: "id", stringValue: stanzaId)
        return stanzaId
    }
}

final class AccountPrimaryStreamAckRequestCoordinator {
    struct Configuration {
        let stanzaThreshold: Int
        let maxDelay: TimeInterval

        static let production = Configuration(stanzaThreshold: 10, maxDelay: 1)
    }

    private let configuration: Configuration
    private let scheduler: AccountConnectionResilienceScheduling
    private let requestAck: () -> Void
    private let queue = DispatchQueue(label: "com.xabber.account.primary-stream-ack-request")

    private var pendingSentAtById: [String: TimeInterval] = [:]
    private var orderedPendingIds: [String] = []
    private var isRequestOutstanding = false
    private var timer: AccountConnectionResilienceCancellable?
    private var timerGeneration: UInt64 = 0

    init(
        configuration: Configuration = .production,
        scheduler: AccountConnectionResilienceScheduling,
        requestAck: @escaping () -> Void
    ) {
        precondition(configuration.stanzaThreshold > 0)
        precondition(configuration.maxDelay > 0)
        self.configuration = configuration
        self.scheduler = scheduler
        self.requestAck = requestAck
    }

    func noteStanzaSent(id: String?) {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return
        }

        let shouldRequest = queue.sync { () -> Bool in
            guard pendingSentAtById[id] == nil else { return false }
            pendingSentAtById[id] = scheduler.now
            orderedPendingIds.append(id)
            return evaluatePendingLocked()
        }
        if shouldRequest {
            requestAck()
        }
    }

    func noteAck(ids: [String]) {
        let acknowledgedIds = Set(ids)
        let shouldRequest = queue.sync { () -> Bool in
            if acknowledgedIds.isEmpty == false {
                acknowledgedIds.forEach { pendingSentAtById.removeValue(forKey: $0) }
                orderedPendingIds.removeAll { acknowledgedIds.contains($0) }
            }
            isRequestOutstanding = false
            return evaluatePendingLocked()
        }
        if shouldRequest {
            requestAck()
        }
    }

    func reset() {
        queue.sync {
            pendingSentAtById.removeAll()
            orderedPendingIds.removeAll()
            isRequestOutstanding = false
            cancelTimerLocked()
        }
    }

    private func evaluatePendingLocked() -> Bool {
        guard !orderedPendingIds.isEmpty else {
            cancelTimerLocked()
            return false
        }
        guard isRequestOutstanding == false else {
            cancelTimerLocked()
            return false
        }

        guard let oldestId = orderedPendingIds.first,
              let oldestSentAt = pendingSentAtById[oldestId] else {
            pendingSentAtById.removeAll()
            orderedPendingIds.removeAll()
            cancelTimerLocked()
            return false
        }

        let age = max(0, scheduler.now - oldestSentAt)
        if orderedPendingIds.count >= configuration.stanzaThreshold || age >= configuration.maxDelay {
            isRequestOutstanding = true
            pendingSentAtById.removeAll()
            orderedPendingIds.removeAll()
            cancelTimerLocked()
            return true
        }

        scheduleTimerLocked(after: configuration.maxDelay - age)
        return false
    }

    private func scheduleTimerLocked(after delay: TimeInterval) {
        guard timer == nil else { return }
        timerGeneration += 1
        let generation = timerGeneration
        timer = scheduler.schedule(after: max(0, delay)) { [weak self] in
            self?.timerDidFire(generation: generation)
        }
    }

    private func timerDidFire(generation: UInt64) {
        let shouldRequest = queue.sync { () -> Bool in
            guard generation == timerGeneration else { return false }
            timer = nil
            return evaluatePendingLocked()
        }
        if shouldRequest {
            requestAck()
        }
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}

enum PrimaryStreamSendRouting {
    static func primaryAccount(owner: String, stream: XMPPStream) -> Account? {
        guard let account = AccountManager.shared.find(for: owner),
              account.xmppStream === stream else {
            return nil
        }
        return account
    }
}

final class AccountPrimaryStreamStanzaTracker {
    struct Configuration {
        let maxTrackedCount: Int
        let maxRetainedXMLBytes: Int
        let ackTimeout: TimeInterval

        static let production = Configuration(
            maxTrackedCount: 512,
            maxRetainedXMLBytes: 512 * 1024,
            ackTimeout: 5
        )
    }

    private struct TimeoutKey: Equatable {
        let stanzaId: String
        let generation: UInt64
    }

    private let configuration: Configuration
    private let scheduler: AccountConnectionResilienceScheduling
    private let onAckTimeout: (PrimaryStreamTrackedStanza) -> Void
    private let queue = DispatchQueue(label: "com.xabber.account.primary-stream-stanza-tracker")

    private var trackedById: [String: PrimaryStreamTrackedStanza] = [:]
    private var orderedIds: [String] = []
    private var retainedXMLBytes = 0
    private var nextGeneration: UInt64 = 0
    private var timeout: AccountConnectionResilienceCancellable?
    private var scheduledTimeoutKey: TimeoutKey?
    private var firedTimeoutGenerations: Set<UInt64> = []
    private var timeoutsSuspended = false

    init(
        configuration: Configuration = .production,
        scheduler: AccountConnectionResilienceScheduling,
        onAckTimeout: @escaping (PrimaryStreamTrackedStanza) -> Void
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
        self.onAckTimeout = onAckTimeout
    }

    @discardableResult
    func track(
        stanzaId: String,
        kind: PrimaryStreamStanzaKind,
        replayPolicy: PrimaryStreamReplayPolicy
    ) -> PrimaryStreamTrackingResult {
        queue.sync {
            if trackedById[stanzaId] != nil {
                return .tracked(stanzaId: stanzaId)
            }

            if let latestPresenceScope = replayPolicy.latestPresenceScope {
                removeLatestPresenceLocked(scope: latestPresenceScope)
            }

            let retainedXMLByteCount = replayPolicy.retainedXMLByteCount
            if orderedIds.count >= configuration.maxTrackedCount {
                removeLowerPriorityTrackedStanzaLocked(for: replayPolicy)
            }
            guard orderedIds.count < configuration.maxTrackedCount else {
                return .rejected(.countLimit(max: configuration.maxTrackedCount))
            }
            if retainedXMLBytes + retainedXMLByteCount > configuration.maxRetainedXMLBytes {
                removeLowerPriorityTrackedStanzasForRetainedBytesLocked(
                    incomingPolicy: replayPolicy,
                    incomingRetainedXMLByteCount: retainedXMLByteCount
                )
            }
            guard retainedXMLBytes + retainedXMLByteCount <= configuration.maxRetainedXMLBytes else {
                return .rejected(
                    .retainedXMLByteLimit(
                        max: configuration.maxRetainedXMLBytes,
                        attempted: retainedXMLBytes + retainedXMLByteCount
                    )
                )
            }

            nextGeneration += 1
            let tracked = PrimaryStreamTrackedStanza(
                stanzaId: stanzaId,
                kind: kind,
                sentAt: scheduler.now,
                attemptCount: 1,
                replayPolicy: replayPolicy,
                retainedXMLByteCount: retainedXMLByteCount,
                generation: nextGeneration
            )
            trackedById[stanzaId] = tracked
            orderedIds.append(stanzaId)
            retainedXMLBytes += retainedXMLByteCount
            scheduleTimeoutLocked()
            return .tracked(stanzaId: stanzaId)
        }
    }

    @discardableResult
    func noteAck(ids: [String]) -> [PrimaryStreamTrackedStanza] {
        queue.sync {
            let removed = ids.compactMap { removeLocked(id: $0) }
            if removed.isEmpty == false {
                scheduleTimeoutLocked()
            }
            return removed
        }
    }

    @discardableResult
    func noteIQResponse(stanzaId: String?, type: String?) -> PrimaryStreamTrackedStanza? {
        guard let stanzaId = stanzaId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stanzaId.isEmpty,
              let type = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              type == "result" || type == "error" else {
            return nil
        }

        return queue.sync {
            guard trackedById[stanzaId]?.kind == .iq else { return nil }
            let removed = removeLocked(id: stanzaId)
            if removed != nil {
                scheduleTimeoutLocked()
            }
            return removed
        }
    }

    @discardableResult
    func noteSendFailed(id: String?) -> PrimaryStreamTrackedStanza? {
        guard let id else { return nil }
        return queue.sync {
            let removed = removeLocked(id: id)
            if removed != nil {
                scheduleTimeoutLocked()
            }
            return removed
        }
    }

    @discardableResult
    func noteResumeSucceeded(ackedIds: [String]) -> [PrimaryStreamTrackedStanza] {
        queue.sync {
            timeoutsSuspended = false
            let removed = ackedIds.compactMap { removeLocked(id: $0) }
            scheduleTimeoutLocked()
            return removed
        }
    }

    @discardableResult
    func noteResumeFailedOrFullReconnect() -> [PrimaryStreamTrackedStanza] {
        queue.sync {
            let removed = orderedIds.compactMap { trackedById[$0] }
            removeAllLocked()
            return removed
        }
    }

    func noteStreamDidDisconnect(canResume: Bool) {
        queue.sync {
            timeout?.cancel()
            timeout = nil
            scheduledTimeoutKey = nil
            timeoutsSuspended = canResume
            if canResume == false {
                removeAllLocked()
            }
        }
    }

    func contains(stanzaId: String?) -> Bool {
        guard let stanzaId else { return false }
        return queue.sync {
            trackedById[stanzaId] != nil
        }
    }

    func trackedStanza(stanzaId: String?) -> PrimaryStreamTrackedStanza? {
        guard let stanzaId else { return nil }
        return queue.sync {
            trackedById[stanzaId]
        }
    }

    func snapshotTrackedPrimaryStanzas() -> [PrimaryStreamTrackedStanza] {
        queue.sync {
            orderedIds.compactMap { trackedById[$0] }
        }
    }

    private func removeLowerPriorityTrackedStanzaLocked(for incomingPolicy: PrimaryStreamReplayPolicy) {
        guard incomingPolicy.isUserCritical else { return }
        guard let candidateId = orderedIds.first(where: { id in
            guard let tracked = trackedById[id] else { return false }
            return tracked.replayPolicy.trackingPriority < incomingPolicy.trackingPriority
        }) else {
            return
        }
        _ = removeLocked(id: candidateId)
    }

    private func removeLowerPriorityTrackedStanzasForRetainedBytesLocked(
        incomingPolicy: PrimaryStreamReplayPolicy,
        incomingRetainedXMLByteCount: Int
    ) {
        guard incomingPolicy.isUserCritical else { return }
        while retainedXMLBytes + incomingRetainedXMLByteCount > configuration.maxRetainedXMLBytes {
            guard let candidateId = orderedIds.first(where: { id in
                guard let tracked = trackedById[id] else { return false }
                return tracked.replayPolicy.trackingPriority < incomingPolicy.trackingPriority
            }) else {
                return
            }
            _ = removeLocked(id: candidateId)
        }
    }

    private func removeLatestPresenceLocked(scope: String) {
        let idsToRemove = orderedIds.filter { id in
            trackedById[id]?.replayPolicy.latestPresenceScope == scope
        }
        idsToRemove.forEach {
            _ = removeLocked(id: $0)
        }
    }

    private func removeLocked(id: String) -> PrimaryStreamTrackedStanza? {
        guard let removed = trackedById.removeValue(forKey: id) else {
            return nil
        }
        orderedIds.removeAll { $0 == id }
        retainedXMLBytes = max(0, retainedXMLBytes - removed.retainedXMLByteCount)
        return removed
    }

    private func removeAllLocked() {
        trackedById.removeAll()
        orderedIds.removeAll()
        retainedXMLBytes = 0
        timeout?.cancel()
        timeout = nil
        scheduledTimeoutKey = nil
        timeoutsSuspended = false
    }

    private func scheduleTimeoutLocked() {
        timeout?.cancel()
        timeout = nil
        scheduledTimeoutKey = nil

        guard timeoutsSuspended == false,
              let oldestId = orderedIds.first(where: { id in
                  guard let tracked = trackedById[id] else { return false }
                  return tracked.replayPolicy.requiresAckTimeout
                      && firedTimeoutGenerations.contains(tracked.generation) == false
              }),
              let oldest = trackedById[oldestId] else {
            return
        }

        let remaining = max(0, configuration.ackTimeout - (scheduler.now - oldest.sentAt))
        let key = TimeoutKey(stanzaId: oldest.stanzaId, generation: oldest.generation)
        scheduledTimeoutKey = key
        timeout = scheduler.schedule(after: remaining) { [weak self] in
            self?.fireTimeout(for: key)
        }
    }

    private func fireTimeout(for key: TimeoutKey) {
        let timedOutStanza = queue.sync { () -> PrimaryStreamTrackedStanza? in
            guard scheduledTimeoutKey == key,
                  let oldest = trackedById[key.stanzaId],
                  oldest.generation == key.generation,
                  oldest.replayPolicy.requiresAckTimeout,
                  firedTimeoutGenerations.contains(key.generation) == false else {
                return nil
            }

            firedTimeoutGenerations.insert(key.generation)
            timeout?.cancel()
            timeout = nil
            scheduledTimeoutKey = nil
            return oldest
        }

        if let timedOutStanza {
            onAckTimeout(timedOutStanza)
        }
    }
}
