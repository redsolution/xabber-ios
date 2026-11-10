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
import CryptoKit

private enum ClientSyncEventVersion {
    static func number(_ value: String?) -> UInt64? {
        guard let value else { return nil }
        return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func newest(_ lhs: String?, _ rhs: String) -> String {
        guard let lhs, let old = number(lhs), let new = number(rhs) else { return rhs }
        return old > new ? lhs : rhs
    }
}

/// Immutable transport between the XMPP parser and the serial Realm applier.
///
/// `DDXMLElement` is mutable and thread-confined in practice. Serializing the
/// already-normalized conversation keeps XML objects off the cross-queue
/// boundary while preserving extension payloads needed by list projection.
struct ClientSyncConversationValue: Sendable {
    let xmlString: String
    let jid: String?
    let rawConversationType: String?
    let lastMessageEncryption: MessageEncryptionProvenance
    let lastMessageAuthenticatedSender: OMEMOAuthenticatedSender?
    let lastMessageWasConsumed: Bool
    var containsEncryptedWire = false

    init(
        _ element: DDXMLElement,
        encryption: MessageEncryptionProvenance = .plaintext,
        consumed: Bool = false,
        authenticatedSender: OMEMOAuthenticatedSender? = nil
    ) {
        xmlString = element.xmlString
        jid = element.attributeStringValue(forName: "jid")
        rawConversationType = element.attributeStringValue(forName: "type")
        lastMessageEncryption = encryption
        lastMessageAuthenticatedSender = !consumed && encryption == .authenticatedSCE(profile: .omemo2) ? authenticatedSender : nil
        lastMessageWasConsumed = consumed
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

/// Durable, schema-neutral deletion watermarks for synchronization ordering.
/// The legacy presence marker remains regular-only for archive admission.
enum ClientSyncRegularConversationDeletionStore {
    private static let lock = NSLock()
    private static var decodedIdentities: [String: (raw: String?, values: Set<String>)] = [:]
    private static var decodedStamps: [String: (raw: String?, values: [String: String])] = [:]
    private static let stampsKey = "regular_conversation_deletion_stamps_v1"

    static func contains(owner: String, jid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identities(for: owner).contains(identity(owner: owner, jid: jid))
    }

    static func markDeleted(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        stamp: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let primary = identity(owner: owner, jid: jid, conversationType: conversationType)
        if conversationType == .regular {
            var values = identities(for: owner)
            if values.insert(primary).inserted {
                persist(values, for: owner)
            }
        }
        if let stamp, ClientSyncEventVersion.number(stamp) != nil {
            var stamps = deletionStamps(for: owner)
            stamps[primary] = ClientSyncEventVersion.newest(stamps[primary], stamp)
            persistStamps(stamps, owner: owner)
        }
    }

    static func clear(owner: String, jid: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = identities(for: owner)
        guard values.remove(identity(owner: owner, jid: jid)) != nil else {
            return
        }
        persist(values, for: owner)
        var stamps = deletionStamps(for: owner)
        if stamps.removeValue(forKey: identity(owner: owner, jid: jid)) != nil {
            persistStamps(stamps, owner: owner)
        }
    }

    static func latestDeletionStamp(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return ClientSyncEventVersion.number(deletionStamps(for: owner)[
            identity(owner: owner, jid: jid, conversationType: conversationType)
        ])
    }

    private static func deletionStamps(for owner: String) -> [String: String] {
        let raw = SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: stampsKey)
        if let cached = decodedStamps[owner], cached.raw == raw { return cached.values }
        guard let raw, let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else {
            decodedStamps[owner] = (raw, [:])
            return [:]
        }
        decodedStamps[owner] = (raw, result)
        return result
    }

    private static func persistStamps(_ stamps: [String: String], owner: String) {
        guard let data = try? JSONEncoder().encode(stamps), let raw = String(data: data, encoding: .utf8) else { return }
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: stampsKey, value: raw)
        decodedStamps[owner] = (raw, stamps)
    }

    static func removeAll(for owner: String) {
        lock.lock()
        defer { lock.unlock() }
        decodedIdentities.removeValue(forKey: owner)
        decodedStamps.removeValue(forKey: owner)
        SettingManager.shared.removeItem(for: owner, scope: .clientSynchronization,
            key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey)
        SettingManager.shared.removeItem(for: owner, scope: .clientSynchronization, key: stampsKey)
    }

    private static func identity(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> String {
        LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
    }

    private static func identities(for owner: String) -> Set<String> {
        let raw = SettingManager.shared.getKey(
            for: owner,
            scope: .clientSynchronization,
            key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey
        )
        if let cached = decodedIdentities[owner], cached.raw == raw { return cached.values }
        guard let raw, let data = raw.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            decodedIdentities[owner] = (raw, [])
            return []
        }
        let values = Set(decoded)
        decodedIdentities[owner] = (raw, values)
        return values
    }

    private static func persist(_ identities: Set<String>, for owner: String) {
        guard !identities.isEmpty else {
            SettingManager.shared.removeItem(
                for: owner,
                scope: .clientSynchronization,
                key: SettingManager.clientSynchronizationRegularDeletionTombstonesKey
            )
            decodedIdentities[owner] = (nil, [])
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
        decodedIdentities[owner] = (raw, identities)
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

    /// Compatibility for callers that only normalize ordinary XML. Production
    /// encrypted ingress uses the typed overload so provenance survives queues.
    static func parseSnapshotPage(from iq: XMPPIQ, pageSize: Int, namespace: String, updateOmemo: (DDXMLElement) -> DDXMLElement) -> SnapshotPage? {
        parseSnapshotPage(from: iq, pageSize: pageSize, namespace: namespace) { query in
            updateOmemo(query).elements(forName: "conversation")
                .map { ClientSyncConversationValue($0) }
        }
    }

    static func parseSnapshotPage(from iq: XMPPIQ, pageSize: Int, namespace: String, prepareConversations: (DDXMLElement) -> [ClientSyncConversationValue]) -> SnapshotPage? {
        guard let query = iq.element(forName: "query", xmlns: namespace),
              let envelope = snapshotEnvelope(from: iq, pageSize: pageSize, namespace: namespace) else { return nil }
        return SnapshotPage(stamp: envelope.stamp, isFinalPage: envelope.isFinalPage,
            nextPageToken: envelope.nextPageToken, conversations: prepareConversations(query), rsm: envelope.rsm)
    }

    struct Envelope {
        let stamp: String
        let isFinalPage: Bool
        let nextPageToken: String?
        let rsm: RSMPage
    }

    static func snapshotEnvelope(from iq: XMPPIQ, pageSize: Int, namespace: String) -> Envelope? {
        guard let query = iq.element(forName: "query", xmlns: namespace),
              let stamp = query.attributeStringValue(forName: "stamp") else { return nil }
        let conversationCount = query.elements(forName: "conversation").count
        let set = query.element(forName: "set")
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
            isFinalPage = firstIndex + conversationCount >= rsmCount
        } else if let rsmCount, rsmCount <= conversationCount {
            isFinalPage = true
        } else if !hasNextPageToken {
            isFinalPage = true
        } else {
            // Some servers omit RSM count while still returning the last
            // cursor on the terminal page. In that shape only a short page
            // proves exhaustion, and it must be compared with the maximum of
            // the matching request.
            isFinalPage = conversationCount < max(pageSize, 1)
        }
        return Envelope(stamp: stamp, isFinalPage: isFinalPage,
            nextPageToken: hasNextPageToken ? nextPageToken : nil,
            rsm: RSMPage(first: first?.isNotEmpty == true ? first : nil,
                firstIndex: firstIndex, last: hasNextPageToken ? nextPageToken : nil, count: rsmCount))
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
        let changedConversationPrimaries: Set<String>
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
        shouldApplyConversation: (DDXMLElement, Realm) -> Bool = { _, _ in true },
        applyConversationState: (DDXMLElement, Realm) -> Bool,
        commitTransaction: (Realm) throws -> Void = { realm in
            try realm.commitWrite()
        }
    ) throws -> ApplyResult {
        var createdChatCount = 0
        var updatedChatCount = 0
        var skippedConversationCount = 0
        var appliedConversationPrimaries = Set<String>()
        var changedConversationPrimaries = Set<String>()
        var acceptedCount = 0

        realm.beginWrite()
        do {
            conversations.forEach { sourceConversation in
                guard shouldApplyConversation(sourceConversation, realm) else {
                    skippedConversationCount += 1
                    return
                }
                let conversation =
                    (sourceConversation.copy() as? DDXMLElement) ??
                    sourceConversation
                let identity = Self.identity(
                    from: conversation,
                    owner: owner
                )
                acceptedCount += 1
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

                let applied = applyConversationState(conversation, realm)
                if let identity, existedBefore || realm.object(
                    ofType: LastChatsStorageItem.self, forPrimaryKey: identity.primary
                ) != nil {
                    changedConversationPrimaries.insert(identity.primary)
                }
                guard applied,
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
            if acceptedCount > 0 || conversations.isEmpty {
                try commitTransaction(realm)
            } else {
                realm.cancelWrite()
            }
        } catch {
            if realm.isInWriteTransaction {
                realm.cancelWrite()
            }
            throw error
        }

        return ApplyResult(
            appliedConversationPrimaries: appliedConversationPrimaries,
            changedConversationPrimaries: changedConversationPrimaries,
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
        var recognizedEventStamp: String? = nil

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
    
    public let pageSize: Int = 40
    
    open var isAvailable: Bool = false
    open var version: String = ""
    private var temporaryVer: String? = nil
    private let applyQueue = DispatchQueue(label: "com.xabber.client-sync.apply")
    private let preparationQueue = DispatchQueue(label: "com.xabber.client-sync.prepare", qos: .userInitiated)
    private let applicationLock = NSRecursiveLock()
    private let stateQueue = DispatchQueue(label: "com.xabber.client-sync.state")
    private let syncLifecycleLock = NSLock()
    private var syncRequestInfoById: [String: TrackedSyncRequest] = [:]
    private var syncSessionGeneration: UInt64 = 0
    // Per authenticated session, including a stamped catch-up over cached rows.
    // Retry/reset of a failed request is not successful startup completion.
    private var startupSynchronizationPending = false
    private enum StartupRecentsSyncActivity {
        case idle, awaitingFirstPage, appliedFirstPage
    }
    private var startupRecentsSyncActivity: StartupRecentsSyncActivity = .idle
    static let startupRecentsSyncActivityDidChange = Notification.Name(
        "com.xabber.client-sync.startup-recents-sync-activity-did-change"
    )
    // Presentation readiness belongs to this account instance. Either an
    // accepted cold checkpoint or a committed startup response is sufficient.
    private var startupRecentsResponseReceived = false
    private var startupRecentsResumeAccepted = false
    static let startupRecentsReadinessDidChange = Notification.Name(
        "com.xabber.client-sync.startup-recents-readiness-did-change"
    )
    internal var startupResponseTimeoutInterval: TimeInterval = 60
    private var startupResponseTimeouts: [String: DispatchWorkItem] = [:]
    private var phase: SyncPhase = .idle
    private var activeSnapshotStamp: String? = nil
    private var activeSnapshotRequestedStampMode: SnapshotRequestStampMode? = nil
    private var requestedSnapshotAfterTokens = Set<String>()
    private var seenSnapshotConversationKeys = Set<String>()
    private var isApplyingPage: Bool = false
    private var needsCatchUpAfterSnapshot = false
    private var pendingSnapshotPageCount = 0
    private var pendingSnapshotContinuation: (token: String, generation: UInt64)?
    private var pendingRecognizedEventStamp: String?
    private struct AppliedFingerprint {
        let generation: UInt64
        let digest: String
    }
    // Accessed under applicationLock; reset need not acquire that lock while
    // holding the lifecycle lock because eligibility includes the generation.
    private var appliedFingerprints: [String: AppliedFingerprint] = [:]
    private var preparedValues: [String: ClientSyncConversationValue] = [:]
    private var preparedValueOrder: [String] = []
    private var preparedValueByteCount = 0
    private let maximumPendingSnapshotPages = 2
    
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
    internal var beforePreparingSyncPage: (() -> Void)?
    internal var beforeRecordingSnapshotPush: (() -> Void)?
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
        let newest = ClientSyncEventVersion.newest(lastRecognizedEventStamp, stamp)
        guard newest != lastRecognizedEventStamp else { return }
        lastRecognizedEventStamp = newest
        updateStoredVersion(newest)
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
        // Presentation-cache misses never invalidate a processed sync cursor.
        // A first synchronization is full; completed state always catches up
        // from its latest event, including after a process restart.
        if isPersistedSnapshotBootstrapInProgress {
            if let recognized = Self.normalizedSyncString(lastRecognizedEventStamp) {
                return .value(recognized)
            }
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
            !isApplyingPage && pendingSnapshotPageCount == 0 &&
                (phase == .snapshotInProgress || phase == .catchingUp)
        }
        guard canRecover else {
            return false
        }
        logSyncTrace("staleSnapshotPhaseRecoveredForRetry", [
            ("persistedSnapshotStamp", "withheld")
        ])
        // performSync already owns the lifecycle lock. Do not recursively
        // acquire it while recovering a response-less pagination phase.
        if resetSyncSessionWhileLifecycleLocked() {
            temporaryVer = nil
            completeSyncSessionReset()
            AccountManager.shared.find(for: owner)?.scheduleStartupSynchronizationRetry()
        }
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

    private func registerSyncQuery(_ elementId: String, request: SyncRequestDiagnostics) -> Bool {
        queryIds.insert(elementId)
        let (timeout, beganRecentsSync) = stateQueue.sync { () -> (DispatchWorkItem?, Bool) in
            syncRequestInfoById[elementId] = TrackedSyncRequest(
                diagnostics: request,
                generation: syncSessionGeneration
            )
            guard startupSynchronizationPending else { return (nil, false) }
            let beganRecentsSync = request.after == nil && startupRecentsSyncActivity == .idle
            if beganRecentsSync { startupRecentsSyncActivity = .awaitingFirstPage }
            let generation = syncSessionGeneration
            let item = DispatchWorkItem { [weak self] in
                self?.startupResponseDidTimeOut(elementId, generation: generation)
            }
            startupResponseTimeouts[elementId] = item
            return (item, beganRecentsSync)
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0.01, startupResponseTimeoutInterval), execute: timeout
            )
        }
        return beganRecentsSync
    }

    private func startupResponseDidTimeOut(_ elementId: String, generation: UInt64) {
        guard isCurrentSyncSessionGeneration(generation), isStartupSynchronizationPending(),
              let request = consumeTrackedSyncRequest(elementId), request.generation == generation else { return }
        logSyncTrace("startupResponseTimedOut", [("id", elementId), ("persistedSnapshotStamp", "withheld")])
        _ = resetSyncStateAfterFailure(expectedGeneration: generation)
    }

    private func consumeTrackedSyncRequest(_ elementId: String) -> TrackedSyncRequest? {
        syncLifecycleLock.lock()
        let trackedRequest = stateQueue.sync {
            startupResponseTimeouts.removeValue(forKey: elementId)?.cancel()
            return syncRequestInfoById.removeValue(forKey: elementId)
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
        // A pipelined successor must not survive failure of an earlier page.
        let didReset = resetSyncSession(expectedGeneration: expectedGeneration)
        if didReset {
            temporaryVer = nil
            notifyInitialListSynchronizationTrafficGateDidChange()
            AccountManager.shared.find(for: owner)?.scheduleStartupSynchronizationRetry()
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
        expectedGeneration: UInt64,
        isInitialServerSnapshot: Bool = false
    ) throws -> SyncPayloadApplyResult {
        try beforeApplyingSyncPayload?()
        applicationLock.lock()
        defer { applicationLock.unlock() }
        guard isCurrentSyncSessionGeneration(expectedGeneration) else {
            throw SyncSessionApplyError.invalidated
        }
        let materializedConversations = conversations.compactMap {
            $0.materializedElement()
        }
        guard materializedConversations.count == conversations.count else {
            throw SyncSessionApplyError.invalidated
        }
        let fingerprints = Dictionary(uniqueKeysWithValues: materializedConversations.map {
            (ObjectIdentifier($0), Self.syncFingerprint($0.xmlString))
        })
        let encryptedPrimaries = Set(zip(materializedConversations, conversations).compactMap { element, value -> String? in
            guard value.containsEncryptedWire || Self.isEncryptedSyncConversation(element) || value.lastMessageEncryption != .plaintext else { return nil }
            return syncConversationPrimary(element)
        })
        let previewPreparationEpoch =
            LastChatListSyncPreviewStore.shared.preparationEpoch(for: owner)
        let realm = try WRealm.safe()
        let relevantRegularJIDs = Set(materializedConversations.compactMap { element -> String? in
            guard Self.effectiveConversationType(from: element) == .regular,
                  let jid = element.attributeStringValue(forName: "jid") else { return nil }
            return GroupStorageKey.bareJID(jid)
        })
        let activeGroupPrimaries = CanonicalGroupRegularShadowPolicy.activeGroupPrimaries(
            in: realm, owners: [owner], restrictedToGroupJIDs: relevantRegularJIDs
        )
        let batch = ClientSyncPageBatch.shared.begin(owner: owner, generation: expectedGeneration)
        var completedBatch = false
        defer { if !completedBatch { ClientSyncPageBatch.shared.cancel(batch) } }
        var committedFingerprints: [String: String] = [:]
        let result = try ClientSyncPageApplier.apply(
            owner: owner,
            realm: realm,
            conversations: materializedConversations,
            activeCanonicalGroupPrimaries: activeGroupPrimaries,
            shouldApplyConversation: { conversation, realm in
                guard self.shouldApplyConversationVersion(conversation, realm: realm) else { return false }
                guard let primary = self.syncConversationPrimary(conversation),
                      let fingerprint = fingerprints[ObjectIdentifier(conversation)] else { return true }
                if !encryptedPrimaries.contains(primary),
                   let applied = self.appliedFingerprints[primary],
                   applied.generation == expectedGeneration,
                   applied.digest == fingerprint,
                   realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) != nil {
                    return false
                }
                committedFingerprints[primary] = fingerprint
                return true
            },
            applyConversationState: self.applyListConversationState(_:realm:),
            commitTransaction: { realm in
                try self.commitSyncPageTransaction(
                    realm,
                    expectedGeneration: expectedGeneration
                )
            }
        )
        let acceptedCurrentConversations = materializedConversations.filter { element in
            guard let primary = syncConversationPrimary(element),
                  let fingerprint = fingerprints[ObjectIdentifier(element)] else { return false }
            return committedFingerprints[primary] == fingerprint
        }
        clearCommittedRegularConversationDeletionMarkers(
            from: acceptedCurrentConversations,
            appliedConversationPrimaries: result.appliedConversationPrimaries,
            realm: realm
        )
        guard isCurrentSyncSessionGeneration(expectedGeneration) else {
            throw SyncSessionApplyError.invalidated
        }
        let previewMutations = zip(materializedConversations, conversations).compactMap { conversation, value -> LastChatListSyncPreviewMutation? in
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
            guard let fingerprint = fingerprints[ObjectIdentifier(conversation)],
                  committedFingerprints[primary] == fingerprint else { return nil }
            let isDeleted = conversation.element(forName: "deleted") != nil ||
                conversation.attributeStringValue(forName: "status") ==
                    ConversationStatus.deleted.rawValue
            if isDeleted {
                return .remove(conversationPrimary: primary)
            }
            guard !value.lastMessageWasConsumed else { return nil }
            guard result.appliedConversationPrimaries.contains(primary),
                  let lastChat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: primary
                  ),
                  let messageElement = Self.syncLastMessage(from: Self.syncMetadata(from: conversation)),
                  let projection = LastChatListSyncPreviewParser.projection(
                    owner: owner,
                    conversationPrimary: primary,
                    lastMessageID: lastChat.lastMessageId,
                    messageElement: messageElement,
                    encryption: value.lastMessageEncryption
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
        routeCanonicalGroupSynchronization(from: acceptedCurrentConversations)
        if appliedFingerprints.count > 4096 { appliedFingerprints.removeAll(keepingCapacity: true) }
        encryptedPrimaries.forEach { appliedFingerprints.removeValue(forKey: $0) }
        appliedFingerprints.merge(committedFingerprints
            .filter { !encryptedPrimaries.contains($0.key) }
            .mapValues { AppliedFingerprint(generation: expectedGeneration, digest: $0) }) { _, new in new }
        let didBecomeRecentsReady = isInitialServerSnapshot && stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration,
                  !startupRecentsResponseReceived else { return false }
            startupRecentsResponseReceived = true
            return !startupRecentsResumeAccepted
        }
        ClientSyncPageBatch.shared.commit(batch, changedConversationPrimaries: result.changedConversationPrimaries)
        completedBatch = true
        if didBecomeRecentsReady { notifyStartupRecentsReadinessDidChange() }
        return SyncPayloadApplyResult(
            applySummary: result.summary
        )
    }

    private static func syncFingerprint(_ xml: String) -> String {
        SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isEncryptedSyncConversation(_ conversation: DDXMLElement) -> Bool {
        effectiveConversationType(from: conversation).isEncrypted || SCEReceivePolicy.containsOMEMO2(conversation)
    }

    private func syncConversationPrimary(_ conversation: DDXMLElement) -> String? {
        guard let jid = conversation.attributeStringValue(forName: "jid"), !jid.isEmpty else { return nil }
        return LastChatsStorageItem.genPrimary(jid: jid, owner: owner,
            conversationType: Self.effectiveConversationType(from: conversation))
    }

    /// Runs inside the Realm write transaction after its automatic refresh, so
    /// a newer push that committed while this page waited cannot be rolled back.
    private func shouldApplyConversationVersion(_ conversation: DDXMLElement, realm: Realm) -> Bool {
        guard let stamp = ClientSyncEventVersion.number(conversation.attributeStringValue(forName: "stamp")),
              let primary = syncConversationPrimary(conversation) else { return true }
        if let existing = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary),
           existing.updateTS > Double(stamp) { return false }
        if let jid = conversation.attributeStringValue(forName: "jid"),
           let deleted = ClientSyncRegularConversationDeletionStore.latestDeletionStamp(
                owner: owner, jid: jid, conversationType: Self.effectiveConversationType(from: conversation)
           ),
           stamp <= deleted { return false }
        return true
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
            pendingSnapshotPageCount = max(0, pendingSnapshotPageCount - 1)
            isApplyingPage = pendingSnapshotPageCount > 0
            if isFinalPage {
                let actions = SnapshotCompletionActions(
                    needsCatchUpSync: needsCatchUpAfterSnapshot,
                    recognizedEventStamp: pendingRecognizedEventStamp
                )
                activeSnapshotStamp = nil
                activeSnapshotRequestedStampMode = nil
                requestedSnapshotAfterTokens.removeAll()
                seenSnapshotConversationKeys.removeAll()
                phase = .live
                needsCatchUpAfterSnapshot = false
                pendingRecognizedEventStamp = nil
                return actions
            } else {
                phase = .catchingUp
                return SnapshotCompletionActions.none
            }
        }
    }

    private func isInitialChatListSynchronizationInProgressLocked() -> Bool {
        // A completed snapshot is a usable chat-list baseline. Later stamp-based
        // catch-up must not turn unrelated account work into a synchronization lane.
        guard isAvailable,
              Self.normalizedSyncString(lastCompletedSnapshotStamp) == nil else {
            return false
        }
        return startupSynchronizationPending ||
            isApplyingPage ||
            phase == .snapshotInProgress ||
            phase == .catchingUp
    }

    public final func isInitialChatListSynchronizationInProgress() -> Bool {
        stateQueue.sync {
            isInitialChatListSynchronizationInProgressLocked()
        }
    }

    final func isStartupSynchronizationPending() -> Bool {
        stateQueue.sync { isAvailable && startupSynchronizationPending }
    }

    final func isAwaitingStartupRecentsSyncResponse() -> Bool {
        stateQueue.sync { startupRecentsSyncActivity == .awaitingFirstPage }
    }

    private func finishStartupRecentsSync(expectedGeneration: UInt64, appliedFirstPage: Bool) {
        let changed = stateQueue.sync {
            guard syncSessionGeneration == expectedGeneration,
                  startupRecentsSyncActivity == .awaitingFirstPage else { return false }
            startupRecentsSyncActivity = appliedFirstPage ? .appliedFirstPage : .idle
            return true
        }
        if changed { notifyStartupRecentsSyncActivityDidChange() }
    }

    private func notifyStartupRecentsSyncActivityDidChange() {
        NotificationCenter.default.post(name: Self.startupRecentsSyncActivityDidChange, object: owner)
    }

    final func canCheckpointForStreamManagement() -> Bool {
        stateQueue.sync {
            !isApplyingPage && pendingSnapshotPageCount == 0 &&
            pendingSnapshotContinuation == nil && syncRequestInfoById.isEmpty
        }
    }

    final func hasReceivedStartupRecentsResponse() -> Bool {
        stateQueue.sync { startupRecentsResponseReceived }
    }

    final func isStartupRecentsReady() -> Bool {
        stateQueue.sync { startupRecentsResponseReceived || startupRecentsResumeAccepted }
    }

    /// The roster coordinator calls this only for a successfully applied or
    /// empty result it correlated with its current initial roster request.
    final func noteLegacyStartupRosterResponse(_ iq: XMPPIQ) {
        guard iq.iqType == .result, syncServerContext(for: iq) == .accountServer else { return }
        let didBecomeRecentsReady = stateQueue.sync {
            guard !isAvailable, !startupRecentsResponseReceived else { return false }
            startupRecentsResponseReceived = true
            return !startupRecentsResumeAccepted
        }
        if didBecomeRecentsReady { notifyStartupRecentsReadinessDidChange() }
    }

    private func notifyStartupRecentsReadinessDidChange() {
        NotificationCenter.default.post(name: Self.startupRecentsReadinessDidChange, object: owner)
    }

    final func isCurrentStartupSynchronizationGeneration(_ generation: UInt64) -> Bool {
        isCurrentSyncSessionGeneration(generation)
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
        if let messageElement,
           let date = SCEReceivePolicy.children(of: messageElement, named: "time", xmlns: "https://xabber.com/protocol/delivery")
            .first?.attributeStringValue(forName: "stamp")?.xmppDate {
            return date.timeIntervalSince1970 * 1_000_000
        }
        return fallback
    }

    static func archivedMessageDate(from messageElement: DDXMLElement?, owner: String? = nil) -> Date? {
        guard let messageElement else { return nil }
        let message = XMPPMessage(from: messageElement)
        // A sync preview contains the original stanza, not another transport
        // envelope. Reuse qualified time/delay validation without accepting a
        // nested archive/rewrite timestamp or the conversation's event stamp.
        guard let path = try? OmemoManager.incomingPath(message, owner: owner),
              path.count == 1 else { return nil }
        return try? OmemoManager.originalSendingTime(for: message, owner: owner)?.date
    }

    private static func syncMetadata(from conversation: DDXMLElement) -> DDXMLElement? {
        conversation
            .elements(forName: "metadata")
            .first(where: { $0.attributeStringValue(forName: "node") == ClientSynchronizationManager.primaryNamespace })
    }

    private static func syncLastMessage(from metadata: DDXMLElement?) -> DDXMLElement? {
        guard let last = metadata?.element(forName: "last-message") else { return nil }
        let messages = SCEReceivePolicy.children(of: last, named: "message", xmlns: "jabber:client")
        return messages.count == 1 ? messages[0] : nil
    }

    private static func normalizedArchiveId(_ value: String?) -> String? {
        guard let value, value.isNotEmpty else {
            return nil
        }
        return value
    }

    private func unreadState(from conversation: DDXMLElement) -> SyncUnreadState? {
        guard let metadata = Self.syncMetadata(from: conversation),
              let unreadElement = metadata.element(forName: "unread") else {
            return nil
        }

        let lastMessageArchiveId = Self.syncLastMessage(from: metadata)
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
        let requestedPageSize = pageSize
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
        let beganRecentsSync = registerSyncQuery(elementId, request: diagnostics)
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
        if beganRecentsSync { notifyStartupRecentsSyncActivityDidChange() }
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
        let conversations = prepareSyncConversations(query, serverContext: syncServerContext(for: iq))
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
            beforeRecordingSnapshotPush?()
            stateQueue.sync {
                guard syncSessionGeneration == expectedGeneration else { return }
                // Choose the disposition and record it together. Final-page
                // completion must not fall between an active-snapshot check
                // and recording this successfully committed push's cursor.
                if phase == .snapshotInProgress || phase == .catchingUp || pendingSnapshotPageCount > 0 {
                    needsCatchUpAfterSnapshot = true
                    pendingRecognizedEventStamp = ClientSyncEventVersion.newest(pendingRecognizedEventStamp, stamp)
                } else {
                    markLastRecognizedEventStamp(stamp)
                }
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
            ClientSyncRegularConversationDeletionStore.markDeleted(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                stamp: conversation.attributeStringValue(forName: "stamp")
            )
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

        let messageElement = Self.syncLastMessage(from: metadata)
        let syncStamp = conversation.attributeDoubleValue(forName: "stamp")
        if let messageElement {
            let message = XMPPMessage(from: messageElement)
            let previousLastMessageID = instance.lastMessageId
            instance.lastMessageId = getOriginId(message) ??
                message.elementID ??
                getStanzaId(message, owner: owner) ??
                ""
            if let messageDate = Self.archivedMessageDate(
                from: messageElement,
                owner: owner
            ) {
                instance.messageDate = messageDate
            } else if previousLastMessageID.isEmpty || previousLastMessageID != instance.lastMessageId {
                // A retained date belongs only to the same known message.
                instance.messageDate = Date(timeIntervalSince1970: 0)
            }
            if let lastMessage = instance.lastMessage,
               lastMessage.messageId != instance.lastMessageId,
               lastMessage.archivedId != instance.lastMessageId {
                instance.lastMessage = nil
            }
        }
        instance.updateTS = syncStamp
        // A list-only sync can omit last-message XML for an established chat.
        // Its known identity/link must not become a new-chat invitation.
        instance.isFreshNotEmptyEncryptedChat =
            conversationType.isEncrypted && messageElement == nil &&
            instance.lastMessageId.isEmpty && instance.lastMessage == nil
        instance.isPrereaded = false

        if existing == nil {
            realm.add(instance, update: .modified)
        }
        return true
    }
    
    internal func claimInitialPresenceSend() -> Bool {
        stateQueue.sync {
            guard !isAvailable || !startupSynchronizationPending else { return false }
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

    internal func rearmUntransmittedStartupPresence() {
        stateQueue.sync { initialPresenceSessionState = .ready }
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
        let pausedRecentsSync = stateQueue.sync {
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
            guard startupRecentsSyncActivity == .awaitingFirstPage else { return false }
            startupRecentsSyncActivity = .idle
            return true
        }
        if pausedRecentsSync { notifyStartupRecentsSyncActivityDidChange() }
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
        if account.isStartupBackgroundTrafficBlocked {
            account.sendStartupPresenceIfReady()
            return
        }
        account.action { [weak self] (user, stream) in
            guard stream.isAuthenticated else { return }
            user.msgDeleteManager.enable(stream)
            if self?.claimInitialPresenceSend() == true {
                user.presence()
            }
        }
    }

    internal func waitForPendingSnapshotApplies() {
        let finished = DispatchGroup()
        finished.enter()
        preparationQueue.async {
            self.applyQueue.async { finished.leave() }
        }
        if Thread.isMainThread {
            // Test barrier only: Realm's pending asynchronous main-thread
            // transactions may already hold the writer lock needed by apply.
            // Keep their source runloop alive while the queue markers drain.
            while finished.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            finished.wait()
        }
    }

    internal func readSnapshot(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result, let elementID = iq.elementID,
              syncQueryElement(in: iq) != nil else { return false }
        guard let request = consumeTrackedSyncRequest(elementID) else { return true }
        let admitted = stateQueue.sync { () -> Bool in
            guard syncSessionGeneration == request.generation else { return false }
            pendingSnapshotPageCount += 1
            isApplyingPage = true
            return true
        }
        guard admitted else { return true }
        // The detached immutable ownership handoff leaves parsing, decryption
        // and persistence off the account's XMPP delegate queue.
        let detached = XMPPIQ(from: iq.copy() as! DDXMLElement)
        preparationQueue.async { [weak self] in
            _ = self?.processSnapshot(detached, trackedRequest: request)
        }
        return true
    }

    private func processSnapshot(_ iq: XMPPIQ, trackedRequest: TrackedSyncRequest) -> Bool {
        guard iq.iqType == .result else {
            return false
        }
        guard let elementId = iq.elementID,
              let query = syncQueryElement(in: iq) else {
            return false
        }
        let isTrackedSyncQuery = true
        logSyncTrace("responseReceivedBeforeParse", [
            ("id", elementId),
            ("isTracked", isTrackedSyncQuery),
            ("iqType", iq.type),
            ("queryNamespace", query.xmlns()),
            ("queryStamp", query.attributeStringValue(forName: "stamp")),
            ("childCount", query.children?.count)
        ])
        guard isCurrentSyncSessionGeneration(trackedRequest.generation) else {
            logSyncTrace("staleSnapshotResponseIgnored", [
                ("id", elementId),
                ("isTracked", isTrackedSyncQuery)
            ])
            return true
        }
        let expectedGeneration = trackedRequest.generation
        let request: SyncRequestDiagnostics? = trackedRequest.diagnostics
        let serverContext = syncServerContext(for: iq)
        var rejectsContinuation = false
        if let envelope = ClientSyncPageParser.snapshotEnvelope(
            from: iq, pageSize: trackedRequest.diagnostics.max, namespace: Self.primaryNamespace
        ) {
            guard beginApplyingPage(snapshotStamp: envelope.stamp, request: request,
                                    expectedGeneration: expectedGeneration) else { return true }
            if !envelope.isFinalPage {
                if let token = envelope.nextPageToken,
                   shouldRequestNextSnapshotPage(after: token, currentAfter: request?.after,
                                                 expectedGeneration: expectedGeneration) {
                    stateQueue.sync {
                        guard syncSessionGeneration == expectedGeneration else { return }
                        pendingSnapshotContinuation = (token, expectedGeneration)
                    }
                    drainSnapshotContinuation()
                } else {
                    // Valid records from an accepted page still commit in
                    // order; only its non-advancing continuation is rejected.
                    rejectsContinuation = true
                }
            }
        }
        beforePreparingSyncPage?()
        guard isCurrentSyncSessionGeneration(expectedGeneration) else { return true }
        guard let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: trackedRequest.diagnostics.max,
            namespace: ClientSynchronizationManager.primaryNamespace,
            prepareConversations: { query in
                self.prepareSyncConversations(query, serverContext: serverContext)
            }
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
            _ = resetSyncStateAfterFailure(expectedGeneration: expectedGeneration)
            return true
        }
        guard let duplicateConversationCount = noteReceivedConversationKeys(
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

        let continuationWasRejected = rejectsContinuation
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
                    expectedGeneration: expectedGeneration,
                    isInitialServerSnapshot: trackedRequest.diagnostics.after == nil && serverContext == .accountServer
                )
                guard self.isCurrentSyncSessionGeneration(expectedGeneration) else {
                    self.logSyncTrace("staleSnapshotPageIgnoredAfterApply", [
                        ("id", elementId),
                        ("snapshotStamp", page.stamp)
                    ])
                    return
                }
                let applyFinishedAt = Date()
                if request?.after == nil {
                    self.finishStartupRecentsSync(
                        expectedGeneration: expectedGeneration,
                        appliedFirstPage: serverContext == .accountServer
                    )
                }

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
                        self.markLastRecognizedEventStamp(
                            ClientSyncEventVersion.newest(actions.recognizedEventStamp, page.stamp)
                        )
                        self.firstSync = false
                        self.acountSynced = true
                        self.temporaryVer = nil
                        if !actions.needsCatchUpSync {
                            self.startupSynchronizationPending = false
                        }
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
                    if !actions.needsCatchUpSync {
                        AccountManager.shared.find(for: self.owner)?
                            .startupSynchronizationDidComplete(generation: expectedGeneration)
                    }
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

                guard self.finishApplyingPage(
                    snapshotStamp: page.stamp,
                    isFinalPage: false,
                    expectedGeneration: expectedGeneration
                ) != nil else { return }
                if continuationWasRejected {
                    self.beforeResettingSnapshotFailure?()
                    _ = self.resetSyncStateAfterFailure(expectedGeneration: expectedGeneration)
                    return
                }
                self.drainSnapshotContinuation()
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
    
    private func drainSnapshotContinuation() {
        let continuation = stateQueue.sync { () -> (token: String, generation: UInt64)? in
            guard pendingSnapshotPageCount < maximumPendingSnapshotPages,
                  let pending = pendingSnapshotContinuation,
                  pending.generation == syncSessionGeneration else { return nil }
            pendingSnapshotContinuation = nil
            return pending
        }
        guard let continuation else { return }
        beforeDispatchingSnapshotContinuation?()
        AccountManager.shared.find(for: owner)?.unsafeAction { _, stream in
            _ = self.performSync(stream, customVer: nil, after: continuation.token,
                                 expectedGeneration: continuation.generation)
        }
    }

    /// Sync metadata may describe a replaced archived version only when the IQ
    /// belongs to this account's server. It never supplies decryption provenance.
    private func syncServerContext(for iq: XMPPIQ) -> OMEMOReceiveServerContext {
        guard let account = XMPPJID(string: owner) else { return .unverified }
        if let rawFrom = iq.attributeStringValue(forName: "from") {
            guard let from = XMPPJID(string: rawFrom),
                  from.bare == account.bare ||
                    (from.user == nil && from.resource == nil && from.domain == account.domain) else {
                return .unverified
            }
        }
        if let rawTo = iq.attributeStringValue(forName: "to") {
            guard let to = XMPPJID(string: rawTo), to.bare == account.bare else {
                return .unverified
            }
        }
        return .accountServer
    }

    internal func prepareSyncConversations(
        _ query: DDXMLElement,
        serverContext: OMEMOReceiveServerContext = .unverified
    ) -> [ClientSyncConversationValue] {
        let source = query.elements(forName: "conversation")
        let generation = currentSyncSessionGeneration()
        let context = serverContext == .accountServer ? "server:" : "unverified:"
        let keys = source.map { context + Self.syncFingerprint($0.xmlString) }
        let cache = stateQueue.sync { preparedValues }
        let missing = source.indices.filter { Self.isEncryptedSyncConversation(source[$0]) || cache[keys[$0]] == nil }
        var prepared = cache
        if !missing.isEmpty {
            let subset = DDXMLElement(name: "query", xmlns: Self.primaryNamespace)
            missing.forEach { subset.addChild(source[$0].copy() as! DDXMLElement) }
            let normalized = AccountManager.shared.find(for: owner)?.omemo
                .prepareSyncConversations(subset, serverContext: serverContext)
                ?? missing.map { ClientSyncConversationValue(source[$0]) }
            for (index, preparedValue) in zip(missing, normalized) {
                var value = preparedValue
                value.containsEncryptedWire = Self.isEncryptedSyncConversation(source[index])
                prepared[keys[index]] = value
                // Failed/unverified preparation may become usable after a
                // later bundle/trust event; never cache that failure.
                guard !Self.isEncryptedSyncConversation(source[index]),
                      value.lastMessageEncryption == .plaintext,
                      value.xmlString.utf8.count <= 65_536 else { continue }
                stateQueue.sync {
                    guard syncSessionGeneration == generation else { return }
                    if preparedValues[keys[index]] == nil { preparedValueOrder.append(keys[index]) }
                    preparedValueByteCount -= preparedValues[keys[index]]?.xmlString.utf8.count ?? 0
                    preparedValues[keys[index]] = value
                    preparedValueByteCount += value.xmlString.utf8.count
                    while preparedValueOrder.count > 512 || preparedValueByteCount > 2 * 1024 * 1024 {
                        if let removed = preparedValues.removeValue(forKey: preparedValueOrder.removeFirst()) {
                            preparedValueByteCount -= removed.xmlString.utf8.count
                        }
                    }
                }
            }
        }
        return keys.compactMap { prepared[$0] }
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
            if trackedRequest.diagnostics.after == nil {
                finishStartupRecentsSync(expectedGeneration: trackedRequest.generation, appliedFirstPage: false)
            }
            stateQueue.sync {
                guard syncSessionGeneration == trackedRequest.generation else { return }
                if phase == .idle || phase == .live {
                    phase = .snapshotInProgress
                }
            }
            AccountManager.shared.find(for: owner)?.scheduleStartupSynchronizationRetry()
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
                AccountManager.shared.find(for: owner)?.scheduleStartupSynchronizationRetry()
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
        let didReset = resetSyncSessionWhileLifecycleLocked(expectedGeneration: expectedGeneration)
        syncLifecycleLock.unlock()
        if didReset {
            completeSyncSessionReset()
            notifyStartupRecentsSyncActivityDidChange()
        }
        return didReset
    }

    /// Caller owns syncLifecycleLock; keeps stale-session cancellation and
    /// request registration atomic without recursively acquiring an NSLock.
    private func resetSyncSessionWhileLifecycleLocked(expectedGeneration: UInt64? = nil) -> Bool {
        let didReset = stateQueue.sync {
            if let expectedGeneration,
               self.syncSessionGeneration != expectedGeneration {
                return false
            }
            self.syncSessionGeneration &+= 1
            if self.startupRecentsSyncActivity == .awaitingFirstPage {
                self.startupRecentsSyncActivity = .idle
            }
            self.phase = .idle
            self.activeSnapshotStamp = nil
            self.activeSnapshotRequestedStampMode = nil
            self.requestedSnapshotAfterTokens.removeAll()
            self.seenSnapshotConversationKeys.removeAll()
            self.isApplyingPage = false
            self.needsCatchUpAfterSnapshot = false
            self.pendingSnapshotPageCount = 0
            self.pendingSnapshotContinuation = nil
            self.pendingRecognizedEventStamp = nil
            self.preparedValues.removeAll()
            self.preparedValueOrder.removeAll()
            self.preparedValueByteCount = 0
            self.syncRequestInfoById.removeAll()
            self.startupResponseTimeouts.values.forEach { $0.cancel() }
            self.startupResponseTimeouts.removeAll()
            return true
        }
        if didReset {
            self.queryIds.removeAll()
        }
        return didReset
    }

    private func completeSyncSessionReset() {
        LastChatListSyncPreviewStore.shared.invalidatePreparations(for: owner)
        notifyInitialListSynchronizationTrafficGateDidChange()
    }

    public final func reset() {
        _ = resetSyncSession()
    }

    final func prepareForAuthenticatedStream(didResume: Bool, restoredCheckpoint: Bool = false) {
        if !didResume || restoredCheckpoint {
            reset()
        }
        let didBecomeRecentsReady = stateQueue.sync {
            if !didResume || restoredCheckpoint {
                startupSynchronizationPending = isAvailable && !restoredCheckpoint
            }
            if restoredCheckpoint { initialPresenceSessionState = .sent }
            // An in-process resume can continue an interrupted fallback sync.
            // Only a restored cold checkpoint replaces the first-page witness.
            guard didResume, restoredCheckpoint, !startupRecentsResumeAccepted else { return false }
            startupRecentsResumeAccepted = true
            return !startupRecentsResponseReceived
        }
        if didBecomeRecentsReady { notifyStartupRecentsReadinessDidChange() }
        AccountManager.shared.find(for: owner)?
            .prepareStartupTrafficOrdering(didResume: didResume, restoredCheckpoint: restoredCheckpoint)
        prepareInitialPresenceForAuthenticatedStream(didResume: didResume)
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        ClientSyncRegularConversationDeletionStore.removeAll(for: owner)
        LastChatListSyncPreviewStore.shared.removeAll(for: owner)
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapInProgressKey, value: false)
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapRequestedStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.snapshotBootstrapLastAfterKey, value: "")
    }
}
