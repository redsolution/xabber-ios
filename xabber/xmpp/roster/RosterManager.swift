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

enum RosterSetMutationMode {
    case optimistic
    case acknowledged
}

enum RosterGroupProjectionSynchronizer {
    static func synchronize(
        _ instance: RosterStorageItem,
        groups: [String],
        owner: String,
        realm: Realm
    ) {
        precondition(realm.isInWriteTransaction)
        let desiredGroups = RosterCircleGroups.normalized(groups)
        let desiredKeys = Set(desiredGroups.map(RosterCircleName.key))
        let allGroups = realm.objects(RosterGroupStorageItem.self)
            .filter("owner == %@", owner)
            .toArray()
        var selectedProjectionByKey: [String: RosterGroupStorageItem] = [:]
        desiredGroups.forEach { name in
            let key = RosterCircleName.key(name)
            let candidates = allGroups.filter {
                $0.isSystemGroup == false && RosterCircleName.key($0.name) == key
            }
            let selected = candidates.first(where: { $0.name == name })
                ?? candidates.sorted(by: { $0.primary < $1.primary }).first
            guard let selected else {
                return
            }
            selectedProjectionByKey[key] = selected
        }

        allGroups.forEach { group in
            let shouldContain: Bool
            if group.name == RosterGroupStorageItem.systemGroupName {
                shouldContain = desiredGroups.isEmpty
            } else if group.name == RosterGroupStorageItem.notInRosterGroupName {
                shouldContain = false
            } else {
                let key = RosterCircleName.key(group.name)
                shouldContain = desiredKeys.contains(key)
                    && selectedProjectionByKey[key]?.primary == group.primary
            }

            while let index = group.contacts.firstIndex(where: { $0.primary == instance.primary }),
                  shouldContain == false {
                group.contacts.remove(at: index)
            }
        }

        if desiredGroups.isEmpty {
            let general = realm.object(
                ofType: RosterGroupStorageItem.self,
                forPrimaryKey: RosterGroupStorageItem.genPrimary(
                    name: RosterGroupStorageItem.systemGroupName,
                    owner: owner
                )
            ) ?? {
                let group = RosterGroupStorageItem()
                group.isSystemGroup = true
                group.name = RosterGroupStorageItem.systemGroupName
                group.owner = owner
                group.primary = RosterGroupStorageItem.genPrimary(name: group.name, owner: owner)
                realm.add(group, update: .modified)
                return group
            }()
            if general.contacts.contains(where: { $0.primary == instance.primary }) == false {
                general.contacts.append(instance)
            }
        } else {
            desiredGroups.forEach { name in
                let key = RosterCircleName.key(name)
                let group = selectedProjectionByKey[key] ?? {
                    let group = RosterGroupStorageItem()
                    group.name = name
                    group.owner = owner
                    group.primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
                    realm.add(group, update: .modified)
                    return group
                }()
                if group.contacts.contains(where: { $0.primary == instance.primary }) == false {
                    group.contacts.append(instance)
                }
            }
        }

        deleteEmptyUserGroups(owner: owner, realm: realm)
    }

    static func remove(
        _ instance: RosterStorageItem,
        owner: String,
        realm: Realm
    ) {
        precondition(realm.isInWriteTransaction)
        realm.objects(RosterGroupStorageItem.self)
            .filter("owner == %@", owner)
            .forEach { group in
                while let index = group.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                    group.contacts.remove(at: index)
                }
            }
        deleteEmptyUserGroups(owner: owner, realm: realm)
    }

    private static func deleteEmptyUserGroups(owner: String, realm: Realm) {
        let emptyUserGroups = realm.objects(RosterGroupStorageItem.self)
            .filter("owner == %@ AND isSystemGroup == false", owner)
            .toArray()
            .filter { $0.contacts.isEmpty }
        realm.delete(emptyUserGroups)
    }
}

final class AccountInitialRosterRequestCoordinator {
    struct Configuration {
        let responseTimeout: TimeInterval

        static let production = Configuration(responseTimeout: 5)
    }

    private enum State {
        case idle
        case waiting(id: String)
        case fallbackReleased(id: String)

        var requestId: String? {
            switch self {
            case .idle:
                return nil
            case .waiting(let id), .fallbackReleased(let id):
                return id
            }
        }
    }

    private let configuration: Configuration
    private let scheduler: AccountConnectionResilienceScheduling
    private let onTimeout: (String) -> Void
    private let queue = DispatchQueue(label: "com.xabber.account.initial-roster-request")
    private var state: State = .idle
    private var timer: AccountConnectionResilienceCancellable?
    private var timerGeneration: UInt64 = 0

    init(
        configuration: Configuration = .production,
        scheduler: AccountConnectionResilienceScheduling,
        onTimeout: @escaping (String) -> Void
    ) {
        precondition(configuration.responseTimeout > 0)
        self.configuration = configuration
        self.scheduler = scheduler
        self.onTimeout = onTimeout
    }

    @discardableResult
    func begin(id: String) -> String? {
        queue.sync {
            let supersededId = state.requestId
            cancelTimerLocked()
            state = .waiting(id: id)
            timerGeneration += 1
            let generation = timerGeneration
            timer = scheduler.schedule(after: configuration.responseTimeout) { [weak self] in
                self?.timerDidFire(id: id, generation: generation)
            }
            return supersededId
        }
    }

    @discardableResult
    func complete(id: String) -> Bool {
        queue.sync {
            switch state {
            case .waiting(let currentId) where currentId == id:
                cancelTimerLocked()
                state = .idle
                return true
            case .fallbackReleased(let currentId) where currentId == id:
                state = .idle
                return false
            case .idle, .waiting, .fallbackReleased:
                return false
            }
        }
    }

    @discardableResult
    func reset() -> String? {
        queue.sync {
            let cancelledId = state.requestId
            cancelTimerLocked()
            state = .idle
            return cancelledId
        }
    }

    static func makeQuery(version: String?) -> DDXMLElement {
        let query = DDXMLElement(name: "query", xmlns: "jabber:iq:roster")
        if let normalizedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines),
           normalizedVersion.isEmpty == false {
            query.addAttribute(withName: "ver", stringValue: normalizedVersion)
        }
        return query
    }

    private func timerDidFire(id: String, generation: UInt64) {
        let shouldNotify = queue.sync { () -> Bool in
            guard generation == timerGeneration,
                  case .waiting(let currentId) = state,
                  currentId == id else {
                return false
            }
            timer = nil
            state = .fallbackReleased(id: id)
            return true
        }
        if shouldNotify {
            onTimeout(id)
        }
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
    }
}

class RosterManager: AbstractXMPPManager {
    
    class QueueItem: Hashable {
        static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        enum Action {
            case add
            case delete
        }
        
        var action: Action
        var elementId: String
        var value: String
        var callback: ((String?, String?, Bool) -> Void)?
        var mutationMode: RosterSetMutationMode
        var groups: [String]
        var nickname: String?
        var timeout: AccountConnectionResilienceCancellable?
        
        init(
            _ action: Action,
            elementId: String,
            value: String,
            mutationMode: RosterSetMutationMode = .optimistic,
            groups: [String] = [],
            nickname: String? = nil,
            callback: ((String?, String?, Bool) -> Void)? = nil
        ) {
            self.action = action
            self.elementId = elementId
            self.callback = callback
            self.value = value
            self.mutationMode = mutationMode
            self.groups = groups
            self.nickname = nickname
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    internal var version: String? = nil
    
    internal var queueItems: SynchronizedArray<QueueItem> = SynchronizedArray<QueueItem>()
    private let mutationQueueLock = NSLock()
    internal var isInitialRosterReceived: Bool = false
    private let initialRosterScheduler: AccountConnectionResilienceScheduling
    private lazy var initialRosterRequestCoordinator = AccountInitialRosterRequestCoordinator(
        scheduler: initialRosterScheduler,
        onTimeout: { [weak self] elementId in
            self?.initialRosterRequestDidTimeout(elementId)
        }
    )
    private var needsInitialRosterRetryAfterResume = false
    
    override func namespaces() -> [String] {
        return ["jabber:iq:roster", ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    override init(withOwner owner: String) {
        self.initialRosterScheduler = DispatchAccountConnectionResilienceScheduler(
            queue: DispatchQueue(label: "com.xabber.roster.initial-timeout.\(owner)")
        )
        super.init(withOwner: owner)
        version = SettingManager.shared.getKey(for: owner, scope: .roster, key: "version")
    }

    init(
        withOwner owner: String,
        initialRosterScheduler: AccountConnectionResilienceScheduling
    ) {
        self.initialRosterScheduler = initialRosterScheduler
        super.init(withOwner: owner)
        version = SettingManager.shared.getKey(for: owner, scope: .roster, key: "version")
    }
    
    open func request(_ xmppStream: XMPPStream) {
        needsInitialRosterRetryAfterResume = false
        isInitialRosterReceived = false
        let elementId = xmppStream.generateUUID
        let query = AccountInitialRosterRequestCoordinator.makeQuery(version: version)
        if let supersededId = initialRosterRequestCoordinator.begin(id: elementId) {
            queryIds.remove(supersededId)
        }
        queryIds.insert(elementId)
        xmppStream.send(XMPPIQ(iqType: .get, elementID: elementId, child: query))
    }
    
    static let acknowledgedMutationTimeoutError = "timeout"

    static func makeSetContactQuery(
        jid: String,
        nickname: String?,
        groups: [String]
    ) -> DDXMLElement {
        let query = DDXMLElement(name: "query", xmlns: "jabber:iq:roster")
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        if let nickname {
            item.addAttribute(withName: "name", stringValue: nickname)
        }
        RosterCircleGroups.normalized(groups)
            .map { DDXMLElement(name: "group", stringValue: $0) }
            .forEach(item.addChild)
        query.addChild(item)
        return query
    }

    open func setContact(
        _ xmppStream: XMPPStream,
        jid: String,
        getNickFromVCard: Bool = false,
        nickname preferredNickname: String? = nil,
        groups: [String] = [],
        shouldAddSystemMessage: Bool = false,
        mutationMode: RosterSetMutationMode = .optimistic,
        responseTimeout: TimeInterval = 15,
        callback: ((String?, String?, Bool) -> Void)? = nil
    ) {
        do {
            let realm = try  WRealm.safe()

            let elementId = xmppStream.generateUUID
            var nickname = preferredNickname
            if getNickFromVCard {
                if let vcard = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                    nickname = vcard.unsafeGeneratedNickname
                }
            }
            
            let displayNick = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))?.displayName
            let normalizedGroups = RosterCircleGroups.normalized(groups)
            let outgoingNickname = mutationMode == .acknowledged
                ? nickname
                : (nickname ?? displayNick)
            let query = Self.makeSetContactQuery(
                jid: jid,
                nickname: outgoingNickname,
                groups: normalizedGroups
            )
            queryIds.insert(elementId)
            let queueItem = QueueItem(
                .add,
                elementId: elementId,
                value: jid,
                mutationMode: mutationMode,
                groups: normalizedGroups,
                nickname: preferredNickname,
                callback: callback
            )
            insertMutationQueueItem(queueItem)
            if mutationMode == .acknowledged {
                queueItem.timeout = initialRosterScheduler.schedule(after: responseTimeout) { [weak self] in
                    self?.acknowledgedMutationDidTimeout(elementId: elementId)
                }
            }
            xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))

            if mutationMode == .optimistic {
                _ = applyLocalSetContact(jid: jid, nickname: preferredNickname, groups: normalizedGroups)
            }
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
            callback?(jid, error.localizedDescription, false)
        }
    }
    
    open func removeContact(_ xmppStream: XMPPStream, jid: String, callback: ((String?, String?, Bool) -> Void)? = nil ) {
        let elementId = xmppStream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "jid", stringValue: jid)
        item.addAttribute(withName: "subscription", stringValue: "remove")
        query.addChild(item)
        xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
        queryIds.insert(elementId)
        insertMutationQueueItem(QueueItem(.delete, elementId: elementId, value: jid, callback: callback))
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner)) {
                try realm.write {
                    instance.subscribtion = .undefined
                    instance.ask = .none
                }
            }
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readError(iq): return true
        case readSuccess(iq): return true
        case readResponse(iq): return true
        default: return false
        }
    }
    
    internal func readSuccess(_ iq: XMPPIQ) -> Bool {
        guard let query = iq.element(forName: "query", xmlns: getPrimaryNamespace()),
            let elementId = iq.elementID else {
            return false
        }

        let isRosterPush = iq.iqType == .set
        if isRosterPush == false {
            guard queryIds.contains(elementId) else { return false }
            queryIds.remove(elementId)
        } else if queryIds.contains(elementId) {
            queryIds.remove(elementId)
        }
        
        if isRosterPush {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.presence()
            })
        }
        var rosterApplySucceeded = true
        do {
            let realm = try  WRealm.safe()
            
            let removedJids = query.elements(forName: "item").compactMap { item -> String? in
                guard item.attributeStringValue(
                    forName: "subscription",
                    withDefaultValue: "none"
                ) == "remove" else {
                    return nil
                }
                return item.attributeStringValue(forName: "jid")
            }
            var removedGroupParticipantIds: [String: [String]] = [:]
            removedJids.forEach { jid in
                let groupPrimary = GroupStorageKey.groupPrimary(
                    owner: owner,
                    groupJID: jid
                )
                if realm.object(
                    ofType: GroupSnapshotStorageItem.self,
                    forPrimaryKey: groupPrimary
                ) != nil {
                    let participantIds = Array(
                        realm.objects(GroupMemberStorageItem.self)
                            .filter("groupPrimary == %@", groupPrimary)
                            .map(\.memberID)
                            .filter { !$0.isEmpty }
                    )
                    removedGroupParticipantIds[jid] = participantIds
                }
            }

            try realm.write {
                query.elements(forName: "item").forEach { item in
                    guard let jid = item.attributeStringValue(forName: "jid") else { return }
                    let subscribtion = item.attributeStringValue(forName: "subscription", withDefaultValue: "none")
                    if subscribtion == "remove" {
                        if let instance = realm.object(ofType: RosterStorageItem.self,
                                                       forPrimaryKey: [jid, owner].prp()) {
                            RosterGroupProjectionSynchronizer.remove(
                                instance,
                                owner: owner,
                                realm: realm
                            )
                            instance.associatedLastChat?.rosterItem = nil
                            
                            realm.delete(instance)
                            
                            if let preaprovedSubscribtionInstance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
                                                                                 forPrimaryKey: PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)) {
                                realm.delete(preaprovedSubscribtionInstance)
                            }
                            if removedGroupParticipantIds[jid] == nil {
                                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.75) {
                                    do {
                                        let realm = try  WRealm.safe()
                                        
                                        if let authMessage = realm.object(
                                            ofType: MessageStorageItem.self,
                                            forPrimaryKey: MessageStorageItem.genPrimary(
                                                messageId: MessageStorageItem.messageIdForAuthRequest(jid: jid),
                                                owner: self.owner
                                            )
                                        ) {
                                            let lastMessageForChat = realm
                                                .objects(MessageStorageItem.self)
                                                .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, jid, ClientSynchronizationManager.ConversationType.omemo.rawValue)
                                                .sorted(byKeyPath: "date", ascending: true).last
                                            try realm.write {
                                                realm.delete(authMessage)
                                                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: .omemo))?.lastMessage = lastMessageForChat
                                            }
                                        }
                                    } catch {
                                        DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
                                    }
                                }
                            }
                        }
                    } else if let instance = realm.object(ofType: RosterStorageItem.self,
                                                          forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                        instance.owner = owner
                        instance.customUsername = item.attributeStringValue(forName: "name", withDefaultValue: "")
                        instance.subscription_ = subscribtion
//                        SharedRosterUtils.setUsername(jid: jid, owner: owner, username: instance.displayName)
//                        instance.ask_ = item.attributeStringValue(forName: "ask", withDefaultValue: "none")
                        if let ask = item.attributeStringValue(forName: "ask") {
                            if ask == "subscribe" {
                                instance.ask = .out
                            }
                        } else {
                            instance.ask = .none
                            if let notifyInstance = realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: UINotificationStorageItem.genPrimary(owner: jid, jid: owner)) {
                                realm.delete(notifyInstance)
                            }
                        }
                        if let approved = item.attributeStringValue(forName: "approved"),
                           approved == "true" {
                            instance.approved = true
                        } else {
                            instance.approved = false
                        }
                        instance.groups.removeAll()
                        let groups = item.elements(forName: "group").compactMap{ return $0.stringValue }
                        instance.groups.removeAll()
                        instance.groups.append(objectsIn: groups)
                        RosterGroupProjectionSynchronizer.synchronize(
                            instance,
                            groups: groups,
                            owner: owner,
                            realm: realm
                        )
                        realm
                            .objects(LastChatsStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, jid)
                            .forEach {
                            $0.rosterItem = instance
                        }
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    } else {
//                        DefaultAvatarManager.shared.updateAvatarIfNeeded(for: jid, owner: owner)
                        let instance = RosterStorageItem()
                        instance.owner = owner
                        instance.jid = jid
                        instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                        instance.customUsername = item.attributeStringValue(forName: "name", withDefaultValue: "")
                        instance.subscription_ = subscribtion
                        if let ask = item.attributeStringValue(forName: "ask") {
                            if ask == "subscribe" {
                                instance.ask = .out
                            }
                        } else {
                            instance.ask = .none
                        }
                        if let approved = item.attributeStringValue(forName: "approved"),
                           approved == "true" {
                            instance.approved = true
                        } else {
                            instance.approved = false
                        }
//                        instance.ask_ = item.attributeStringValue(forName: "ask", withDefaultValue: "none")
                        instance.groups.removeAll()
                        let groups = item.elements(forName: "group").compactMap{ return $0.stringValue }
                        instance.groups.append(objectsIn: groups)
//                        instance.associatedLastChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(
//                            jid: ,
//                            owner: ,
//                            conversationType:
//                        ))
                        realm.add(instance, update: .modified)
                        
                        RosterGroupProjectionSynchronizer.synchronize(
                            instance,
                            groups: groups,
                            owner: owner,
                            realm: realm
                        )
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
                        RosterDisplayNameStorageItem.createOrUpdate(
                            jid: jid,
                            owner: self.owner,
                            displayName: item.attributeStringValue(forName: "name", withDefaultValue: ""),
                            commitTransaction: false
                        )
                        realm
                            .objects(LastChatsStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, jid)
                            .forEach {
                            $0.rosterItem = instance
                        }
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    }
                }
            }
            removedJids.forEach { jid in
                CommonContactsMetadataManager.shared.remove(owner: owner, jid: jid)
                if let participantIds = removedGroupParticipantIds[jid] {
                    DefaultAvatarManager.shared.invalidatePushAvatarSnapshots(
                        owner: owner,
                        groupchat: jid,
                        participantIds: participantIds
                    )
                }
            }
            
        } catch {
            rosterApplySucceeded = false
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
        }
        
        if let item = takeMutationQueueItem(elementId: elementId) {
            var mutationSucceeded = rosterApplySucceeded
            var mutationError: String?
            if item.mutationMode == .acknowledged,
               query.elements(forName: "item").isEmpty,
               mutationSucceeded {
                mutationSucceeded = applyLocalSetContact(
                    jid: item.value,
                    nickname: item.nickname,
                    groups: item.groups
                )
            }
            if item.mutationMode == .acknowledged, mutationSucceeded == false {
                mutationError = "local-storage-error"
            }
            item.callback?(item.value, mutationError, mutationSucceeded)
        }
        if iq.iqType == .set { return true }
        resolveRosterVersion(
            serverVersion: query.attributeStringValue(forName: "ver"),
            rosterApplySucceeded: rosterApplySucceeded
        )

        completeInitialRosterRequestIfNeeded(
            elementId,
            reason: rosterApplySucceeded ? "resultApplied" : "storageFallback"
        )

        return true
    }
    
    internal func readError(_ iq: XMPPIQ) -> Bool {
        guard let errorElement = iq.element(forName: "error"),
            let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        completeInitialRosterRequestIfNeeded(elementId, reason: "errorFallback")
        
        let error = errorElement.children?
            .compactMap { $0 as? DDXMLElement }
            .first(where: { $0.name != "text" })?
            .name ?? "stanza-error"
        if let item = takeMutationQueueItem(elementId: elementId) {
            item.callback?(item.value, error,false)
        }
        return true
    }
    
    internal func readResponse(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
            queryIds.contains(elementId) else {
                return false
        }
        queryIds.remove(elementId)
        completeInitialRosterRequestIfNeeded(elementId, reason: "emptyResult")
        if let item = takeMutationQueueItem(elementId: elementId) {
            let localApplySucceeded = item.mutationMode == .acknowledged
                ? applyLocalSetContact(jid: item.value, nickname: item.nickname, groups: item.groups)
                : true
            item.callback?(
                item.value,
                localApplySucceeded ? nil : "local-storage-error",
                localApplySucceeded
            )
        }
        return true
    }

    private func insertMutationQueueItem(_ item: QueueItem) {
        mutationQueueLock.lock()
        queueItems.insert(item)
        mutationQueueLock.unlock()
    }

    private func takeMutationQueueItem(elementId: String) -> QueueItem? {
        mutationQueueLock.lock()
        defer { mutationQueueLock.unlock() }
        guard let item = queueItems.first(where: { $0.elementId == elementId }) else {
            return nil
        }
        queueItems.remove(item)
        item.timeout?.cancel()
        item.timeout = nil
        return item
    }

    @discardableResult
    private func applyLocalSetContact(
        jid: String,
        nickname: String?,
        groups: [String]
    ) -> Bool {
        do {
            let realm = try WRealm.safe()
            let primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
            let normalizedGroups = RosterCircleGroups.normalized(groups)
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: primary) {
                try realm.write {
                    instance.groups.removeAll()
                    instance.groups.append(objectsIn: normalizedGroups)
                    instance.customUsername = nickname ?? ""
                    RosterGroupProjectionSynchronizer.synchronize(
                        instance,
                        groups: normalizedGroups,
                        owner: owner,
                        realm: realm
                    )
                }
            } else {
                let instance = RosterStorageItem()
                instance.jid = jid
                instance.owner = owner
                instance.customUsername = nickname ?? ""
                instance.primary = primary
                instance.subscribtion = .none
                instance.associatedLastChat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: ClientSynchronizationManager.ConversationType(
                            rawValue: CommonConfigManager.shared.config.locked_conversation_type
                        ) ?? .regular
                    )
                )
                try realm.write {
                    realm.add(instance, update: .modified)
                    instance.groups.append(objectsIn: normalizedGroups)
                    RosterGroupProjectionSynchronizer.synchronize(
                        instance,
                        groups: normalizedGroups,
                        owner: owner,
                        realm: realm
                    )
                }
            }
            return true
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func acknowledgedMutationDidTimeout(elementId: String) {
        guard let item = takeMutationQueueItem(elementId: elementId),
              item.mutationMode == .acknowledged else {
            return
        }
        queryIds.remove(elementId)
        item.callback?(
            item.value,
            Self.acknowledgedMutationTimeoutError,
            false
        )
    }

    private func completeInitialRosterRequestIfNeeded(_ elementId: String, reason: String) {
        guard initialRosterRequestCoordinator.complete(id: elementId) else { return }
        finishInitialRosterRequest(reason: reason)
    }

    private func initialRosterRequestDidTimeout(_ elementId: String) {
        guard queryIds.contains(elementId),
              let account = AccountManager.shared.find(for: owner),
              account.xmppStream.isAuthenticated,
              account.sm.didResume == false else {
            return
        }
        finishInitialRosterRequest(reason: "timeoutFallback")
    }

    private func finishInitialRosterRequest(reason: String) {
        isInitialRosterReceived = true
        guard let account = AccountManager.shared.find(for: owner) else { return }
        account.logConnectionDiagnostics(
            event: "initial_roster_resolved",
            details: ["reason": reason]
        )
        account.didReceiveRoster()
    }

    internal func resolveRosterVersion(serverVersion: String?, rosterApplySucceeded: Bool) {
        guard rosterApplySucceeded else {
            version = nil
            SettingManager.shared.removeItem(for: owner, scope: .roster, key: "version")
            return
        }
        guard let serverVersion else { return }
        version = serverVersion
        SettingManager.shared.saveItem(for: owner, scope: .roster, key: "version", value: serverVersion)
    }

    func clearInitialRosterSession() {
        if let cancelledId = initialRosterRequestCoordinator.reset() {
            needsInitialRosterRetryAfterResume = true
            queryIds.remove(cancelledId)
        }
        isInitialRosterReceived = false
    }

    @discardableResult
    func retryInitialRosterAfterResumeIfNeeded(_ xmppStream: XMPPStream) -> Bool {
        guard needsInitialRosterRetryAfterResume else { return false }
        request(xmppStream)
        AccountManager.shared.find(for: owner)?.logConnectionDiagnostics(
            event: "initial_roster_retry_after_sm_resume"
        )
        return true
    }
    
    
    static func remove(for owner: String, commitTransaction: Bool) {
        SettingManager.shared.removeItem(for: owner, scope: .roster, key: "version")
        do {
            let realm = try  WRealm.safe()
            let items = realm.objects(RosterStorageItem.self).filter("owner == %@", owner)
            let groups = realm.objects(RosterGroupStorageItem.self).filter("owner == %@", owner)
            let displayNames = realm.objects(RosterDisplayNameStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(items)
                        realm.delete(groups)
                        realm.delete(displayNames)
                    }
                }
            } else {
                realm.delete(items)
            }
        } catch {
            DDLogDebug("cant delete roster for \(owner)")
        }
    }
}
