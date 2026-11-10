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
        let batch = Batch(owner: owner, realm: realm)
        batch.synchronize(instance, groups: groups)
        batch.finish()
    }

    static func remove(
        _ instance: RosterStorageItem,
        owner: String,
        realm: Realm
    ) {
        let batch = Batch(owner: owner, realm: realm)
        batch.remove(instance)
        batch.finish()
    }

    /// One owner-scoped roster write. Resolve aliases and membership changes in
    /// wire order, then flush each surviving group's pending list edits once.
    final class Batch {
        private final class Group {
            let record: RosterGroupStorageItem
            let primary: String
            let name: String
            let isSystem: Bool
            var members: Set<String>
            var removedOriginalMembers: Set<String> = []
            var additions: [(primary: String, item: RosterStorageItem)] = []
            var liveAdditionIndices: [String: Int] = [:]

            init(_ record: RosterGroupStorageItem) {
                self.record = record
                primary = record.primary
                name = record.name
                isSystem = record.isSystemGroup
                members = Set(record.contacts.map(\.primary))
            }

            func remove(_ primary: String) {
                guard members.remove(primary) != nil else { return }
                if liveAdditionIndices.removeValue(forKey: primary) == nil {
                    removedOriginalMembers.insert(primary)
                }
            }

            func append(_ item: RosterStorageItem) -> Bool {
                let primary = item.primary
                guard members.insert(primary).inserted else { return false }
                liveAdditionIndices[primary] = additions.count
                additions.append((primary, item))
                return true
            }

            func applyListEdits() {
                if !removedOriginalMembers.isEmpty {
                    for index in (0..<record.contacts.count).reversed() {
                        if removedOriginalMembers.contains(record.contacts[index].primary) {
                            record.contacts.remove(at: index)
                        }
                    }
                }
                let survivingAdditions = additions.enumerated().compactMap { index, addition in
                    liveAdditionIndices[addition.primary] == index ? addition.item : nil
                }
                if !survivingAdditions.isEmpty { record.contacts.append(objectsIn: survivingAdditions) }
            }
        }

        private let owner: String
        private let realm: Realm
        private var groupsByPrimary: [String: Group] = [:]
        private var userGroupsByKey: [String: [Group]] = [:]
        private var groupsByContact: [String: Set<String>] = [:]
        private var emptyUserGroups: Set<String> = []
        private var changedGroups: Set<String> = []

        init(owner: String, realm: Realm) {
            precondition(realm.isInWriteTransaction)
            self.owner = owner
            self.realm = realm
            realm.objects(RosterGroupStorageItem.self).filter("owner == %@", owner).forEach {
                register(Group($0))
            }
        }

        func synchronize(_ item: RosterStorageItem, groups: [String]) {
            let desiredNames = RosterCircleGroups.normalized(groups)
            let selectedGroups = desiredNames.map { name -> Group? in
                let candidates = userGroupsByKey[RosterCircleName.key(name)] ?? []
                return candidates.first { $0.name == name }
                    ?? candidates.min { $0.primary < $1.primary }
            }
            let existingMemberships = groupsByContact[item.primary] ?? []
            let retainedPrimaries: Set<String>
            if desiredNames.isEmpty {
                retainedPrimaries = Set(existingMemberships.filter {
                    groupsByPrimary[$0]?.name == RosterGroupStorageItem.systemGroupName
                })
            } else {
                retainedPrimaries = Set(selectedGroups.compactMap { $0?.primary })
            }
            removeMemberships(item.primary, from: existingMemberships.subtracting(retainedPrimaries))

            if desiredNames.isEmpty {
                let name = RosterGroupStorageItem.systemGroupName
                let primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
                let group = groupsByPrimary[primary] ?? createGroup(name: name, isSystem: true)
                append(item, to: group)
            } else {
                for (name, selected) in zip(desiredNames, selectedGroups) {
                    append(item, to: selected ?? createGroup(name: name, isSystem: false))
                }
            }
            deleteEmptyUserGroups()
        }

        func remove(_ item: RosterStorageItem) {
            removeMemberships(item.primary, from: groupsByContact[item.primary] ?? [])
            deleteEmptyUserGroups()
        }

        func finish() {
            for primary in changedGroups { groupsByPrimary[primary]?.applyListEdits() }
            changedGroups.removeAll()
        }

        private func append(_ item: RosterStorageItem, to group: Group) {
            guard group.append(item) else { return }
            groupsByContact[item.primary, default: []].insert(group.primary)
            changedGroups.insert(group.primary)
            emptyUserGroups.remove(group.primary)
        }

        private func removeMemberships(_ contact: String, from primaries: Set<String>) {
            for primary in primaries {
                guard let group = groupsByPrimary[primary] else { continue }
                group.remove(contact)
                groupsByContact[contact]?.remove(primary)
                changedGroups.insert(primary)
                if !group.isSystem && group.members.isEmpty { emptyUserGroups.insert(primary) }
            }
            if groupsByContact[contact]?.isEmpty == true { groupsByContact.removeValue(forKey: contact) }
        }

        private func createGroup(name: String, isSystem: Bool) -> Group {
            let record = RosterGroupStorageItem()
            record.owner = owner
            record.name = name
            record.primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
            record.isSystemGroup = isSystem
            if let previous = groupsByPrimary[record.primary] { unregister(previous) }
            realm.add(record, update: .modified)
            let group = Group(record)
            register(group)
            return group
        }

        private func register(_ group: Group) {
            groupsByPrimary[group.primary] = group
            for contact in group.members { groupsByContact[contact, default: []].insert(group.primary) }
            if !group.isSystem {
                userGroupsByKey[RosterCircleName.key(group.name), default: []].append(group)
                if group.members.isEmpty { emptyUserGroups.insert(group.primary) }
            }
        }

        private func unregister(_ group: Group) {
            groupsByPrimary.removeValue(forKey: group.primary)
            changedGroups.remove(group.primary)
            emptyUserGroups.remove(group.primary)
            for contact in group.members {
                groupsByContact[contact]?.remove(group.primary)
                if groupsByContact[contact]?.isEmpty == true { groupsByContact.removeValue(forKey: contact) }
            }
            if !group.isSystem {
                let key = RosterCircleName.key(group.name)
                userGroupsByKey[key]?.removeAll { $0.primary == group.primary }
                if userGroupsByKey[key]?.isEmpty == true { userGroupsByKey.removeValue(forKey: key) }
            }
        }

        private func deleteEmptyUserGroups() {
            // Delete logically empty rows at each wire step. A later item can
            // then recreate a group under a different exact alias, as before.
            let primaries = emptyUserGroups
            for primary in primaries {
                guard let group = groupsByPrimary[primary] else { continue }
                unregister(group)
                realm.delete(group.record)
            }
        }
    }
}

final class AccountInitialRosterRequestCoordinator {
    enum Completion: Equatable {
        case matched
        case matchedAfterFallback
        case unmatched
    }

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
        completeWithOutcome(id: id) == .matched
    }

    func completeWithOutcome(id: String) -> Completion {
        queue.sync {
            switch state {
            case .waiting(let currentId) where currentId == id:
                cancelTimerLocked()
                state = .idle
                return .matched
            case .fallbackReleased(let currentId) where currentId == id:
                state = .idle
                return .matchedAfterFallback
            case .idle, .waiting, .fallbackReleased:
                return .unmatched
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
        let items = query.elements(forName: "item")
        var rosterApplySucceeded = true
        do {
            let realm = try  WRealm.safe()
            
            let removedJids = items.compactMap { item -> String? in
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
                var projection: RosterGroupProjectionSynchronizer.Batch?
                var chatLinks: [String: RosterStorageItem] = [:]
                let accountDomain = XMPPJID(string: owner)?.domain
                func groupProjection() -> RosterGroupProjectionSynchronizer.Batch {
                    if let projection { return projection }
                    let batch = RosterGroupProjectionSynchronizer.Batch(owner: owner, realm: realm)
                    projection = batch
                    return batch
                }

                items.forEach { item in
                    guard let jid = item.attributeStringValue(forName: "jid") else { return }
                    let subscribtion = item.attributeStringValue(forName: "subscription", withDefaultValue: "none")
                    if subscribtion == "remove" {
                        chatLinks.removeValue(forKey: jid)
                        if let instance = realm.object(ofType: RosterStorageItem.self,
                                                       forPrimaryKey: [jid, owner].prp()) {
                            groupProjection().remove(instance)
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
                        if instance.owner != owner { instance.owner = owner }
                        let nickname = item.attributeStringValue(forName: "name", withDefaultValue: "")
                        if instance.customUsername != nickname { instance.customUsername = nickname }
                        if instance.subscription_ != subscribtion { instance.subscription_ = subscribtion }
//                        SharedRosterUtils.setUsername(jid: jid, owner: owner, username: instance.displayName)
//                        instance.ask_ = item.attributeStringValue(forName: "ask", withDefaultValue: "none")
                        if let ask = item.attributeStringValue(forName: "ask") {
                            if ask == "subscribe", instance.ask != .out {
                                instance.ask = .out
                            }
                        } else {
                            if instance.ask_ != RosterStorageItem.Ask.none.rawValue { instance.ask = .none }
                            if let notifyInstance = realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: UINotificationStorageItem.genPrimary(owner: jid, jid: owner)) {
                                realm.delete(notifyInstance)
                            }
                        }
                        let approved = item.attributeStringValue(forName: "approved") == "true"
                        if instance.approved != approved { instance.approved = approved }
                        let groups = item.elements(forName: "group").compactMap(\.stringValue)
                        if !instance.groups.elementsEqual(groups) {
                            instance.groups.removeAll()
                            instance.groups.append(objectsIn: groups)
                        }
                        groupProjection().synchronize(instance, groups: groups)
                        chatLinks[jid] = instance
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
                        let groups = item.elements(forName: "group").compactMap(\.stringValue)
                        instance.groups.append(objectsIn: groups)
//                        instance.associatedLastChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(
//                            jid: ,
//                            owner: ,
//                            conversationType:
//                        ))
                        realm.add(instance, update: .modified)
                        
                        groupProjection().synchronize(instance, groups: groups)
                        if jid == accountDomain {
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
                        chatLinks[jid] = instance
                        let username = instance.displayName
                        let avatarUrl = instance.avatarUrl
                        CommonContactsMetadataManager.shared.update(owner: self.owner, jid: jid, username: username, avatarUrl: avatarUrl)
                    }
                }
                projection?.finish()
                if !chatLinks.isEmpty {
                    realm.objects(LastChatsStorageItem.self)
                        .filter("owner == %@ AND jid IN %@", owner, Array(chatLinks.keys))
                        .forEach { chat in
                            guard let contact = chatLinks[chat.jid],
                                  chat.rosterItem?.primary != contact.primary else { return }
                            chat.rosterItem = contact
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
               items.isEmpty,
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
            reason: rosterApplySucceeded ? "resultApplied" : "storageFallback",
            successfulResult: rosterApplySucceeded && iq.iqType == .result ? iq : nil
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
        let isEmptyResult = iq.iqType == .result && iq.children?.contains { $0 is DDXMLElement } != true
        completeInitialRosterRequestIfNeeded(elementId, reason: "emptyResult",
                                             successfulResult: isEmptyResult ? iq : nil)
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

    private func completeInitialRosterRequestIfNeeded(
        _ elementId: String,
        reason: String,
        successfulResult: XMPPIQ? = nil
    ) {
        let completion = initialRosterRequestCoordinator.completeWithOutcome(id: elementId)
        guard completion != .unmatched else { return }
        if let successfulResult, let account = AccountManager.shared.find(for: owner), account.roster === self {
            account.syncManager.noteLegacyStartupRosterResponse(successfulResult)
        }
        if completion == .matched { finishInitialRosterRequest(reason: reason) }
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
