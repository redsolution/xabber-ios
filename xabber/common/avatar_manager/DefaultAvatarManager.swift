//
//  DefaultAvatarManager.swift
//  xabber_test_xmpp
//
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
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import Kingfisher
import LetterAvatarKit
import CocoaLumberjack
import MaterialComponents.MDCPalettes

enum PushAvatarSnapshotRevision {
    static func make(
        sourceKeys: [String],
        metadataRevision: String?
    ) -> String {
        let sources = sourceKeys
            .filter { !$0.isEmpty }
            .sorted()
        let metadata = metadataRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (["v2", metadata] + sources).joined(separator: "\u{0}")
    }
}

struct PushAvatarBackfillBudget {
    let maximumCandidates: Int
    let deadlineUptime: TimeInterval
    private(set) var claimedCandidates: Int = 0

    var remainingCandidates: Int {
        max(0, maximumCandidates - claimedCandidates)
    }

    func canContinue(at uptime: TimeInterval) -> Bool {
        claimedCandidates < maximumCandidates && uptime < deadlineUptime
    }

    mutating func claim(at uptime: TimeInterval) -> Bool {
        guard canContinue(at: uptime) else { return false }
        claimedCandidates += 1
        return true
    }
}

final class PushAvatarSnapshotPublisher {
    typealias Token = PushAvatarSnapshotGenerationGate.Token
    private typealias Completion = (PublishResult) -> Void

    enum PublishResult: Equatable {
        case stored
        case alreadyCurrent
        case stale
        case failed
    }

    private let store: PushNotificationAvatarStore
    private let queue: DispatchQueue
    private let generationGate: PushAvatarSnapshotGenerationGate
    private let maximumPendingPublishes: Int
    private let imageEncoder: (UIImage) -> Data?
    private let sourceRevisionProvider: (Token) -> String?
    private let snapshotWriter: (Data, PushNotificationAvatarIdentity, String) throws -> Void
    private let pendingLock = NSLock()
    private var pendingPublishes: [Token: PendingPublish] = [:]
    private var pendingTokensByIdentity: [
        PushNotificationAvatarIdentity: Set<Token>
    ] = [:]

    private struct PendingPublish {
        let image: UIImage
        var completions: [Completion]
    }

    var pendingPublishCount: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingPublishes.count
    }

    init(
        store: PushNotificationAvatarStore,
        queue: DispatchQueue = DispatchQueue(
            label: "com.xabber.push-avatar-snapshot-publisher",
            qos: .utility,
            autoreleaseFrequency: .workItem
        ),
        generationGate: PushAvatarSnapshotGenerationGate = .shared,
        maximumPendingPublishes: Int = 64,
        imageEncoder: @escaping (UIImage) -> Data? = {
            PushNotificationAvatarStore.snapshotData(from: $0)
        },
        sourceRevisionProvider: @escaping (Token) -> String? = { $0.sourceKey },
        snapshotWriter: ((Data, PushNotificationAvatarIdentity, String) throws -> Void)? = nil
    ) {
        self.store = store
        self.queue = queue
        self.generationGate = generationGate
        self.maximumPendingPublishes = max(0, maximumPendingPublishes)
        self.imageEncoder = imageEncoder
        self.sourceRevisionProvider = sourceRevisionProvider
        self.snapshotWriter = snapshotWriter ?? { data, identity, sourceKey in
            try store.storePending(
                imageData: data,
                for: identity,
                sourceKey: sourceKey
            )
        }
    }

    func begin(
        identity: PushNotificationAvatarIdentity,
        sourceKey: String,
        metadataRevision: String? = nil,
        sourceScope: PushAvatarSnapshotSourceScope = .managed
    ) -> Token {
        let token = generationGate.begin(
            identity: identity,
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            sourceScope: sourceScope
        )
        cancelPending(identity: identity, except: token)
        return token
    }

    func publish(
        _ image: UIImage,
        token: Token,
        completion: ((PublishResult) -> Void)? = nil
    ) {
        guard generationGate.isCurrent(token) else {
            completion?(.stale)
            return
        }
        pendingLock.lock()
        if var pending = pendingPublishes[token] {
            if let completion {
                pending.completions.append(completion)
                pendingPublishes[token] = pending
            }
            pendingLock.unlock()
            return
        }
        guard pendingPublishes.count < maximumPendingPublishes else {
            pendingLock.unlock()
            completion?(.failed)
            return
        }
        pendingPublishes[token] = PendingPublish(
            image: image,
            completions: completion.map { [$0] } ?? []
        )
        pendingTokensByIdentity[token.identity, default: []].insert(token)
        pendingLock.unlock()

        queue.async { [weak self] in
            self?.executePendingPublish(token: token)
        }
    }

    private func executePendingPublish(token: Token) {
        pendingLock.lock()
        let image = pendingPublishes[token]?.image
        pendingLock.unlock()
        guard let image else { return }

        let result: PublishResult = autoreleasepool {
            guard generationGate.isCurrent(token),
                  let sourceRevision = sourceRevisionProvider(token) else {
                return .stale
            }
            if store.hasValidSnapshot(
                for: token.identity,
                sourceKey: sourceRevision
            ) {
                return generationGate.isCurrent(token)
                    && sourceRevisionProvider(token) == sourceRevision
                    ? .alreadyCurrent
                    : .stale
            }
            guard let imageData = imageEncoder(image),
                  generationGate.isCurrent(token),
                  sourceRevisionProvider(token) == sourceRevision else {
                return .stale
            }
            do {
                try snapshotWriter(imageData, token.identity, sourceRevision)
                guard generationGate.isCurrent(token),
                      sourceRevisionProvider(token) == sourceRevision else {
                    // Writes are serial. A newer publish cannot have committed yet.
                    store.remove(for: token.identity)
                    return .stale
                }
                store.clearDeletionMarkers(for: token.identity)
                return .stored
            } catch {
                store.remove(for: token.identity)
                return .failed
            }
        }
        finishPendingPublish(token: token, result: result)
    }

    private func finishPendingPublish(token: Token, result: PublishResult) {
        pendingLock.lock()
        let completions = removePendingLocked(token: token)
        pendingLock.unlock()
        completions.forEach { $0(result) }
    }

    private func removePendingLocked(token: Token) -> [Completion] {
        let completions = pendingPublishes.removeValue(forKey: token)?.completions ?? []
        pendingTokensByIdentity[token.identity]?.remove(token)
        if pendingTokensByIdentity[token.identity]?.isEmpty == true {
            pendingTokensByIdentity.removeValue(forKey: token.identity)
        }
        return completions
    }

    private func cancelPending(identity: PushNotificationAvatarIdentity, except: Token?) {
        pendingLock.lock()
        let tokens = pendingTokensByIdentity[identity]?.filter { $0 != except } ?? []
        let completions = tokens.flatMap { removePendingLocked(token: $0) }
        pendingLock.unlock()
        deliverStale(completions)
    }

    private func cancelPending(
        where shouldCancel: (Token) -> Bool
    ) {
        pendingLock.lock()
        let tokens = pendingPublishes.keys.filter(shouldCancel)
        let completions = tokens.flatMap { removePendingLocked(token: $0) }
        pendingLock.unlock()
        deliverStale(completions)
    }

    private func deliverStale(_ completions: [Completion]) {
        guard !completions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            completions.forEach { $0(.stale) }
        }
    }

    func remove(
        identity: PushNotificationAvatarIdentity,
        completion: (() -> Void)? = nil
    ) {
        remove(identities: [identity], completion: completion)
    }

    func remove(
        identities: [PushNotificationAvatarIdentity],
        completion: (() -> Void)? = nil
    ) {
        let identities = Array(Set(identities))
        guard !identities.isEmpty else {
            completion?()
            return
        }
        let identitySet = Set(identities)
        generationGate.invalidate(identities: identities)
        cancelPending(where: { identitySet.contains($0.identity) })
        identities.forEach { identity in
            do {
                try store.markDeleted(identity: identity)
            } catch {
                store.remove(for: identity)
            }
        }
        queue.async { [store = self.store] in
            identities.forEach { store.remove(for: $0) }
            completion?()
        }
    }

    func removeAll(owner: String, completion: (() -> Void)? = nil) {
        generationGate.invalidate(owner: owner)
        let normalizedOwner = PushNotificationAvatarIdentity(
            owner: owner,
            contactJid: owner
        ).owner
        cancelPending(where: { $0.identity.owner == normalizedOwner })
        do {
            try store.markDeleted(owner: normalizedOwner)
        } catch {
            store.removeAll(owner: normalizedOwner)
        }
        queue.async { [store = self.store] in
            store.removeAll(owner: owner)
            completion?()
        }
    }

    func removeAll(completion: (() -> Void)? = nil) {
        generationGate.invalidateAll()
        cancelPending(where: { _ in true })
        queue.async { [store = self.store] in
            store.removeAll()
            completion?()
        }
    }
}

class DefaultAvatarManager: NSObject {
    
    enum ImageSize: CGFloat, CaseIterable {
        case px32 = 32
        case px48 = 48
        case px64 = 64
        case px96 = 96
        case px128 = 128
        case px192 = 192
        case px256 = 256
        case px384 = 384
        case px512 = 512
        case original = 0
    }
    
    open class var shared: DefaultAvatarManager {
        struct DefaultAvatarManagerSingleton {
            static let instance = DefaultAvatarManager()
        }
        return DefaultAvatarManagerSingleton.instance
    }
    
    static let defaultSize: CGSize = CGSize(square: 140)
    
    static let queue: DispatchQueue = DispatchQueue(
        label: "com.xabber.avatarManager.default",
        qos: .utility,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem,
        target: nil
    )
    
    internal var bag: DisposeBag = DisposeBag()
    private let pushAvatarPreheatLock = NSLock()
    private var didSchedulePushAvatarPreheat = false
    private lazy var pushAvatarPublisher = PushAvatarSnapshotPublisher(
        store: .shared,
        sourceRevisionProvider: { [weak self] token in
            self?.currentPushAvatarSourceRevision(for: token)
        }
    )
        
    override init() {
        super.init()
        ImageCache.default.memoryStorage.config.expiration = .seconds(60*60*1)
        ImageCache.default.memoryStorage.config.countLimit = 3000
        ImageCache.default.memoryStorage.config.keepWhenEnteringBackground = true
        ImageCache.default.memoryStorage.config.totalCostLimit = 300 * 1024 * 1024
        ImageCache.default.diskStorage.config.expiration = .never
        ImageCache.default.diskStorage.config.sizeLimit = 0
    }
    
    public final func preheat() {
        pushAvatarPreheatLock.lock()
        guard !didSchedulePushAvatarPreheat else {
            pushAvatarPreheatLock.unlock()
            return
        }
        didSchedulePushAvatarPreheat = true
        pushAvatarPreheatLock.unlock()

        Self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            autoreleasepool {
                let now = ProcessInfo.processInfo.systemUptime
                self.continuePushAvatarBackfill(
                    cursor: PushAvatarBackfillCursor(),
                    budget: PushAvatarBackfillBudget(
                        maximumCandidates: 64,
                        deadlineUptime: now + 3
                    )
                )
            }
        }
    }
    
    
//    public final func getGroupAvatar(user: String, jid: String, owner: String, size: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
//        callback?(nil)
//    }
    
    public final func storeImage(for key: String, image: UIImage) {
        ImageCache.default.store(image, forKey: key, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
    }

    public final func publishPushAvatarSnapshot(
        _ image: UIImage,
        sourceKey: String,
        metadataRevision: String? = nil,
        owner: String,
        jid: String
    ) {
        publishPushAvatarSnapshot(
            image,
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            identity: PushNotificationAvatarIdentity(owner: owner, contactJid: jid),
            sourceScope: .managed
        )
    }

    final func publishTransientPushAvatarSnapshot(
        _ image: UIImage,
        sourceKey: String,
        metadataRevision: String? = nil,
        owner: String,
        jid: String
    ) {
        publishPushAvatarSnapshot(
            image,
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            identity: PushNotificationAvatarIdentity(owner: owner, contactJid: jid),
            sourceScope: .unmanagedTransient
        )
    }

    private func publishPushAvatarSnapshot(
        _ image: UIImage,
        sourceKey: String,
        metadataRevision: String?,
        identity: PushNotificationAvatarIdentity,
        sourceScope: PushAvatarSnapshotSourceScope
    ) {
        let token = pushAvatarPublisher.begin(
            identity: identity,
            sourceKey: sourceKey,
            metadataRevision: metadataRevision,
            sourceScope: sourceScope
        )
        pushAvatarPublisher.publish(image, token: token)
    }

    public final func invalidatePushAvatarSnapshot(owner: String, jid: String) {
        pushAvatarPublisher.remove(
            identity: PushNotificationAvatarIdentity(owner: owner, contactJid: jid)
        )
    }

    public final func invalidatePushAvatarSnapshot(
        owner: String,
        groupchat: String,
        participantId: String
    ) {
        pushAvatarPublisher.remove(
            identity: PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: groupchat,
                participantId: participantId
            )
        )
    }

    public final func invalidatePushAvatarSnapshots(
        owner: String,
        groupchat: String,
        participantIds: [String]
    ) {
        let groupIdentity = PushNotificationAvatarIdentity(
            owner: owner,
            contactJid: groupchat
        )
        let participantIdentities = participantIds.map {
            PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: groupchat,
                participantId: $0
            )
        }
        pushAvatarPublisher.remove(
            identities: [groupIdentity] + participantIdentities
        )
    }

    static func pushAvatarGroupIdentity(
        owner: String,
        storedGroupPrimary: String,
        resolvedGroupJid: String?,
        participantId: String
    ) -> PushNotificationAvatarIdentity? {
        _ = storedGroupPrimary
        guard let groupchat = resolvedGroupJid?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !groupchat.isEmpty else {
            return nil
        }
        return PushNotificationAvatarIdentity(
            owner: owner,
            groupchat: groupchat,
            participantId: participantId
        )
    }

    final func cachedAvatarImage(url: String?) -> UIImage? {
        guard let url = url else {
            return nil
        }

        return ImageCache.default.retrieveImageInMemoryCache(
            forKey: url,
            options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory])
        )
    }
    
    public final func getGroupAvatar(url: String?, userId: String, jid: String, owner: String, size requiredSize: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        if let url = url {
            let token = pushAvatarPublisher.begin(
                identity: PushNotificationAvatarIdentity(
                    owner: owner,
                    groupchat: jid,
                    participantId: userId
                ),
                sourceKey: url
            )
            if ImageCache.default.isCached(forKey: url) {
                ImageCache.default.retrieveImage(forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]), callbackQueue: .mainAsync) { result in
                    switch result {
                        case .success(let image):
                            guard let cachedImage = image.image else {
                                callback?(nil)
                                return
                            }
                            callback?(cachedImage)
                            self.pushAvatarPublisher.publish(cachedImage, token: token)
                        default:
                            callback?(nil)
                    }
                }
            } else {
                callback?(nil)
                guard let urlUnwr = URL(string: url) else {
                    return
                }
                ImageDownloader.default.downloadImage(with: urlUnwr, options: KingfisherParsedOptionsInfo([.cacheOriginalImage, .alsoPrefetchToMemory, .callbackQueue(.untouch)])) { result in
                    switch result {
                        case .success(let image):
                            ImageCache.default.store(image.image, forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                            self.pushAvatarPublisher.publish(image.image, token: token)
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                do {
                                    let realm = try WRealm.safe()
                                    if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: userId, groupchat: jid, owner: owner)) {
                                        try realm.write {
                                            instance.updatedTS = Date().timeIntervalSince1970
                                        }
                                    }
                                } catch {
                                    DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                                }
                            }
                        default:
                            break
                    }
                }
            }
        }
        callback?(nil)
    }
    
    public final func getAvatar(url: String?, jid: String, owner: String, size requiredSize: CGFloat = 0, callback: ((UIImage?) -> Void)?) {
        guard let url = url else {
            callback?(nil)
            return
        }
        let token = pushAvatarPublisher.begin(
            identity: PushNotificationAvatarIdentity(owner: owner, contactJid: jid),
            sourceKey: url
        )

        if let cachedImage = cachedAvatarImage(url: url) {
            callback?(cachedImage)
            pushAvatarPublisher.publish(cachedImage, token: token)
            return
        }

        if ImageCache.default.isCached(forKey: url) {
            ImageCache.default.retrieveImage(forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory, .loadDiskFileSynchronously]), callbackQueue: .mainAsync) { result in
                switch result {
                    case .success(let image):
                        guard let cachedImage = image.image else {
                            callback?(nil)
                            return
                        }
//                            print("rgthio", image.image == nil)
                        callback?(cachedImage)
                        self.pushAvatarPublisher.publish(cachedImage, token: token)
                    default:
                        callback?(nil)
                }
            }
            return
        }

        callback?(nil)
        guard let urlUnwr = URL(string: url) else {
            return
        }
        ImageDownloader.default.downloadImage(with: urlUnwr, options: KingfisherParsedOptionsInfo([.cacheOriginalImage, .keepCurrentImageWhileLoading, .alsoPrefetchToMemory, .callbackQueue(.untouch)])) { result in
            switch result {
                case .success(let image):
                    ImageCache.default.store(image.image, forKey: url, options: KingfisherParsedOptionsInfo([.alsoPrefetchToMemory]))
                    self.pushAvatarPublisher.publish(image.image, token: token)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        do {
                            let realm = try WRealm.safe()
                            let collectionChats = realm.objects(LastChatsStorageItem.self).filter("jid == %@ AND owner == %@", jid, owner)
                            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                                try realm.write {
                                    instance.updatedTS = Date().timeIntervalSince1970
                                    collectionChats.forEach { $0.updateTS = Date().timeIntervalSince1970 }
                                }
                            }
                            if jid == owner {
                                if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                                    try realm.write {
                                        instance.avatarUpdatedTS = Double(Date().timeIntervalSince1970)
                                    }
                                }
                            }

                        } catch {
                            DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                default:
                    break
            }
        }
    }
    
    public final func deleteAvatar(jid: String, owner: String) {
        pushAvatarPublisher.remove(
            identity: PushNotificationAvatarIdentity(owner: owner, contactJid: jid)
        )
    }
    
    public final func deleteAllAvatars() {
        pushAvatarPublisher.removeAll()
        ImageCache.default.memoryStorage.removeAll()
        do {
            try ImageCache.default.diskStorage.removeAll()
        } catch {
            DDLogDebug("DefaultAvatarManager: unable to clear avatar disk cache")
        }
        do {
            let realm = try WRealm.safe()
            let avatars =  realm.objects(AvatarStorageItem.self)
            try realm.write {
                realm.delete(avatars)
            }
        } catch {
            DDLogDebug("DefaultAvatarManager: unable to clear AvatarStorageItems")
        }
    }

    private struct PushAvatarSnapshotCandidate {
        let identity: PushNotificationAvatarIdentity
        let sourceKeys: [String]
        let sourceRevision: String
        let metadataRevision: String?
    }

    private struct PushAvatarBackfillCursor {
        var phase: Int = 0
        var rosterOffset: Int = 0
        var accountOffset: Int = 0
        var groupParticipantOffset: Int = 0
    }

    private func pushAvatarSnapshotCandidates(
        limit: Int,
        cursor: inout PushAvatarBackfillCursor,
        budget: inout PushAvatarBackfillBudget
    ) -> [PushAvatarSnapshotCandidate] {
        do {
            let realm = try WRealm.safe()
            var candidates: [PushAvatarSnapshotCandidate] = []
            var identities = Set<PushNotificationAvatarIdentity>()

            func appendCandidate(
                identity: PushNotificationAvatarIdentity,
                sourceKeys: [String],
                metadataRevision: String?
            ) {
                guard candidates.count < limit,
                      budget.canContinue(at: ProcessInfo.processInfo.systemUptime),
                      !sourceKeys.isEmpty else {
                    return
                }
                let sourceRevision = PushAvatarSnapshotRevision.make(
                    sourceKeys: sourceKeys,
                    metadataRevision: metadataRevision
                )
                guard !PushNotificationAvatarStore.shared.hasValidSnapshot(
                    for: identity,
                    sourceKey: sourceRevision
                ) else {
                    return
                }
                let cachedSourceKeys = sourceKeys.filter {
                    ImageCache.default.isCached(forKey: $0)
                }
                guard !cachedSourceKeys.isEmpty,
                      identities.insert(identity).inserted,
                      budget.claim(at: ProcessInfo.processInfo.systemUptime) else {
                    return
                }
                candidates.append(PushAvatarSnapshotCandidate(
                    identity: identity,
                    sourceKeys: cachedSourceKeys,
                    sourceRevision: sourceRevision,
                    metadataRevision: metadataRevision
                ))
            }

            let rosterItems = realm.objects(RosterStorageItem.self)
            while cursor.phase == 0,
                  cursor.rosterOffset < rosterItems.count,
                  candidates.count < limit,
                  budget.canContinue(at: ProcessInfo.processInfo.systemUptime) {
                let item = rosterItems[cursor.rosterOffset]
                cursor.rosterOffset += 1
                guard !item.removed, !item.isHidden else { continue }
                let identity = PushNotificationAvatarIdentity(
                    owner: item.owner,
                    contactJid: item.jid
                )
                guard identity.entityJid != identity.owner else { continue }
                appendCandidate(
                    identity: identity,
                    sourceKeys: Self.effectiveAvatarSourceKeys(
                        maxURL: item.avatarMaxUrl,
                        minURL: item.avatarMinUrl,
                        oldschoolKey: item.oldschoolAvatarKey
                    ),
                    metadataRevision: item.oldschoolAvatarKey
                )
            }
            if cursor.phase == 0, cursor.rosterOffset >= rosterItems.count {
                cursor.phase = 1
            }

            let accountItems = realm.objects(AccountStorageItem.self)
            while cursor.phase == 1,
                  cursor.accountOffset < accountItems.count,
                  candidates.count < limit,
                  budget.canContinue(at: ProcessInfo.processInfo.systemUptime) {
                let item = accountItems[cursor.accountOffset]
                cursor.accountOffset += 1
                appendCandidate(
                    identity: PushNotificationAvatarIdentity(
                        owner: item.jid,
                        contactJid: item.jid
                    ),
                    sourceKeys: Self.effectiveAvatarSourceKeys(
                        maxURL: item.avatarMaxUrl,
                        minURL: item.avatarMinUrl,
                        oldschoolKey: item.oldschoolAvatarKey
                    ),
                    metadataRevision: item.oldschoolAvatarKey
                )
            }
            if cursor.phase == 1, cursor.accountOffset >= accountItems.count {
                cursor.phase = 2
            }

            let groupUsers = realm.objects(GroupchatUserStorageItem.self)
            while cursor.phase == 2,
                  cursor.groupParticipantOffset < groupUsers.count,
                  candidates.count < limit,
                  budget.canContinue(at: ProcessInfo.processInfo.systemUptime) {
                let item = groupUsers[cursor.groupParticipantOffset]
                cursor.groupParticipantOffset += 1
                let participantId = item.userId.isEmpty ? item.jid : item.userId
                guard !item.avatarURI.isEmpty,
                      !participantId.isEmpty,
                      !item.groupchatId.isEmpty,
                      !item.isKicked,
                      !item.isHidden,
                      !item.isTemporary,
                      let group = realm.object(
                        ofType: GroupChatStorageItem.self,
                        forPrimaryKey: item.groupchatId
                      ),
                      !group.isDeleted,
                      let identity = Self.pushAvatarGroupIdentity(
                        owner: item.owner,
                        storedGroupPrimary: item.groupchatId,
                        resolvedGroupJid: group.jid,
                        participantId: participantId
                      ) else {
                    continue
                }
                appendCandidate(
                    identity: identity,
                    sourceKeys: [item.avatarURI],
                    metadataRevision: Self.groupAvatarMetadataRevision(
                        avatarHash: item.avatarHash,
                        temporaryAvatarHash: item.temporaryAvatarHash
                    )
                )
            }
            if cursor.phase == 2,
               cursor.groupParticipantOffset >= groupUsers.count {
                cursor.phase = 3
            }
            return candidates
        } catch {
            DDLogDebug("DefaultAvatarManager: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    private func continuePushAvatarBackfill(
        cursor: PushAvatarBackfillCursor,
        budget: PushAvatarBackfillBudget
    ) {
        var nextCursor = cursor
        var nextBudget = budget
        guard nextCursor.phase < 3,
              nextBudget.canContinue(at: ProcessInfo.processInfo.systemUptime) else {
            return
        }
        let candidates = pushAvatarSnapshotCandidates(
            limit: min(8, nextBudget.remainingCandidates),
            cursor: &nextCursor,
            budget: &nextBudget
        )
        guard !candidates.isEmpty else { return }
        backfillPushAvatarSnapshots(
            candidates: candidates,
            deadlineUptime: nextBudget.deadlineUptime
        ) { [weak self] in
            Self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                guard let self else { return }
                autoreleasepool {
                    self.continuePushAvatarBackfill(
                        cursor: nextCursor,
                        budget: nextBudget
                    )
                }
            }
        }
    }

    private func backfillPushAvatarSnapshots(
        candidates: [PushAvatarSnapshotCandidate],
        candidateIndex: Int = 0,
        deadlineUptime: TimeInterval,
        completion: @escaping () -> Void
    ) {
        guard candidateIndex < candidates.count,
              ProcessInfo.processInfo.systemUptime < deadlineUptime else {
            completion()
            return
        }
        let candidate = candidates[candidateIndex]
        if PushNotificationAvatarStore.shared.hasValidSnapshot(
            for: candidate.identity,
            sourceKey: candidate.sourceRevision
        ) {
            backfillPushAvatarSnapshots(
                candidates: candidates,
                candidateIndex: candidateIndex + 1,
                deadlineUptime: deadlineUptime,
                completion: completion
            )
            return
        }
        retrieveBackfillImage(
            candidate: candidate,
            sourceIndex: 0
        ) { [weak self] in
            self?.backfillPushAvatarSnapshots(
                candidates: candidates,
                candidateIndex: candidateIndex + 1,
                deadlineUptime: deadlineUptime,
                completion: completion
            )
        }
    }

    private func retrieveBackfillImage(
        candidate: PushAvatarSnapshotCandidate,
        sourceIndex: Int,
        completion: @escaping () -> Void
    ) {
        guard sourceIndex < candidate.sourceKeys.count else {
            completion()
            return
        }
        let sourceKey = candidate.sourceKeys[sourceIndex]
        let token = pushAvatarPublisher.begin(
            identity: candidate.identity,
            sourceKey: sourceKey,
            metadataRevision: candidate.metadataRevision
        )
        Self.queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            autoreleasepool {
                let options = KingfisherParsedOptionsInfo([])
                let memoryImage = ImageCache.default.retrieveImageInMemoryCache(
                    forKey: sourceKey,
                    options: options
                )
                let diskImage: UIImage? = {
                    guard memoryImage == nil,
                          let data = try? ImageCache.default.diskStorage.value(
                            forKey: sourceKey
                          ) else {
                        return nil
                    }
                    return options.cacheSerializer.image(with: data, options: options)
                }()
                guard let image = memoryImage ?? diskImage else {
                    self.retrieveBackfillImage(
                        candidate: candidate,
                        sourceIndex: sourceIndex + 1,
                        completion: completion
                    )
                    return
                }
                self.pushAvatarPublisher.publish(image, token: token) { _ in
                    completion()
                }
            }
        }
    }

    private func currentPushAvatarSourceRevision(
        for token: PushAvatarSnapshotGenerationGate.Token
    ) -> String? {
        do {
            let realm = try WRealm.safe()
            let identity = token.identity
            let ownerAccount = realm.object(
                ofType: AccountStorageItem.self,
                forPrimaryKey: identity.owner
            ) ?? realm.objects(AccountStorageItem.self)
                .filter("jid ==[c] %@", identity.owner)
                .first
            guard let ownerAccount else { return nil }
            let sourceKeys: [String]
            let metadataRevision: String?
            switch identity.scope {
            case .contact:
                if identity.entityJid == identity.owner {
                    sourceKeys = Self.effectiveAvatarSourceKeys(
                        maxURL: ownerAccount.avatarMaxUrl,
                        minURL: ownerAccount.avatarMinUrl,
                        oldschoolKey: ownerAccount.oldschoolAvatarKey
                    )
                    metadataRevision = ownerAccount.oldschoolAvatarKey
                } else {
                    guard let item = realm.object(
                        ofType: RosterStorageItem.self,
                        forPrimaryKey: RosterStorageItem.genPrimary(
                            jid: identity.entityJid,
                            owner: identity.owner
                        )
                    ) else {
                        return Self.missingRecordSourceRevision(for: token)
                    }
                    guard !item.removed, !item.isHidden else { return nil }
                    sourceKeys = Self.effectiveAvatarSourceKeys(
                        maxURL: item.avatarMaxUrl,
                        minURL: item.avatarMinUrl,
                        oldschoolKey: item.oldschoolAvatarKey
                    )
                    metadataRevision = item.oldschoolAvatarKey
                }
            case .groupParticipant:
                guard let participantId = identity.participantId else { return nil }
                let groupPrimary = GroupChatStorageItem.genPrimary(
                    jid: identity.entityJid,
                    owner: identity.owner
                )
                var item = realm.object(
                    ofType: GroupchatUserStorageItem.self,
                    forPrimaryKey: GroupchatUserStorageItem.genPrimary(
                        id: participantId,
                        groupchat: identity.entityJid,
                        owner: identity.owner
                    )
                )
                if item == nil, participantId.contains("@") {
                    item = realm.objects(GroupchatUserStorageItem.self)
                        .filter(
                            "owner == %@ AND groupchatId == %@ AND jid ==[c] %@",
                            identity.owner,
                            groupPrimary,
                            participantId
                        )
                        .first
                }
                guard let item else {
                    return Self.missingRecordSourceRevision(for: token)
                }
                guard !item.isKicked,
                      !item.isHidden,
                      !item.isTemporary || token.sourceScope == .unmanagedTransient else {
                    return nil
                }
                guard let group = realm.object(
                    ofType: GroupChatStorageItem.self,
                    forPrimaryKey: groupPrimary
                ), !group.isDeleted else {
                    return token.sourceScope == .unmanagedTransient
                        ? Self.missingRecordSourceRevision(for: token)
                        : nil
                }
                sourceKeys = Self.uniqueNonEmptySourceKeys([item.avatarURI])
                metadataRevision = Self.groupAvatarMetadataRevision(
                    avatarHash: item.avatarHash,
                    temporaryAvatarHash: item.temporaryAvatarHash
                )
            }
            guard sourceKeys.contains(token.sourceKey) else { return nil }
            if let expectedMetadataRevision = token.metadataRevision,
               expectedMetadataRevision != metadataRevision {
                return nil
            }
            return PushAvatarSnapshotRevision.make(
                sourceKeys: sourceKeys,
                metadataRevision: metadataRevision
            )
        } catch {
            DDLogDebug("DefaultAvatarManager: unable to validate push avatar source")
            return nil
        }
    }

    private static func missingRecordSourceRevision(
        for token: PushAvatarSnapshotGenerationGate.Token
    ) -> String? {
        guard token.sourceScope == .unmanagedTransient else { return nil }
        return PushAvatarSnapshotRevision.make(
            sourceKeys: [token.sourceKey],
            metadataRevision: token.metadataRevision
        )
    }

    static func groupAvatarMetadataRevision(
        avatarHash: String,
        temporaryAvatarHash: String
    ) -> String? {
        let values = uniqueNonEmptySourceKeys([avatarHash, temporaryAvatarHash])
        guard !values.isEmpty else { return nil }
        return (["avatarHash"] + values).joined(separator: "\u{0}")
    }

    private static func effectiveAvatarSourceKeys(
        maxURL: String?,
        minURL: String?,
        oldschoolKey: String?
    ) -> [String] {
        let remoteKeys = uniqueNonEmptySourceKeys([maxURL, minURL])
        if !remoteKeys.isEmpty {
            return remoteKeys
        }
        return uniqueNonEmptySourceKeys([oldschoolKey])
    }

    private static func uniqueNonEmptySourceKeys(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value,
                  !value.isEmpty,
                  seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

}
