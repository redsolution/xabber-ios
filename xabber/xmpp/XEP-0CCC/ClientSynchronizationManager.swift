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

struct ClientSyncPageParser {
    struct SnapshotPage {
        let stamp: String
        let isFinalPage: Bool
        let nextPageToken: String?
        let conversations: [DDXMLElement]
    }

    static func parseSnapshotPage(from iq: XMPPIQ, pageSize: Int, namespace: String, updateOmemo: (DDXMLElement) -> DDXMLElement) -> SnapshotPage? {
        guard let query = iq.element(forName: "query", xmlns: namespace),
              let stamp = query.attributeStringValue(forName: "stamp") else {
            return nil
        }
        let normalizedQuery = updateOmemo(query)
        let conversations = normalizedQuery.elements(forName: "conversation").compactMap { $0.copy() as? DDXMLElement }
        let nextPageToken = normalizedQuery
            .element(forName: "set")?
            .element(forName: "last")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNextPageToken = nextPageToken?.isNotEmpty == true
        let isFinalPage = conversations.isEmpty || conversations.count < pageSize || !hasNextPageToken
        return SnapshotPage(
            stamp: stamp,
            isFinalPage: isFinalPage,
            nextPageToken: hasNextPageToken ? nextPageToken : nil,
            conversations: conversations
        )
    }
}

struct ClientSyncPageApplier {
    struct ApplyResult {
        let queueItems: Set<MessageManager.MessageQueueItem>
        let detectedInvite: Bool
    }

    static func apply(
        realm: Realm,
        conversations: [DDXMLElement],
        accountCreateDate: Date?,
        applyConversationState: (DDXMLElement, Realm) -> Bool,
        readInvites: (DDXMLElement, Realm) -> Bool,
        readConversation: (DDXMLElement, Realm, Date?) -> MessageManager.MessageQueueItem?,
        readMarkers: (DDXMLElement, Realm) -> Void,
        readPresence: (DDXMLElement, Realm) -> Void
    ) throws -> ApplyResult {
        var queueItems = Set<MessageManager.MessageQueueItem>()
        var detectedInvite = false
        try realm.write {
            conversations.forEach { conversation in
                guard applyConversationState(conversation, realm) else {
                    return
                }
                if readInvites(conversation, realm) {
                    detectedInvite = true
                }
                if let item = readConversation(conversation, realm, accountCreateDate) {
                    queueItems.insert(item)
                }
                readMarkers(conversation, realm)
                readPresence(conversation, realm)
            }
        }
        return ApplyResult(queueItems: queueItems, detectedInvite: detectedInvite)
    }
}

class ClientSynchronizationManager: AbstractXMPPManager {
    private struct SyncUnreadState {
        let count: Int
        let afterId: String?
        let lastMessageArchiveId: String?
    }

    enum SyncPhase {
        case idle
        case snapshotInProgress
        case catchingUp
        case live
    }
    
    public let pageSize: Int = 60
    
    open var isAvailable: Bool = false
    open var version: String = ""
    private var temporaryVer: String? = nil
    private let syncQueryIds = SynchronizedArray<String>()
    private let applyQueue = DispatchQueue(label: "com.xabber.client-sync.apply")
    private let stateQueue = DispatchQueue(label: "com.xabber.client-sync.state")
    private var phase: SyncPhase = .idle
    private var activeSnapshotStamp: String? = nil
    private var isApplyingPage: Bool = false
    private var shouldRequestInviteFallbackAfterSnapshot: Bool = false
    
    internal var isPresenceSended: Bool = false
    
    internal var acountSynced: Bool = false
    private var ignorePush: Bool = false
    
    internal var firstSync: Bool = true
    internal var beforeApplyingSyncPayload: (() throws -> Void)?
    
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
        version = lastRecognizedEventStamp ?? SettingManager.shared.getKey(for: owner, scope: .clientSynchronization, key: "version") ?? ""
        if version.isEmpty {
            SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "0")
        }
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

    private func updateStoredVersion(_ stamp: String) {
        version = stamp
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: stamp)
    }

    private func markLastRecognizedEventStamp(_ stamp: String) {
        lastRecognizedEventStamp = stamp
        updateStoredVersion(stamp)
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
                shouldRequestInviteFallbackAfterSnapshot = false
                return true
            case .snapshotInProgress, .catchingUp:
                return false
            }
        }
    }

    private func updatePhase(_ phase: SyncPhase) {
        stateQueue.sync {
            self.phase = phase
        }
    }

    private func registerSyncQuery(_ elementId: String) {
        queryIds.insert(elementId)
        syncQueryIds.insert(elementId)
    }

    private func unregisterSyncQuery(_ elementId: String) {
        queryIds.remove(elementId)
        syncQueryIds.remove(elementId)
    }

    private func resetSyncStateAfterFailure() {
        stateQueue.sync {
            phase = .idle
            activeSnapshotStamp = nil
            isApplyingPage = false
            shouldRequestInviteFallbackAfterSnapshot = false
        }
        temporaryVer = nil
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

    private func applySyncPayload(
        conversations: [DDXMLElement],
        accountCreateDate: Date?
    ) throws -> Bool {
        try beforeApplyingSyncPayload?()
        let realm = try WRealm.safe()
        let result = try ClientSyncPageApplier.apply(
            realm: realm,
            conversations: conversations,
            accountCreateDate: accountCreateDate,
            applyConversationState: self.readConversationMetadata(_:realm:),
            readInvites: self.readInvites(_:realm:),
            readConversation: self.readConversation(_:realm:accountCreateDate:),
            readMarkers: self.readMessageMarkers(_:realm:),
            readPresence: self.readPresence(_:realm:)
        )
        processQueueItems(result.queueItems)
        return result.detectedInvite
    }

    private func beginApplyingPage(snapshotStamp: String) {
        stateQueue.sync {
            isApplyingPage = true
            if activeSnapshotStamp == nil {
                activeSnapshotStamp = snapshotStamp
            }
        }
    }

    private func finishApplyingPage(snapshotStamp: String, isFinalPage: Bool) -> Bool {
        stateQueue.sync {
            isApplyingPage = false
            if isFinalPage {
                activeSnapshotStamp = nil
                phase = .live
                return shouldRequestInviteFallbackAfterSnapshot
            } else {
                phase = .catchingUp
                return false
            }
        }
    }

    private func noteInviteFallbackNeeded() {
        stateQueue.sync {
            shouldRequestInviteFallbackAfterSnapshot = true
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
    
    open func sync(_ xmppStream: XMPPStream, customVer: String? = nil, after: String? = nil) -> Bool {
        if !isAvailable || !canStartSync(after: after) { return false }
        acountSynced = false
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: ClientSynchronizationManager.primaryNamespace)
        if let customVer = customVer,
           customVer.isNotEmpty {
            query.addAttribute(withName: "stamp", stringValue: customVer)
        } else if let lastRecognizedEventStamp, lastRecognizedEventStamp.isNotEmpty {
            query.addAttribute(withName: "stamp", stringValue: lastRecognizedEventStamp)
        } else if version.isNotEmpty {
            query.addAttribute(withName: "stamp", stringValue: version)
        }
        let set = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        set.addChild(DDXMLElement(name: "max", stringValue: "\(pageSize)"))
        if let after = after {
            set.addChild(DDXMLElement(name: "after", stringValue: after))
        }
        query.addChild(set)
        xmppStream.send(XMPPIQ(iqType: .get,
                               to: nil,
                               elementID: elementId,
                               child: query))
        registerSyncQuery(elementId)
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
                    self.queryIds.insert(elementId)
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
                    self.queryIds.insert(elementId)
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
            self.queryIds.insert(elementId)
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
            let shouldRunInviteFallback = try applySyncPayload(
                conversations: query.elements(forName: "conversation"),
                accountCreateDate: accountCreateDate
            )
            markLastRecognizedEventStamp(stamp)
            if shouldRunInviteFallback {
                AccountManager.shared.find(for: owner)?.groupchats.getInvitesFallback()
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
                            let savedMessages = realm.objects(MessageStorageItem.self).filter("owner == %@ AND conversationType_ == %@", owner, ClientSynchronizationManager.ConversationType.saved.rawValue)
                            
                            realm.delete(savedMessages)
                            
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
    
//    <iq xmlns="jabber:client" lang="ru" to="igor.boldin@redsolution.com/xabber-ios-3F02F22F" from="igor.boldin@redsolution.com" type="result" id="EF06FF8B-BC20-4215-A7C5-CC9675DC5366">
//      <synchronization xmlns="https://xabber.com/protocol/synchronization" stamp="1594109688793236">
//        <set xmlns="http://jabber.org/protocol/rsm">
//          <count>82</count>
//        </set>
//      </synchronization>
//    </iq>
    
    internal func readSnapshot(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result else {
            return false
        }
        guard let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: self.pageSize,
            namespace: ClientSynchronizationManager.primaryNamespace,
            updateOmemo: updateOmemoMessages(_:)
        ) else {
                return false
        }
        if let elementId = iq.elementID {
            unregisterSyncQuery(elementId)
        }

        AccountManager.shared.changeNewUserState(for: self.owner, to: .dataLoaded)
        beginApplyingPage(snapshotStamp: page.stamp)

        if !isPresenceSended && self.version.isNotEmpty {
            isPresenceSended = true
            AccountManager
                .shared
                .find(for: owner)?
                .unsafeAction { (user, stream) in
                    user.msgDeleteManager.enable(stream)
                    if !user.sm.didResume {
                        user.presence()
                    }
                }
        }
        applyQueue.async {
            do {
                let accountCreateDate = try WRealm.safe().object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.createdAt
                let detectedInvite = try self.applySyncPayload(
                    conversations: page.conversations,
                    accountCreateDate: accountCreateDate
                )
                if detectedInvite {
                    self.noteInviteFallbackNeeded()
                }

                if !page.isFinalPage, let nextPageToken = page.nextPageToken {
                    AccountManager.shared.find(for: self.owner)?.unsafeAction { _, stream in
                        _ = self.sync(stream, after: nextPageToken)
                    }
                }

                let shouldRunInviteFallback = self.finishApplyingPage(snapshotStamp: page.stamp, isFinalPage: page.isFinalPage)
                if page.isFinalPage {
                    self.lastCompletedSnapshotStamp = page.stamp
                    self.markLastRecognizedEventStamp(page.stamp)
                    self.firstSync = false
                    self.acountSynced = true
                    self.temporaryVer = nil
                    AccountManager.shared.find(for: self.owner)?.unsafeAction({ (user, stream) in
                        user.csi.active(stream, by: .synchronization)
                    })
                    if shouldRunInviteFallback {
                        AccountManager.shared.find(for: self.owner)?.groupchats.getInvitesFallback()
                    }
                }
            } catch {
                _ = self.finishApplyingPage(snapshotStamp: page.stamp, isFinalPage: page.isFinalPage)
                self.resetSyncStateAfterFailure()
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
    internal func readInvites(_ conversation: DDXMLElement, realm: Realm) -> Bool {
        let timestamp = conversation.attributeDoubleValue(forName: "stamp")
        if let messageElement = conversation.elements(forName: "metadata").first(where: { $0.attributeStringValue(forName: "node") == "https://xabber.com/protocol/synchronization" })?.element(forName: "last-message")?.element(forName: "message"),
            (AccountManager.shared.find(for: owner)?.groupchats.isInvite(XMPPMessage(from: messageElement.copy() as! DDXMLElement)) ?? false) {
            let inviteMessage = XMPPMessage(from: messageElement.copy() as! DDXMLElement)
            let uniqueId = getUniqueMessageId(inviteMessage, owner: self.owner)
            if uniqueId.isNotEmpty,
               realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: [uniqueId, owner].prp()) != nil {
                conversation.removeAttribute(forName: "jid")
                return false
            }
            if AccountManager
                .shared
                .find(for: owner)?
                .groupchats
                .readInvite(in: inviteMessage,
                            date: Date(timeIntervalSince1970: timestamp / 1000000), isRead: false, commit: false) ?? false {
                conversation.removeAttribute(forName: "jid")
                return true
            }
        }
        return false
    }
    
    internal func readConversation(_ conversation: DDXMLElement, realm: Realm, accountCreateDate: Date? = nil) -> MessageManager.MessageQueueItem? {
        guard let jid = conversation.attributeStringValue(forName: "jid"),
              jid.isNotEmpty else {
            return nil
        }
        
        let conversationStatus = conversation.attributeStringValue(forName: "status") ?? "active"
        
        let conversationType = ConversationType(rawValue: conversation.attributeStringValue(forName: "type") ?? "none") ?? .regular
        
        if conversationType == .notifications {
            return nil
        }
        
        if XMPPJID(string: jid)?.isServer ?? false {
            return nil
        }
        
        if jid == AccountManager.shared.find(for: self.owner)?.notifications.node {
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

            
            
            
            
            if let messageElement = metadata.element(forName: "last-message")?.element(forName: "message") {
                if (AccountManager.shared.find(for: owner)?.groupchats.isInvite(XMPPMessage(from: messageElement)) ?? false) {
                    return nil
                }
            }
            
            let isNewChatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType)
            ) == nil
            
            let instance = try getChat(realm, jid: jid, conversationType: conversationType)
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
            instance.lastReadId = metadata.element(forName: "unread")?.attributeStringValue(forName: "after")
            instance.unread = metadata.element(forName: "unread")?.attributeIntegerValue(forName: "count") ?? 0
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

                    if realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: jid, owner: owner)) == nil {
                        let groupchatStorageItem = GroupChatStorageItem()
                        groupchatStorageItem.jid = jid
                        groupchatStorageItem.owner = owner
                        groupchatStorageItem.primary = GroupChatStorageItem.genPrimary(jid: jid, owner: owner)
                        groupchatStorageItem.members = 1
                        realm.add(groupchatStorageItem, update: .modified)
                    }
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
            if let card = userCard {
                _ = AccountManager
                    .shared
                    .find(for: owner)?
                    .groupchats
                    .updateUserCard(card,
                                    myCard: true,
                                    groupchat: jid,
                                    trustedSource: true,
                                    messageAction: nil,
                                    commitTransaction: false)
            }
            
            if conversationType.isEncrypted,
               metadata.element(forName: "last-message")?.element(forName: "message") == nil {
                instance.isFreshNotEmptyEncryptedChat = true
                instance.isSynced = false//!firstSync
            }
            if let messageElement {
                if let date = getDeliveryDate(XMPPMessage(from: messageElement)) {
                    if conversationType.isEncrypted, let accountCreateDate = accountCreateDate {
                        if date.timeIntervalSince1970 < accountCreateDate.timeIntervalSince1970 {
                            instance.isFreshNotEmptyEncryptedChat = true
                            instance.isSynced = false//!firstSync
                            instance.lastMessageId = getOriginId(XMPPMessage(from: messageElement)) ?? XMPPMessage(from: messageElement).elementID ?? getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
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
                if ((AccountManager.shared.find(for: self.owner)?.groupchats.readMessage(withMessage: messageElement as! XMPPMessage, commitTransaction: false)) ?? false) {
                    return nil
                }
                let stanzaId = getStanzaId(XMPPMessage(from: messageElement), owner: self.owner)
                var state: MessageStorageItem.MessageSendingState = .sended
                if unreadAfterTS == messageSyncStamp {
                    state = .read
                } else if instance.deliveredId == stanzaId {
                    state = .deliver
                }
                let readDate = state != .read ? nil : Date(timeIntervalSince1970: stamp / 1000000)
                
                if !(AccountManager
                        .shared
                        .find(for: owner)?
                        .groupchats
                        .isInvite(XMPPMessage(from: messageElement)) ?? false) {
                    let messageStanza = XMPPMessage(from: messageElement)
                    guard let from = messageStanza.from?.bare,
                          let to = messageStanza.to?.bare,
                          [self.owner, jid].contains(from),
                          [self.owner, jid].contains(to) else {
                        return nil
                    }
                    if instance.lastMessageId != getUniqueMessageId(messageStanza, owner: self.owner) {
                        instance.isSynced = false//!firstSync
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
                }
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
              iq.iqType == .error,
              queryIds.contains(elementId) else {
            return false
        }
        let isSyncQuery = syncQueryIds.contains(elementId)
        queryIds.remove(elementId)
        if isSyncQuery {
            unregisterSyncQuery(elementId)
            resetSyncStateAfterFailure()
        }
        return true
    }
    
    internal func readResult(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.iqType == .result,
              queryIds.contains(elementId) else { // BAD ACCESS
                return false
        }
        let isSyncQuery = syncQueryIds.contains(elementId)
        queryIds.remove(elementId)
        if isSyncQuery {
            unregisterSyncQuery(elementId)
            resetSyncStateAfterFailure()
        }
        return true
    }
    
    public final func isSynced() -> Bool {
        if isAvailable {
            return acountSynced
        }
        return true
    }
    
    public final func reset() {
        self.queryIds.removeAll()
        self.syncQueryIds.removeAll()
        self.isPresenceSended = false
        stateQueue.sync {
            self.phase = .idle
            self.activeSnapshotStamp = nil
            self.isApplyingPage = false
            self.shouldRequestInviteFallbackAfterSnapshot = false
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: "version", value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastRecognizedEventStampKey, value: "")
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization, key: ClientSynchronizationManager.lastCompletedSnapshotStampKey, value: "")
    }
}
