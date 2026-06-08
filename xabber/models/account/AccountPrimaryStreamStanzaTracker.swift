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
    case durableRegularMessage(originId: String)
    case latestPresence(scope: String)
    case safeIdempotentIQ(retainedXML: String)

    var retainedXMLByteCount: Int {
        switch self {
        case .safeIdempotentIQ(let retainedXML):
            return retainedXML.utf8.count
        case .notReplayable, .durableRegularMessage, .latestPresence:
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
        case .safeIdempotentIQ:
            return 10
        case .notReplayable:
            return 0
        }
    }

    fileprivate var isUserCritical: Bool {
        if case .durableRegularMessage = self {
            return true
        }
        return false
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
    case rejected(PrimaryStreamTrackingLimitViolation)
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
              let oldestId = orderedIds.first,
              let oldest = trackedById[oldestId],
              firedTimeoutGenerations.contains(oldest.generation) == false else {
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
                  let oldestId = orderedIds.first,
                  oldestId == key.stanzaId,
                  let oldest = trackedById[oldestId],
                  oldest.generation == key.generation,
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
