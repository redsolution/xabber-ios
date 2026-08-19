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
import XMPPFramework
import RealmSwift

enum CanonicalGroupSynchronizationSignal: Equatable {
    case active(groupJID: String)
    case pendingInvite(groupJID: String)
    case deleted(groupJID: String)
}

struct ClientSyncPageParser {
    struct RSMPage {
        let first: String?
        let firstIndex: Int?
        let last: String?
        let count: Int?
    }

    struct SnapshotPage {
        let stamp: String
        let isFinalPage: Bool
        let nextPageToken: String?
        let conversations: [DDXMLElement]
        let rsm: RSMPage
    }

    static func parseSnapshotPage(from iq: XMPPIQ, pageSize: Int, namespace: String, updateOmemo: (DDXMLElement) -> DDXMLElement) -> SnapshotPage? {
        guard let query = iq.element(forName: "query", xmlns: namespace),
              let stamp = query.attributeStringValue(forName: "stamp") else {
            return nil
        }
        let normalizedQuery = updateOmemo(query)
        let conversations = normalizedQuery.elements(forName: "conversation").compactMap { $0.copy() as? DDXMLElement }
        let set = normalizedQuery.element(forName: "set")
        let firstElement = set?.element(forName: "first")
        let first = firstElement?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstIndex = firstElement
            .flatMap { $0.attributeStringValue(forName: "index") }
            .flatMap { Int($0) }
        let nextPageToken = set?
            .element(forName: "last")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rsmCountString = set?
            .element(forName: "count")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rsmCount = rsmCountString.flatMap { Int($0) }
        let hasNextPageToken = nextPageToken?.isNotEmpty == true
        let isFinalPage: Bool
        if let rsmCount, let firstIndex {
            isFinalPage = firstIndex + conversations.count >= rsmCount
        } else if let rsmCount, rsmCount <= conversations.count {
            isFinalPage = true
        } else if !hasNextPageToken {
            isFinalPage = true
        } else {
            isFinalPage = false
        }
        return SnapshotPage(
            stamp: stamp,
            isFinalPage: isFinalPage,
            nextPageToken: hasNextPageToken ? nextPageToken : nil,
            conversations: conversations,
            rsm: RSMPage(
                first: first?.isNotEmpty == true ? first : nil,
                firstIndex: firstIndex,
                last: hasNextPageToken ? nextPageToken : nil,
                count: rsmCount
            )
        )
    }
}

struct ClientSyncPageApplier {
    struct ApplySummary {
        let receivedCount: Int
        let createdChatCount: Int
        let updatedChatCount: Int
        let skippedConversationCount: Int
        let failedConversationCount: Int
    }

    struct ApplyResult {
        let queueItems: Set<MessageManager.MessageQueueItem>
        let summary: ApplySummary
    }

    private struct ConversationIdentity {
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let primary: String
    }

    private static func identity(from conversation: DDXMLElement, owner: String) -> ConversationIdentity? {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              jid.isNotEmpty else {
            return nil
        }
        let rawType = conversation.attributeStringValue(forName: "type")
            ?? CommonConfigManager.shared.config.locked_conversation_type
        let conversationType = ClientSynchronizationManager.ConversationType(rawValue: rawType) ?? .regular
        return ConversationIdentity(
            jid: jid,
            conversationType: conversationType,
            primary: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        )
    }

    static func apply(
        owner: String,
        realm: Realm,
        conversations: [DDXMLElement],
        accountCreateDate: Date?,
        activeCanonicalGroupPrimaries: Set<String> = [],
        applyConversationState: (DDXMLElement, Realm) -> Bool,
        readInvites: (DDXMLElement, Realm) -> Bool,
        readConversation: (DDXMLElement, Realm, Date?) -> MessageManager.MessageQueueItem?,
        readMarkers: (DDXMLElement, Realm) -> Void,
        readPresence: (DDXMLElement, Realm) -> Void
    ) throws -> ApplyResult {
        var queueItems = Set<MessageManager.MessageQueueItem>()
        var createdChatCount = 0
        var updatedChatCount = 0
        var skippedConversationCount = 0
        var failedConversationCount = 0

        conversations.forEach { sourceConversation in
            let conversation = (sourceConversation.copy() as? DDXMLElement) ?? sourceConversation
            let identity = Self.identity(from: conversation, owner: owner)
            if let identity,
               CanonicalGroupRegularShadowPolicy.shouldSuppress(
                    owner: owner,
                    jid: identity.jid,
                    conversationType: identity.conversationType,
                    activeGroupPrimaries: activeCanonicalGroupPrimaries
               ) {
                // Ignore the entire generic projection. In particular, do not
                // leak a canonical group into roster/presence contact state.
                skippedConversationCount += 1
                return
            }
            // For a not-yet-admitted Xabber Group, XEP-SYNC is only a discovery
            // signal. Existing `.both` memberships may still consume ordinary
            // unread/pin/mute projection metadata, but generic sync cannot
            // create LastChat/roster/resource before membership is proven.
            if let identity,
               identity.conversationType == .group,
               !CanonicalGroupMessageAdmission.allowsPersistence(
                    owner: owner,
                    groupJID: identity.jid,
                    repository: GroupRepository(realm: realm)
               ) {
                skippedConversationCount += 1
                return
            }
            let existedBefore = identity
                .flatMap { realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: $0.primary) } != nil
            var didApplyConversationState = false
            var consumedInvite = false

            do {
                try realm.write {
                    guard applyConversationState(conversation, realm) else {
                        return
                    }
                    didApplyConversationState = true
                    if readInvites(conversation, realm) {
                        consumedInvite = true
                        return
                    }
                    if let item = readConversation(conversation, realm, accountCreateDate) {
                        queueItems.insert(item)
                    }
                    readMarkers(conversation, realm)
                    readPresence(conversation, realm)
                }
            } catch {
                failedConversationCount += 1
                DDLogDebug("ClientSyncPageApplier: failed conversation owner=\(owner) jid=\(identity?.jid ?? "-") type=\(identity?.conversationType.rawValue ?? "-") error=\(error.localizedDescription)")
                return
            }

            guard didApplyConversationState, !consumedInvite, let identity else {
                skippedConversationCount += 1
                return
            }

            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: identity.primary) != nil {
                if existedBefore {
                    updatedChatCount += 1
                } else {
                    createdChatCount += 1
                }
            } else {
                skippedConversationCount += 1
            }
        }

        return ApplyResult(
            queueItems: queueItems,
            summary: ApplySummary(
                receivedCount: conversations.count,
                createdChatCount: createdChatCount,
                updatedChatCount: updatedChatCount,
                skippedConversationCount: skippedConversationCount,
                failedConversationCount: failedConversationCount
            )
        )
    }
}

class ClientSynchronizationManager: AbstractXMPPManager {
    private struct SyncUnreadState {
        let count: Int
        let afterId: String?
        let lastMessageArchiveId: String?
    }

    struct ConversationSnapshotLastMessageIdentity: Equatable {
        let archiveId: String?
        let messageId: String?
        let senderId: String?
        let bodyFingerprint: String?
        let date: Date?
    }

    typealias RegularSnapshotLastMessageIdentity = ConversationSnapshotLastMessageIdentity

    enum ConversationSnapshotSyncPolicy {
        static func matchesLocalLastMessage(
            snapshot: ConversationSnapshotLastMessageIdentity,
            localLastMessageId: String,
            localLastMessage: MessageStorageItem?,
            owner: String,
            jid: String
        ) -> Bool {
            if let archiveId = snapshot.archiveId,
               archiveId.isNotEmpty,
               localLastMessage?.archivedId == archiveId {
                return true
            }

            if let messageId = snapshot.messageId,
               messageId.isNotEmpty,
               localLastMessageId == messageId || localLastMessage?.messageId == messageId {
                return true
            }

            guard let localLastMessage,
                  let snapshotDate = snapshot.date else {
                return false
            }

            let localSenderId = localLastMessage.outgoing ? owner : jid
            let datesMatch = abs(localLastMessage.date.timeIntervalSince1970 - snapshotDate.timeIntervalSince1970) < 1
            let senderMatches = snapshot.senderId?.isEmpty != false || snapshot.senderId == localSenderId
            let bodyMatches = snapshot.bodyFingerprint?.isEmpty != false ||
                MentionNotificationSync.normalizedBodyFingerprint(localLastMessage.body) == snapshot.bodyFingerprint

            return datesMatch && senderMatches && bodyMatches
        }
    }

    enum RegularSnapshotSyncPolicy {
        static func matchesLocalLastMessage(
            snapshot: ConversationSnapshotLastMessageIdentity,
            localLastMessageId: String,
            localLastMessage: MessageStorageItem?,
            owner: String,
            jid: String
        ) -> Bool {
            ConversationSnapshotSyncPolicy.matchesLocalLastMessage(
                snapshot: snapshot,
                localLastMessageId: localLastMessageId,
                localLastMessage: localLastMessage,
                owner: owner,
                jid: jid
            )
        }
    }

    private struct SyncPayloadApplyResult {
        let snapshotRepairTargets: [MessageArchiveManager.SnapshotRepairTarget]
        let applySummary: ClientSyncPageApplier.ApplySummary
    }

    struct SyncRequestDiagnostics {
        let id: String
        let stamp: String?
        let after: String?
        let before: String?
        let max: Int
    }

    private struct TrackedSyncRequest {
        let diagnostics: SyncRequestDiagnostics
        let generation: UInt64
    }

    private enum SyncSessionApplyError: Error {
        case invalidated
    }

    private struct SnapshotCompletionActions {
        let snapshotRepairTargets: [MessageArchiveManager.SnapshotRepairTarget]
        let postBootstrapWork: [() -> Void]
        let needsCatchUpSync: Bool

        static let none = SnapshotCompletionActions(
            snapshotRepairTargets: [],
            postBootstrapWork: [],
            needsCatchUpSync: false
        )
    }

    enum SyncPhase {
        case idle
        case snapshotInProgress
        case catchingUp
        case live
    }

    private enum SnapshotRequestStampMode: Equatable {
        case absent
        case value(String)

        var attributeValue: String? {
            switch self {
            case .absent:
                return nil
            case .value(let stamp):
                return stamp
            }
        }

        var persistedValue: String {
            switch self {
            case .absent:
                return ClientSynchronizationManager.snapshotBootstrapAbsentStampSentinel
            case .value(let stamp):
                return stamp
            }
        }

        static func fromAttribute(_ stamp: String?) -> SnapshotRequestStampMode {
            if let stamp = ClientSynchronizationManager.normalizedSyncString(stamp) {
                return .value(stamp)
            }
            return .absent
        }
    }
    
    public let pageSize: Int = 60
    
    open var isAvailable: Bool = false
    open var version: String = ""
    private var temporaryVer: String? = nil
    private let applyQueue = DispatchQueue(label: "com.xabber.client-sync.apply")
    private let stateQueue = DispatchQueue(label: "com.xabber.client-sync.state")
    private let syncLifecycleLock = NSLock()
    private var syncRequestInfoById: [String: TrackedSyncRequest] = [:]
    private var syncSessionGeneration: UInt64 = 0
    private var phase: SyncPhase = .idle
    private var activeSnapshotStamp: String? = nil
    private var activeSnapshotRequestedStampMode: SnapshotRequestStampMode? = nil
    private var requestedSnapshotAfterTokens = Set<String>()
    private var seenSnapshotConversationKeys = Set<String>()
    private var isApplyingPage: Bool = false
    private var pendingSnapshotRepairTargets = Set<MessageArchiveManager.SnapshotRepairTarget>()
    private var pendingPostBootstrapWork: [() -> Void] = []
    private var needsCatchUpAfterSnapshot = false
    
    private enum InitialPresenceSessionState {
        case awaitingAuthenticatedStream(wasSent: Bool)
        case ready
        case sent
    }

    private var initialPresenceSessionState: InitialPresenceSessionState = .awaitingAuthenticatedStream(wasSent: false)
    
    internal var acountSynced: Bool = false
    private var ignorePush: Bool = false
    
    internal var firstSync: Bool = true
    internal var beforeApplyingSyncPayload: (() throws -> Void)?
    internal var syncRequestObserver: ((SyncRequestDiagnostics) -> Void)?
    internal var initialPresenceSendAttemptObserver: (() -> Void)?
    internal var beforeResettingSyncResult: (() -> Void)?
    internal var beforeResettingSnapshotFailure: (() -> Void)?
    internal var beforeDispatchingSnapshotContinuation: (() -> Void)?
    
    enum ConversationStatus: String {
        case archived = "archived"
        case active = "active"
        case deleted = "deleted"
    }
    
    enum ConversationType: String {
        case regular = "urn:xabber:chat"
        case group = "https://xabber.com/protocol/groups"
        case channel = "https://xabber.com/protocol/channels"
        case omemo = "urn:xmpp:omemo:2"
        case omemo1 = "urn:xmpp:omemo:1"
        case axolotl = "eu.siacs.conversations.axolotl"
        case notifications = "urn:xabber:xen:0"
        case saved = "urn:xabber:favorites:0"
        
        var isEncrypted: Bool {
            get {
                return [.omemo, .omemo1, .axolotl].contains(self)
            }
        }

        var supportsSnapshotArchiveRepair: Bool {
            [.regular, .group, .omemo, .omemo1, .axolotl, .saved].contains(self)
        }
    }
    
    static public let primaryNamespace = "https://xabber.com/protocol/synchronization"
    private static let lastRecognizedEventStampKey = "last_recognized_event_stamp"
    private static let lastCompletedSnapshotStampKey = "last_completed_snapshot_stamp"
    private static let snapshotBootstrapInProgressKey = "snapshot_bootstrap_in_progress"
    private static let snapshotBootstrapRequestedStampKey = "snapshot_bootstrap_requested_stamp"
    private static let snapshotBootstrapLastAfterKey = "snapshot_bootstrap_last_after"
    private static let snapshotBootstrapAbsentStampSentinel = "__xabber_snapshot_stamp_absent__"
    
    init(withOwner owner: String, ignorePush: Bool = false) {
        super.init(withOwner: owner)
        self.ignorePush = ignorePush
    }
    
    override func getPrimaryNamespace() -> String {
        return ClientSynchronizationManager.primaryNamespace
    }
    
    open func checkAvailability(_ features: DDXMLElement) {
        if features.element(forName: "starttls") != nil { return }
        guard let synchronization = features.element(forName: "synchronization"),
            synchronization.xmlns() == ClientSynchronizationManager.primaryNamespace else {
                isAvailable = false
                return
        }
        isAvailable = true
        updateStateForAccount()
        version = Self.normalizedSyncString(lastRecognizedEventStamp)
            ?? SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: "version")
            ?? ""
        if version.isEmpty {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "0")
        }
    }

    private static func normalizedSyncString(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isNotEmpty ? normalized : nil
    }

    private var lastRecognizedEventStamp: String? {
        get {
            SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey)
        }
        set {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey, value: newValue ?? "")
        }
    }

    private var lastCompletedSnapshotStamp: String? {
        get {
            SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey)
        }
        set {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey, value: newValue ?? "")
        }
    }

    static func completedSnapshotStamp(for owner: String) -> String? {
        normalizedSyncString(
            SettingManager.shared.getKey(
                for: owner,
                scope: .clientSynchronization,
                key: lastCompletedSnapshotStampKey
            )
        )
    }

    private func updateStoredVersion(_ stamp: String) {
        version = stamp
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: stamp)
    }

    private func markLastRecognizedEventStamp(_ stamp: String) {
        lastRecognizedEventStamp = stamp
        updateStoredVersion(stamp)
    }

    private var isPersistedSnapshotBootstrapInProgress: Bool {
        SettingManager.shared.getKeyBool(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapInProgressKey
        ) == true
    }

    private var persistedSnapshotBootstrapRequestedStampMode: SnapshotRequestStampMode? {
        let raw = SettingManager.shared.getKey(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey
        )
        if raw == ClientSynchronizationManager.snapshotBootstrapAbsentStampSentinel {
            return .absent
        }
        guard let stamp = Self.normalizedSyncString(raw) else {
            return nil
        }
        if stamp == "0",
           Self.normalizedSyncString(lastCompletedSnapshotStamp) == nil,
           Self.normalizedSyncString(lastRecognizedEventStamp) == nil {
            return .absent
        }
        return .value(stamp)
    }

    private func markSnapshotBootstrapInProgress(requestedStampMode: SnapshotRequestStampMode, after: String?) {
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapInProgressKey,
            value: true
        )
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey,
            value: requestedStampMode.persistedValue
        )
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapLastAfterKey,
            value: after ?? ""
        )
    }

    private func clearSnapshotBootstrapInProgress() {
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapInProgressKey,
            value: false
        )
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey,
            value: ""
        )
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: ClientSynchronizationManager.snapshotBootstrapLastAfterKey,
            value: ""
        )
    }

    private func stampModeForSyncRequest(customVer: String?, after: String?) -> SnapshotRequestStampMode? {
        if let customVer = Self.normalizedSyncString(customVer) {
            return .value(customVer)
        }
        if after != nil {
            if let active = stateQueue.sync(execute: { activeSnapshotRequestedStampMode }) {
                return active
            }
            if let persistedSnapshotBootstrapRequestedStampMode {
                return persistedSnapshotBootstrapRequestedStampMode
            }
        }
        if isPersistedSnapshotBootstrapInProgress {
            if let lastCompletedSnapshotStamp = Self.normalizedSyncString(lastCompletedSnapshotStamp) {
                return .value(lastCompletedSnapshotStamp)
            }
            return persistedSnapshotBootstrapRequestedStampMode ?? .absent
        }
        if let lastRecognizedEventStamp = Self.normalizedSyncString(lastRecognizedEventStamp) {
            return .value(lastRecognizedEventStamp)
        }
        if let version = Self.normalizedSyncString(version),
           version != "0" {
            return .value(version)
        }
        return nil
    }

    private func canStartSync(after: String?) -> Bool {
        stateQueue.sync {
            if after != nil {
                return true
            }
            if isApplyingPage {
                return false
            }
            switch phase {
            case .idle, .live:
                phase = .snapshotInProgress
                activeSnapshotStamp = nil
                activeSnapshotRequestedStampMode = nil
                requestedSnapshotAfterTokens.removeAll()
                seenSnapshotConversationKeys.removeAll()
                pendingSnapshotRepairTargets.removeAll()
                needsCatchUpAfterSnapshot = false
                return true
            case .snapshotInProgress, .catchingUp:
                return false
            }
        }
    }

    private func canStartSyncWithStalePhaseRecovery(after: String?) -> Bool {
        if canStartSync(after: after) {
            return true
        }
        guard after == nil,
              stateQueue.sync(execute: { syncRequestInfoById.isEmpty }) else {
            return false
        }
        let canRecover = stateQueue.sync {
            !isApplyingPage && (phase == .snapshotInProgress || phase == .catchingUp)
        }
        guard canRecover else {
            return false
        }
        logSyncTrace("staleSnapshotPhaseRecoveredForRetry", [
            ("persistedSnapshotStamp", "withheld")
        ])
        resetSyncStateAfterFailure()
        return canStartSync(after: after)
    }

    private func updatePhase(_ phase: SyncPhase) {
        stateQueue.sync {
            self.phase = phase
        }
    }

    private func isCurrentSyncSessionGeneration(_ generation: UInt64) -> Bool {
        stateQueue.sync { syncSessionGeneration == generation }
    }

    private func registerSyncQuery(_ elementId: String, request: SyncRequestDiagnostics) {
        queryIds.insert(elementId)
        stateQueue.sync {
            syncRequestInfoById[elementId] = TrackedSyncRequest(
                diagnostics: request,
                generation: syncSessionGeneration
            )
        }
    }

    private func consumeTrackedSyncRequest(_ elementId: String) -> TrackedSyncRequest? {
        syncLifecycleLock.lock()
        let trackedRequest = stateQueue.sync {
            syncRequestInfoById.removeValue(forKey: elementId)
        }
        if trackedRequest != nil {
            queryIds.remove(elementId)
        }
        syncLifecycleLock.unlock()
        return trackedRequest
    }

    private func registerGenericQueryId(_ elementId: String) {
        syncLifecycleLock.lock()
        queryIds.insert(elementId)
        syncLifecycleLock.unlock()
    }

    private func consumeGenericQueryId(_ elementId: String) -> Bool {
        syncLifecycleLock.lock()
        let isTracked = queryIds.contains(elementId)
        if isTracked {
            queryIds.remove(elementId)
        }
        syncLifecycleLock.unlock()
        return isTracked
    }

    @discardableResult
    private func resetSyncStateAfterFailure(expectedGeneration: UInt64? = nil) -> Bool {
        let didReset = stateQueue.sync {
            if let expectedGeneration,
               syncSessionGeneration != expectedGeneration {
                return false
            }
            phase = .idle
            activeSnapshotStamp = nil
            activeSnapshotRequestedStampMode = nil
            requestedSnapshotAfterTokens.removeAll()
            seenSnapshotConversationKeys.removeAll()
            isApplyingPage = false
            pendingSnapshotRepairTargets.removeAll()
            needsCatchUpAfterSnapshot = false
            return true
        }
        if didReset {
            temporaryVer = nil
        }
        return didReset
    }

    private func processQueueItems(_ queueItems: Set<MessageManager.MessageQueueItem>) {
        guard !queueItems.isEmpty else { return }
        AccountManager
            .shared
            .find(for: self.owner)?
            .messages
            .processQueue(queueItems) {
                if let results = $0 {
                    AccountManager.shared.find(for: self.owner)?.messages.save(results)
                }
            }
    }

    private func routeCanonicalGroupMessages(
        from conversations: [DDXMLElement]
    ) {
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        conversations.compactMap(Self.syncLastMessage).forEach { message in
            _ = account.routeCanonicalGroupMessage(message)
        }
    }

    static func canonicalGroupSynchronizationSignal(
        from conversation: DDXMLElement
    ) -> CanonicalGroupSynchronizationSignal? {
        guard conversation.attributeStringValue(forName: "type") ==
                ConversationType.group.rawValue,
              let rawJID = conversation.attributeStringValue(forName: "jid") else {
            return nil
        }
        let groupJID = GroupStorageKey.bareJID(rawJID)
        guard !groupJID.isEmpty else { return nil }
        if conversation.element(forName: "deleted") != nil ||
            conversation.attributeStringValue(forName: "status") ==
                ConversationStatus.deleted.rawValue {
            return .deleted(groupJID: groupJID)
        }
        if let message = syncLastMessage(from: conversation),
           isCanonicalGroupInvite(message) {
            return .pendingInvite(groupJID: groupJID)
        }
        let status = conversation.attributeStringValue(forName: "status")
        guard status == nil || status == ConversationStatus.active.rawValue ||
                status == ConversationStatus.archived.rawValue else {
            return nil
        }
        return .active(groupJID: groupJID)
    }

    private func routeCanonicalGroupSynchronization(
        from conversations: [DDXMLElement]
    ) {
        let signals = conversations.compactMap(
            Self.canonicalGroupSynchronizationSignal(from:)
        )
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        signals.forEach { signal in
            switch signal {
            case let .active(groupJID):
                account.recoverCanonicalGroupMembershipFromSynchronization(groupJID)
            case .pendingInvite:
                // The canonical invite message was routed above and remains a
                // separate pending object. It is never admitted as a chat.
                break
            case let .deleted(groupJID):
                account.reconcileCanonicalGroupDeletionFromSynchronization(groupJID)
            }
        }
    }

    private func applySyncPayload(
        conversations: [DDXMLElement],
        accountCreateDate: Date?,
        expectedGeneration: UInt64? = nil
    ) throws -> SyncPayloadApplyResult {
        try beforeApplyingSyncPayload?()
        if let expectedGeneration,
           !isCurrentSyncSessionGeneration(expectedGeneration) {
            throw SyncSessionApplyError.invalidated
        }
        routeCanonicalGroupMessages(from: conversations)
        var snapshotRepairTargets: [MessageArchiveManager.SnapshotRepairTarget] = []
        var seenSnapshotRepairTargets = Set<MessageArchiveManager.SnapshotRepairTarget>()
        let recordSnapshotRepairTarget: (MessageArchiveManager.SnapshotRepairTarget) -> Void = { target in
            guard seenSnapshotRepairTargets.insert(target).inserted else {
                return
            }
            snapshotRepairTargets.append(target)
        }
        let realm = try WRealm.safe()
        let activeGroupPrimaries = CanonicalGroupRegularShadowPolicy
            .activeGroupPrimaries(in: realm, owners: [self.owner])
        let result = try ClientSyncPageApplier.apply(
            owner: owner,
            realm: realm,
            conversations: conversations,
            accountCreateDate: accountCreateDate,
            activeCanonicalGroupPrimaries: activeGroupPrimaries,
            applyConversationState: self.readConversationMetadata(_:realm:),
            readInvites: self.readInvites(_:realm:),
            readConversation: { conversation, realm, accountCreateDate in
                self.readConversation(
                    conversation,
                    realm: realm,
                    accountCreateDate: accountCreateDate,
                    activeGroupPrimaries: activeGroupPrimaries,
                    recordSnapshotRepairTarget: recordSnapshotRepairTarget
                )
            },
            readMarkers: self.readMessageMarkers(_:realm:),
            readPresence: self.readPresence(_:realm:)
        )
        processQueueItems(result.queueItems)
        routeCanonicalGroupSynchronization(from: conversations)
        return SyncPayloadApplyResult(
            snapshotRepairTargets: snapshotRepairTargets,
            applySummary: result.summary
        )
    }

    @discardableResult
    private func beginApplyingPage(
        snapshotStamp: String,
        request: SyncRequestDiagnostics?,
        expectedGeneration: UInt64
    ) -> Bool {
        let requestedStampMode = request.map { SnapshotRequestStampMode.fromAttribute($0.stamp) }
            ?? stateQueue.sync { activeSnapshotRequestedStampMode }
            ?? Self.normalizedSyncString(lastCompletedSnapshotStamp).map { SnapshotRequestStampMode.value($0) }
            ?? .absent
        let didBegin = stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration else {
                return false
            }
            isApplyingPage = true
            if activeSnapshotStamp == nil {
                activeSnapshotStamp = snapshotStamp
                activeSnapshotRequestedStampMode = requestedStampMode
                if phase == .idle || phase == .live {
                    phase = .snapshotInProgress
                }
            }
            return true
        }
        guard didBegin else { return false }
        markSnapshotBootstrapInProgress(requestedStampMode: requestedStampMode, after: request?.after)
        return isCurrentSyncSessionGeneration(expectedGeneration)
    }

    private func finishApplyingPage(
        snapshotStamp: String,
        isFinalPage: Bool,
        expectedGeneration: UInt64
    ) -> SnapshotCompletionActions? {
        stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration else {
                return nil
            }
            isApplyingPage = false
            if isFinalPage {
                let actions = SnapshotCompletionActions(
                    snapshotRepairTargets: Array(pendingSnapshotRepairTargets),
                    postBootstrapWork: pendingPostBootstrapWork,
                    needsCatchUpSync: needsCatchUpAfterSnapshot
                )
                activeSnapshotStamp = nil
                activeSnapshotRequestedStampMode = nil
                requestedSnapshotAfterTokens.removeAll()
                seenSnapshotConversationKeys.removeAll()
                phase = .live
                pendingSnapshotRepairTargets.removeAll()
                pendingPostBootstrapWork.removeAll()
                needsCatchUpAfterSnapshot = false
                return actions
            } else {
                phase = .catchingUp
                return SnapshotCompletionActions.none
            }
        }
    }

    @discardableResult
    private func recordAppliedSnapshotPage(
        _ result: SyncPayloadApplyResult,
        expectedGeneration: UInt64
    ) -> Bool {
        stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration else {
                return false
            }
            result.snapshotRepairTargets.forEach { pendingSnapshotRepairTargets.insert($0) }
            return true
        }
    }

    private func noteCatchUpNeededAfterSnapshot() {
        stateQueue.sync {
            needsCatchUpAfterSnapshot = true
        }
    }

    private func deferSnapshotRepairTargets(_ targets: [MessageArchiveManager.SnapshotRepairTarget]) {
        guard targets.isNotEmpty else { return }
        stateQueue.sync {
            targets.forEach { pendingSnapshotRepairTargets.insert($0) }
        }
    }

    private func scheduleSnapshotRepairTargetsImmediately(_ targets: [MessageArchiveManager.SnapshotRepairTarget]) {
        guard targets.isNotEmpty else { return }
        // The archive engine verifies only the window a user requests. A
        // completed account snapshot may mark many conversations stale, but
        // eagerly issuing one MAM repair per conversation creates a long
        // head-of-line queue in front of chat open, paging, and search while
        // also amplifying server work. Keep the stale metadata as admission
        // input and repair it on demand through AccountArchiveEngine.
    }

    private func shouldDeferBootstrapWorkLocked() -> Bool {
        // A completed snapshot is a usable local baseline. Later stamp-based
        // catch-up must not turn the primary stream back into a bootstrap-only lane.
        guard isAvailable,
              Self.normalizedSyncString(lastCompletedSnapshotStamp) == nil else {
            return false
        }
        return !acountSynced ||
            isApplyingPage ||
            phase == .snapshotInProgress ||
            phase == .catchingUp ||
            isPersistedSnapshotBootstrapInProgress
    }

    @discardableResult
    public final func deferPostBootstrapWorkIfNeeded(_ work: @escaping () -> Void) -> Bool {
        stateQueue.sync {
            guard shouldDeferBootstrapWorkLocked() else {
                return false
            }
            pendingPostBootstrapWork.append(work)
            return true
        }
    }

    public final func isBootstrapCriticalSyncInProgress() -> Bool {
        stateQueue.sync {
            shouldDeferBootstrapWorkLocked()
        }
    }

    private func flushSnapshotCompletionActions(_ actions: SnapshotCompletionActions) {
        let account = AccountManager.shared.find(for: self.owner)
        account?.flushBootstrapQueuedPrimaryStanzas(reason: "snapshotComplete")
        account?.xmppTaskScheduler.bootstrapGateDidChange()
        scheduleSnapshotRepairTargetsImmediately(actions.snapshotRepairTargets)
        actions.postBootstrapWork.forEach { $0() }
    }

    private func conversationKeys(from conversations: [DDXMLElement]) -> [String] {
        conversations.compactMap { conversation in
            guard let jid = conversation.attributeStringValue(forName: "jid"),
                  jid.isNotEmpty else {
                return nil
            }
            let type = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
            return "\(jid)|\(type.rawValue)"
        }
    }

    private func noteReceivedConversationKeys(
        _ keys: [String],
        expectedGeneration: UInt64
    ) -> Int? {
        stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration else {
                return nil
            }
            var duplicateCount = 0
            keys.forEach { key in
                if !seenSnapshotConversationKeys.insert(key).inserted {
                    duplicateCount += 1
                }
            }
            return duplicateCount
        }
    }

    private func shouldRequestNextSnapshotPage(
        after nextPageToken: String,
        currentAfter: String?,
        expectedGeneration: UInt64
    ) -> Bool {
        stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration,
                  nextPageToken.isNotEmpty,
                  nextPageToken != currentAfter,
                  !requestedSnapshotAfterTokens.contains(nextPageToken) else {
                return false
            }
            requestedSnapshotAfterTokens.insert(nextPageToken)
            return true
        }
    }

    static func dateFromSyncStamp(_ stamp: Double) -> Date {
        Date(timeIntervalSince1970: stamp / 1_000_000)
    }

    static func syncStamp(from messageElement: DDXMLElement?, fallback: Double) -> Double {
        if let date = messageElement?.element(forName: "time")?.attributeStringValue(forName: "stamp")?.xmppDate {
            return date.timeIntervalSince1970 * 1_000_000
        }
        return fallback
    }

    static func archivedMessageDate(from messageElement: DDXMLElement?, fallbackSyncStamp: Double) -> Date {
        guard let messageElement = messageElement else {
            return dateFromSyncStamp(fallbackSyncStamp)
        }
        return dateFromSyncStamp(syncStamp(from: messageElement, fallback: fallbackSyncStamp))
    }

    private func conversationSnapshotIdentity(
        from messageStanza: XMPPMessage,
        fallbackDate: Date
    ) -> ConversationSnapshotLastMessageIdentity {
        let archiveId = Self.normalizedArchiveId(getStanzaId(messageStanza, owner: self.owner))
        let messageId = getUniqueMessageId(messageStanza, owner: self.owner)
        return ConversationSnapshotLastMessageIdentity(
            archiveId: archiveId,
            messageId: messageId.isNotEmpty ? messageId : nil,
            senderId: messageStanza.from?.bare,
            bodyFingerprint: MentionNotificationSync.normalizedBodyFingerprint(messageStanza.body),
            date: getDeliveryDate(messageStanza) ?? fallbackDate
        )
    }

    private func applyConversationSnapshotArchiveState(
        jid: String,
        conversationType: ConversationType,
        snapshot: ConversationSnapshotLastMessageIdentity?,
        lastChat: LastChatsStorageItem,
        previousSyncUnreadCount: Int,
        previousSyncUnreadAfterId: String?,
        previousLastMessageId: String,
        previousLastMessage: MessageStorageItem?,
        isNewChatInstance: Bool,
        realm: Realm,
        recordRepairTarget: (MessageArchiveManager.SnapshotRepairTarget) -> Void
    ) {
        guard conversationType.supportsSnapshotArchiveRepair else {
            return
        }

        let statePrimary = RegularChatArchiveSyncStateStorageItem.genPrimary(
            jid: jid,
            owner: self.owner,
            conversationType: conversationType
        )
        let existingArchiveState = realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: statePrimary
        )
        let unreadChanged = previousSyncUnreadCount != lastChat.syncUnreadCount
        let unreadBoundaryChanged = previousSyncUnreadAfterId != lastChat.syncUnreadAfterId
        let lastMessageChanged: Bool
        if let snapshot {
            lastMessageChanged = !ConversationSnapshotSyncPolicy.matchesLocalLastMessage(
                snapshot: snapshot,
                localLastMessageId: previousLastMessageId,
                localLastMessage: previousLastMessage,
                owner: self.owner,
                jid: jid
            )
        } else {
            lastMessageChanged = false
        }
        let localStateMissingOrStale: Bool
        if isNewChatInstance ||
            !lastChat.isSynced ||
            !lastChat.isInitialArchiveLoaded {
            // First-login snapshot pages normally create every conversation.
            // Their legacy flags already prove that readiness is missing, so
            // avoid one Realm message query per conversation in the bulk page.
            localStateMissingOrStale = true
        } else {
            let localMessageCount =
                ConversationArchiveDurableReadinessPolicy.localMessageCount(
                    owner: self.owner,
                    jid: jid,
                    conversationType: conversationType,
                    in: realm
                )
            localStateMissingOrStale =
                !ConversationArchiveDurableReadinessPolicy.isReady(
                    chat: lastChat,
                    archiveState: existingArchiveState,
                    conversationType: conversationType,
                    localMessageCount: localMessageCount
                )
        }

        guard unreadChanged || unreadBoundaryChanged || lastMessageChanged || localStateMissingOrStale else {
            return
        }

        let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
            owner: self.owner,
            jid: jid,
            conversationType: conversationType,
            in: realm
        )
        if let snapshot {
            archiveState.lastSnapshotArchiveId = snapshot.archiveId
            archiveState.lastSnapshotMessageId = snapshot.messageId
            archiveState.lastSnapshotSenderId = snapshot.senderId
            archiveState.lastSnapshotBodyFingerprint = snapshot.bodyFingerprint
            archiveState.lastSnapshotDate = snapshot.date
        }
        archiveState.updatedAt = Date()
        lastChat.isSynced = false
        archiveState.newerLiveEdgeReached = false
        recordRepairTarget(.init(jid: jid, conversationType: conversationType))
    }

    private static func syncMetadata(from conversation: DDXMLElement) -> DDXMLElement? {
        conversation
            .elements(forName: "metadata")
            .first(where: { $0.attributeStringValue(forName: "node") == ClientSynchronizationManager.primaryNamespace })
    }

    private static func syncLastMessage(
        from conversation: DDXMLElement
    ) -> XMPPMessage? {
        guard let message = syncMetadata(from: conversation)?
            .element(forName: "last-message")?
            .element(forName: "message")?
            .copy() as? DDXMLElement else {
            return nil
        }
        return XMPPMessage(from: message)
    }

    private static func classifyCanonicalGroupMessage(
        _ message: XMPPMessage
    ) -> Account.CanonicalGroupMessageRouting {
        do {
            guard let event = try GroupStanzaRouter.route(message) else {
                return .notGroup
            }
            switch event {
            case .message:
                return .validatedMessage
            case .invite, .reducer, .iq:
                return .consumed
            }
        } catch {
            return .consumed
        }
    }

    private static func isCanonicalGroupInvite(_ message: XMPPMessage) -> Bool {
        do {
            guard let event = try GroupStanzaRouter.route(message) else {
                return false
            }
            if case .invite = event {
                return true
            }
            return false
        } catch {
            return message.elements(forName: "invite").contains {
                $0.xmlns() == GroupProtocolNamespace.groups
            }
        }
    }

    private static func normalizedArchiveId(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }

    private func unreadState(from conversation: DDXMLElement) -> SyncUnreadState? {
        guard let metadata = Self.syncMetadata(from: conversation),
              let unreadElement = metadata.element(forName: "unread") else {
            return nil
        }

        let lastMessageArchiveId = metadata
            .element(forName: "last-message")?
            .element(forName: "message")
            .flatMap { messageElement in
                let archiveId = getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
                return Self.normalizedArchiveId(archiveId)
            }

        return SyncUnreadState(
            count: max(unreadElement.attributeIntegerValue(forName: "count"), 0),
            afterId: Self.normalizedArchiveId(unreadElement.attributeStringValue(forName: "after")),
            lastMessageArchiveId: lastMessageArchiveId
        )
    }

    @discardableResult
    private func ensureNotificationSyncStorage(in realm: Realm) -> XMPPNotificationsManagerStorageItem {
        let primary = XMPPNotificationsManagerStorageItem.genPrimary(owner: self.owner)
        if let existing = realm.object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: primary) {
            return existing
        }

        let storage = XMPPNotificationsManagerStorageItem()
        storage.owner = self.owner
        storage.primary = primary
        realm.add(storage, update: .modified)
        return storage
    }

    private func reconcileNotificationReadState(
        from unreadState: SyncUnreadState,
        in realm: Realm
    ) {
        let storage = ensureNotificationSyncStorage(in: realm)
        storage.unread = unreadState.count
        storage.unreadAfterId = unreadState.afterId
        XMPPNotificationsManagerStorageItem.reconcileStoredNotificationReadState(
            owner: self.owner,
            storage: storage,
            in: realm
        )
    }

    private func applyNotificationConversationState(
        _ conversation: DDXMLElement,
        jid: String,
        realm: Realm
    ) {
        let storage = ensureNotificationSyncStorage(in: realm)
        if storage.node?.isNotEmpty != true {
            storage.node = jid
        }

        guard let unreadState = unreadState(from: conversation) else {
            return
        }
        
        reconcileNotificationReadState(from: unreadState, in: realm)
        storage.lastSyncAt = Date()
    }
    
    internal func updateStateForAccount() {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                if instance.clientSyncSupport != isAvailable && !realm.isInWriteTransaction {
                    try realm.write {
                        instance.clientSyncSupport = isAvailable
                    }
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func logSyncTrace(_ event: String, _ details: [(String, Any?)]) {
        let renderedDetails = details
            .map { key, value in "\(key)=\(value.map { String(describing: $0) } ?? "nil")" }
            .joined(separator: " ")
        DDLogDebug("CLIENT_SYNC_TRACE event=\(event) owner=\(owner) \(renderedDetails)")
    }

    static func isClientSyncPaginationIQ(_ stanza: XMPPElement) -> Bool {
        guard stanza.name == "iq",
              stanza.attributeStringValue(forName: "type") == "get",
              let query = stanza.element(forName: "query", xmlns: ClientSynchronizationManager.primaryNamespace) else {
            return false
        }
        return query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") != nil
    }

    private func syncQueryElement(in iq: XMPPIQ) -> DDXMLElement? {
        iq.element(forName: "query", xmlns: ClientSynchronizationManager.primaryNamespace)
            ?? iq.element(forName: "synchronization", xmlns: ClientSynchronizationManager.primaryNamespace)
    }
    
    open func sync(_ xmppStream: XMPPStream, customVer: String? = nil, after: String? = nil) -> Bool {
        return performSync(
            xmppStream,
            customVer: customVer,
            after: after,
            expectedGeneration: nil
        )
    }

    private func performSync(
        _ xmppStream: XMPPStream,
        customVer: String?,
        after: String?,
        expectedGeneration: UInt64?
    ) -> Bool {
        syncLifecycleLock.lock()
        if let expectedGeneration,
           !stateQueue.sync(execute: { syncSessionGeneration == expectedGeneration }) {
            syncLifecycleLock.unlock()
            return false
        }
        guard isAvailable,
              canStartSyncWithStalePhaseRecovery(after: after) else {
            syncLifecycleLock.unlock()
            return false
        }
        acountSynced = false
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: ClientSynchronizationManager.primaryNamespace)
        let requestedStamp = stampModeForSyncRequest(customVer: customVer, after: after)?.attributeValue
        if let requestedStamp {
            query.addAttribute(withName: "stamp", stringValue: requestedStamp)
        }
        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        set.addChild(DDXMLElement(name: "max", stringValue: "\(pageSize)"))
        if let after = after {
            set.addChild(DDXMLElement(name: "after", stringValue: after))
        }
        query.addChild(set)
        let iq = XMPPIQ(iqType: .get,
                        to: nil,
                        elementID: elementId,
                        child: query)
        let diagnostics = SyncRequestDiagnostics(
            id: elementId,
            stamp: requestedStamp,
            after: after,
            before: nil,
            max: pageSize
        )
        registerSyncQuery(elementId, request: diagnostics)
        syncLifecycleLock.unlock()
        let sendStartedAt = Date()
        logSyncTrace("requestSendStart", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", pageSize)
        ])
        xmppStream.send(iq)
        logSyncTrace("requestSendFinish", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", pageSize),
            ("durationMs", Int(Date().timeIntervalSince(sendStartedAt) * 1000))
        ])
        syncRequestObserver?(diagnostics)
        logSyncTrace("request", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", pageSize)
        ])
        return isAvailable
    }
    
    public final func muteChat(_ xmppStream: XMPPStream, jid: String, conversatuinType: ClientSynchronizationManager.ConversationType) -> Bool {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversatuinType
                )) {
                conversation.addAttribute(withName: "type", stringValue: instance.conversationType.rawValue)
                if instance.isPinned {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = 0
                        instance.isPinned = false
                    }
                    conversation.addAttribute(withName: "mute", stringValue: "0")
                } else {
                    let position = Date().timeIntervalSince1970.rounded()*1000
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = position
                        instance.isPinned = true
                    }
                    conversation.addAttribute(withName: "pinned", doubleValue: position)
                }
                query.addChild(conversation)
                if self.isAvailable {
                    xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
                    self.registerGenericQueryId(elementId)
                    return true
                } else {
                    return false
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    public final func pinChat(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )) {
                conversation.addAttribute(withName: "type", stringValue: instance.conversationType.rawValue)
                if instance.isPinned {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = 0
                        instance.isPinned = false
                    }
                    conversation.addAttribute(withName: "pinned", stringValue: "0")
                } else {
                    let position = Date().timeIntervalSince1970.rounded()*1000
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.pinnedPosition = position
                        instance.isPinned = true
                    }
                    conversation.addAttribute(withName: "pinned", doubleValue: position)
                }
                query.addChild(conversation)
                if self.isAvailable {
                    xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
                    self.registerGenericQueryId(elementId)
                    return true
                } else {
                    return false
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    public final func update(_ xmppStream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, status: ConversationStatus? = nil, pinned: Double? = nil, mute: Double? = nil) -> String? {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let conversation = DDXMLElement(name: "conversation")
        conversation.addAttribute(withName: "jid", stringValue: jid)
        do {
            let realm = try  WRealm.safe()
            
                conversation.addAttribute(withName: "type", stringValue: conversationType.rawValue)
                if let status = status {
                    conversation.addAttribute(withName: "status", stringValue: status.rawValue)
                } else {
                    if let instance = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: LastChatsStorageItem.genPrimary(
                            jid: jid,
                            owner: self.owner,
                            conversationType: conversationType
                        )) {
                        if let pinned = pinned {
                            conversation.addAttribute(withName: "pinned", doubleValue: pinned)
                        } else if instance.isPinned && mute == nil {
                            conversation.addAttribute(withName: "pinned", stringValue: "")
                        } else {
                            if let mute = mute {
                                conversation.addAttribute(withName: "mute", doubleValue: mute)
                            } else if instance.isMuted && pinned == nil {
                                conversation.addAttribute(withName: "mute", stringValue: "")
                            }
                        }
                    }
                }
            query.addChild(conversation)
            xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
            self.registerGenericQueryId(elementId)
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        
        return nil
    }
 
    open func checkNextPage(_ xmppStream: XMPPStream, in iq: XMPPIQ) -> Bool {
        false
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readPush(iq): return true
        case readSnapshot(iq): return true
        case readError(iq): return true
        case readResult(iq): return true
        default: return false
        }
    }
    
    internal func readPush(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .set,
              let query = iq.element(forName: "synchronization") ?? iq.element(forName: "query"),
              query.xmlns() == ClientSynchronizationManager.primaryNamespace,
              let stamp = query.attributeStringValue(forName: "stamp") else {
                return false
        }
        if ignorePush {
            return true
        }
        
        do {
            let accountCreateDate = try WRealm.safe()
                .object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?
                .createdAt
            let applyResult = try applySyncPayload(
                conversations: query.elements(forName: "conversation"),
                accountCreateDate: accountCreateDate
            )
            logSyncTrace("pushApply", [
                ("stamp", stamp),
                ("count", applyResult.applySummary.receivedCount),
                ("created", applyResult.applySummary.createdChatCount),
                ("updated", applyResult.applySummary.updatedChatCount),
                ("skipped", applyResult.applySummary.skippedConversationCount),
                ("failed", applyResult.applySummary.failedConversationCount)
            ])
            if isBootstrapCriticalSyncInProgress() {
                deferSnapshotRepairTargets(applyResult.snapshotRepairTargets)
                noteCatchUpNeededAfterSnapshot()
            } else {
                scheduleSnapshotRepairTargetsImmediately(applyResult.snapshotRepairTargets)
                markLastRecognizedEventStamp(stamp)
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func readConversationMetadata(_ conversation: DDXMLElement, realm: Realm) -> Bool {
        guard let jid = conversation.attributeStringValue(forName: "jid")
               else {
            return false
        }
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
        if conversationType == .notifications {
            applyNotificationConversationState(conversation, jid: jid, realm: realm)
            return false
        }
        do {
            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)) {
                if let pinnedRaw = conversation.attributeStringValue(forName: "pinned") {
                    let pinned = Double(pinnedRaw) ?? 0
                    if instance.pinnedPosition != pinned {
                        instance.pinnedPosition = pinned
                        instance.isPinned = pinned != 0
                    }
                }
                if let muteRaw = conversation.attributeStringValue(forName: "mute") {
                    let muteExpired = Double(muteRaw) ?? 0
                    if instance.muteExpired != muteExpired {
                        instance.muteExpired = muteExpired
                    }
                }
                if let statusRaw = conversation.attributeStringValue(forName: "status"),
                   let status = ConversationStatus(rawValue: statusRaw) {
                    switch status {
                    case .archived:
                        instance.isArchived = true
                    case .active:
                        instance.isArchived = false
                    case .deleted:
                        let messages = realm
                            .objects(MessageStorageItem.self)
                            .filter("opponent == %@ AND owner == %@", jid, owner)

                        let messagesReference = realm
                            .objects(MessageReferenceStorageItem.self)
                            .filter("jid == %@ AND owner == %@", jid, owner)
                        let messagesInlines = realm
                            .objects(MessageForwardsInlineStorageItem.self)
                            .filter("jid == %@ AND owner == %@", jid, owner)
                        
                        let conversationType = instance.conversationType
                        
                        instance.rosterItem?.associatedLastChat = nil
                        realm.delete(instance)
                        realm.delete(messages)
                        realm.delete(messagesReference)
                        realm.delete(messagesInlines)
                        
                        if conversationType == .saved {
                            try AccountManager.shared.find(for: owner)?.favorites.createLastChatsStorageItem(commitTransaction: false)
                        }
                        return false
                    }
                }
                
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    internal func claimInitialPresenceSend() -> Bool {
        stateQueue.sync {
            guard case .ready = initialPresenceSessionState else { return false }
            initialPresenceSessionState = .sent
            return true
        }
    }

    @discardableResult
    internal func claimInitialPresenceForDeferredBroadcastFlush() -> Bool {
        claimInitialPresenceSend()
    }

    internal func noteBroadcastPresenceWillSend() {
        _ = claimInitialPresenceSend()
    }

    internal func prepareInitialPresenceForAuthenticatedStream(didResume: Bool) {
        stateQueue.sync {
            if didResume {
                switch initialPresenceSessionState {
                case .awaitingAuthenticatedStream(let wasSent):
                    initialPresenceSessionState = wasSent ? .sent : .ready
                case .ready, .sent:
                    break
                }
            } else {
                initialPresenceSessionState = .ready
            }
        }
    }

    internal func suspendInitialPresenceUntilAuthenticatedStream() {
        stateQueue.sync {
            let wasSent: Bool
            switch initialPresenceSessionState {
            case .sent:
                wasSent = true
            case .awaitingAuthenticatedStream(let previousWasSent):
                wasSent = previousWasSent
            case .ready:
                wasSent = false
            }
            initialPresenceSessionState = .awaitingAuthenticatedStream(wasSent: wasSent)
        }
    }

    @discardableResult
    internal func sendInitialPresenceIfNeeded() -> Bool {
        initialPresenceSendAttemptObserver?()
        guard let account = AccountManager.shared.find(for: owner) else {
            return false
        }
        account.action { [weak self] (user, stream) in
            guard stream.isAuthenticated,
                  self?.claimInitialPresenceSend() == true else {
                return
            }
            user.msgDeleteManager.enable(stream)
            user.presence()
        }
        return true
    }

    internal func restoreAfterStreamManagementResume() {
        guard let account = AccountManager.shared.find(for: owner) else { return }
        account.action { [weak self] (user, stream) in
            guard stream.isAuthenticated else { return }
            user.msgDeleteManager.enable(stream)
            if self?.claimInitialPresenceSend() == true {
                user.presence()
            }
        }
    }

    internal func waitForPendingSnapshotApplies() {
        applyQueue.sync {}
    }
    
    internal func readSnapshot(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result else {
            return false
        }
        guard let elementId = iq.elementID,
              let query = syncQueryElement(in: iq) else {
            return false
        }
        let trackedRequest = consumeTrackedSyncRequest(elementId)
        let isTrackedSyncQuery = trackedRequest != nil
        logSyncTrace("responseReceivedBeforeParse", [
            ("id", elementId),
            ("isTracked", isTrackedSyncQuery),
            ("iqType", iq.type),
            ("queryNamespace", query.xmlns()),
            ("queryStamp", query.attributeStringValue(forName: "stamp")),
            ("childCount", query.children?.count)
        ])
        guard let trackedRequest,
              isCurrentSyncSessionGeneration(trackedRequest.generation) else {
            logSyncTrace("staleSnapshotResponseIgnored", [
                ("id", elementId),
                ("isTracked", isTrackedSyncQuery)
            ])
            return true
        }
        let expectedGeneration = trackedRequest.generation
        let request: SyncRequestDiagnostics? = trackedRequest.diagnostics
        guard let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: self.pageSize,
            namespace: ClientSynchronizationManager.primaryNamespace,
            updateOmemo: updateOmemoMessages(_:)
        ) else {
            guard isCurrentSyncSessionGeneration(expectedGeneration) else {
                logSyncTrace("staleSnapshotParseFailureIgnored", [("id", elementId)])
                return true
            }
            let requestedStampMode = request.map { SnapshotRequestStampMode.fromAttribute($0.stamp) }
                ?? stateQueue.sync { activeSnapshotRequestedStampMode }
                ?? .absent
            markSnapshotBootstrapInProgress(requestedStampMode: requestedStampMode, after: request?.after)
            stateQueue.sync {
                guard syncSessionGeneration == expectedGeneration else { return }
                if phase == .idle || phase == .live {
                    phase = .snapshotInProgress
                }
                isApplyingPage = false
            }
            logSyncTrace("snapshotParseFailed", [
                ("id", iq.elementID),
                ("requestedStamp", request?.stamp),
                ("requestedAfter", request?.after),
                ("queryNamespace", query.xmlns()),
                ("queryStamp", query.attributeStringValue(forName: "stamp")),
                ("childNames", query.children?.compactMap { ($0 as? DDXMLElement)?.name }.joined(separator: ",")),
                ("persistedSnapshotStamp", "withheld")
            ])
            return true
        }
        guard beginApplyingPage(
            snapshotStamp: page.stamp,
            request: request,
            expectedGeneration: expectedGeneration
        ), let duplicateConversationCount = noteReceivedConversationKeys(
            conversationKeys(from: page.conversations),
            expectedGeneration: expectedGeneration
        ) else {
            logSyncTrace("staleSnapshotPageIgnoredBeforeApply", [
                ("id", elementId),
                ("snapshotStamp", page.stamp)
            ])
            return true
        }
        logSyncTrace("pageReceived", [
            ("id", elementId),
            ("requestedStamp", request?.stamp),
            ("requestedAfter", request?.after),
            ("requestedBefore", request?.before),
            ("requestedMax", request?.max),
            ("snapshotStamp", page.stamp),
            ("received", page.conversations.count),
            ("rsmFirst", page.rsm.first),
            ("rsmFirstIndex", page.rsm.firstIndex),
            ("rsmLast", page.rsm.last),
            ("rsmCount", page.rsm.count),
            ("duplicateConversations", duplicateConversationCount),
            ("isFinalByParser", page.isFinalPage)
        ])

        applyQueue.async {
            guard self.isCurrentSyncSessionGeneration(expectedGeneration) else {
                self.logSyncTrace("staleSnapshotPageIgnoredBeforeApply", [
                    ("id", elementId),
                    ("snapshotStamp", page.stamp)
                ])
                return
            }
            let applyStartedAt = Date()
            self.logSyncTrace("pageApplyStart", [
                ("snapshotStamp", page.stamp),
                ("count", page.conversations.count),
                ("after", request?.after)
            ])
            do {
                let accountCreateDate = try WRealm.safe().object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.createdAt
                let applyResult = try self.applySyncPayload(
                    conversations: page.conversations,
                    accountCreateDate: accountCreateDate,
                    expectedGeneration: expectedGeneration
                )
                guard self.recordAppliedSnapshotPage(
                    applyResult,
                    expectedGeneration: expectedGeneration
                ) else {
                    self.logSyncTrace("staleSnapshotPageIgnoredAfterApply", [
                        ("id", elementId),
                        ("snapshotStamp", page.stamp)
                    ])
                    return
                }
                let applyFinishedAt = Date()

                self.logSyncTrace("pageApplyFinish", [
                    ("snapshotStamp", page.stamp),
                    ("received", applyResult.applySummary.receivedCount),
                    ("duplicates", duplicateConversationCount),
                    ("created", applyResult.applySummary.createdChatCount),
                    ("updated", applyResult.applySummary.updatedChatCount),
                    ("skipped", applyResult.applySummary.skippedConversationCount),
                    ("failed", applyResult.applySummary.failedConversationCount),
                    ("isFinalByParser", page.isFinalPage),
                    ("durationMs", Int(applyFinishedAt.timeIntervalSince(applyStartedAt) * 1000))
                ])

                if page.isFinalPage {
                    let completionStartedAt = Date()
                    guard let actions = self.finishApplyingPage(
                        snapshotStamp: page.stamp,
                        isFinalPage: true,
                        expectedGeneration: expectedGeneration
                    ) else {
                        self.logSyncTrace("staleSnapshotCompletionIgnored", [
                            ("id", elementId),
                            ("snapshotStamp", page.stamp)
                        ])
                        return
                    }
                    let didPersistCompletion = self.stateQueue.sync {
                        guard self.syncSessionGeneration == expectedGeneration else {
                            return false
                        }
                        self.clearSnapshotBootstrapInProgress()
                        self.lastCompletedSnapshotStamp = page.stamp
                        self.markLastRecognizedEventStamp(page.stamp)
                        self.firstSync = false
                        self.acountSynced = true
                        self.temporaryVer = nil
                        return true
                    }
                    guard didPersistCompletion,
                          self.isCurrentSyncSessionGeneration(expectedGeneration) else {
                        self.logSyncTrace("staleSnapshotCompletionIgnored", [
                            ("id", elementId),
                            ("snapshotStamp", page.stamp)
                        ])
                        return
                    }
                    AccountManager.shared.find(for: self.owner)?
                        .archiveXEPSYNCSnapshotDidComplete(
                            fingerprint: page.stamp
                        )
                    AccountManager.shared.changeNewUserState(for: self.owner, to: .dataLoaded)
                    self.logSyncTrace("snapshotComplete", [
                        ("snapshotStamp", page.stamp),
                        ("persistedCompletedStamp", page.stamp),
                        ("persistedRecognizedStamp", page.stamp),
                        ("deferredRepairs", actions.snapshotRepairTargets.count),
                        ("needsCatchUpSync", actions.needsCatchUpSync),
                        ("completionTailMs", Int(Date().timeIntervalSince(completionStartedAt) * 1000))
                    ])
                    if actions.needsCatchUpSync {
                        AccountManager.shared.find(for: self.owner)?.unsafeAction { _, stream in
                            _ = self.performSync(
                                stream,
                                customVer: nil,
                                after: nil,
                                expectedGeneration: expectedGeneration
                            )
                        }
                    }
                    guard self.isCurrentSyncSessionGeneration(expectedGeneration) else { return }
                    self.flushSnapshotCompletionActions(actions)
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                        guard self.isCurrentSyncSessionGeneration(expectedGeneration) else { return }
                        user.csi.active(stream, by: .synchronization)
                    })
                    guard self.isCurrentSyncSessionGeneration(expectedGeneration) else { return }
                    return
                }

                guard let nextPageToken = page.nextPageToken,
                      self.shouldRequestNextSnapshotPage(
                        after: nextPageToken,
                        currentAfter: request?.after,
                        expectedGeneration: expectedGeneration
                      ) else {
                    guard self.finishApplyingPage(
                        snapshotStamp: page.stamp,
                        isFinalPage: false,
                        expectedGeneration: expectedGeneration
                    ) != nil else {
                        self.logSyncTrace("staleSnapshotPaginationFailureIgnored", [
                            ("id", elementId),
                            ("snapshotStamp", page.stamp)
                        ])
                        return
                    }
                    self.logSyncTrace("paginationStalled", [
                        ("snapshotStamp", page.stamp),
                        ("requestedAfter", request?.after),
                        ("nextPageToken", page.nextPageToken),
                        ("persistedSnapshotStamp", "withheld")
                    ])
                    self.beforeResettingSnapshotFailure?()
                    _ = self.resetSyncStateAfterFailure(expectedGeneration: expectedGeneration)
                    return
                }

                guard self.finishApplyingPage(
                    snapshotStamp: page.stamp,
                    isFinalPage: false,
                    expectedGeneration: expectedGeneration
                ) != nil else {
                    self.logSyncTrace("staleSnapshotContinuationIgnored", [
                        ("id", elementId),
                        ("snapshotStamp", page.stamp)
                    ])
                    return
                }
                self.logSyncTrace("pageContinuation", [
                    ("snapshotStamp", page.stamp),
                    ("after", nextPageToken),
                    ("persistedSnapshotStamp", "withheld"),
                    ("schedulingGapMs", Int(Date().timeIntervalSince(applyFinishedAt) * 1000))
                ])
                self.beforeDispatchingSnapshotContinuation?()
                AccountManager.shared.find(for: self.owner)?.unsafeAction { _, stream in
                    _ = self.performSync(
                        stream,
                        customVer: nil,
                        after: nextPageToken,
                        expectedGeneration: expectedGeneration
                    )
                }
                self.logSyncTrace("pageContinuationDispatched", [
                    ("snapshotStamp", page.stamp),
                    ("after", nextPageToken),
                    ("dispatchGapMs", Int(Date().timeIntervalSince(applyFinishedAt) * 1000))
                ])
            } catch SyncSessionApplyError.invalidated {
                self.logSyncTrace("staleSnapshotPageIgnoredDuringApply", [
                    ("id", elementId),
                    ("snapshotStamp", page.stamp)
                ])
            } catch {
                guard self.finishApplyingPage(
                    snapshotStamp: page.stamp,
                    isFinalPage: page.isFinalPage,
                    expectedGeneration: expectedGeneration
                ) != nil else {
                    self.logSyncTrace("staleSnapshotFailureIgnored", [
                        ("id", elementId),
                        ("snapshotStamp", page.stamp)
                    ])
                    return
                }
                self.beforeResettingSnapshotFailure?()
                _ = self.resetSyncStateAfterFailure(expectedGeneration: expectedGeneration)
                self.logSyncTrace("pageApplyFailed", [
                    ("snapshotStamp", page.stamp),
                    ("error", error.localizedDescription),
                    ("persistedSnapshotStamp", "withheld")
                ])
                DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
            }
        }
        return true
    }
    
    internal func updateOmemoMessages(_ query: DDXMLElement) -> DDXMLElement {
        
        if let modifiedQuery = AccountManager.shared.find(for: self.owner)?.omemo.modifySyncQuery(query) {
            return modifiedQuery
        }
        return query
        
    }
    
    internal func readPresence(_ conversation: DDXMLElement, realm: Realm) {
        func checkPresenceSubscribe(_ conversation: DDXMLElement) -> Bool {
            if let presenceRaw = conversation.element(forName: "presence"),
               let presence = try? XMPPPresence(xmlString: presenceRaw.xmlString),
               presence.presenceType == .subscribe {
                return true
            } else {
                return false
            }
        }
        
        guard let jid = conversation.attributeStringValue(forName: "jid") else { return }

        if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
            instance.ask = checkPresenceSubscribe(conversation) ? .in : .none
        } else {
            let instance = RosterStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
            instance.subscribtion = .undefined
            instance.ask = checkPresenceSubscribe(conversation) ? .in : .none
            realm.add(instance)
        }
    }
    
    internal func readMessageMarkers(_ conversation: DDXMLElement, realm: Realm) {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              let metadata = conversation
                            .elements(forName: "metadata")
                            .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" }) else { return }
        
        let stamp = conversation.attributeDoubleValue(forName: "stamp")
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
        guard conversationType != .notifications else {
            return
        }
        if let delivered = metadata.element(forName: "delivered")?.attributeStringValue(forName: "id"),
           let deliveredMessageTimeInterval = TimeInterval(delivered) {
            let deliveredMessageDate = Date(timeIntervalSince1970: deliveredMessageTimeInterval / 1000000)
            realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND outgoing == true AND state_ == %@ AND date <= %@ AND conversationType_ == %@",
                        owner,
                        jid,
                        MessageStorageItem.MessageSendingState.sended.rawValue,
                        deliveredMessageDate,
                        conversationType.rawValue)
                .forEach { $0.state = .deliver}
        }
        
        if let displayed = metadata.element(forName: "displayed")?.attributeStringValue(forName: "id"),
           let displayedMessageTimeInterval = TimeInterval(displayed) {
            let displayedMessageDate = Date(timeIntervalSince1970: displayedMessageTimeInterval / 1000000)
            let readDate = Date(timeIntervalSince1970: stamp / 1000000)
            realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND state_ == %@ AND date <= %@ AND conversationType_ == %@",
                        owner,
                        jid,
                        MessageStorageItem.MessageSendingState.deliver.rawValue,
                        displayedMessageDate,
                        conversationType.rawValue)
                .forEach {
                    $0.state = .read
                    $0.isRead = true
                    if $0.afterburnInterval > 0 && $0.burnDate <= 1 && $0.autoDeleteExpiresAt <= 0 {
                        $0.readDate = readDate.timeIntervalSince1970
                        $0.burnDate = readDate.timeIntervalSince1970 + $0.afterburnInterval
                        if (readDate.timeIntervalSince1970 + $0.afterburnInterval) < Date().timeIntervalSince1970 {
                            $0.markAutoDeleted()
                        }
                    }
                }
        }
    }
    
    @discardableResult
    internal func readInvites(_ conversation: DDXMLElement, realm _: Realm) -> Bool {
        guard let inviteMessage = Self.syncLastMessage(from: conversation),
              Self.isCanonicalGroupInvite(inviteMessage) else {
            return false
        }
        conversation.removeAttribute(forName: "jid")
        return true
    }
    
    internal func readConversation(
        _ conversation: DDXMLElement,
        realm: Realm,
        accountCreateDate: Date? = nil,
        activeGroupPrimaries: Set<String>? = nil,
        recordSnapshotRepairTarget: ((MessageArchiveManager.SnapshotRepairTarget) -> Void)? = nil
    ) -> MessageManager.MessageQueueItem? {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              jid.isNotEmpty else {
            return nil
        }
        
        let conversationStatus = conversation.attributeStringValue(forName: "status") ?? "active"
        
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
        
        if conversationType == .notifications {
            return nil
        }
        
        if conversationType != .saved,
           XMPPJID(string: jid)?.isServer ?? false {
            return nil
        }
        
        if jid == AccountManager.shared.find(for: self.owner)?.notifications.node {
            return nil
        }

        let activeGroupPrimaries = activeGroupPrimaries ??
            CanonicalGroupRegularShadowPolicy.activeGroupPrimaries(
                in: realm,
                owners: [self.owner]
            )
        if CanonicalGroupRegularShadowPolicy.shouldSuppress(
            owner: self.owner,
            jid: jid,
            conversationType: conversationType,
            activeGroupPrimaries: activeGroupPrimaries
        ) {
            // XEP-SYNC may expose the sender-side account archive copy of a
            // group message as `urn:xabber:chat`. Canonical group projection,
            // membership, and archive routing remain authoritative.
            return nil
        }

        let stamp = conversation.attributeDoubleValue(forName: "stamp")
        if conversation.element(forName: "deleted") != nil || conversationStatus == "deleted" {
            do {
                if let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: self.owner,
                        conversationType: conversationType)) {
                    realm.delete(instance)
                    if instance.conversationType == .saved {
                        try AccountManager.shared.find(for: self.owner)?.favorites.createLastChatsStorageItem(commitTransaction: false)
                    }
                }
            } catch {
                DDLogDebug("ClientSynchronizationManager; \(#function). \(error.localizedDescription)")
            }
            return nil
        }
        
        guard let metadata = conversation
            .elements(forName: "metadata")
            .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" }) else {
            return nil
        }
        func getChat(_ realm: Realm, jid: String, conversationType: ConversationType) throws -> LastChatsStorageItem {
            if let instance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            ) {
                return instance
            }
            let instance = LastChatsStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.conversationType = conversationType
//            var needGenAvatar: Bool = false
            if let rosterItem = realm
                .object(ofType: RosterStorageItem.self,
                        forPrimaryKey: [jid, owner].prp()) {
                instance.rosterItem = rosterItem
                rosterItem.associatedLastChat = instance
                
                rosterItem.isContact = [ConversationType.regular, ConversationType.omemo, ConversationType.omemo1, ConversationType.axolotl].contains(conversationType)
            } else {
                let rosterItem = RosterStorageItem()
                rosterItem.owner = owner
                rosterItem.jid = jid
                rosterItem.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                rosterItem.groups.append(RosterUtils.ungroupped)
                rosterItem.associatedLastChat = instance
                rosterItem.isContact = [ConversationType.regular, ConversationType.omemo, ConversationType.omemo1, ConversationType.axolotl].contains(conversationType)
                realm.add(rosterItem)
                instance.rosterItem = rosterItem
            }
            instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
            instance.setPrimary(withOwner: owner)
            realm.add(instance, update: .modified)
            
            return instance
        }
        do {
            if metadata.element(forName: "last-message")?.element(forName: "message") == nil {
                if conversation.element(forName: "presence")?.attributeStringValue(forName: "type") == "subscribe" {
                    if conversationType != ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                        return nil
                    }
                }
//                if let instance = realm.object(
//                    ofType: LastChatsStorageItem.self,
//                    forPrimaryKey: LastChatsStorageItem.genPrimary(
//                        jid: jid,
//                        owner: self.owner,
//                        conversationType: conversationType)) {
//                    realm.delete(instance)
//                }
//                return nil
            }

            
            
            
            
            if let messageElement = metadata.element(forName: "last-message")?.element(forName: "message"),
               Self.isCanonicalGroupInvite(XMPPMessage(from: messageElement)) {
                return nil
            }
            
            let isNewChatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType)
            ) == nil
            
            let instance = try getChat(realm, jid: jid, conversationType: conversationType)
            let previousSyncUnreadCount = instance.syncUnreadCount
            let previousSyncUnreadAfterId = instance.syncUnreadAfterId
            let previousLastMessageId = instance.lastMessageId
            let previousLastMessage = instance.lastMessage
            instance.conversationType_ = conversationType.rawValue
            let mute = conversation.attributeDoubleValue(forName: "mute", withDefaultValue: -1)
            instance.muteExpired = mute
            
            let pinnedPosition = conversation.attributeDoubleValue(forName: "pinned", withDefaultValue: 0)
            instance.pinnedPosition = pinnedPosition
            instance.isPinned = pinnedPosition != 0
            
            if let retractVersion = conversation
                .elements(forName: "metadata")
                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/rewrite" })?
                .element(forName: "retract")?
                .attributeStringValue(forName: "version"),
                retractVersion != "0" {
                if conversationType == .group && !isNewChatInstance {
                    if AccountManager.shared.activeUsers.value.count == 1 {
                        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                            session.retract?.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                        }, fail: {
                            AccountManager.shared.find(for: self.owner)?.delayedAction(delay: 0.5, toExecute: { (user, stream) in
                                user.msgDeleteManager.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                            })
                        })
                    } else {
                        AccountManager.shared.find(for: owner)?.delayedAction(delay: 0.5, toExecute: { (user, stream) in
                            user.msgDeleteManager.enableForGroupchat(stream, jid: jid, maxItems: 50, currentVersion: retractVersion)
                        })
                    }
                }
            }
            instance.displayedId = metadata.element(forName: "displayed")?.attributeStringValue(forName: "id")
            instance.deliveredId = metadata.element(forName: "delivered")?.attributeStringValue(forName: "id")
            let syncUnreadState = unreadState(from: conversation) ?? SyncUnreadState(
                count: 0,
                afterId: nil,
                lastMessageArchiveId: nil
            )
            LastChatUnreadCounter.applySynchronizationSnapshot(
                to: instance,
                count: syncUnreadState.count,
                afterId: syncUnreadState.afterId,
                snapshotLastArchiveId: syncUnreadState.lastMessageArchiveId,
                in: realm
            )
            instance.isPrereaded = false

            if conversationType == .group {
                MentionNotificationSync.refreshLastChatMentionIds(
                    owner: self.owner,
                    groupchatJids: [jid],
                    in: realm
                )
            }

            if conversationStatus == "archived" {
                instance.isArchived = true
            } else if conversationStatus == "active" {
                instance.isArchived = false
            }
            
            let messageElement = metadata.element(forName: "last-message")?.element(forName: "message")
            let messageSyncStamp = ClientSynchronizationManager.syncStamp(from: messageElement, fallback: stamp)
            let conversationDate = ClientSynchronizationManager.archivedMessageDate(from: messageElement, fallbackSyncStamp: stamp)
            instance.messageDate = conversationDate
            let unreadAfterTS = metadata.element(forName: "unread")?.attributeDoubleValue(forName: "after")

            if let interval = unreadAfterTS {
                NotifyManager.shared.clearNotifications(for: interval as TimeInterval,
                                                        owner: owner,
                                                        jid: jid)
            }

            if isNewChatInstance {
                if conversationType == .group {
                    let resource = ResourceStorageItem()
                    resource.owner = owner
                    resource.jid = jid
                    resource.resource = owner
                    resource.status = .offline
                    resource.entity = .groupchat
                    resource.type = .groupchat
                    resource.priority = -5
                    resource.isTemporary = true
                    resource.primary = ResourceStorageItem.genPrimary(jid: jid, owner: owner, resource: owner)
                    realm.add(resource, update: .modified)

                } else {
                    if jid == XMPPJID(string: owner)?.domain {
                        let resourceInstance = ResourceStorageItem()
                        resourceInstance.jid = jid
                        resourceInstance.owner = owner
                        resourceInstance.resource = "server"
                        resourceInstance.status = .online
                        resourceInstance.statusMessage = ""
                        resourceInstance.priority = -5
                        resourceInstance.entity = .server
                        resourceInstance.client = ""
                        resourceInstance.isTemporary = false
                        resourceInstance.timestamp = Date()
                        resourceInstance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: owner, resource: "server")
                        realm.add(resourceInstance, update: .modified)
                    }
                }
            }
            let userCard = conversation
                .elements(forName: "metadata")
                .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/groups" })?
                .element(forName: "user", xmlns: "https://xabber.com/protocol/groups")
            
            if conversationType.isEncrypted,
               metadata.element(forName: "last-message")?.element(forName: "message") == nil {
                instance.isFreshNotEmptyEncryptedChat = true
                instance.isSynced = false//!firstSync
            }
            if messageElement == nil {
                applyConversationSnapshotArchiveState(
                    jid: jid,
                    conversationType: conversationType,
                    snapshot: nil,
                    lastChat: instance,
                    previousSyncUnreadCount: previousSyncUnreadCount,
                    previousSyncUnreadAfterId: previousSyncUnreadAfterId,
                    previousLastMessageId: previousLastMessageId,
                    previousLastMessage: previousLastMessage,
                    isNewChatInstance: isNewChatInstance,
                    realm: realm,
                    recordRepairTarget: recordSnapshotRepairTarget ?? { _ in }
                )
            }
            if let messageElement {
                if let date = getDeliveryDate(XMPPMessage(from: messageElement)) {
                    if conversationType.isEncrypted, let accountCreateDate = accountCreateDate {
                        if date.timeIntervalSince1970 < accountCreateDate.timeIntervalSince1970 {
                            instance.isFreshNotEmptyEncryptedChat = true
                            instance.isSynced = false//!firstSync
                            instance.lastMessageId = getOriginId(XMPPMessage(from: messageElement)) ?? XMPPMessage(from: messageElement).elementID ?? getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
                            let messageStanza = XMPPMessage(from: messageElement)
                            applyConversationSnapshotArchiveState(
                                jid: jid,
                                conversationType: conversationType,
                                snapshot: conversationSnapshotIdentity(
                                    from: messageStanza,
                                    fallbackDate: conversationDate
                                ),
                                lastChat: instance,
                                previousSyncUnreadCount: previousSyncUnreadCount,
                                previousSyncUnreadAfterId: previousSyncUnreadAfterId,
                                previousLastMessageId: previousLastMessageId,
                                previousLastMessage: previousLastMessage,
                                isNewChatInstance: isNewChatInstance,
                                realm: realm,
                                recordRepairTarget: recordSnapshotRepairTarget ?? { _ in }
                            )
                            return nil
                        }
                    }
//                    if !self.firstSync {
//                        return nil
//                    }
                }
                
                if VoIPManager.shared.onReceiveMessage(messageElement, owner: self.owner, archivedDate: conversationDate, commitTransaction: false, realm: realm) {
                    return nil
                }
                let messageStanza = XMPPMessage(from: messageElement)
                if Self.classifyCanonicalGroupMessage(messageStanza) == .consumed {
                    return nil
                }
                let stanzaId = getStanzaId(messageStanza, owner: self.owner)
                var state: MessageStorageItem.MessageSendingState = .sended
                if unreadAfterTS == messageSyncStamp {
                    state = .read
                } else if instance.deliveredId == stanzaId {
                    state = .deliver
                }
                let readDate = state != .read ? nil : Date(timeIntervalSince1970: stamp / 1000000)
                guard let from = messageStanza.from?.bare,
                      let to = messageStanza.to?.bare,
                      [self.owner, jid].contains(from),
                      [self.owner, jid].contains(to) else {
                    return nil
                }
                if conversationType.supportsSnapshotArchiveRepair {
                    let snapshot = self.conversationSnapshotIdentity(
                        from: messageStanza,
                        fallbackDate: conversationDate
                    )
                    self.applyConversationSnapshotArchiveState(
                        jid: jid,
                        conversationType: conversationType,
                        snapshot: snapshot,
                        lastChat: instance,
                        previousSyncUnreadCount: previousSyncUnreadCount,
                        previousSyncUnreadAfterId: previousSyncUnreadAfterId,
                        previousLastMessageId: previousLastMessageId,
                        previousLastMessage: previousLastMessage,
                        isNewChatInstance: isNewChatInstance,
                        realm: realm,
                        recordRepairTarget: recordSnapshotRepairTarget ?? { _ in }
                    )
                } else if instance.lastMessageId != getUniqueMessageId(messageStanza, owner: self.owner) {
                    instance.isSynced = false//!firstSync
                }
                if conversationType == .saved {
                    let favorites = AccountManager.shared.find(for: owner)?.favorites ?? XMPPFavoritesManager(withOwner: owner)
                    try favorites.receiveSaved(
                        message: messageStanza,
                        realm: realm,
                        commitTransaction: false,
                        favoritesNodeOverride: jid
                    )
                    return nil
                }
                return AccountManager
                    .shared
                    .find(for: owner)?
                    .messages
                    .receiveClientSyncRaw(messageStanza,
                                          groupchatUserCard: userCard,
                                          isRead: state == .read,
                                          state: state,
                                          date: conversationDate,
                                          readDate: readDate)
            } else {
                if let retractVersion = conversation
                    .elements(forName: "metadata")
                    .first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/rewrite" })?
                    .element(forName: "retract")?
                    .attributeStringValue(forName: "version"),
                    retractVersion != "0" {
//                    if instance.retractVersion != retractVersion {
//                        instance.lastMessage = nil
//                    }
                }
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return nil
    }

    internal func readError(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.iqType == .error else {
            return false
        }
        if let trackedRequest = consumeTrackedSyncRequest(elementId) {
            logSyncTrace("syncResultUnexpectedGenericPath", [
                ("id", elementId),
                ("persistedSnapshotStamp", "withheld")
            ])
            stateQueue.sync {
                guard syncSessionGeneration == trackedRequest.generation else { return }
                if phase == .idle || phase == .live {
                    phase = .snapshotInProgress
                }
            }
            return true
        }
        return consumeGenericQueryId(elementId)
    }
    
    internal func readResult(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.iqType == .result else {
            return false
        }
        if let trackedRequest = consumeTrackedSyncRequest(elementId) {
            logSyncTrace("syncError", [
                ("id", elementId),
                ("isTrackedSyncQuery", true),
                ("persistedSnapshotStamp", "withheld")
            ])
            beforeResettingSyncResult?()
            if resetSyncSession(expectedGeneration: trackedRequest.generation) {
                temporaryVer = nil
            }
            return true
        }
        return consumeGenericQueryId(elementId)
    }
    
    public final func isSynced() -> Bool {
        if isAvailable {
            return acountSynced
        }
        return true
    }
    
    @discardableResult
    private func resetSyncSession(expectedGeneration: UInt64? = nil) -> Bool {
        syncLifecycleLock.lock()
        let didReset = stateQueue.sync {
            if let expectedGeneration,
               self.syncSessionGeneration != expectedGeneration {
                return false
            }
            self.syncSessionGeneration &+= 1
            self.phase = .idle
            self.activeSnapshotStamp = nil
            self.activeSnapshotRequestedStampMode = nil
            self.requestedSnapshotAfterTokens.removeAll()
            self.seenSnapshotConversationKeys.removeAll()
            self.isApplyingPage = false
            self.pendingSnapshotRepairTargets.removeAll()
            self.pendingPostBootstrapWork.removeAll()
            self.needsCatchUpAfterSnapshot = false
            self.syncRequestInfoById.removeAll()
            return true
        }
        if didReset {
            self.queryIds.removeAll()
        }
        syncLifecycleLock.unlock()
        return didReset
    }

    public final func reset() {
        _ = resetSyncSession()
    }

    final func prepareForAuthenticatedStream(didResume: Bool) {
        if !didResume {
            reset()
        }
        prepareInitialPresenceForAuthenticatedStream(didResume: didResume)
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapInProgressKey, value: false)
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapLastAfterKey, value: "")
    }
}
