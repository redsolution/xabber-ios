import Foundation
import RealmSwift

struct RosterCircleMemberSnapshot: Hashable {
    enum Kind: Hashable {
        case contact
        case groupchat
    }

    let primary: String
    let owner: String
    let jid: String
    let displayName: String
    let rosterName: String?
    let avatarURL: String?
    let groups: [String]
    let kind: Kind
    let status: ResourceStatus

    init(
        primary: String,
        owner: String,
        jid: String,
        displayName: String,
        rosterName: String?,
        avatarURL: String?,
        groups: [String],
        kind: Kind,
        status: ResourceStatus
    ) {
        self.primary = primary
        self.owner = owner
        self.jid = GroupStorageKey.bareJID(jid)
        self.displayName = displayName
        self.rosterName = rosterName
        self.avatarURL = avatarURL
        self.groups = RosterCircleGroups.normalized(groups)
        self.kind = kind
        self.status = status
    }
}

struct RosterCircleSnapshot: Equatable {
    let name: String
    let members: [RosterCircleMemberSnapshot]
}

struct RosterCircleAvatarSummary: Equatable {
    static let maximumVisibleCount = 3

    let visibleMembers: [RosterCircleMemberSnapshot]
    let overflowCount: Int

    init(members: [RosterCircleMemberSnapshot]) {
        visibleMembers = Array(members.prefix(Self.maximumVisibleCount))
        overflowCount = max(0, members.count - Self.maximumVisibleCount)
    }
}

enum RosterCircleValidationError: Error, Equatable {
    case emptyName
    case duplicateName
    case noMembers
    case circleNotFound
}

enum RosterCircleName {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func key(_ value: String) -> String {
        normalized(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        key(lhs) == key(rhs)
    }

    static func validate(_ value: String, existingNames: [String]) throws -> String {
        let normalizedValue = normalized(value)
        guard normalizedValue.isNotEmpty else {
            throw RosterCircleValidationError.emptyName
        }
        guard RosterCircleGroups.isSystemName(normalizedValue) == false else {
            throw RosterCircleValidationError.duplicateName
        }
        guard existingNames.contains(where: { isSame($0, normalizedValue) }) == false else {
            throw RosterCircleValidationError.duplicateName
        }
        return normalizedValue
    }
}

enum RosterCircleGroups {
    static let systemNames: Set<String> =
        [RosterGroupStorageItem.systemGroupName, RosterGroupStorageItem.notInRosterGroupName]

    static func isSystemName(_ name: String) -> Bool {
        let key = RosterCircleName.key(name)
        return systemNames.contains { RosterCircleName.key($0) == key }
    }

    static func normalized(_ groups: [String]) -> [String] {
        var resultByKey: [String: String] = [:]
        groups.forEach { rawValue in
            let value = RosterCircleName.normalized(rawValue)
            guard value.isNotEmpty, isSystemName(value) == false else { return }
            let key = RosterCircleName.key(value)
            if resultByKey[key] == nil {
                resultByKey[key] = value
            }
        }
        return resultByKey.values.sorted(by: circleNameSort)
    }

    static func contains(_ name: String, in groups: [String]) -> Bool {
        groups.contains(where: { RosterCircleName.isSame($0, name) })
    }

    static func adding(_ name: String, to groups: [String]) -> [String] {
        normalized(groups + [name])
    }

    static func removing(_ name: String, from groups: [String]) -> [String] {
        normalized(groups.filter { RosterCircleName.isSame($0, name) == false })
    }

    static func replacing(_ oldName: String, with newName: String, in groups: [String]) -> [String] {
        adding(newName, to: removing(oldName, from: groups))
    }

    private static func circleNameSort(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
    }
}

enum RosterCircleCatalog {
    static func circles(from members: [RosterCircleMemberSnapshot]) -> [RosterCircleSnapshot] {
        let sortedMembers = members.sorted(by: memberSort)
        var namesByKey: [String: String] = [:]
        var membersByKey: [String: [RosterCircleMemberSnapshot]] = [:]

        sortedMembers.forEach { member in
            member.groups.forEach { rawName in
                let name = RosterCircleName.normalized(rawName)
                guard name.isNotEmpty, RosterCircleGroups.isSystemName(name) == false else { return }
                let key = RosterCircleName.key(name)
                if namesByKey[key] == nil {
                    namesByKey[key] = name
                }
                if membersByKey[key]?.contains(where: { $0.primary == member.primary }) != true {
                    membersByKey[key, default: []].append(member)
                }
            }
        }

        return namesByKey
            .map { key, name in
                RosterCircleSnapshot(name: name, members: membersByKey[key] ?? [])
            }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return comparison == .orderedSame ? lhs.name < rhs.name : comparison == .orderedAscending
            }
    }

    static func members(
        in circleName: String,
        from members: [RosterCircleMemberSnapshot]
    ) -> [RosterCircleMemberSnapshot] {
        members
            .filter { RosterCircleGroups.contains(circleName, in: $0.groups) }
            .sorted(by: memberSort)
    }

    static func memberSort(
        _ lhs: RosterCircleMemberSnapshot,
        _ rhs: RosterCircleMemberSnapshot
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.jid.localizedCaseInsensitiveCompare(rhs.jid) == .orderedAscending
        }
        return comparison == .orderedAscending
    }
}

struct RosterCircleMutation: Equatable {
    let primary: String
    let owner: String
    let jid: String
    let rosterName: String?
    let groups: [String]

    init(
        primary: String,
        owner: String,
        jid: String,
        rosterName: String?,
        groups: [String]
    ) {
        self.primary = primary
        self.owner = owner
        self.jid = GroupStorageKey.bareJID(jid)
        self.rosterName = rosterName
        self.groups = RosterCircleGroups.normalized(groups)
    }
}

enum RosterCircleOperationPlan {
    static func create(
        name: String,
        selectedPrimaries: Set<String>,
        members: [RosterCircleMemberSnapshot],
        existingCircleNames: [String],
        allowsExistingTarget: Bool = false
    ) throws -> [RosterCircleMutation] {
        let namesForValidation = allowsExistingTarget
            ? existingCircleNames.filter { RosterCircleName.isSame($0, name) == false }
            : existingCircleNames
        let normalizedName = try RosterCircleName.validate(
            name,
            existingNames: namesForValidation
        )
        guard selectedPrimaries.isNotEmpty else {
            throw RosterCircleValidationError.noMembers
        }
        let selectedMembers = members.filter { selectedPrimaries.contains($0.primary) }
        guard selectedMembers.isNotEmpty else {
            throw RosterCircleValidationError.noMembers
        }
        return selectedMembers
            .filter { RosterCircleGroups.contains(normalizedName, in: $0.groups) == false }
            .map { mutation(for: $0, groups: RosterCircleGroups.adding(normalizedName, to: $0.groups)) }
            .sorted { $0.primary < $1.primary }
    }

    static func setMembers(
        circleName: String,
        selectedPrimaries: Set<String>,
        members: [RosterCircleMemberSnapshot]
    ) throws -> [RosterCircleMutation] {
        let normalizedName = RosterCircleName.normalized(circleName)
        guard normalizedName.isNotEmpty else {
            throw RosterCircleValidationError.circleNotFound
        }
        guard members.contains(where: {
            RosterCircleGroups.contains(normalizedName, in: $0.groups)
        }) else {
            throw RosterCircleValidationError.circleNotFound
        }
        return members.compactMap { member in
            let isCurrentMember = RosterCircleGroups.contains(normalizedName, in: member.groups)
            let shouldBeMember = selectedPrimaries.contains(member.primary)
            guard isCurrentMember != shouldBeMember else { return nil }
            let groups = shouldBeMember
                ? RosterCircleGroups.adding(normalizedName, to: member.groups)
                : RosterCircleGroups.removing(normalizedName, from: member.groups)
            return mutation(for: member, groups: groups)
        }.sorted { $0.primary < $1.primary }
    }

    static func rename(
        oldName: String,
        newName: String,
        members: [RosterCircleMemberSnapshot],
        existingCircleNames: [String],
        allowsExistingTarget: Bool = false
    ) throws -> [RosterCircleMutation] {
        guard members.contains(where: {
            RosterCircleGroups.contains(oldName, in: $0.groups)
        }) else {
            throw RosterCircleValidationError.circleNotFound
        }
        let namesExcludingCurrent = existingCircleNames.filter { existingName in
            guard RosterCircleName.isSame(existingName, oldName) == false else { return false }
            return allowsExistingTarget == false
                || RosterCircleName.isSame(existingName, newName) == false
        }
        let normalizedName = try RosterCircleName.validate(
            newName,
            existingNames: namesExcludingCurrent
        )
        guard RosterCircleName.isSame(oldName, normalizedName) == false || oldName != normalizedName else {
            return []
        }
        return members
            .filter { RosterCircleGroups.contains(oldName, in: $0.groups) }
            .map {
                mutation(
                    for: $0,
                    groups: RosterCircleGroups.replacing(oldName, with: normalizedName, in: $0.groups)
                )
            }
            .sorted { $0.primary < $1.primary }
    }

    static func delete(
        name: String,
        members: [RosterCircleMemberSnapshot]
    ) -> [RosterCircleMutation] {
        members
            .filter { RosterCircleGroups.contains(name, in: $0.groups) }
            .map { mutation(for: $0, groups: RosterCircleGroups.removing(name, from: $0.groups)) }
            .sorted { $0.primary < $1.primary }
    }

    static func removeMember(
        primary: String,
        from circleName: String,
        members: [RosterCircleMemberSnapshot]
    ) -> [RosterCircleMutation] {
        guard let member = members.first(where: {
            $0.primary == primary && RosterCircleGroups.contains(circleName, in: $0.groups)
        }) else {
            return []
        }
        return [mutation(for: member, groups: RosterCircleGroups.removing(circleName, from: member.groups))]
    }

    private static func mutation(
        for member: RosterCircleMemberSnapshot,
        groups: [String]
    ) -> RosterCircleMutation {
        RosterCircleMutation(
            primary: member.primary,
            owner: member.owner,
            jid: member.jid,
            rosterName: member.rosterName,
            groups: groups
        )
    }
}

struct RosterCircleSelectionState {
    let members: [RosterCircleMemberSnapshot]
    let initiallySelectedPrimaries: Set<String>
    var selectedPrimaries: Set<String>
    var query: String = ""

    init(members: [RosterCircleMemberSnapshot], initiallySelected: Set<String>) {
        self.members = members.sorted(by: RosterCircleCatalog.memberSort)
        initiallySelectedPrimaries = initiallySelected
        selectedPrimaries = initiallySelected
    }

    var filteredMembers: [RosterCircleMemberSnapshot] {
        let normalizedQuery = RosterCircleName.normalized(query)
        guard normalizedQuery.isNotEmpty else { return members }
        return members.filter { member in
            matches(member.displayName, query: normalizedQuery)
                || matches(member.jid, query: normalizedQuery)
        }
    }

    var hasChanges: Bool {
        selectedPrimaries != initiallySelectedPrimaries
    }

    mutating func toggle(primary: String) {
        if selectedPrimaries.contains(primary) {
            selectedPrimaries.remove(primary)
        } else {
            selectedPrimaries.insert(primary)
        }
    }

    func canCreate(name: String, existingNames: [String]) -> Bool {
        guard selectedPrimaries.isNotEmpty else { return false }
        return (try? RosterCircleName.validate(name, existingNames: existingNames)) != nil
    }

    private func matches(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: .current
        ) != nil
    }
}

enum RosterCircleMutationError: Error, Equatable {
    case connection
    case timeout
    case server(String)
}

struct RosterCircleBatchFailure: Equatable {
    let primary: String
    let error: RosterCircleMutationError
}

struct RosterCircleBatchResult: Equatable {
    let confirmedPrimaries: Set<String>
    let failures: [RosterCircleBatchFailure]

    var isComplete: Bool { failures.isEmpty }
}

protocol RosterCircleMutationSending: AnyObject {
    func send(
        _ mutation: RosterCircleMutation,
        completion: @escaping (Result<Void, RosterCircleMutationError>) -> Void
    )
}

final class RosterCircleBatchExecutor {
    private let sender: RosterCircleMutationSending
    private let maximumConcurrentRequests: Int
    private let lock = NSLock()
    private var pending: [RosterCircleMutation] = []
    private var inFlight: Set<String> = []
    private var confirmed: Set<String> = []
    private var failures: [RosterCircleBatchFailure] = []
    private var completion: ((RosterCircleBatchResult) -> Void)?

    init(sender: RosterCircleMutationSending, maximumConcurrentRequests: Int = 4) {
        precondition(maximumConcurrentRequests > 0)
        self.sender = sender
        self.maximumConcurrentRequests = maximumConcurrentRequests
    }

    func execute(
        _ mutations: [RosterCircleMutation],
        completion: @escaping (RosterCircleBatchResult) -> Void
    ) {
        lock.lock()
        precondition(self.completion == nil, "A batch executor cannot run overlapping batches")
        pending = mutations
        inFlight = []
        confirmed = []
        failures = []
        self.completion = completion
        lock.unlock()

        if mutations.isEmpty {
            finishIfNeeded()
        } else {
            startAvailableRequests()
        }
    }

    private func startAvailableRequests() {
        var toStart: [RosterCircleMutation] = []
        lock.lock()
        while inFlight.count < maximumConcurrentRequests, pending.isNotEmpty {
            let mutation = pending.removeFirst()
            inFlight.insert(mutation.primary)
            toStart.append(mutation)
        }
        lock.unlock()

        toStart.forEach { mutation in
            sender.send(mutation) { [weak self] result in
                self?.didComplete(mutation, result: result)
            }
        }
    }

    private func didComplete(
        _ mutation: RosterCircleMutation,
        result: Result<Void, RosterCircleMutationError>
    ) {
        lock.lock()
        guard inFlight.remove(mutation.primary) != nil else {
            lock.unlock()
            return
        }
        switch result {
        case .success:
            confirmed.insert(mutation.primary)
        case .failure(let error):
            failures.append(RosterCircleBatchFailure(primary: mutation.primary, error: error))
        }
        let shouldStartMore = pending.isNotEmpty
        lock.unlock()

        if shouldStartMore {
            startAvailableRequests()
        }
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        var callback: ((RosterCircleBatchResult) -> Void)?
        var result: RosterCircleBatchResult?
        lock.lock()
        if pending.isEmpty, inFlight.isEmpty, let completion {
            callback = completion
            result = RosterCircleBatchResult(
                confirmedPrimaries: confirmed,
                failures: failures.sorted { $0.primary < $1.primary }
            )
            self.completion = nil
        }
        lock.unlock()

        if let callback, let result {
            callback(result)
        }
    }
}

protocol RosterCircleSnapshotStoring {
    func members(owner: String) throws -> [RosterCircleMemberSnapshot]
}

final class RealmRosterCircleSnapshotStore: RosterCircleSnapshotStoring {
    func members(owner: String) throws -> [RosterCircleMemberSnapshot] {
        let owner = GroupStorageKey.bareJID(owner)
        let realm = try WRealm.safe()
        let ignoredJIDs = Set(
            XMPPServiceJidsSupport.ignoredServiceJids(in: realm, accountJids: [owner])
                .map(GroupStorageKey.bareJID)
        )
        let groups = CanonicalGroupListUIQuery.active(in: realm, owners: [owner])
        let groupByJID = Dictionary(uniqueKeysWithValues: groups.map { ($0.groupJID, $0) })

        return realm.objects(RosterStorageItem.self)
            .filter("owner == %@ AND isHidden == false AND removed == false", owner)
            .toArray()
            .compactMap { item -> RosterCircleMemberSnapshot? in
                let jid = GroupStorageKey.bareJID(item.jid)
                guard jid.isNotEmpty, ignoredJIDs.contains(jid) == false else { return nil }

                let group = groupByJID[jid]
                let isJoinedContact = item.isContact
                    && [RosterStorageItem.Subsccribtion.to, .from, .both].contains(item.subscribtion)
                guard isJoinedContact || group != nil else { return nil }

                let kind: RosterCircleMemberSnapshot.Kind = group == nil ? .contact : .groupchat
                let displayName = group?.title ?? item.displayName
                let avatarURL = item.avatarMaxUrl
                    ?? group?.avatarURL
                    ?? item.avatarMinUrl
                    ?? item.oldschoolAvatarKey
                let status = group?.statusDisplayed ?? item.getPrimaryResource()?.status ?? .offline
                let rosterName = item.customUsername.trimmingCharacters(in: .whitespacesAndNewlines)

                return RosterCircleMemberSnapshot(
                    primary: item.primary,
                    owner: item.owner,
                    jid: jid,
                    displayName: displayName,
                    rosterName: rosterName.isEmpty ? nil : rosterName,
                    avatarURL: avatarURL,
                    groups: item.groups.toArray(),
                    kind: kind,
                    status: status
                )
            }
            .sorted(by: RosterCircleCatalog.memberSort)
    }
}

final class XMPPRosterCircleMutationSender: RosterCircleMutationSending {
    func send(
        _ mutation: RosterCircleMutation,
        completion: @escaping (Result<Void, RosterCircleMutationError>) -> Void
    ) {
        XMPPUIActionManager.shared.performRequest(owner: mutation.owner) { stream, session in
            guard let roster = session.roster else {
                completion(.failure(.connection))
                return
            }
            roster.setContact(
                stream,
                jid: mutation.jid,
                nickname: mutation.rosterName,
                groups: mutation.groups,
                mutationMode: .acknowledged,
                responseTimeout: 15
            ) { _, error, succeeded in
                if succeeded {
                    completion(.success(()))
                } else if error == RosterManager.acknowledgedMutationTimeoutError {
                    completion(.failure(.timeout))
                } else {
                    completion(.failure(.server(error ?? "unknown-error")))
                }
            }
        } fail: {
            completion(.failure(.connection))
        }
    }
}

enum RosterCircleServiceError: Error, Equatable {
    case validation(RosterCircleValidationError)
    case storage(String)
}

protocol RosterCircleServicing: AnyObject {
    func loadMembers() throws -> [RosterCircleMemberSnapshot]
    func loadCircles() throws -> [RosterCircleSnapshot]
    func create(
        name: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    )
    func setMembers(
        circleName: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    )
    func rename(
        oldName: String,
        newName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    )
    func delete(
        name: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    )
    func removeMember(
        primary: String,
        circleName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    )
}

final class RosterCircleService: RosterCircleServicing {
    private enum RetryOperation: Hashable {
        case create(nameKey: String, selectedPrimaries: [String])
        case rename(oldNameKey: String, newNameKey: String)
    }

    private let owner: String
    private let store: RosterCircleSnapshotStoring
    private let sender: RosterCircleMutationSending
    private let retryLock = NSLock()
    private var retryOperations: Set<RetryOperation> = []

    init(
        owner: String,
        store: RosterCircleSnapshotStoring = RealmRosterCircleSnapshotStore(),
        sender: RosterCircleMutationSending = XMPPRosterCircleMutationSender()
    ) {
        self.owner = GroupStorageKey.bareJID(owner)
        self.store = store
        self.sender = sender
    }

    func loadMembers() throws -> [RosterCircleMemberSnapshot] {
        try store.members(owner: owner)
    }

    func loadCircles() throws -> [RosterCircleSnapshot] {
        RosterCircleCatalog.circles(from: try loadMembers())
    }

    func create(
        name: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        let retryOperation = RetryOperation.create(
            nameKey: RosterCircleName.key(name),
            selectedPrimaries: selectedPrimaries.sorted()
        )
        let allowsExistingTarget = isPendingRetry(retryOperation)
        perform({ members in
            try RosterCircleOperationPlan.create(
                name: name,
                selectedPrimaries: selectedPrimaries,
                members: members,
                existingCircleNames: RosterCircleCatalog.circles(from: members).map(\.name),
                allowsExistingTarget: allowsExistingTarget
            )
        }, retryOperation: retryOperation, completion: completion)
    }

    func setMembers(
        circleName: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        perform({ members in
            try RosterCircleOperationPlan.setMembers(
                circleName: circleName,
                selectedPrimaries: selectedPrimaries,
                members: members
            )
        }, completion: completion)
    }

    func rename(
        oldName: String,
        newName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        let retryOperation = RetryOperation.rename(
            oldNameKey: RosterCircleName.key(oldName),
            newNameKey: RosterCircleName.key(newName)
        )
        let allowsExistingTarget = isPendingRetry(retryOperation)
        perform({ members in
            try RosterCircleOperationPlan.rename(
                oldName: oldName,
                newName: newName,
                members: members,
                existingCircleNames: RosterCircleCatalog.circles(from: members).map(\.name),
                allowsExistingTarget: allowsExistingTarget
            )
        }, retryOperation: retryOperation, completion: completion)
    }

    func delete(
        name: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        perform({ RosterCircleOperationPlan.delete(name: name, members: $0) }, completion: completion)
    }

    func removeMember(
        primary: String,
        circleName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        perform({
            RosterCircleOperationPlan.removeMember(primary: primary, from: circleName, members: $0)
        }, completion: completion)
    }

    private func perform(
        _ makeMutations: ([RosterCircleMemberSnapshot]) throws -> [RosterCircleMutation],
        retryOperation: RetryOperation? = nil,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        do {
            let mutations = try makeMutations(loadMembers())
            let executor = RosterCircleBatchExecutor(sender: sender, maximumConcurrentRequests: 4)
            executor.execute(mutations) { [executor] result in
                _ = executor
                if let retryOperation {
                    self.setPendingRetry(retryOperation, pending: result.isComplete == false)
                }
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            }
        } catch let error as RosterCircleValidationError {
            DispatchQueue.main.async { completion(.failure(.validation(error))) }
        } catch {
            DispatchQueue.main.async { completion(.failure(.storage(error.localizedDescription))) }
        }
    }

    private func isPendingRetry(_ operation: RetryOperation) -> Bool {
        retryLock.lock()
        defer { retryLock.unlock() }
        return retryOperations.contains(operation)
    }

    private func setPendingRetry(_ operation: RetryOperation, pending: Bool) {
        retryLock.lock()
        if pending {
            retryOperations.insert(operation)
        } else {
            retryOperations.remove(operation)
        }
        retryLock.unlock()
    }
}
