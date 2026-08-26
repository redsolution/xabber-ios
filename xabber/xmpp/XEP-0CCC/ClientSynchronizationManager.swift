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

/// Immutable transport between the XMPP parser and the serial Realm applier.
///
/// `DDXMLElement` is mutable and thread-confined in practice. Serializing the
/// already-normalized conversation keeps XML objects off the cross-queue
/// boundary while preserving extension payloads needed by list projection.
struct ClientSyncConversationValue: Sendable {
    let xmlString: String
    let jid: String?
    let rawConversationType: String?

    init(_ element: DDXMLElement) {
        xmlString = element.xmlString
        jid = element.attributeStringValue(forName: "jid")
        rawConversationType = element.attributeStringValue(forName: "type")
    }

    func materializedElement() -> DDXMLElement? {
        guard let document = try? DDXMLDocument(
            xmlString: xmlString,
            options: 0
        ) else {
            return nil
        }
        return document.rootElement()
    }
}

/// Durable, schema-neutral guard against an in-flight archive page restoring
/// a regular conversation after XEP-SYNC authoritatively deleted it.
enum ClientSyncRegularConversationDeletionStore {
    private static let lock = NSLock()

    static func contains(owner: String, jid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identities(for: owner).contains(identity(owner: owner, jid: jid))
    }

    static func markDeleted(owner: String, jid: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = identities(for: owner)
        guard values.insert(identity(owner: owner, jid: jid)).inserted else {
            return
        }
        persist(values, for: owner)
    }

    static func clear(owner: String, jid: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = identities(for: owner)
        guard values.remove(identity(owner: owner, jid: jid)) != nil else {
            return
        }
        persist(values, for: owner)
    }

    private static func identity(owner: String, jid: String) -> String {
        LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
    }

    private static func identities(for owner: String) -> Set<String> {
        guard let raw = SettingManager.shared.getKey(
            for: owner,
            scope: .clientSynchronization,
            key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey
        ),
        let data = raw.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    private static func persist(_ identities: Set<String>, for owner: String) {
        guard !identities.isEmpty else {
            SettingManager.shared.removeItem(
                for: owner,
                scope: .clientSynchronization,
                key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey
            )
            return
        }
        guard let data = try? JSONEncoder().encode(identities.sorted()),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        SettingManager.shared.saveItem(
            for: owner,
            scope: .clientSynchronization,
            key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey,
            value: raw
        )
    }
}

enum CanonicalGroupSynchronizationSignal: Equatable {
    case active(groupJID: String)
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
        let conversations: [ClientSyncConversationValue]
        let rsm: RSMPage
    }

    static func parseSnapshotPage(from iq: XMPPIQ, pageSize: Int, namespace: String, updateOmemo: (DDXMLElement) -> DDXMLElement) -> SnapshotPage? {
        guard let query = iq.element(forName: "query", xmlns: namespace),
              let stamp = query.attributeStringValue(forName: "stamp") else {
            return nil
        }
        let normalizedQuery = updateOmemo(query)
        let conversations = normalizedQuery
            .elements(forName: "conversation")
            .compactMap { $0.copy() as? DDXMLElement }
            .map(ClientSyncConversationValue.init)
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
            // Some servers omit RSM count while still returning the last
            // cursor on the terminal page. In that shape only a short page
            // proves exhaustion, and it must be compared with the maximum of
            // the matching request (the first viewport page is intentionally
            // smaller than its continuations).
            isFinalPage = conversations.count < max(pageSize, 1)
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
        let appliedConversationPrimaries: Set<String>
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
        activeCanonicalGroupPrimaries: Set<String> = [],
        applyConversationState: (DDXMLElement, Realm) -> Bool,
        commitTransaction: (Realm) throws -> Void = { realm in
            try realm.commitWrite()
        }
    ) throws -> ApplyResult {
        var createdChatCount = 0
        var updatedChatCount = 0
        var skippedConversationCount = 0
        var appliedConversationPrimaries = Set<String>()

        realm.beginWrite()
        do {
            conversations.forEach { sourceConversation in
                let conversation =
                    (sourceConversation.copy() as? DDXMLElement) ??
                    sourceConversation
                let identity = Self.identity(
                    from: conversation,
                    owner: owner
                )
                if let identity,
                   CanonicalGroupRegularShadowPolicy.shouldSuppress(
                        owner: owner,
                        jid: identity.jid,
                        conversationType: identity.conversationType,
                        activeGroupPrimaries: activeCanonicalGroupPrimaries
                   ) {
                    // Ignore the entire generic projection. In particular,
                    // do not leak a canonical group into contact state.
                    skippedConversationCount += 1
                    return
                }
                let existedBefore = identity.flatMap {
                    realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: $0.primary
                    )
                } != nil

                guard applyConversationState(conversation, realm),
                      let identity else {
                    skippedConversationCount += 1
                    return
                }

                if realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: identity.primary
                ) != nil {
                    appliedConversationPrimaries.insert(identity.primary)
                    if existedBefore {
                        updatedChatCount += 1
                    } else {
                        createdChatCount += 1
                    }
                } else {
                    skippedConversationCount += 1
                }
            }
            try commitTransaction(realm)
        } catch {
            if realm.isInWriteTransaction {
                realm.cancelWrite()
            }
            throw error
        }

        return ApplyResult(
            appliedConversationPrimaries: appliedConversationPrimaries,
            summary: ApplySummary(
                receivedCount: conversations.count,
                createdChatCount: createdChatCount,
                updatedChatCount: updatedChatCount,
                skippedConversationCount: skippedConversationCount,
                failedConversationCount: 0
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

    private struct SyncPayloadApplyResult {
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
        let needsCatchUpSync: Bool

        static let none = SnapshotCompletionActions(
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
    
    internal static let initialViewportPageSize: Int = 20
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
    internal var beforeCommittingSyncPage: (() -> Void)?
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
        // The synchronized preview cache is intentionally process-resident.
        // A stamped cold-start delta cannot restore unchanged rows after a
        // relaunch, so recover only when durable Last Chats rows prove that a
        // server preview exists but neither a materialized message nor a
        // process projection can render it. This remains list-only and uses
        // the bounded 20-row first page.
        if needsColdListPreviewRecoverySnapshot() {
            return .absent
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

    private func needsColdListPreviewRecoverySnapshot() -> Bool {
        do {
            let realm = try WRealm.safe()
            let unresolvedRows = realm
                .objects(LastChatsStorageItem.self)
                .filter(
                    "owner == %@ AND lastMessage == nil AND lastMessageId != ''",
                    owner
                )
            return unresolvedRows.contains { row in
                LastChatListSyncPreviewStore.shared.projection(
                    owner: owner,
                    conversationPrimary: row.primary,
                    expectedLastMessageID: row.lastMessageId
                ) == nil
            }
        } catch {
            DDLogDebug(
                "ClientSynchronizationManager: \(#function). \(error.localizedDescription)"
            )
            return false
        }
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

    private func currentSyncSessionGeneration() -> UInt64 {
        stateQueue.sync { syncSessionGeneration }
    }

    private func commitSyncPageTransaction(
        _ realm: Realm,
        expectedGeneration: UInt64
    ) throws {
        beforeCommittingSyncPage?()
        syncLifecycleLock.lock()
        defer { syncLifecycleLock.unlock() }
        guard stateQueue.sync(execute: {
            syncSessionGeneration == expectedGeneration
        }) else {
            throw SyncSessionApplyError.invalidated
        }
        try realm.commitWrite()
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
            needsCatchUpAfterSnapshot = false
            return true
        }
        if didReset {
            temporaryVer = nil
            notifyInitialListSynchronizationTrafficGateDidChange()
        }
        return didReset
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
            case .active:
                // Active rows are list-only and start no group IQ.
                break
            case let .deleted(groupJID):
                account.reconcileCanonicalGroupDeletionFromSynchronization(groupJID)
            }
        }
    }

    private static func effectiveConversationType(
        from conversation: DDXMLElement
    ) -> ConversationType {
        ConversationType(
            rawValue: conversation.attributeStringValue(forName: "type") ??
                "none"
        ) ?? ConversationType(
            rawValue: CommonConfigManager.shared.config.locked_conversation_type
        ) ?? .regular
    }

    private static func isActiveListStatus(_ status: String?) -> Bool {
        status == nil || status == ConversationStatus.active.rawValue
    }

    private func clearCommittedRegularConversationDeletionMarkers(
        from conversations: [DDXMLElement],
        appliedConversationPrimaries: Set<String>,
        realm: Realm
    ) {
        var visitedPrimaries = Set<String>()
        for conversation in conversations.reversed() {
            guard let jid = conversation.attributeStringValue(forName: "jid"),
                  jid.isNotEmpty,
                  Self.effectiveConversationType(from: conversation) ==
                    .regular else {
                continue
            }
            let primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
            guard visitedPrimaries.insert(primary).inserted,
                  Self.isActiveListStatus(
                    conversation.attributeStringValue(forName: "status")
                  ),
                  appliedConversationPrimaries.contains(primary),
                  realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: primary
                  ) != nil else {
                continue
            }
            ClientSyncRegularConversationDeletionStore.clear(
                owner: owner,
                jid: jid
            )
        }
    }

    private func applySyncPayload(
        conversations: [ClientSyncConversationValue],
        expectedGeneration: UInt64
    ) throws -> SyncPayloadApplyResult {
        try beforeApplyingSyncPayload?()
        guard isCurrentSyncSessionGeneration(expectedGeneration) else {
            throw SyncSessionApplyError.invalidated
        }
        let materializedConversations = conversations.compactMap {
            $0.materializedElement()
        }
        guard materializedConversations.count == conversations.count else {
            throw SyncSessionApplyError.invalidated
        }
        let previewPreparationEpoch =
            LastChatListSyncPreviewStore.shared.preparationEpoch(for: owner)
        let realm = try WRealm.safe()
        let activeGroupPrimaries = CanonicalGroupRegularShadowPolicy
            .activeGroupPrimaries(in: realm, owners: [self.owner])
        let result = try ClientSyncPageApplier.apply(
            owner: owner,
            realm: realm,
            conversations: materializedConversations,
            activeCanonicalGroupPrimaries: activeGroupPrimaries,
            applyConversationState: self.applyListConversationState(_:realm:),
            commitTransaction: { realm in
                try self.commitSyncPageTransaction(
                    realm,
                    expectedGeneration: expectedGeneration
                )
            }
        )
        clearCommittedRegularConversationDeletionMarkers(
            from: materializedConversations,
            appliedConversationPrimaries: result.appliedConversationPrimaries,
            realm: realm
        )
        guard isCurrentSyncSessionGeneration(expectedGeneration) else {
            throw SyncSessionApplyError.invalidated
        }
        let previewMutations = materializedConversations.compactMap { conversation -> LastChatListSyncPreviewMutation? in
            guard let jid = conversation.attributeStringValue(forName: "jid"),
                  jid.isNotEmpty else {
                return nil
            }
            let conversationType = ConversationType(
                rawValue: conversation.attributeStringValue(forName: "type") ?? "none"
            ) ?? ConversationType(
                rawValue: CommonConfigManager.shared.config.locked_conversation_type
            ) ?? .regular
            guard conversationType != .notifications else { return nil }
            let primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
            let isDeleted = conversation.element(forName: "deleted") != nil ||
                conversation.attributeStringValue(forName: "status") ==
                    ConversationStatus.deleted.rawValue
            if isDeleted {
                return .remove(conversationPrimary: primary)
            }
            guard result.appliedConversationPrimaries.contains(primary),
                  let lastChat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: primary
                  ),
                  let messageElement = Self.syncMetadata(from: conversation)?
                    .element(forName: "last-message")?
                    .element(forName: "message"),
                  let projection = LastChatListSyncPreviewParser.projection(
                    owner: owner,
                    conversationPrimary: primary,
                    lastMessageID: lastChat.lastMessageId,
                    messageElement: messageElement
                  ) else {
                return nil
            }
            return .upsert(projection)
        }
        LastChatListSyncPreviewStore.shared.apply(
            previewMutations,
            for: owner,
            expectedEpoch: previewPreparationEpoch
        )
        guard isCurrentSyncSessionGeneration(expectedGeneration) else {
            throw SyncSessionApplyError.invalidated
        }
        routeCanonicalGroupSynchronization(from: materializedConversations)
        return SyncPayloadApplyResult(
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
                    needsCatchUpSync: needsCatchUpAfterSnapshot
                )
                activeSnapshotStamp = nil
                activeSnapshotRequestedStampMode = nil
                requestedSnapshotAfterTokens.removeAll()
                seenSnapshotConversationKeys.removeAll()
                phase = .live
                needsCatchUpAfterSnapshot = false
                return actions
            } else {
                phase = .catchingUp
                return SnapshotCompletionActions.none
            }
        }
    }

    private func noteCatchUpNeededAfterSnapshot() {
        stateQueue.sync {
            needsCatchUpAfterSnapshot = true
        }
    }

    private func isInitialChatListSynchronizationInProgressLocked() -> Bool {
        // A completed snapshot is a usable chat-list baseline. Later stamp-based
        // catch-up must not turn unrelated account work into a synchronization lane.
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

    public final func isInitialChatListSynchronizationInProgress() -> Bool {
        stateQueue.sync {
            isInitialChatListSynchronizationInProgressLocked()
        }
    }

    /// Scheduler-facing gate for the active initial snapshot only. Unlike the
    /// broader readiness query above, this deliberately opens again after a
    /// failed/reset request so auxiliary work cannot be stranded indefinitely.
    final func isInitialListSynchronizationTrafficGateActive() -> Bool {
        stateQueue.sync {
            guard isAvailable,
                  Self.normalizedSyncString(lastCompletedSnapshotStamp) == nil else {
                return false
            }
            return isApplyingPage ||
                phase == .snapshotInProgress ||
                phase == .catchingUp
        }
    }

    private func notifyInitialListSynchronizationTrafficGateDidChange() {
        AccountManager.shared.find(for: owner)?
            .xmppTaskScheduler
            .initialListSynchronizationDidChange()
    }

    private func conversationKeys(
        from conversations: [ClientSyncConversationValue]
    ) -> [String] {
        conversations.compactMap { conversation in
            guard let jid = conversation.jid,
                  jid.isNotEmpty else {
                return nil
            }
            let type = ConversationType(
                rawValue: conversation.rawConversationType ?? "none"
            ) ?? .regular
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

    private static func syncMetadata(from conversation: DDXMLElement) -> DDXMLElement? {
        conversation
            .elements(forName: "metadata")
            .first(where: { $0.attributeStringValue(forName: "node") == ClientSynchronizationManager.primaryNamespace })
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
                let message = XMPPMessage(from: messageElement)
                let conversationJID = conversation
                    .attributeStringValue(forName: "jid")
                    .map { GroupStorageKey.bareJID($0) }
                let archiveId = getStanzaId(message, owner: self.owner) ??
                    conversationJID.flatMap { getStanzaId(message, owner: $0) }
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
        let requestedPageSize = after == nil && requestedStamp == nil
            ? Self.initialViewportPageSize
            : pageSize
        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        set.addChild(DDXMLElement(name: "max", stringValue: "\(requestedPageSize)"))
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
            max: requestedPageSize
        )
        registerSyncQuery(elementId, request: diagnostics)
        syncLifecycleLock.unlock()
        notifyInitialListSynchronizationTrafficGateDidChange()
        let sendStartedAt = Date()
        logSyncTrace("requestSendStart", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", requestedPageSize)
        ])
        xmppStream.send(iq)
        logSyncTrace("requestSendFinish", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", requestedPageSize),
            ("durationMs", Int(Date().timeIntervalSince(sendStartedAt) * 1000))
        ])
        syncRequestObserver?(diagnostics)
        logSyncTrace("request", [
            ("id", elementId),
            ("stamp", requestedStamp),
            ("after", after),
            ("before", Optional<String>.none),
            ("max", requestedPageSize)
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

        let expectedGeneration = currentSyncSessionGeneration()
        let conversations = query
            .elements(forName: "conversation")
            .compactMap { $0.copy() as? DDXMLElement }
            .map(ClientSyncConversationValue.init)
        do {
            let applyResult = try applySyncPayload(
                conversations: conversations,
                expectedGeneration: expectedGeneration
            )
            guard isCurrentSyncSessionGeneration(expectedGeneration) else {
                return true
            }
            logSyncTrace("pushApply", [
                ("stamp", stamp),
                ("count", applyResult.applySummary.receivedCount),
                ("created", applyResult.applySummary.createdChatCount),
                ("updated", applyResult.applySummary.updatedChatCount),
                ("skipped", applyResult.applySummary.skippedConversationCount),
                ("failed", applyResult.applySummary.failedConversationCount)
            ])
            if isInitialChatListSynchronizationInProgress() {
                noteCatchUpNeededAfterSnapshot()
            } else {
                syncLifecycleLock.lock()
                if isCurrentSyncSessionGeneration(expectedGeneration) {
                    markLastRecognizedEventStamp(stamp)
                }
                syncLifecycleLock.unlock()
            }
        } catch {
            DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
        }
        return true
    }
    
    private final func applyListConversationState(
        _ conversation: DDXMLElement,
        realm: Realm
    ) -> Bool {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              jid.isNotEmpty else {
            return false
        }
        let conversationType = Self.effectiveConversationType(
            from: conversation
        )
        if conversationType == .notifications {
            applyNotificationConversationState(conversation, jid: jid, realm: realm)
            return false
        }

        let primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        let existing = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: primary
        )
        let status = conversation.attributeStringValue(forName: "status")
        let isDeleted = conversation.element(forName: "deleted") != nil ||
            status == ConversationStatus.deleted.rawValue
        if isDeleted {
            if conversationType == .regular {
                ClientSyncRegularConversationDeletionStore.markDeleted(
                    owner: owner,
                    jid: jid
                )
            }
            if let existing {
                realm.delete(existing)
            }
            return false
        }
        if conversationType == .regular,
           ClientSyncRegularConversationDeletionStore.contains(
                owner: owner,
                jid: jid
           ),
           !Self.isActiveListStatus(status) {
            if let existing {
                realm.delete(existing)
            }
            return false
        }

        if conversationType == .group {
            let containsInviteControl = Self.syncMetadata(from: conversation)?
                .element(forName: "last-message")?
                .element(forName: "message")?
                .element(
                    forName: "invite",
                    xmlns: ConversationType.group.rawValue
                ) != nil
            guard !containsInviteControl else {
                // XEP-SYNC is not an invite ingress. Fail closed without
                // creating either a chat projection or a GroupInvite; the
                // authoritative invite path owns the pending invite.
                return false
            }
            guard Self.canonicalGroupSynchronizationSignal(
                from: conversation
            ) == .active(groupJID: GroupStorageKey.bareJID(jid)) else {
                // Unsupported group states remain outside the chat list.
                // Authoritative delete was handled above.
                return false
            }
        }

        let instance = existing ?? LastChatsStorageItem()
        if existing == nil {
            instance.jid = jid
            instance.conversationType = conversationType
            instance.setPrimary(withOwner: owner)
        }
        if (conversationType == .regular || conversationType.isEncrypted),
           let rosterItem = realm.object(
                ofType: RosterStorageItem.self,
                forPrimaryKey: RosterStorageItem.genPrimary(
                    jid: jid,
                    owner: owner
                )
           ) {
            instance.rosterItem = rosterItem
        }
        instance.isArchived =
            status == ConversationStatus.archived.rawValue

        let pinned = conversation.attributeDoubleValue(
            forName: "pinned",
            withDefaultValue: 0
        )
        instance.pinnedPosition = pinned
        instance.isPinned = pinned != 0
        instance.muteExpired = conversation.attributeDoubleValue(
            forName: "mute",
            withDefaultValue: -1
        )

        let unread = unreadState(from: conversation) ?? SyncUnreadState(
            count: 0,
            afterId: nil,
            lastMessageArchiveId: nil
        )
        // XEP-SYNC owns the list counter, but it must not rewrite runtime
        // message buckets. Live ingress will build new runtime contribution
        // state after this authoritative list snapshot.
        instance.syncUnreadCount = unread.count
        instance.syncUnreadAfterId = unread.afterId
        instance.syncSnapshotLastArchiveId = unread.lastMessageArchiveId
        instance.lastReadId = unread.afterId
        instance.runtimeUnreadCount = 0
        instance.unread = unread.count

        let metadata = Self.syncMetadata(from: conversation)
        instance.displayedId = metadata?
            .element(forName: "displayed")?
            .attributeStringValue(forName: "id")
        instance.deliveredId = metadata?
            .element(forName: "delivered")?
            .attributeStringValue(forName: "id")

        let messageElement = metadata?
            .element(forName: "last-message")?
            .element(forName: "message")
        let syncStamp = conversation.attributeDoubleValue(forName: "stamp")
        if let messageElement {
            let message = XMPPMessage(from: messageElement)
            instance.lastMessageId = getOriginId(message) ??
                message.elementID ??
                getStanzaId(message, owner: owner) ??
                ""
            instance.messageDate = Self.archivedMessageDate(
                from: messageElement,
                fallbackSyncStamp: syncStamp
            )
            if let lastMessage = instance.lastMessage,
               lastMessage.messageId != instance.lastMessageId,
               lastMessage.archivedId != instance.lastMessageId {
                instance.lastMessage = nil
            }
        } else if existing == nil {
            instance.messageDate = Self.dateFromSyncStamp(syncStamp)
        }
        instance.updateTS = syncStamp
        instance.isFreshNotEmptyEncryptedChat =
            conversationType.isEncrypted && messageElement == nil
        instance.isPrereaded = false

        if existing == nil {
            realm.add(instance, update: .modified)
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
            pageSize: trackedRequest.diagnostics.max,
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
                let applyResult = try self.applySyncPayload(
                    conversations: page.conversations,
                    expectedGeneration: expectedGeneration
                )
                guard self.isCurrentSyncSessionGeneration(expectedGeneration) else {
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
                    self.notifyInitialListSynchronizationTrafficGateDidChange()
                    AccountManager.shared.changeNewUserState(for: self.owner, to: .dataLoaded)
                    self.logSyncTrace("snapshotComplete", [
                        ("snapshotStamp", page.stamp),
                        ("persistedCompletedStamp", page.stamp),
                        ("persistedRecognizedStamp", page.stamp),
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
            self.needsCatchUpAfterSnapshot = false
            self.syncRequestInfoById.removeAll()
            return true
        }
        if didReset {
            self.queryIds.removeAll()
        }
        syncLifecycleLock.unlock()
        if didReset {
            LastChatListSyncPreviewStore.shared.invalidatePreparations(
                for: owner
            )
            notifyInitialListSynchronizationTrafficGateDidChange()
        }
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
        LastChatListSyncPreviewStore.shared.removeAll(for: owner)
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapInProgressKey, value: false)
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapLastAfterKey, value: "")
    }
}
