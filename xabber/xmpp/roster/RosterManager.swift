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
        
        init(_ action: Action, elementId: String, value: String, callback: ((String?, String?,  Bool) -> Void)? = nil) {
            self.action = action
            self.elementId = elementId
            self.callback = callback
            self.value = value
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    internal var version: String? = nil
    
    internal var queueItems: SynchronizedArray<QueueItem> = SynchronizedArray<QueueItem>()
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
    
    open func setContact(_ xmppStream: XMPPStream, jid: String, getNickFromVCard: Bool = false, nickname preferredNickname: String? = nil, groups: [String] = [], shouldAddSystemMessage: Bool = false, callback: ((String?, String?, Bool) -> Void)? = nil) {
        do {
            let realm = try  WRealm.safe()
            
            func updateGroups(_ instance: RosterStorageItem, groups: [String]) {
                if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.notInRosterGroupName, owner].prp()) {
                    if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                        item.contacts.remove(at: index)
                    }
                }
                if groups.isEmpty {
                    realm.objects(RosterGroupStorageItem.self)
                        .filter("owner == %@", owner)
                        .forEach { item in
                            if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                item.contacts.remove(at: index)
                            }
                        }
                    if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if !group.contacts.contains(instance) {
                            group.contacts.append(instance)
                        }
                    } else {
                        let group = RosterGroupStorageItem()
                        group.isSystemGroup = true
                        group.name = RosterGroupStorageItem.systemGroupName
                        group.owner = owner
                        group.primary = RosterGroupStorageItem.genPrimary(name: RosterGroupStorageItem.systemGroupName, owner: owner)
                        group.contacts.append(instance)
                        realm.add(group, update: .modified)
                    }
                } else {
                    if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                            item.contacts.remove(at: index)
                        }
                    }
                    groups.forEach {
                        groupName in
                        realm.objects(RosterGroupStorageItem.self)
                            .filter("owner == %@", owner)
                            .forEach { item in
                                if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }),
                                   item.groupName != groupName {
                                    item.contacts.remove(at: index)
                                }
                            }
                        if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [groupName, owner].prp()) {
                            if !group.contacts.contains(instance) {
                                group.contacts.append(instance)
                            }
                        } else {
                            let group = RosterGroupStorageItem()
                            group.name = groupName
                            group.owner = owner
                            group.primary = RosterGroupStorageItem.genPrimary(name: groupName, owner: owner)
                            group.contacts.append(instance)
                            realm.add(group, update: .modified)
                        }
                    }
                }
            }
            
            let elementId = xmppStream.generateUUID
            let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
            let item = DDXMLElement(name: "item")
            item.addAttribute(withName: "jid", stringValue: jid)
            var nickname = preferredNickname
            if getNickFromVCard {
                if let vcard = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                    nickname = vcard.unsafeGeneratedNickname
                }
            }
            
            let displayNick = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: self.owner))?.displayName
            
            if let nickname = nickname {
                item.addAttribute(withName: "name", stringValue: nickname)
            } else if let nick = displayNick {
                item.addAttribute(withName: "name", stringValue: nick)
            }
            groups
                .filter{ $0.isNotEmpty }
                .compactMap { return DDXMLElement(name: "group", stringValue: $0) }
                .forEach { item.addChild($0) }
            query.addChild(item)
            xmppStream.send(XMPPIQ(iqType: .set, elementID: elementId, child: query))
            queryIds.insert(elementId)
            queueItems.insert(QueueItem(.add, elementId: elementId, value: jid, callback: callback))
        
            
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                try realm.write {
                    instance.groups.removeAll()
                    instance.groups.append(objectsIn: groups)
                    instance.customUsername = preferredNickname ?? ""
                    updateGroups(instance, groups: groups)
                }
            } else {
                let instance = RosterStorageItem()
                instance.jid = jid
                instance.owner = owner
                instance.customUsername = preferredNickname ?? ""
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .none
                instance.associatedLastChat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular))
                try realm.write {
                    realm.add(instance, update: .modified)
                    updateGroups(instance, groups: groups)
                }
            }
        } catch {
            DDLogDebug("RosterManager: \(#function). \(error.localizedDescription)")
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
        queueItems.insert(QueueItem(.delete, elementId: elementId, value: jid, callback: callback))
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
            
            func updateGroups(_ instance: RosterStorageItem, groups: [String]) {
                if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.notInRosterGroupName, owner].prp()) {
                    if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                        item.contacts.remove(at: index)
                    }
                }
                if groups.isEmpty {
                    realm.objects(RosterGroupStorageItem.self)
                        .filter("owner == %@", owner)
                        .forEach { item in
                            if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                item.contacts.remove(at: index)
                            }
                        }
                    if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if !group.contacts.contains(instance) {
                            group.contacts.append(instance)
                        }
                    } else {
                        let group = RosterGroupStorageItem()
                        group.isSystemGroup = true
                        group.name = RosterGroupStorageItem.systemGroupName
                        group.owner = owner
                        group.primary = RosterGroupStorageItem.genPrimary(name: RosterGroupStorageItem.systemGroupName, owner: owner)
                        group.contacts.append(instance)
                        realm.add(group, update: .modified)
                    }
                } else {
                    if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                        if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                            item.contacts.remove(at: index)
                        }
                    }
                    groups.forEach {
                        groupName in
                        realm.objects(RosterGroupStorageItem.self)
                            .filter("owner == %@", owner)
                            .forEach { item in
                                if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }),
                                   item.groupName != groupName {
                                    item.contacts.remove(at: index)
                                }
                            }
                        if let group = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [groupName, owner].prp()) {
                            if !group.contacts.contains(instance) {
                                group.contacts.append(instance)
                            }
                        } else {
                            let group = RosterGroupStorageItem()
                            group.name = groupName
                            group.owner = owner
                            group.primary = RosterGroupStorageItem.genPrimary(name: groupName, owner: owner)
                            group.contacts.append(instance)
                            realm.add(group, update: .modified)
                        }
                    }
                }
            }
            
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
                            realm
                                .objects(RosterGroupStorageItem.self)
                                .filter("owner == %@ AND name IN %@", owner, instance.groups.toArray())
                                .forEach { item in
                                    if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                        item.contacts.remove(at: index)
                                    }
                                }
                            if let item = realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: [RosterGroupStorageItem.systemGroupName, owner].prp()) {
                                if let index = item.contacts.firstIndex(where: { $0.primary == instance.primary }) {
                                    item.contacts.remove(at: index)
                                }
                            }
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
                        updateGroups(instance, groups: groups)
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
                        
                        updateGroups(instance, groups: groups)
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
        
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, nil, true)
            queueItems.remove(item)
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
        
        let error = errorElement.name
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, error,false)
            queueItems.remove(item)
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
        if let item = queueItems.first(where: { $0.elementId == elementId }) {
            item.callback?(item.value, nil, true)
            queueItems.remove(item)
        }
        return true
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
