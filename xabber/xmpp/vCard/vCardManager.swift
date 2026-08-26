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
//import Haneke

internal enum VCardRequestPriority: Int, Comparable {
    case background = 0
    case foreground = 1

    static func < (lhs: VCardRequestPriority, rhs: VCardRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var schedulerPriority: AccountXMPPTaskScheduler.Priority {
        switch self {
        case .background: return .background
        case .foreground: return .foreground
        }
    }
}

internal enum VCardRequestRefreshPolicy {
    static let failureRetryCooldown: TimeInterval = 60

    static func shouldRequest(
        persistedOwner: String?,
        requestOwner: String,
        lastRequestFailed: Bool,
        lastUpdateDate: Date,
        now: Date = Date()
    ) -> Bool {
        // vCardStorageItem is historically keyed only by bare JID. A card
        // written by another account must therefore be treated as a cache
        // miss instead of suppressing this account's visible request.
        guard persistedOwner == requestOwner else {
            return true
        }
        guard lastRequestFailed else {
            return false
        }
        return now.timeIntervalSince(lastUpdateDate) >= failureRetryCooldown
    }
}

internal struct VCardPresentationIdentity: Hashable, Sendable {
    let owner: String
    let jid: String

    init?(owner rawOwner: String, jid rawJID: String) {
        guard let owner = XMPPJID(string: rawOwner)?.bare,
              let jid = XMPPJID(string: rawJID)?.bare,
              owner.isNotEmpty,
              jid.isNotEmpty else {
            return nil
        }
        self.owner = owner
        self.jid = jid
    }
}

/// Schema 19 keeps the historical JID-only Realm primary key for vCards.
/// This process-local projection preserves account-scoped presentation values
/// when two enabled accounts hydrate the same contact JID in one process.
internal final class VCardPresentationProjectionStore {
    static let shared = VCardPresentationProjectionStore()

    private let lock = NSLock()
    private var titlesByIdentity: [VCardPresentationIdentity: String] = [:]

    @discardableResult
    func apply(
        owner: String,
        jid: String,
        title rawTitle: String
    ) -> Bool {
        guard let identity = VCardPresentationIdentity(owner: owner, jid: jid) else {
            return false
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isNotEmpty else { return false }

        lock.lock()
        titlesByIdentity[identity] = title
        lock.unlock()
        return true
    }

    func title(owner: String, jid: String) -> String? {
        guard let identity = VCardPresentationIdentity(owner: owner, jid: jid) else {
            return nil
        }
        lock.lock()
        let title = titlesByIdentity[identity]
        lock.unlock()
        return title
    }

    func titles(
        for identities: Set<VCardPresentationIdentity>
    ) -> [VCardPresentationIdentity: String] {
        lock.lock()
        let titles = identities.reduce(
            into: [VCardPresentationIdentity: String]()
        ) { result, identity in
            result[identity] = titlesByIdentity[identity]
        }
        lock.unlock()
        return titles
    }

    func removeAll(for rawOwner: String) {
        guard let owner = XMPPJID(string: rawOwner)?.bare else { return }
        lock.lock()
        titlesByIdentity = titlesByIdentity.filter { $0.key.owner != owner }
        lock.unlock()
    }
}

internal enum VCardVisibleRetryRequestGuard {
    static func shouldSubmit(
        expectedManagerEpoch: UUID,
        currentManagerEpoch: UUID,
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        isCurrentAccountManager: Bool,
        isStreamAuthenticated: Bool
    ) -> Bool {
        expectedManagerEpoch == currentManagerEpoch
            && expectedGeneration == currentGeneration
            && isCurrentAccountManager
            && isStreamAuthenticated
    }
}

internal struct VCardVisibleRetryProof: Hashable, Sendable {
    let managerEpoch: UUID
    let generation: UInt64
}

internal enum VCardVisibleRequestDisposition: Equatable {
    case satisfied
    case submitted(proof: VCardVisibleRetryProof)
    case retryAfter(deadline: Date, proof: VCardVisibleRetryProof)
    case stale
    case unavailable
}

internal struct VCardSingleFlightRequest: Equatable {
    let owner: String
    let jid: String
    let generation: UInt64
    let elementID: String
    let priority: VCardRequestPriority

    var deduplicationKey: String {
        "vcard.\(owner).\(generation).\(jid)"
    }
}

internal enum VCardSingleFlightSubmission: Equatable {
    case enqueue(VCardSingleFlightRequest)
    case joined(VCardSingleFlightRequest)
    case promote(VCardSingleFlightRequest)
}

/// Owns the complete account-scoped vCard request lifecycle. A scheduler
/// transaction remains active from wire send through response persistence;
/// queued duplicates join the same stanza and can only raise its priority.
internal final class VCardRequestSingleFlightCoordinator {
    typealias Completion = (VCardSingleFlightRequest, Bool) -> Void

    struct ResponseReceipt: Equatable {
        fileprivate let request: VCardSingleFlightRequest
    }

    private enum State: Equatable {
        case queued
        case active
        case processingResponse
    }

    private struct Entry {
        var request: VCardSingleFlightRequest
        var state: State
        var completions: [Completion]
        var schedulerFinish: (() -> Void)?
        var timeoutWorkItem: DispatchWorkItem?
    }

    static let responseTimeout: TimeInterval = 15

    private let owner: String
    private let timeout: TimeInterval
    private let timeoutQueue: DispatchQueue
    private let elementIDFactory: () -> String
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var entriesByElementID: [String: Entry] = [:]
    private var elementIDByJID: [String: String] = [:]

    init(
        owner: String,
        timeout: TimeInterval = VCardRequestSingleFlightCoordinator.responseTimeout,
        timeoutQueue: DispatchQueue = DispatchQueue(label: "com.xabber.vcard-single-flight.timeout"),
        elementIDFactory: @escaping () -> String = { "vCard: \(NanoID.new(8))" }
    ) {
        self.owner = Self.normalizedBareJID(owner) ?? owner
        self.timeout = max(0, timeout)
        self.timeoutQueue = timeoutQueue
        self.elementIDFactory = elementIDFactory
    }

    var currentGeneration: UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    var pendingCount: Int {
        lock.lock()
        let value = entriesByElementID.count
        lock.unlock()
        return value
    }

    @discardableResult
    func streamDidPrepare() -> UInt64 {
        advanceGeneration()
    }

    func disconnect() {
        _ = advanceGeneration()
    }

    func submit(
        jid rawJID: String,
        priority: VCardRequestPriority,
        completion: Completion? = nil
    ) -> VCardSingleFlightSubmission? {
        guard let jid = Self.normalizedBareJID(rawJID) else {
            completion?(
                VCardSingleFlightRequest(
                    owner: owner,
                    jid: rawJID,
                    generation: currentGeneration,
                    elementID: elementIDFactory(),
                    priority: priority
                ),
                false
            )
            return nil
        }

        lock.lock()
        if let elementID = elementIDByJID[jid],
           var existing = entriesByElementID[elementID],
           existing.request.generation == generation {
            if let completion {
                existing.completions.append(completion)
            }
            if priority > existing.request.priority,
               existing.state == .queued {
                existing.request = VCardSingleFlightRequest(
                    owner: existing.request.owner,
                    jid: existing.request.jid,
                    generation: existing.request.generation,
                    elementID: existing.request.elementID,
                    priority: priority
                )
                entriesByElementID[elementID] = existing
                lock.unlock()
                return .promote(existing.request)
            }
            entriesByElementID[elementID] = existing
            lock.unlock()
            return .joined(existing.request)
        }

        let request = VCardSingleFlightRequest(
            owner: owner,
            jid: jid,
            generation: generation,
            elementID: elementIDFactory(),
            priority: priority
        )
        entriesByElementID[request.elementID] = Entry(
            request: request,
            state: .queued,
            completions: completion.map { [$0] } ?? [],
            schedulerFinish: nil,
            timeoutWorkItem: nil
        )
        elementIDByJID[jid] = request.elementID
        lock.unlock()
        return .enqueue(request)
    }

    @discardableResult
    func activate(
        _ request: VCardSingleFlightRequest,
        schedulerFinish: @escaping () -> Void
    ) -> Bool {
        let timeoutWorkItem: DispatchWorkItem
        lock.lock()
        guard var entry = matchingEntryLocked(request),
              entry.state == .queued else {
            lock.unlock()
            return false
        }
        entry.state = .active
        entry.schedulerFinish = schedulerFinish
        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.failIdentity(
                elementID: request.elementID,
                generation: request.generation
            )
        }
        entry.timeoutWorkItem = timeoutWorkItem
        entriesByElementID[request.elementID] = entry
        lock.unlock()

        timeoutQueue.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )
        return true
    }

    func matchResponse(
        elementID: String,
        generation responseGeneration: UInt64,
        responseBareJID: String?
    ) -> ResponseReceipt? {
        lock.lock()
        guard responseGeneration == generation,
              var entry = entriesByElementID[elementID],
              entry.request.generation == responseGeneration,
              entry.state == .active else {
            lock.unlock()
            return nil
        }

        let normalizedResponseJID = responseBareJID.flatMap(Self.normalizedBareJID)
        let isSelfResponseWithoutFrom = normalizedResponseJID == nil && entry.request.jid == owner
        guard isSelfResponseWithoutFrom || normalizedResponseJID == entry.request.jid else {
            lock.unlock()
            return nil
        }

        // From this point the response is owned by synchronous persistence.
        // The wire timeout must not release the scheduler lane in the middle
        // of the Realm transaction.
        entry.timeoutWorkItem?.cancel()
        entry.timeoutWorkItem = nil
        entry.state = .processingResponse
        entriesByElementID[elementID] = entry
        lock.unlock()
        return ResponseReceipt(request: entry.request)
    }

    func completeResponse(_ receipt: ResponseReceipt, success: Bool) {
        finishIdentity(
            elementID: receipt.request.elementID,
            generation: receipt.request.generation,
            success: success
        )
    }

    func fail(_ request: VCardSingleFlightRequest) {
        finishIdentity(
            elementID: request.elementID,
            generation: request.generation,
            success: false
        )
    }

    private func matchingEntryLocked(_ request: VCardSingleFlightRequest) -> Entry? {
        guard let entry = entriesByElementID[request.elementID],
              entry.request.generation == request.generation,
              entry.request.jid == request.jid else {
            return nil
        }
        return entry
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        lock.lock()
        generation &+= 1
        let staleEntries = Array(entriesByElementID.values)
        entriesByElementID.removeAll(keepingCapacity: true)
        elementIDByJID.removeAll(keepingCapacity: true)
        let nextGeneration = generation
        lock.unlock()

        staleEntries.forEach { finish($0, success: false) }
        return nextGeneration
    }

    private func failIdentity(elementID: String, generation: UInt64) {
        finishIdentity(elementID: elementID, generation: generation, success: false)
    }

    private func finishIdentity(elementID: String, generation: UInt64, success: Bool) {
        lock.lock()
        guard let entry = entriesByElementID[elementID],
              entry.request.generation == generation else {
            lock.unlock()
            return
        }
        entriesByElementID.removeValue(forKey: elementID)
        if elementIDByJID[entry.request.jid] == elementID {
            elementIDByJID.removeValue(forKey: entry.request.jid)
        }
        lock.unlock()
        finish(entry, success: success)
    }

    private func finish(_ entry: Entry, success: Bool) {
        entry.timeoutWorkItem?.cancel()
        entry.completions.forEach { $0(entry.request, success) }
        entry.schedulerFinish?()
    }

    private static func normalizedBareJID(_ rawJID: String) -> String? {
        let trimmed = rawJID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isNotEmpty,
              let bare = XMPPJID(string: trimmed)?.bare,
              bare.isNotEmpty else {
            return nil
        }
        return bare
    }
}

internal enum VCardTerminalStorageMutation {
    static func persistFailure(
        in realm: Realm,
        owner: String,
        jid: String,
        at date: Date = Date()
    ) {
        if let instance = realm.object(
            ofType: vCardStorageItem.self,
            forPrimaryKey: jid
        ) {
            // `jid` is this object's Realm primary key. Realm rejects even an
            // equal-value assignment once the object is managed.
            instance.owner = owner
            instance.lastUpdateDate = date
            instance.isLastUpdateErrorOccured = true
            return
        }

        let instance = vCardStorageItem()
        instance.jid = jid
        instance.owner = owner
        instance.lastUpdateDate = date
        instance.isLastUpdateErrorOccured = true
        realm.add(instance)
    }
}


class VCardManager: AbstractXMPPManager {
    static let didPersistVCardNotification = Notification.Name(
        "com.xabber.vcard.didPersist"
    )
    static let persistedOwnerUserInfoKey = "owner"
    static let persistedJIDUserInfoKey = "jid"
    static let didFailVisibleVCardRequestNotification = Notification.Name(
        "com.xabber.vcard.didFailVisibleRequest"
    )
    static let failedOwnerUserInfoKey = "owner"
    static let failedJIDUserInfoKey = "jid"
    static let failedManagerEpochUserInfoKey = "managerEpoch"
    static let failedGenerationUserInfoKey = "generation"
    static let failedAtUserInfoKey = "failedAt"

    private let requestCoordinator: VCardRequestSingleFlightCoordinator
    private let requestManagerEpoch: UUID

    internal static func emitDidPersistVCard(
        owner rawOwner: String,
        jid rawJID: String,
        notificationCenter: NotificationCenter = .default
    ) {
        guard let owner = XMPPJID(string: rawOwner)?.bare,
              let jid = XMPPJID(string: rawJID)?.bare else {
            return
        }
        notificationCenter.post(
            name: didPersistVCardNotification,
            object: nil,
            userInfo: [
                persistedOwnerUserInfoKey: owner,
                persistedJIDUserInfoKey: jid,
            ]
        )
    }

    internal static func emitDidFailVisibleVCardRequest(
        owner rawOwner: String,
        jid rawJID: String,
        managerEpoch: UUID,
        generation: UInt64,
        failedAt: Date = Date(),
        notificationCenter: NotificationCenter = .default
    ) {
        guard let owner = XMPPJID(string: rawOwner)?.bare,
              let jid = XMPPJID(string: rawJID)?.bare else {
            return
        }
        notificationCenter.post(
            name: didFailVisibleVCardRequestNotification,
            object: nil,
            userInfo: [
                failedOwnerUserInfoKey: owner,
                failedJIDUserInfoKey: jid,
                failedManagerEpochUserInfoKey: managerEpoch,
                failedGenerationUserInfoKey: generation,
                failedAtUserInfoKey: failedAt,
            ]
        )
    }

    override init(withOwner owner: String) {
        self.requestCoordinator = VCardRequestSingleFlightCoordinator(owner: owner)
        self.requestManagerEpoch = UUID()
        super.init(withOwner: owner)
    }

    override func onStreamPrepared(_ stream: XMPPStream) {
        super.onStreamPrepared(stream)
        guard AccountManager.shared.find(for: owner)?.vcards === self else {
            return
        }
        requestCoordinator.streamDidPrepare()
    }

    override func clearSession() {
        requestCoordinator.disconnect()
        super.clearSession()
    }
    
    class VCardMetaItem {
        var title: String
        var value: String
        var key: String
        var childs: [VCardMetaItem]
        
        init(title: String, value: String, key: String, childs: [VCardMetaItem] = []) {
            self.title = title
            self.value = value
            self.key = key
            self.childs = childs
        }
    }
    
    override func namespaces() -> [String] {
        return [
            "vcard-temp"
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    static public func getVcardStructure(_ vcard: vCardStorageItem, jid: String) -> [VCardMetaItem] {
        var out: [VCardMetaItem] = []
        
        func addSection(_ title: String, items: [VCardMetaItem]) {
            let item = VCardMetaItem(title: title, value: "", key: "", childs: items)
            if out.isEmpty {
                out = [item]
            } else {
                out.append(item)
            }
        }
        
        addSection("Nickname".localizeString(id: "vcard_nick_name", arguments: []), items: [
            VCardMetaItem(title: "\(jid.split(separator: "@").first!)", value: vcard.nickname, key: "ci_nickname"),
            VCardMetaItem(title: "Full name".localizeString(id: "vcard_full_name", arguments: []),
                          value: vcard.fn, key: "ci_full_name"),
            VCardMetaItem(title: "Given name".localizeString(id: "vcard_given_name", arguments: []),
                          value: vcard.given, key: "ci_given_name"),
            VCardMetaItem(title: "Middle name".localizeString(id: "vcard_middle_name", arguments: []),
                          value: vcard.middle, key: "ci_middle_name"),
            VCardMetaItem(title: "Family name".localizeString(id: "vcard_family_name", arguments: []),
                          value: vcard.family, key: "ci_family_name"),
            ])
        
        addSection("Birthday".localizeString(id: "vcard_birth_date", arguments: []), items: [
            VCardMetaItem(title: "YYYY-MM-DD".localizeString(id: "vcard_birth_date_placeholder", arguments: []),
                          value: vcard.birthdayString, key: "ci_birthday")])
        
        addSection("Job".localizeString(id: "vcard_job", arguments: []), items: [
            VCardMetaItem(title: "Company".localizeString(id: "vcard_company", arguments: []),
                          value: vcard.orgname, key: "wp_orgname"),
            VCardMetaItem(title: "Job title".localizeString(id: "vcard_title", arguments: []),
                          value: vcard.title, key: "wp_title"),
            VCardMetaItem(title: "Role".localizeString(id: "vcard_role", arguments: []),
                          value: vcard.role, key: "wp_role"),
            VCardMetaItem(title: "Unit".localizeString(id: "vcard_organization_unit", arguments: []),
                          value: vcard.orgunit, key: "wp_orgunit")
            ])
        
        addSection("Website".localizeString(id: "vcard_website", arguments: []), items: [
            VCardMetaItem(title: "URL".localizeString(id: "vcard_url", arguments: []),
                          value: vcard.url, key: "desc_url")])
        
        addSection("Description".localizeString(id: "vcard_decsription", arguments: []), items: [
            VCardMetaItem(title: "Bio".localizeString(id: "vcard_bio", arguments: []),
                          value: vcard.descr, key: "desc_descr")])
        
        addSection("Phone".localizeString(id: "vcard_telephone", arguments: []), items: [
            VCardMetaItem(title: "Work".localizeString(id: "vcard_type_work", arguments: []),
                          value: vcard.telWorkVoice, key: "ph_workPhone"),
            VCardMetaItem(title: "Home".localizeString(id: "vcard_type_home", arguments: []),
                          value: vcard.telHomeVoice, key: "ph_homePhone"),
            VCardMetaItem(title: "Mobile".localizeString(id: "vcard_type_mobile", arguments: []),
                          value: vcard.telHomeMsg, key: "ph_homeMsg")
            ])
        
        addSection("Email".localizeString(id: "vcard_email", arguments: []), items: [
            VCardMetaItem(title: "Work".localizeString(id: "vcard_type_work", arguments: []),
                          value: vcard.emailWork, key: "desc_email_work"),
            VCardMetaItem(title: "Personal".localizeString(id: "vcard_type_personal", arguments: []),
                          value: vcard.emailHome, key: "desc_email_home"),
            ])
        
        addSection("Home address".localizeString(id: "vcard_home_address", arguments: []), items: [
            VCardMetaItem(title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []),
                          value: vcard.adrHomePoBox, key: "ha_pobox"),
            VCardMetaItem(title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []),
                          value: vcard.adrHomeExtadd, key: "ha_address"),
            VCardMetaItem(title: "Street".localizeString(id: "vcard_address_street", arguments: []),
                          value: vcard.adrHomeStreet, key: "ha_street"),
            VCardMetaItem(title: "Locality".localizeString(id: "vcard_address_locality", arguments: []),
                          value: vcard.adrHomeLocality, key: "ha_locality"),
            VCardMetaItem(title: "Region".localizeString(id: "vcard_address_region", arguments: []),
                          value: vcard.adrHomeRegion, key: "ha_region"),
            VCardMetaItem(title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []),
                          value: vcard.adrHomePCode, key: "ha_pcode"),
            VCardMetaItem(title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []),
                          value: vcard.adrHomeCountry, key: "ha_country")
            ])
        
        addSection("Work address".localizeString(id: "vcard_work_address", arguments: []), items: [
            VCardMetaItem(title: "PO box".localizeString(id: "vcard_address_pobox", arguments: []),
                          value: vcard.adrWorkPoBox, key: "wa_pobox"),
            VCardMetaItem(title: "Extended address".localizeString(id: "vcard_address_extadr", arguments: []),
                          value: vcard.adrWorkExtadd, key: "wa_address"),
            VCardMetaItem(title: "Street".localizeString(id: "vcard_address_street", arguments: []),
                          value: vcard.adrWorkStreet, key: "wa_street"),
            VCardMetaItem(title: "Locality".localizeString(id: "vcard_address_locality", arguments: []),
                          value: vcard.adrWorkLocality, key: "wa_locality"),
            VCardMetaItem(title: "Region".localizeString(id: "vcard_address_region", arguments: []),
                          value: vcard.adrWorkRegion, key: "wa_region"),
            VCardMetaItem(title: "Postal code".localizeString(id: "vcard_address_pcode", arguments: []),
                          value: vcard.adrWorkPCode, key: "wa_pcode"),
            VCardMetaItem(title: "Country name".localizeString(id: "vcard_address_ctry", arguments: []),
                          value: vcard.adrWorkCountry, key: "wa_country")
            ])
        return out
    }
        
    public final func lazyLoadMissedVCards(_ stream: XMPPStream) {
        _ = stream
        do {
            let realm = try WRealm.safe()
            let rosterJIDs = Set(
                realm.objects(RosterStorageItem.self)
                    .filter("owner == %@", owner)
                    .compactMap(\.jid)
            )
            guard let primaryManager = AccountManager.shared.find(for: owner)?.vcards else {
                return
            }
            let now = Date()
            rosterJIDs
                .sorted()
                .filter { jid in
                    let storedCard = realm.object(
                        ofType: vCardStorageItem.self,
                        forPrimaryKey: jid
                    )
                    return VCardRequestRefreshPolicy.shouldRequest(
                        persistedOwner: storedCard?.owner,
                        requestOwner: self.owner,
                        lastRequestFailed: storedCard?.isLastUpdateErrorOccured == true,
                        lastUpdateDate: storedCard?.lastUpdateDate ?? .distantPast,
                        now: now
                    )
                }
                .forEach { jid in
                    _ = primaryManager.scheduleRequest(jid: jid, priority: .background)
                }
        } catch {
            DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
        }
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        guard let elementID = iq.elementID,
              let receipt = requestCoordinator.matchResponse(
                elementID: elementID,
                generation: requestCoordinator.currentGeneration,
                responseBareJID: iq.from?.bare
              ) else {
            return false
        }

        let requestJID = receipt.request.jid
        let isError = iq.iqType == .error || iq.element(forName: "error") != nil
        let didPersist: Bool
        let succeeded: Bool
        if isError {
            didPersist = persistVCardFailure(for: requestJID)
            succeeded = false
        } else if let query = iq.element(forName: "vCard", xmlns: getPrimaryNamespace()) {
            didPersist = persistVCard(query, for: requestJID)
            succeeded = didPersist
        } else {
            didPersist = persistVCardFailure(for: requestJID)
            succeeded = false
        }

        guard didPersist else {
            DDLogError("VCardManager failed to persist terminal response for \(requestJID)")
            requestCoordinator.completeResponse(receipt, success: false)
            return true
        }
        if succeeded {
            Self.emitDidPersistVCard(owner: owner, jid: requestJID)
        }
        requestCoordinator.completeResponse(receipt, success: succeeded)
        return true
    }

    private func persistVCardFailure(for jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            let update = {
                VCardTerminalStorageMutation.persistFailure(
                    in: realm,
                    owner: self.owner,
                    jid: jid
                )
            }
            if realm.isInWriteTransaction {
                update()
            } else {
                try realm.write(update)
            }
            return true
        } catch {
            DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func persistVCard(_ query: DDXMLElement, for jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            var generatedNickname = ""
            var rosterDisplayName: String?
            var rosterAvatarURL: String?
            let update = {
                let stored = realm.object(
                    ofType: vCardStorageItem.self,
                    forPrimaryKey: jid
                )
                let instance = stored ?? vCardStorageItem()
                if stored == nil {
                    instance.jid = jid
                }
                self.apply(query, to: instance)
                generatedNickname = instance.generatedNickname
                if stored == nil {
                    realm.add(instance)
                }

                if jid == self.owner {
                    realm.object(
                        ofType: AccountStorageItem.self,
                        forPrimaryKey: self.owner
                    )?.username = generatedNickname
                } else if let roster = realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: [jid, self.owner].prp()
                ) {
                    roster.username = generatedNickname
                    rosterDisplayName = roster.displayName
                    rosterAvatarURL = roster.avatarUrl
                }
            }
            if realm.isInWriteTransaction {
                update()
            } else {
                try realm.write(update)
            }

            _ = VCardPresentationProjectionStore.shared.apply(
                owner: owner,
                jid: jid,
                title: generatedNickname
            )

            if jid == owner {
                AccountManager.shared.find(for: owner)?.updateUsername(generatedNickname)
            } else if let rosterDisplayName {
                CommonContactsMetadataManager.shared.update(
                    owner: owner,
                    jid: jid,
                    username: rosterDisplayName,
                    avatarUrl: rosterAvatarURL
                )
            }
            return true
        } catch {
            DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func apply(
        _ query: DDXMLElement,
        to instance: vCardStorageItem
    ) {
        instance.lastUpdateDate = Date()
        instance.owner = owner
        instance.isLastUpdateErrorOccured = false
        instance.fn = getEscapingElementValue(element: query.element(forName: "FN"))
        instance.family = getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "FAMILY"))
        instance.given = getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "GIVEN"))
        instance.middle = getEscapingElementValue(element: query.element(forName: "N")?.element(forName: "MIDDLE"))
        instance.nickname = getEscapingElementValue(element: query.element(forName: "NICKNAME"))
        instance.url = getEscapingElementValue(element: query.element(forName: "URL"))
        instance.birthday = Date()
        instance.birthdayString = getEscapingElementValue(element: query.element(forName: "BDAY"))
        instance.orgname = getEscapingElementValue(element: query.element(forName: "ORG")?.element(forName: "ORGNAME"))
        instance.orgunit = getEscapingElementValue(element: query.element(forName: "ORG")?.element(forName: "ORGUNIT"))
        instance.title = getEscapingElementValue(element: query.element(forName: "TITLE"))
        instance.role = getEscapingElementValue(element: query.element(forName: "ROLE"))

        for telephone in query.elements(forName: "TEL") {
            if telephone.element(forName: "WORK") != nil {
                instance.telWorkVoice = getEscapingElementValue(element: telephone.element(forName: "NUMBER"))
            } else if telephone.element(forName: "HOME") != nil {
                instance.telHomeVoice = getEscapingElementValue(element: telephone.element(forName: "NUMBER"))
            } else if telephone.element(forName: "MOBILE") != nil {
                instance.telHomeMsg = getEscapingElementValue(element: telephone.element(forName: "NUMBER"))
            }
        }
        for address in query.elements(forName: "ADR") {
            if address.element(forName: "WORK") != nil {
                instance.adrWorkPoBox = getEscapingElementValue(element: address.element(forName: "POBOX"))
                instance.adrWorkExtadd = getEscapingElementValue(element: address.element(forName: "EXTADD"))
                instance.adrWorkStreet = getEscapingElementValue(element: address.element(forName: "STREET"))
                instance.adrWorkLocality = getEscapingElementValue(element: address.element(forName: "LOCALITY"))
                instance.adrWorkRegion = getEscapingElementValue(element: address.element(forName: "REGION"))
                instance.adrWorkPCode = getEscapingElementValue(element: address.element(forName: "PCODE"))
                instance.adrWorkCountry = getEscapingElementValue(element: address.element(forName: "CTRY"))
            } else if address.element(forName: "HOME") != nil {
                instance.adrHomePoBox = getEscapingElementValue(element: address.element(forName: "POBOX"))
                instance.adrHomeExtadd = getEscapingElementValue(element: address.element(forName: "EXTADD"))
                instance.adrHomeStreet = getEscapingElementValue(element: address.element(forName: "STREET"))
                instance.adrHomeLocality = getEscapingElementValue(element: address.element(forName: "LOCALITY"))
                instance.adrHomeRegion = getEscapingElementValue(element: address.element(forName: "REGION"))
                instance.adrHomePCode = getEscapingElementValue(element: address.element(forName: "PCODE"))
                instance.adrHomeCountry = getEscapingElementValue(element: address.element(forName: "CTRY"))
            }
        }
        for email in query.elements(forName: "EMAIL") {
            if email.element(forName: "WORK") != nil {
                instance.emailWork = getEscapingElementValue(element: email.element(forName: "USERID"))
            }
            if email.element(forName: "HOME") != nil {
                instance.emailHome = getEscapingElementValue(element: email.element(forName: "USERID"))
            }
        }
        instance.jabberId = getEscapingElementValue(element: query.element(forName: "JABBERID"))
        instance.descr = getEscapingElementValue(element: query.element(forName: "DESC"))
    }
    
    private final func getEscapingElementValue(element: DDXMLElement?) -> String {
        return element?.stringValue ?? ""
    }
    
    public final func setSelfNickname(_ stream: XMPPStream, nickname: String) {
        let vcard = DDXMLElement(name: "vCard", xmlns: "vcard-temp")
        vcard.addChild(DDXMLElement(name: "NICKNAME", stringValue: nickname))
        stream.send(XMPPIQ(iqType: .set, to: nil, elementID: stream.generateUUID, child: vcard))
    }
    
    func createFromDatasource(items: [VCardMetaItem]) {
        func fill(_ instance: vCardStorageItem) {
            items.forEach { (item) in
                switch item.key {
                case "ci_nickname":     instance.nickname = item.value
                case "ci_full_name":    instance.fn = item.value
                case "ci_given_name":   instance.given = item.value
                case "ci_middle_name":  instance.middle = item.value
                case "ci_family_name":  instance.family = item.value
                case "ci_birthday":     instance.birthdayString = item.value
                case "wp_title":        instance.title = item.value
                case "wp_role":         instance.role = item.value
                case "wp_orgname":      instance.orgname = item.value
                case "wp_orgunit":      instance.orgunit = item.value
                case "ph_workPhone":    instance.telWorkVoice = item.value
                case "ph_workFax":      instance.telWorkFax = item.value
                case "ph_workMsg":      instance.telWorkMsg = item.value
                case "ph_homePhone":    instance.telHomeVoice = item.value
                case "ph_homeFax":      instance.telHomeFax = item.value
                case "ph_homeMsg":      instance.telHomeMsg = item.value
                case "wa_pobox":        instance.adrWorkPoBox = item.value
                case "wa_address":      instance.adrWorkExtadd = item.value
                case "wa_street":       instance.adrWorkStreet = item.value
                case "wa_locality":     instance.adrWorkLocality = item.value
                case "wa_region":       instance.adrWorkRegion = item.value
                case "wa_pcode":        instance.adrWorkPCode = item.value
                case "wa_country":      instance.adrWorkCountry = item.value
                case "ha_pobox":        instance.adrHomePoBox = item.value
                case "ha_address":      instance.adrHomeExtadd = item.value
                case "ha_street":       instance.adrHomeStreet = item.value
                case "ha_locality":     instance.adrHomeLocality = item.value
                case "ha_region":       instance.adrHomeRegion = item.value
                case "ha_pcode":        instance.adrHomePCode = item.value
                case "ha_country":      instance.adrHomeCountry = item.value
                case "desc_email_work": instance.emailWork = item.value
                case "desc_email_home": instance.emailHome = item.value
                case "desc_xmppId":     instance.jabberId = item.value
                case "desc_descr":      instance.descr = item.value
                case "desc_url":        instance.url = item.value
                default:                break
                }
            }
            AccountManager.shared.find(for: owner)?.updateUsername(instance.generatedNickname)
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: self.owner) {
                if !realm.isInWriteTransaction{
                    try realm.write {
                        if instance.isInvalidated { return }
                        fill(instance)
                    }
                }
            } else {
                let instance = vCardStorageItem()
                instance.jid = owner
                fill(instance)
                if !realm.isInWriteTransaction{
                    try realm.write {
                        if instance.isInvalidated { return }
                        realm.add(instance, update: .modified)
                        if instance.nickname.isNotEmpty {
                            realm.object(ofType: AccountStorageItem.self,
                                         forPrimaryKey: self.owner)?.username = instance.nickname
                        }
                    }
                }
            }
        } catch {
            DDLogDebug(["cant update instance of user vcard", owner, #function].joined(separator: ". "))
        }
    }
    
    public final func requestItem(_ xmppStream: XMPPStream, jid: String, addContactVcardCheckCallback: ((String, Bool) -> Void)? = nil) -> String {
        _ = xmppStream
        guard let primaryManager = AccountManager.shared.find(for: owner)?.vcards else {
            addContactVcardCheckCallback?(jid, false)
            return "vCard: \(NanoID.new(8))"
        }
        let completion: VCardRequestSingleFlightCoordinator.Completion? =
            addContactVcardCheckCallback.map { callback in
                { request, success in
                    callback(request.jid, success)
                }
            }
        return primaryManager.scheduleRequest(jid: jid, priority: .foreground, completion: completion)?.elementID
            ?? "vCard: \(NanoID.new(8))"
    }

    public final func requestIfMissed(_ stream: XMPPStream, jid: String) {
        _ = stream
        _ = requestIfNeeded(jid: jid, priority: .background)
    }

    @discardableResult
    final func requestVisibleIfNeeded(
        _ stream: XMPPStream,
        jid: String
    ) -> VCardVisibleRequestDisposition {
        _ = stream
        return requestIfNeeded(
            jid: jid,
            priority: .foreground,
            reportsVisibleFailure: true
        )
    }

    @discardableResult
    final func retryVisibleIfNeeded(
        _ stream: XMPPStream,
        jid: String,
        expectedProof: VCardVisibleRetryProof
    ) -> VCardVisibleRequestDisposition {
        let isCurrentManager = AccountManager.shared.find(for: owner)?.vcards === self
        guard VCardVisibleRetryRequestGuard.shouldSubmit(
            expectedManagerEpoch: expectedProof.managerEpoch,
            currentManagerEpoch: requestManagerEpoch,
            expectedGeneration: expectedProof.generation,
            currentGeneration: requestCoordinator.currentGeneration,
            isCurrentAccountManager: isCurrentManager,
            isStreamAuthenticated: stream.isAuthenticated
        ) else {
            return .stale
        }
        return requestIfNeeded(
            jid: jid,
            priority: .foreground,
            reportsVisibleFailure: true
        )
    }

    private func requestIfNeeded(
        jid rawJID: String,
        priority: VCardRequestPriority,
        reportsVisibleFailure: Bool = false,
        now: Date = Date()
    ) -> VCardVisibleRequestDisposition {
        guard let jid = XMPPJID(string: rawJID)?.bare else {
            return .unavailable
        }
        do {
            let realm = try WRealm.safe()
            let storedCard = realm.object(
                ofType: vCardStorageItem.self,
                forPrimaryKey: jid
            )
            let persistedOwner = storedCard?.owner
            let lastRequestFailed = storedCard?.isLastUpdateErrorOccured == true
            let lastUpdateDate = storedCard?.lastUpdateDate ?? .distantPast
            guard VCardRequestRefreshPolicy.shouldRequest(
                persistedOwner: persistedOwner,
                requestOwner: owner,
                lastRequestFailed: lastRequestFailed,
                lastUpdateDate: lastUpdateDate,
                now: now
            ) else {
                if persistedOwner == owner, lastRequestFailed {
                    return .retryAfter(
                        deadline: lastUpdateDate.addingTimeInterval(
                            VCardRequestRefreshPolicy.failureRetryCooldown
                        ),
                        proof: VCardVisibleRetryProof(
                            managerEpoch: requestManagerEpoch,
                            generation: requestCoordinator.currentGeneration
                        )
                    )
                }
                return .satisfied
            }
            guard let primaryManager = AccountManager.shared.find(for: owner)?.vcards,
                  primaryManager === self else {
                return .unavailable
            }
            let managerEpoch = requestManagerEpoch
            let completion: VCardRequestSingleFlightCoordinator.Completion? =
                reportsVisibleFailure
                    ? { request, success in
                        guard !success else { return }
                        Self.emitDidFailVisibleVCardRequest(
                            owner: request.owner,
                            jid: request.jid,
                            managerEpoch: managerEpoch,
                            generation: request.generation
                        )
                    }
                    : nil
            guard let request = primaryManager.scheduleRequest(
                jid: jid,
                priority: priority,
                completion: completion
            ) else {
                return .unavailable
            }
            return .submitted(
                proof: VCardVisibleRetryProof(
                    managerEpoch: requestManagerEpoch,
                    generation: request.generation
                )
            )
        } catch {
            DDLogDebug("VCardManager: \(#function). \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func scheduleRequest(
        jid: String,
        priority: VCardRequestPriority,
        completion: VCardRequestSingleFlightCoordinator.Completion? = nil
    ) -> VCardSingleFlightRequest? {
        guard let account = AccountManager.shared.find(for: owner),
              account.vcards === self else {
            return nil
        }
        guard let submission = requestCoordinator.submit(
            jid: jid,
            priority: priority,
            completion: completion
        ) else {
            return nil
        }

        let request: VCardSingleFlightRequest
        switch submission {
        case .joined(let joined):
            return joined
        case .promote(let promoted):
            account.xmppTaskScheduler.promotePendingTask(
                deduplicationKey: promoted.deduplicationKey,
                to: promoted.priority.schedulerPriority
            )
            return promoted
        case .enqueue(let enqueued):
            request = enqueued
        }

        account.xmppTaskScheduler.enqueueAccountTask(
            priority: request.priority.schedulerPriority,
            resource: .vcard,
            deduplicationKey: request.deduplicationKey,
            requiresAuthenticatedStream: true,
            unavailable: { [weak self] in
                self?.requestCoordinator.fail(request)
            }
        ) { [weak self] account, _, schedulerFinish in
            guard let self else {
                schedulerFinish()
                return
            }
            guard self.requestCoordinator.activate(
                request,
                schedulerFinish: schedulerFinish
            ) else {
                schedulerFinish()
                return
            }

            let iq = XMPPIQ(
                iqType: .get,
                to: request.jid == request.owner ? nil : XMPPJID(string: request.jid),
                elementID: request.elementID,
                child: DDXMLElement(name: "vCard", xmlns: self.getPrimaryNamespace())
            )
            if case .rejected = account.sendPrimaryStanza(
                iq,
                replayPolicy: .notReplayable
            ) {
                self.requestCoordinator.fail(request)
            }
        }
        return request
    }
    
    func update(_ xmppStream: XMPPStream) {
        
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: self.owner) {
                let elementId = xmppStream.generateUUID
                let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: instance.getXMLData())
                xmppStream.send(iq)
            }
        } catch {
            DDLogDebug("cant update vcard instance")
        }
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        VCardPresentationProjectionStore.shared.removeAll(for: owner)
        do {
            let realm = try  WRealm.safe()
            var collection: [vCardStorageItem] = []
            realm.objects(RosterStorageItem.self)
                .filter("owner == %@", owner)
                .map({ return $0.jid })
                .forEach({
                    if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: $0) {
                        collection.append(instance)
                    }
                })
            if commitTransaction {
                try realm.write {
                    realm.delete(collection)
                }
            } else {
                realm.delete(collection)
            }
        } catch {
            DDLogDebug("cant save vcard instance")
        }
    }
    
}
