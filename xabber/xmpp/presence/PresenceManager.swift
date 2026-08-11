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
import RealmSwift
import RxSwift
import XMPPFramework
import Network

/// Coalesces inbound contact presence before persistence. Ordinary status for
/// a full JID is last-value-wins, while device-bearing and unavailable stanzas
/// retain a separate lifecycle lane so reconciliation events are not dropped.
final class PresenceBatchAccumulator {
    static let defaultFlushInterval: TimeInterval = 0.05
    static let defaultBatchSize = 128
    static let defaultCapacity = 1_024

    private enum Lane: Hashable {
        case status
        case deviceLifecycle(UInt64)
    }

    private struct Key: Hashable {
        let jid: String
        let resource: String
        let lane: Lane
    }

    private struct PendingValue {
        let sequence: UInt64
        let presence: XMPPPresence
    }

    private struct PendingBatch {
        let generation: UInt64
        let presences: [XMPPPresence]
    }

    private let flushInterval: TimeInterval
    private let batchSize: Int
    private let capacity: Int
    private let deliveryQueue: DispatchQueue
    private let handler: (UInt64, [XMPPPresence]) -> Void
    private let timerQueue = DispatchQueue(
        label: "com.xabber.presence-batch.timer",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSLock()
    private var pending: [Key: PendingValue] = [:]
    private var nextSequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var scheduledDrain: DispatchWorkItem?

    // Internal seam for the generation handoff regression test.
    var deliveryGenerationValidationObserver: (() -> Void)?

    init(
        flushInterval: TimeInterval = PresenceBatchAccumulator.defaultFlushInterval,
        batchSize: Int = PresenceBatchAccumulator.defaultBatchSize,
        capacity: Int = PresenceBatchAccumulator.defaultCapacity,
        deliveryQueue: DispatchQueue = DispatchQueue(
            label: "com.xabber.presence-batch.delivery",
            qos: .utility,
            autoreleaseFrequency: .workItem
        ),
        handler: @escaping (UInt64, [XMPPPresence]) -> Void
    ) {
        self.flushInterval = max(0, flushInterval)
        self.batchSize = max(1, batchSize)
        self.capacity = min(max(1, capacity), Self.defaultCapacity)
        self.deliveryQueue = deliveryQueue
        self.handler = handler
    }

    var pendingKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    @discardableResult
    func enqueue(_ presence: XMPPPresence) -> Bool {
        guard let from = presence.from,
              let resource = from.resource,
              !resource.isEmpty else {
            return false
        }

        let isDeviceLifecycle = presence.presenceType == .unavailable
            || presence.element(
                forName: "device",
                xmlns: "https://xabber.com/protocol/devices"
            ) != nil
        var batch: PendingBatch?
        lock.lock()
        nextSequence &+= 1
        let key = Key(
            jid: from.bare,
            resource: resource,
            lane: isDeviceLifecycle ? .deviceLifecycle(nextSequence) : .status
        )
        if pending[key] == nil,
           pending.count >= capacity,
           let oldest = pending.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            pending.removeValue(forKey: oldest)
        }
        pending[key] = PendingValue(sequence: nextSequence, presence: presence)
        if pending.count >= batchSize {
            batch = takePendingLocked()
        } else if scheduledDrain == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.drainNow()
            }
            scheduledDrain = workItem
            timerQueue.asyncAfter(deadline: .now() + flushInterval, execute: workItem)
        }
        lock.unlock()

        if let batch {
            deliver(batch)
        }
        return true
    }

    func drainNow() {
        lock.lock()
        let batch = takePendingLocked()
        lock.unlock()
        if let batch {
            deliver(batch)
        }
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        scheduledDrain?.cancel()
        scheduledDrain = nil
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func takePendingLocked() -> PendingBatch? {
        scheduledDrain?.cancel()
        scheduledDrain = nil
        guard !pending.isEmpty else { return nil }
        let presences = pending.values
            .sorted(by: { $0.sequence < $1.sequence })
            .map(\.presence)
        pending.removeAll(keepingCapacity: true)
        return PendingBatch(generation: generation, presences: presences)
    }

    private func deliver(_ batch: PendingBatch) {
        guard !batch.presences.isEmpty else { return }
        deliveryQueue.async { [weak self] in
            guard let self,
                  self.isCurrentGeneration(batch.generation) else {
                return
            }
            self.deliveryGenerationValidationObserver?()
            self.handler(batch.generation, batch.presences)
        }
    }

    private func isCurrentGeneration(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }
}

class PresenceManager: AbstractXMPPManager {

    private struct PresencePersistenceBatch {
        let id: UInt64
        let generation: UInt64
        let presences: [XMPPPresence]
    }

    private enum PresencePersistenceResult {
        case persisted
        case retry
        case discarded
    }
    
    enum PresenceDirection {
        case incoming
        case outgoing
    }
    
    internal var bag: DisposeBag = DisposeBag()
    private var batchAccumulator: PresenceBatchAccumulator?
    private let presencePersistenceQueue = DispatchQueue(
        label: "com.xabber.presence-processing",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let presencePersistenceStateLock = NSLock()
    private var presencePersistenceGeneration: UInt64 = 0
    private var isPresencePersistenceInvalidated = false
    private var pendingPresencePersistenceBatches: [PresencePersistenceBatch] = []
    private var nextPresencePersistenceBatchID: UInt64 = 0
    private var activePresencePersistenceBatchID: UInt64?
    private var scheduledPresencePersistenceRetryBatchID: UInt64?
    private static let presencePersistenceRetryInterval: TimeInterval = 0.1

    // Internal seams are intentionally limited to persistence regression coverage.
    var presencePersistenceAttemptObserver: (() -> Void)?
    var presencePersistenceFailureInjector: (() throws -> Void)?
    var presenceBatchDeliveryGenerationValidationObserver: (() -> Void)? {
        get { batchAccumulator?.deliveryGenerationValidationObserver }
        set { batchAccumulator?.deliveryGenerationValidationObserver = newValue }
    }

    init(withOwner owner: String, withoutSubscribtion: Bool) {
        super.init(withOwner: owner)
        configureBatchAccumulator()
    }
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        configureBatchAccumulator()
        subscribe()
    }

    private func configureBatchAccumulator() {
        batchAccumulator = PresenceBatchAccumulator(
            deliveryQueue: presencePersistenceQueue
        ) { [weak self] generation, presences in
            guard let self,
                  self.isPresencePersistenceActive(generation: generation) else {
                return
            }
            self.enqueuePresencePersistenceBatch(
                presences,
                generation: generation
            )
        }
    }
    
    override func namespaces() -> [String] {
        return [
            "http://jabber.org/protocol/caps",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    fileprivate final func subscribe() {
        bag = DisposeBag()
        
        checkTemporarySubscribtions()
        RunLoop.main.perform {
            self.resetResources(commitTransaction: true)
        }
    }

    private func enqueuePresencePersistenceBatch(
        _ presences: [XMPPPresence],
        generation: UInt64
    ) {
        guard presences.isNotEmpty,
              isPresencePersistenceActive(generation: generation) else {
            return
        }
        nextPresencePersistenceBatchID &+= 1
        pendingPresencePersistenceBatches.append(
            PresencePersistenceBatch(
                id: nextPresencePersistenceBatchID,
                generation: generation,
                presences: presences
            )
        )
        startNextPresencePersistenceBatchIfNeeded()
    }

    private func startNextPresencePersistenceBatchIfNeeded() {
        guard activePresencePersistenceBatchID == nil,
              scheduledPresencePersistenceRetryBatchID == nil,
              let batch = pendingPresencePersistenceBatches.first else {
            return
        }
        guard isPresencePersistenceActive(generation: batch.generation) else {
            pendingPresencePersistenceBatches.removeFirst()
            startNextPresencePersistenceBatchIfNeeded()
            return
        }

        activePresencePersistenceBatchID = batch.id
        commitPresenceBatch(batch) { [weak self] result in
            guard let self else { return }
            self.presencePersistenceQueue.async { [weak self] in
                self?.finishPresencePersistenceBatch(batch, result: result)
            }
        }
    }

    private func finishPresencePersistenceBatch(
        _ batch: PresencePersistenceBatch,
        result: PresencePersistenceResult
    ) {
        guard activePresencePersistenceBatchID == batch.id else {
            return
        }
        activePresencePersistenceBatchID = nil

        switch result {
        case .persisted, .discarded:
            if pendingPresencePersistenceBatches.first?.id == batch.id {
                pendingPresencePersistenceBatches.removeFirst()
            } else {
                pendingPresencePersistenceBatches.removeAll { $0.id == batch.id }
            }
            startNextPresencePersistenceBatchIfNeeded()
        case .retry:
            guard isPresencePersistenceActive(generation: batch.generation),
                  pendingPresencePersistenceBatches.first?.id == batch.id else {
                pendingPresencePersistenceBatches.removeAll { $0.id == batch.id }
                startNextPresencePersistenceBatchIfNeeded()
                return
            }
            scheduledPresencePersistenceRetryBatchID = batch.id
            presencePersistenceQueue.asyncAfter(
                deadline: .now() + Self.presencePersistenceRetryInterval
            ) { [weak self] in
                guard let self,
                      self.scheduledPresencePersistenceRetryBatchID == batch.id else {
                    return
                }
                self.scheduledPresencePersistenceRetryBatchID = nil
                self.startNextPresencePersistenceBatchIfNeeded()
            }
        }
    }

    private func commitPresenceBatch(
        _ batch: PresencePersistenceBatch,
        completion: @escaping (PresencePersistenceResult) -> Void
    ) {
        guard batch.presences.isNotEmpty,
              isPresencePersistenceActive(generation: batch.generation),
              let expectedAccount = AccountManager.shared.find(for: owner),
              expectedAccount.presences === self else {
            completion(.discarded)
            return
        }
        expectedAccount.action { [weak self, weak expectedAccount] account, _ in
            guard let self,
                  let expectedAccount,
                  account === expectedAccount,
                  account.presences === self,
                  AccountManager.shared.find(for: self.owner) === account,
                  self.isPresencePersistenceActive(generation: batch.generation) else {
                completion(.discarded)
                return
            }
            do {
                let realm = try WRealm.safe()
                self.presencePersistenceAttemptObserver?()
                try self.presencePersistenceFailureInjector?()
                var didPersist = false
                try realm.write {
                    guard self.isPresencePersistenceActive(generation: batch.generation),
                          AccountManager.shared.find(for: self.owner) === account,
                          account.presences === self else {
                        return
                    }
                    batch.presences.forEach { self.parse(contact: $0, realm: realm) }
                    account.devices.readBatch(batch.presences, commitTransaction: false)
                    didPersist = true
                }
                completion(didPersist ? .persisted : .discarded)
            } catch {
                DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
                completion(.retry)
            }
        }
    }

    private func activePresencePersistenceGeneration() -> UInt64? {
        presencePersistenceStateLock.lock()
        defer { presencePersistenceStateLock.unlock() }
        guard !isPresencePersistenceInvalidated else { return nil }
        return presencePersistenceGeneration
    }

    private func isPresencePersistenceActive(generation: UInt64) -> Bool {
        presencePersistenceStateLock.lock()
        defer { presencePersistenceStateLock.unlock() }
        return !isPresencePersistenceInvalidated && presencePersistenceGeneration == generation
    }

    private func cancelPendingPresencePersistence(permanently: Bool) {
        presencePersistenceStateLock.lock()
        presencePersistenceGeneration &+= 1
        if permanently {
            isPresencePersistenceInvalidated = true
        }
        presencePersistenceStateLock.unlock()
        batchAccumulator?.cancel()
        presencePersistenceQueue.async { [weak self] in
            guard let self else { return }
            let activeGeneration = self.activePresencePersistenceGeneration()
            self.pendingPresencePersistenceBatches.removeAll { batch in
                guard let activeGeneration else { return true }
                return batch.generation != activeGeneration
            }
            if let activeID = self.activePresencePersistenceBatchID,
               !self.pendingPresencePersistenceBatches.contains(where: { $0.id == activeID }) {
                self.activePresencePersistenceBatchID = nil
            }
            if let retryID = self.scheduledPresencePersistenceRetryBatchID,
               !self.pendingPresencePersistenceBatches.contains(where: { $0.id == retryID }) {
                self.scheduledPresencePersistenceRetryBatchID = nil
            }
            self.startNextPresencePersistenceBatchIfNeeded()
        }
    }

    /// Permanently closes detached presence persistence before account Realm cleanup.
    /// The state check is repeated inside the acquired Realm transaction so an
    /// already-running writer cannot recreate account-owned rows after deletion.
    final func invalidatePendingPresencePersistence() {
        cancelPendingPresencePersistence(permanently: true)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
        cancelPendingPresencePersistence(permanently: false)
    }
    
    internal func processQueue() {
        
    }
    
    open func unsubscribed(_ xmppStream: XMPPStream, jid: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    realm.delete(instance)
                }
            }
            xmppStream.send(XMPPPresence(type: .unsubscribed, to: XMPPJID(string: jid)))
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    open func unsubscribe(_ xmppStream: XMPPStream, jid: String) {
        xmppStream.send(XMPPPresence(type: .unsubscribe, to: XMPPJID(string: jid)))
    }
    
    
    open func subscribed(_ xmppStream: XMPPStream, jid: String, storePreaproved: Bool = true) {
        do {
            let realm = try  WRealm.safe()
            if storePreaproved {
                let instance = PreaprovedSubscribtionStorageItem()
                instance.owner = owner
                instance.jid = jid
                instance.primary = PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)
                try realm.write {
                    realm.add(instance, update: .modified)
                }
            }
            xmppStream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        do {
            let realm = try WRealm.safe()
            if let instance =  realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                try realm.write {
                    instance.ask = .none
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }

    }
    
    
    open func subscribe(_ xmppStream: XMPPStream, jid: String) {
        xmppStream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: jid)))
    }
    
    open func sendSubscribtionRequest(_ xmppStream: XMPPStream, jid: String) {
        do {
            let realm = try  WRealm.safe()
            let instance = PreaprovedSubscribtionStorageItem()
            instance.owner = owner
            instance.jid = jid
            instance.primary = PreaprovedSubscribtionStorageItem.genPrimary(jid: jid, owner: owner)
            try realm.write {
                realm.add(instance, update: .modified)
            }
            xmppStream.send(XMPPPresence(type: .subscribe, to: XMPPJID(string: jid)))
            xmppStream.send(XMPPPresence(type: .subscribed, to: XMPPJID(string: jid)))

        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: jid)
        })
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    instance.ask = .out
                }
            } else {
                let instance = RosterStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .undefined
                instance.ask = .out
                try realm.write {
                    if realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil { return }
                    realm.add(instance)
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func receiveError(_ presence: XMPPPresence) -> Bool {
//        guard presence.presenceType == .error,
//            let jid = presence.from?.bare else {
//                return false
//        }
//        do {
//            let realm = try  WRealm.safe()
//            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
//                                           forPrimaryKey: [jid, owner].prp()) {
//                try realm.write {
//                    realm.delete(instance)
//                }
//            }
//        } catch {
//            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
//        }
//
//        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
//            user.presences.unsubscribe(stream, jid: jid)
//            user.presences.unsubscribed(stream, jid: jid)
//        })
        return false
    }
    
    public final func clearAuthMessage(for jid: String) {
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
                    .sorted(byKeyPath: "date", ascending: false).last
                try realm.write {
                    realm.delete(authMessage)
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .omemo))?.lastMessage = lastMessageForChat
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func receivePreapruvedSubscribeRequest(_ presence: XMPPPresence) -> Bool {
        guard let jid = presence.from?.bare,
            presence.presenceType == .subscribe else {
                return false
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: PreaprovedSubscribtionStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                AccountManager
                    .shared
                    .find(for: owner)?
                    .unsafeAction({ (user, stream) in
                        stream.send(XMPPPresence(
                                        type: .subscribed,
                                        to: XMPPJID(string: jid)))
                    })
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        return false
    }
    
    open func updateMyself(_ xmppStream: XMPPStream, with status: ResourceStorageItem, ver: String, to jid: XMPPJID?) {
        var show: XMPPPresence.ShowType? = nil
        switch status.status {
        case .offline, .online:
            break
        case .xa:
            show = XMPPPresence.ShowType.xa
        case .away:
            show = XMPPPresence.ShowType.away
        case .dnd:
            show = XMPPPresence.ShowType.dnd
        case .chat:
            show = XMPPPresence.ShowType.chat
        }
        let presence = XMPPPresence(type: nil,
                                    show: show,
                                    status: status.statusMessage,
                                    to: jid)
        if let deviceElement = AccountManager.shared.find(for: self.owner)?.devices.deviceElement  {
            presence.addChild(deviceElement)
        }
        presence.addChild(DDXMLElement(name: "priority", stringValue: "67"))
        let caps = DDXMLElement.element(withName: "c") as! DDXMLElement
        caps.setXmlns("http://jabber.org/protocol/caps")
        caps.addAttribute(withName: "hash", stringValue: "sha-1")
        caps.addAttribute(withName: "node", stringValue: "https://www.xabber.com")
        caps.addAttribute(withName: "ver", stringValue: ver)
        presence.addChild(caps)
//        xmppStream.send(DDXMLElement(name: "inactive", xmlns: "urn:xmpp:csi:0"))
        if status.status != .offline {
            xmppStream.send(presence)
        }
    }
    
    final func probe(_ xmppStream: XMPPStream, jid: String) {
        let presence = XMPPPresence(type: .probe, to: XMPPJID(string: jid))
        xmppStream.send(presence)
    }
    
    public static func parseStatusValue(from presence: XMPPPresence) -> ResourceStatus {
        if presence.type == "unavailable" {
            return .offline
        }
        if let show = presence.element(forName: "show") {
            return RosterUtils.shared.convertShowStatus(show.stringValue ?? "unavailable")
        }
        return .online
    }
    
    public static func parseStatusMessage(from presence: XMPPPresence) -> String {
        return presence.element(forName: "status")?.stringValue ?? ""
    }
    
    open func read(withPresence presence: XMPPPresence) -> Bool {
        switch true {
        case receiveError(presence): return true
        case receivePreapruvedSubscribeRequest(presence): return true
        case didReceiveSubscribeRequest(presence): return true
        case didReceiveUnsubscribedRequest(presence): return true
        case didReceiveMyPresence(presence): return true
        case didReceiveContactPresence(presence): return true
        default: return false
        }
    }
    
    internal func parse(contact presence: XMPPPresence) {
        do {
            let realm = try  WRealm.safe()
            if realm.isInWriteTransaction {
                parse(contact: presence, realm: realm)
            } else {
                try realm.write {
                    parse(contact: presence, realm: realm)
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }

    internal func parse(contact presence: XMPPPresence, realm: Realm) {
        guard let fromJid = presence.from,
            fromJid.bare != owner,
            let resource = fromJid.resource else {
                return
        }

        guard realm.isInWriteTransaction else {
            parse(contact: presence)
            return
        }

        if PresenceManager.parseStatusValue(from: presence) == .offline && presence.element(forName: "x", xmlns: GroupchatManager.staticGetNamespace()) == nil {
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [fromJid.bare,
                                                           resource,
                                                           owner].prp()) {
                instance.status = .offline
                realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [fromJid.bare, owner].prp())?.notes = " "
            }
        } else {
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                            forPrimaryKey: [fromJid.bare,
                                            fromJid.resource ?? "",
                                            owner].prp()) {

                if instance.isInvalidated { return }

                instance.status = PresenceManager.parseStatusValue(from: presence)
                instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                instance.priority = presence.priority
                instance.timestamp = presence.delayedDeliveryDate ?? Date()
            } else {
                let instance = ResourceStorageItem()
                instance.jid = fromJid.bare
                instance.owner = owner
                instance.resource = fromJid.resource ?? ""
                instance.status = PresenceManager.parseStatusValue(from: presence)
                instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                instance.priority = presence.priority
                instance.client = ""
                instance.isTemporary = false
                instance.timestamp = presence.delayedDeliveryDate ?? Date()
                instance.primary = ResourceStorageItem.genPrimary(jid: fromJid.bare, owner: owner, resource: fromJid.resource ?? "")
                realm.add(instance, update: .modified)
            }
            realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [fromJid.bare, owner].prp())?.notes = " "
            realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [fromJid.bare, owner].prp())?.isContact = presence.element(forName: "x", xmlns: GroupchatManager.staticGetNamespace()) == nil
        }
    }
    
    internal func didReceiveMyPresence(_ presence: XMPPPresence) -> Bool {
        guard let from = presence.from,
            let to = presence.to,
            from.full != to.full,
            from.bare == owner else { return false }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [from.bare,
                                                           from.resource ?? "",
                                                           owner].prp()) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        if instance.isInvalidated { return }
                        instance.status = PresenceManager.parseStatusValue(from: presence)
                        instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                        instance.priority = presence.priority
                        instance.timestamp = presence.delayedDeliveryDate ?? Date()
                    }
                }
            } else {
                let instance = ResourceStorageItem()
                instance.jid = from.bare
                instance.owner = owner
                instance.resource = from.resource ?? ""
                instance.status = PresenceManager.parseStatusValue(from: presence)
                instance.statusMessage = PresenceManager.parseStatusMessage(from: presence)
                instance.priority = presence.priority
                instance.client = ""
                instance.isTemporary = false
                instance.timestamp = presence.delayedDeliveryDate ?? Date()
                instance.primary = ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: from.resource ?? "")
                
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                    }
                }
            }
        } catch {
            DDLogDebug("cant update presence info for account \(owner)")
        }
        return true
    }
    
    internal func didReceiveContactPresence(_ presence: XMPPPresence) -> Bool {
        guard let fromJid = presence.from,
            fromJid.bare != owner,
            fromJid.resource != nil else {
                return false
        }
        _ = batchAccumulator?.enqueue(presence)
        
        return true
    }
    
    internal func didReceiveUnsubscribedRequest(_ presence: XMPPPresence) -> Bool {
            guard let jid = presence.from?.bare,
                jid != owner,
                presence.presenceType == .unsubscribed else {
                    return false
            }
            do {
                let realm = try WRealm.safe()
                if let instance =  realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                    try realm.write {
                        instance.subscribtion = .none
                        instance.ask = .none
                    }
                }
            } catch {
                DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
            }
            return true
        }
    
    internal func didReceiveSubscribeRequest(_ presence: XMPPPresence) -> Bool {
        guard let jid = presence.from?.bare,
            jid != owner,
            presence.presenceType == .subscribe else {
                return false
        }
        let wireNickname = presence
            .element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let notificationText = presence.status ?? ""
        let notificationReceivedAt = presence.delayedDeliveryDate ?? Date()
        let isFreshForLocalNotification = LocalNotificationAdmissionPolicy
            .allowsSubscribePresence(receivedAt: notificationReceivedAt)
        var shouldNotifyLocally = false
        var resolvedDisplayName = wireNickname?.isEmpty == false ? wireNickname! : jid
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: jid)
        })
        
        do {
            let realm = try  WRealm.safe()
            let primary = UINotificationStorageItem.genPrimary(owner: owner, jid: jid)
            if realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: primary) == nil {
                let uiNotifyObject = UINotificationStorageItem()
                uiNotifyObject.primary = primary
                uiNotifyObject.owner = owner
                uiNotifyObject.jid = jid
                uiNotifyObject.kind = .contactRequest
                uiNotifyObject.date = Date()
                uiNotifyObject.readAt = nil
                try realm.write {
                    realm.add(uiNotifyObject)
                }
                shouldNotifyLocally = true
            }
//            let notificationId = ["subscribtion_request", jid, owner].prp()
//            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: notificationId)) {
//                try realm.write {
//                    instance.date = Date()
//                    instance.associatedJid = jid
//                    instance.displayedNick = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue
//                }
//            } else {
//                let instance = NotificationStorageItem()
//                instance.owner = owner
//                instance.jid = jid
//                instance.uniqueId = notificationId
//                instance.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: notificationId)
//                instance.associatedJid = jid
//                instance.displayedNick = presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue
//                instance.date = Date()
//                instance.isRead = true
//                instance.shouldShow = true
//                instance.category = .contact
//                instance.metadata = [
//                    "message": presence.status ?? "",
//                    "username": presence.element(forName: "nick", xmlns: "http://jabber.org/protocol/nick")?.stringValue ?? jid
//                ]
//                try realm.write {
//                    realm.add(instance)
//                }
//                
//                
//                
//            }
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) {
                try realm.write {
                    instance.ask = .in
                    if instance.username.isEmpty {
                        instance.username = wireNickname ?? ""
                    }
                }
                resolvedDisplayName = instance.displayName.isEmpty ? resolvedDisplayName : instance.displayName
            } else {
                let instance = RosterStorageItem()
                instance.owner = self.owner
                instance.jid = jid
                instance.username = wireNickname ?? ""
                instance.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                instance.subscribtion = .undefined
                instance.ask = .in
                try realm.write {
                    if realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil { return }
                    realm.add(instance)
                }
                resolvedDisplayName = instance.displayName.isEmpty ? resolvedDisplayName : instance.displayName
            }
            
            if realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, owner].prp()) != nil {
                return true
            }
            
            AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, _ in
                user.avatarManager.enqueuePubSubItemRequest(node: .metadata, jid: jid, by: "")
            })
            if shouldNotifyLocally && isFreshForLocalNotification {
                let notificationOwner = owner
                let displayName = resolvedDisplayName
                DispatchQueue.main.async {
                    NotifyManager.shared.update(
                        withSubscription: notificationText,
                        opponent: jid,
                        owner: notificationOwner,
                        displayName: displayName
                    )
                }
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    
    open func didResetState() {
        self.cancelPendingPresencePersistence(permanently: false)
//        self.subscribe()
//        RunLoop.main.perform {
//            self.resetResources(commitTransaction: true)
//        }
    }
    
    func resetResources(for jid: String? = nil,commitTransaction: Bool) {
        let resource = AccountManager.shared.find(for: owner)?.resource ?? ""
        do {
            let realm = try WRealm.safe()
            var collection = realm.objects(ResourceStorageItem.self).filter("owner == %@ AND resource != %@ AND statusExt == %@", owner, resource, RosterItemEntity.contact.rawValue)
            if let jid = jid {
                collection = collection.filter("jid == %@", jid)
            }
            if commitTransaction {
                realm.writeAsync {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
            
        } catch {
            DDLogDebug("cant reset resources for \((jid == nil) ? "all contacts" : jid!) of \(self.owner)")
        }
    }
    
    override func clearSession() {
//        unsubscribe()
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            let collection = realm.objects(ResourceStorageItem.self)
                .filter("owner == %@", owner)
            let preaproved = realm.objects(PreaprovedSubscribtionStorageItem.self).filter("owner == %@", owner)
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                    realm.delete(preaproved)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("PresenceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    deinit {
        bag = DisposeBag()
        presencePersistenceStateLock.lock()
        presencePersistenceGeneration &+= 1
        presencePersistenceStateLock.unlock()
        batchAccumulator?.cancel()
    }
    
}
