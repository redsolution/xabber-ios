import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class RosterCircleManagementTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "RosterCircleManagementTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testCatalogBuildsSortedCirclesAndFiltersSystemNames() {
        let alice = member(
            "alice@example.com",
            name: "Alice",
            groups: ["Work", RosterGroupStorageItem.systemGroupName, "Friends"]
        )
        let room = member(
            "room@example.com",
            name: "Room",
            groups: ["work", "Travel"],
            kind: .groupchat
        )

        let circles = RosterCircleCatalog.circles(from: [room, alice])

        XCTAssertEqual(circles.map(\.name), ["Friends", "Travel", "Work"])
        XCTAssertEqual(circles[0].members.map(\.jid), ["alice@example.com"])
        XCTAssertEqual(circles[2].members.map(\.jid), ["alice@example.com", "room@example.com"])
        XCTAssertEqual(circles[2].members.last?.kind, .groupchat)
        XCTAssertFalse(circles.map(\.name).contains(RosterGroupStorageItem.systemGroupName))
        XCTAssertFalse(circles.map(\.name).contains(RosterGroupStorageItem.notInRosterGroupName))
    }

    func testAvatarSummaryUsesAtMostThreeAvatarsAndOverflow() {
        let members = (0..<8).map { member("user\($0)@example.com", name: "User \($0)") }

        XCTAssertEqual(RosterCircleAvatarSummary(members: []).visibleMembers.count, 0)
        XCTAssertEqual(RosterCircleAvatarSummary(members: []).overflowCount, 0)
        XCTAssertEqual(RosterCircleAvatarSummary(members: Array(members.prefix(1))).visibleMembers.count, 1)
        XCTAssertEqual(RosterCircleAvatarSummary(members: Array(members.prefix(3))).visibleMembers.count, 3)
        XCTAssertEqual(RosterCircleAvatarSummary(members: Array(members.prefix(5))).visibleMembers.count, 3)
        XCTAssertEqual(RosterCircleAvatarSummary(members: Array(members.prefix(5))).overflowCount, 2)
        XCTAssertEqual(RosterCircleAvatarSummary(members: members).visibleMembers.count, 3)
        XCTAssertEqual(RosterCircleAvatarSummary(members: members).overflowCount, 5)
    }

    func testNameValidationTrimsAndComparesCaseAndDiacriticsInsensitively() {
        XCTAssertEqual(RosterCircleName.normalized("  Friends \n"), "Friends")
        XCTAssertThrowsError(try RosterCircleName.validate("  ", existingNames: [])) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .emptyName)
        }
        XCTAssertThrowsError(try RosterCircleName.validate("Ecole", existingNames: ["École"])) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .duplicateName)
        }
        XCTAssertThrowsError(try RosterCircleName.validate(
            RosterGroupStorageItem.systemGroupName.uppercased(),
            existingNames: []
        )) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .duplicateName)
        }
        XCTAssertEqual(
            try RosterCircleName.validate(" Travel ", existingNames: ["Friends"]),
            "Travel"
        )
    }

    func testCreateAddsCircleAndPreservesRosterNameAndOtherGroups() throws {
        let alice = member(
            "alice@example.com",
            name: "Alice",
            rosterName: "A. Example",
            groups: ["Friends", "Friends", ""]
        )

        let mutations = try RosterCircleOperationPlan.create(
            name: " Work ",
            selectedPrimaries: [alice.primary],
            members: [alice],
            existingCircleNames: ["Friends"]
        )

        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations[0].rosterName, "A. Example")
        XCTAssertEqual(mutations[0].groups, ["Friends", "Work"])
    }

    func testCreateRejectsSelectionThatNoLongerExistsInRoster() {
        XCTAssertThrowsError(try RosterCircleOperationPlan.create(
            name: "Work",
            selectedPrimaries: ["removed-primary"],
            members: [],
            existingCircleNames: []
        )) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .noMembers)
        }
    }

    func testSetMembersUsesSymmetricDifferenceOnly() throws {
        let alice = member("alice@example.com", name: "Alice", groups: ["Friends", "Work"])
        let bob = member("bob@example.com", name: "Bob", groups: ["Work"])
        let carol = member("carol@example.com", name: "Carol", groups: ["Family"])

        let mutations = try RosterCircleOperationPlan.setMembers(
            circleName: "Work",
            selectedPrimaries: [alice.primary, carol.primary],
            members: [alice, bob, carol]
        )

        XCTAssertEqual(mutations.map(\.primary), [bob.primary, carol.primary])
        XCTAssertEqual(mutations[0].groups, [])
        XCTAssertEqual(mutations[1].groups, ["Family", "Work"])
    }

    func testRenameAndDeletePreserveOtherGroupsWithoutMerge() throws {
        let alice = member("alice@example.com", name: "Alice", groups: ["Friends", "Work"])
        let bob = member("bob@example.com", name: "Bob", groups: ["Work"])

        let renamed = try RosterCircleOperationPlan.rename(
            oldName: "Work",
            newName: " Team ",
            members: [alice, bob],
            existingCircleNames: ["Friends", "Work"]
        )
        XCTAssertEqual(renamed.map(\.groups), [["Friends", "Team"], ["Team"]])

        XCTAssertThrowsError(
            try RosterCircleOperationPlan.rename(
                oldName: "Work",
                newName: "friends",
                members: [alice, bob],
                existingCircleNames: ["Friends", "Work"]
            )
        ) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .duplicateName)
        }

        let deleted = RosterCircleOperationPlan.delete(name: "Work", members: [alice, bob])
        XCTAssertEqual(deleted.map(\.groups), [["Friends"], []])
    }

    func testEditAndRenameRejectCircleThatNoLongerExists() {
        let alice = member("alice@example.com", name: "Alice", groups: ["Friends"])

        XCTAssertThrowsError(try RosterCircleOperationPlan.setMembers(
            circleName: "Work",
            selectedPrimaries: [alice.primary],
            members: [alice]
        )) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .circleNotFound)
        }
        XCTAssertThrowsError(try RosterCircleOperationPlan.rename(
            oldName: "Work",
            newName: "Team",
            members: [alice],
            existingCircleNames: ["Friends"]
        )) {
            XCTAssertEqual($0 as? RosterCircleValidationError, .circleNotFound)
        }
    }

    func testRemoveMemberOnlyChangesRequestedRosterItem() {
        let alice = member("alice@example.com", name: "Alice", groups: ["Friends", "Work"])
        let bob = member("bob@example.com", name: "Bob", groups: ["Work"])

        let mutations = RosterCircleOperationPlan.removeMember(
            primary: alice.primary,
            from: "Work",
            members: [alice, bob]
        )

        XCTAssertEqual(mutations.map(\.primary), [alice.primary])
        XCTAssertEqual(mutations.first?.groups, ["Friends"])
    }

    func testSelectionSearchMatchesDisplayNameAndBareJIDAndKeepsSelection() {
        let alice = member("alice@example.com/mobile", name: "Álice Johnson")
        let bob = member("bob@example.com", name: "Bob")
        var state = RosterCircleSelectionState(
            members: [bob, alice],
            initiallySelected: [bob.primary]
        )

        state.toggle(primary: alice.primary)
        state.query = "alice"
        XCTAssertEqual(state.filteredMembers.map(\.primary), [alice.primary])
        XCTAssertEqual(state.selectedPrimaries, [alice.primary, bob.primary])

        state.query = "bob@example"
        XCTAssertEqual(state.filteredMembers.map(\.primary), [bob.primary])
        XCTAssertTrue(state.hasChanges)
    }

    func testCreateSelectionRequiresUniqueNameAndAtLeastOneMember() {
        let alice = member("alice@example.com", name: "Alice")
        var state = RosterCircleSelectionState(members: [alice], initiallySelected: [])

        XCTAssertFalse(state.canCreate(name: "Friends", existingNames: []))
        state.toggle(primary: alice.primary)
        XCTAssertTrue(state.canCreate(name: " Friends ", existingNames: []))
        XCTAssertFalse(state.canCreate(name: "", existingNames: []))
        XCTAssertFalse(state.canCreate(name: "friends", existingNames: ["Friends"]))
    }

    func testProjectionKeepsOneItemInMultipleGroupsAndDeletesEmptyProjection() throws {
        let realm = try WRealm.safe()
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: "alice@example.com", owner: "me@example.com")
        roster.owner = "me@example.com"
        roster.jid = "alice@example.com"

        try realm.write {
            realm.add(roster)
            RosterGroupProjectionSynchronizer.synchronize(
                roster,
                groups: ["Friends", "Work"],
                owner: roster.owner,
                realm: realm
            )
        }

        let friends = try XCTUnwrap(realm.object(
            ofType: RosterGroupStorageItem.self,
            forPrimaryKey: RosterGroupStorageItem.genPrimary(name: "Friends", owner: roster.owner)
        ))
        let workPrimary = RosterGroupStorageItem.genPrimary(name: "Work", owner: roster.owner)
        XCTAssertEqual(friends.contacts.map(\.primary), [roster.primary])
        XCTAssertEqual(realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: workPrimary)?.contacts.map(\.primary), [roster.primary])

        try realm.write {
            RosterGroupProjectionSynchronizer.synchronize(
                roster,
                groups: ["Friends"],
                owner: roster.owner,
                realm: realm
            )
        }

        XCTAssertNil(realm.object(ofType: RosterGroupStorageItem.self, forPrimaryKey: workPrimary))
        XCTAssertEqual(friends.contacts.map(\.primary), [roster.primary])

        try realm.write {
            RosterGroupProjectionSynchronizer.remove(roster, owner: roster.owner, realm: realm)
        }
        XCTAssertNil(realm.object(
            ofType: RosterGroupStorageItem.self,
            forPrimaryKey: RosterGroupStorageItem.genPrimary(name: "Friends", owner: roster.owner)
        ))
    }

    func testProjectionReusesCaseInsensitiveGroupInsteadOfDuplicatingIt() throws {
        let realm = try WRealm.safe()
        let roster = RosterStorageItem()
        roster.primary = RosterStorageItem.genPrimary(jid: "alice@example.com", owner: "me@example.com")
        roster.owner = "me@example.com"
        roster.jid = "alice@example.com"
        let existingGroup = RosterGroupStorageItem()
        existingGroup.primary = RosterGroupStorageItem.genPrimary(
            name: "work",
            owner: roster.owner
        )
        existingGroup.owner = roster.owner
        existingGroup.name = "work"

        try realm.write {
            realm.add(roster)
            realm.add(existingGroup)
            RosterGroupProjectionSynchronizer.synchronize(
                roster,
                groups: ["Work"],
                owner: roster.owner,
                realm: realm
            )
        }

        let matchingGroups = realm.objects(RosterGroupStorageItem.self)
            .filter("owner == %@", roster.owner)
            .toArray()
            .filter { RosterCircleName.isSame($0.name, "Work") }
        XCTAssertEqual(matchingGroups.count, 1)
        XCTAssertEqual(matchingGroups.first?.contacts.map(\.primary), [roster.primary])
    }

    func testRealmSnapshotStoreIncludesJoinedContactsAndActiveGroupChatsAndFiltersTechnicalRows() throws {
        let owner = "me@example.com"
        let realm = try WRealm.safe()
        let contact = RosterStorageItem()
        contact.primary = RosterStorageItem.genPrimary(jid: "alice@example.com", owner: owner)
        contact.owner = owner
        contact.jid = "alice@example.com"
        contact.customUsername = "Alice"
        contact.subscribtion = .both
        contact.avatarMaxUrl = "https://example.com/alice-max.png"
        contact.groups.append("Friends")

        let hidden = RosterStorageItem()
        hidden.primary = RosterStorageItem.genPrimary(jid: "hidden@example.com", owner: owner)
        hidden.owner = owner
        hidden.jid = "hidden@example.com"
        hidden.subscribtion = .both
        hidden.isHidden = true

        let selfItem = RosterStorageItem()
        selfItem.primary = RosterStorageItem.genPrimary(jid: owner, owner: owner)
        selfItem.owner = owner
        selfItem.jid = owner
        selfItem.subscribtion = .both

        let groupJID = "room@example.com"
        let groupPrimary = GroupStorageKey.groupPrimary(owner: owner, groupJID: groupJID)
        let groupRoster = RosterStorageItem()
        groupRoster.primary = RosterStorageItem.genPrimary(jid: groupJID, owner: owner)
        groupRoster.owner = owner
        groupRoster.jid = groupJID
        groupRoster.customUsername = "Roster Room"
        groupRoster.isContact = false
        groupRoster.avatarMaxUrl = "https://example.com/room-max.png"
        groupRoster.groups.append("Work")

        let snapshot = GroupSnapshotStorageItem()
        snapshot.primary = groupPrimary
        snapshot.owner = owner
        snapshot.groupJID = groupJID
        snapshot.name = "Room"
        snapshot.avatarURL = "https://example.com/room-group.png"
        snapshot.settingsPresent = true
        snapshot.lifecycleStateRaw = GroupLifecycleState.active.rawValue

        let membership = GroupSelfMembershipStorageItem()
        membership.primary = groupPrimary
        membership.owner = owner
        membership.groupJID = groupJID
        membership.stateRaw = GroupSelfMembershipState.both.rawValue
        membership.memberID = "self-member"

        let selfMember = GroupMemberStorageItem()
        selfMember.primary = GroupStorageKey.memberPrimary(
            owner: owner,
            groupJID: groupJID,
            memberID: "self-member"
        )
        selfMember.groupPrimary = groupPrimary
        selfMember.owner = owner
        selfMember.groupJID = groupJID
        selfMember.memberID = "self-member"
        selfMember.jid = owner
        selfMember.roleRaw = GroupMemberRole.member.rawValue

        try realm.write {
            realm.add([contact, hidden, selfItem, groupRoster])
            realm.add(snapshot)
            realm.add(membership)
            realm.add(selfMember)
        }

        let members = try RealmRosterCircleSnapshotStore().members(owner: owner)

        XCTAssertEqual(members.map(\.displayName), ["Alice", "Room"])
        XCTAssertEqual(members.map(\.kind), [.contact, .groupchat])
        XCTAssertEqual(
            members.map(\.avatarURL),
            ["https://example.com/alice-max.png", "https://example.com/room-max.png"]
        )
        XCTAssertEqual(members.map(\.groups), [["Friends"], ["Work"]])
    }

    func testRosterSetQueryContainsOneItemAndDeduplicatedGroups() throws {
        let query = RosterManager.makeSetContactQuery(
            jid: "alice@example.com",
            nickname: "Alice",
            groups: ["Work", "", " Work ", "Friends", "Friends"]
        )

        let items = query.elements(forName: "item")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].attributeStringValue(forName: "jid"), "alice@example.com")
        XCTAssertEqual(items[0].attributeStringValue(forName: "name"), "Alice")
        XCTAssertEqual(items[0].elements(forName: "group").compactMap(\.stringValue), ["Friends", "Work"])
    }

    func testBatchExecutorCapsConcurrencyAndReportsPartialResult() {
        let sender = ControlledCircleMutationSender()
        let executor = RosterCircleBatchExecutor(sender: sender, maximumConcurrentRequests: 4)
        let mutations = (0..<8).map {
            RosterCircleMutation(
                primary: "primary-\($0)",
                owner: "me@example.com",
                jid: "user\($0)@example.com",
                rosterName: nil,
                groups: ["Work"]
            )
        }
        let completed = expectation(description: "batch completes")
        var result: RosterCircleBatchResult?

        executor.execute(mutations) {
            result = $0
            completed.fulfill()
        }

        XCTAssertEqual(sender.inFlightCount, 4)
        XCTAssertEqual(sender.maximumObservedInFlightCount, 4)
        sender.finish(primary: "primary-0", result: .success(()))
        XCTAssertEqual(sender.inFlightCount, 4)
        sender.finishAll { primary in
            primary == "primary-5" ? .failure(.server("not-allowed")) : .success(())
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(result?.confirmedPrimaries.count, 7)
        XCTAssertEqual(result?.failures.map(\.primary), ["primary-5"])
        XCTAssertFalse(result?.isComplete ?? true)
    }

    func testCreateRetryAfterPartialSuccessSendsOnlyRemainingDifference() {
        let alice = member("alice@example.com", name: "Alice")
        let bob = member("bob@example.com", name: "Bob")
        let store = MutableRosterCircleSnapshotStore(members: [alice, bob])
        let sender = ApplyingControlledCircleMutationSender(store: store)
        let service = RosterCircleService(
            owner: "me@example.com",
            store: store,
            sender: sender
        )
        let firstCompletion = expectation(description: "partial create")
        var firstResult: RosterCircleBatchResult?

        service.create(
            name: "Work",
            selectedPrimaries: [alice.primary, bob.primary]
        ) { result in
            firstResult = try? result.get()
            firstCompletion.fulfill()
        }
        XCTAssertEqual(Set(sender.pendingPrimaries), [alice.primary, bob.primary])
        sender.finish(primary: alice.primary, result: .success(()))
        sender.finish(primary: bob.primary, result: .failure(.server("temporary")))
        wait(for: [firstCompletion], timeout: 1)
        XCTAssertEqual(firstResult?.confirmedPrimaries, [alice.primary])
        XCTAssertEqual(store.members.first(where: { $0.primary == alice.primary })?.groups, ["Work"])

        let retryCompletion = expectation(description: "retry create")
        var retryResult: Result<RosterCircleBatchResult, RosterCircleServiceError>?
        service.create(
            name: "Work",
            selectedPrimaries: [alice.primary, bob.primary]
        ) { result in
            retryResult = result
            retryCompletion.fulfill()
        }
        XCTAssertEqual(sender.pendingPrimaries, [bob.primary])
        sender.finish(primary: bob.primary, result: .success(()))
        wait(for: [retryCompletion], timeout: 1)

        XCTAssertEqual(try? retryResult?.get().confirmedPrimaries, [bob.primary])
        XCTAssertEqual(store.members.first(where: { $0.primary == bob.primary })?.groups, ["Work"])
    }

    func testRenameRetryPlanAllowsPartiallyCreatedTargetAndSkipsConfirmedMembers() throws {
        let alice = member("alice@example.com", name: "Alice", groups: ["Team"])
        let bob = member("bob@example.com", name: "Bob", groups: ["Work"])

        let mutations = try RosterCircleOperationPlan.rename(
            oldName: "Work",
            newName: "Team",
            members: [alice, bob],
            existingCircleNames: ["Team", "Work"],
            allowsExistingTarget: true
        )

        XCTAssertEqual(mutations.map(\.primary), [bob.primary])
        XCTAssertEqual(mutations.first?.groups, ["Team"])
    }

    func testAcknowledgedRosterSetDoesNotMutateUntilResultArrives() throws {
        let owner = "me@example.com"
        let roster = try storeRosterItem(
            jid: "alice@example.com",
            owner: owner,
            nickname: "Alice Roster",
            groups: ["Friends"]
        )
        let scheduler = RosterCircleTestScheduler()
        let manager = RosterManager(withOwner: owner, initialRosterScheduler: scheduler)
        let stream = RosterCircleCapturingXMPPStream()
        var callback: (jid: String?, error: String?, success: Bool)?

        manager.setContact(
            stream,
            jid: roster.jid,
            nickname: roster.customUsername,
            groups: ["Work", "Friends", "Work"],
            mutationMode: .acknowledged,
            responseTimeout: 5
        ) { jid, error, success in
            callback = (jid, error, success)
        }

        XCTAssertEqual(roster.groups.toArray(), ["Friends"])
        XCTAssertNil(callback)
        let iq = try XCTUnwrap(stream.sentIQs.first)
        let item = try XCTUnwrap(iq.element(forName: "query")?.element(forName: "item"))
        XCTAssertEqual(item.attributeStringValue(forName: "name"), "Alice Roster")
        XCTAssertEqual(item.elements(forName: "group").compactMap(\.stringValue), ["Friends", "Work"])

        XCTAssertTrue(manager.read(withIQ: XMPPIQ(iqType: .result, elementID: iq.elementID)))
        XCTAssertEqual(roster.groups.toArray(), ["Friends", "Work"])
        XCTAssertEqual(roster.customUsername, "Alice Roster")
        XCTAssertEqual(callback?.jid, roster.jid)
        XCTAssertNil(callback?.error)
        XCTAssertEqual(callback?.success, true)
        XCTAssertTrue(manager.queueItems.isEmpty)
    }

    func testAcknowledgedRosterSetAppliesRequestedMembershipForEmptyRosterQueryResult() throws {
        let owner = "me@example.com"
        let roster = try storeRosterItem(
            jid: "alice@example.com",
            owner: owner,
            nickname: "Alice",
            groups: ["Friends"]
        )
        let scheduler = RosterCircleTestScheduler()
        let manager = RosterManager(withOwner: owner, initialRosterScheduler: scheduler)
        let stream = RosterCircleCapturingXMPPStream()
        var callbackSucceeded = false

        manager.setContact(
            stream,
            jid: roster.jid,
            nickname: roster.customUsername,
            groups: ["Friends", "Work"],
            mutationMode: .acknowledged
        ) { _, error, success in
            XCTAssertNil(error)
            callbackSucceeded = success
        }
        let requestID = try XCTUnwrap(stream.sentIQs.first?.elementID)
        let emptyQuery = DDXMLElement(name: "query", xmlns: "jabber:iq:roster")

        XCTAssertTrue(manager.read(withIQ: XMPPIQ(
            iqType: .result,
            elementID: requestID,
            child: emptyQuery
        )))
        XCTAssertTrue(callbackSucceeded)
        XCTAssertEqual(roster.groups.toArray(), ["Friends", "Work"])
        XCTAssertTrue(manager.queueItems.isEmpty)
    }

    func testAcknowledgedRosterSetTimeoutLeavesLocalMembershipUntouchedAndIgnoresLateResult() throws {
        let owner = "me@example.com"
        let roster = try storeRosterItem(
            jid: "alice@example.com",
            owner: owner,
            nickname: "Alice",
            groups: ["Friends"]
        )
        let scheduler = RosterCircleTestScheduler()
        let manager = RosterManager(withOwner: owner, initialRosterScheduler: scheduler)
        let stream = RosterCircleCapturingXMPPStream()
        var callbackCount = 0
        var callbackError: String?

        manager.setContact(
            stream,
            jid: roster.jid,
            nickname: roster.customUsername,
            groups: ["Friends", "Work"],
            mutationMode: .acknowledged,
            responseTimeout: 5
        ) { _, error, success in
            callbackCount += 1
            callbackError = error
            XCTAssertFalse(success)
        }
        let requestID = try XCTUnwrap(stream.sentIQs.first?.elementID)

        scheduler.advance(by: 5)

        XCTAssertEqual(roster.groups.toArray(), ["Friends"])
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(callbackError, RosterManager.acknowledgedMutationTimeoutError)
        XCTAssertTrue(manager.queueItems.isEmpty)
        XCTAssertFalse(manager.read(withIQ: XMPPIQ(iqType: .result, elementID: requestID)))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(roster.groups.toArray(), ["Friends"])
    }

    func testAcknowledgedRosterSetErrorLeavesLocalMembershipUntouched() throws {
        let owner = "me@example.com"
        let roster = try storeRosterItem(
            jid: "alice@example.com",
            owner: owner,
            nickname: "Alice",
            groups: ["Friends"]
        )
        let scheduler = RosterCircleTestScheduler()
        let manager = RosterManager(withOwner: owner, initialRosterScheduler: scheduler)
        let stream = RosterCircleCapturingXMPPStream()
        var callbackError: String?

        manager.setContact(
            stream,
            jid: roster.jid,
            nickname: roster.customUsername,
            groups: ["Work"],
            mutationMode: .acknowledged
        ) { _, error, success in
            callbackError = error
            XCTAssertFalse(success)
        }
        let requestID = try XCTUnwrap(stream.sentIQs.first?.elementID)
        let errorElement = DDXMLElement(name: "error")
        errorElement.addChild(DDXMLElement(
            name: "not-allowed",
            xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"
        ))

        XCTAssertTrue(manager.read(withIQ: XMPPIQ(
            iqType: .error,
            elementID: requestID,
            child: errorElement
        )))
        XCTAssertEqual(callbackError, "not-allowed")
        XCTAssertEqual(roster.groups.toArray(), ["Friends"])
        XCTAssertTrue(manager.queueItems.isEmpty)
    }

    private func member(
        _ jid: String,
        name: String,
        rosterName: String? = nil,
        groups: [String] = [],
        kind: RosterCircleMemberSnapshot.Kind = .contact
    ) -> RosterCircleMemberSnapshot {
        let bareJID = jid.split(separator: "/", maxSplits: 1).first.map(String.init) ?? jid
        return RosterCircleMemberSnapshot(
            primary: RosterStorageItem.genPrimary(jid: bareJID, owner: "me@example.com"),
            owner: "me@example.com",
            jid: bareJID,
            displayName: name,
            rosterName: rosterName,
            avatarURL: nil,
            groups: groups,
            kind: kind,
            status: .offline
        )
    }

    private func storeRosterItem(
        jid: String,
        owner: String,
        nickname: String,
        groups: [String]
    ) throws -> RosterStorageItem {
        let realm = try WRealm.safe()
        let item = RosterStorageItem()
        item.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        item.owner = owner
        item.jid = jid
        item.customUsername = nickname
        item.subscribtion = .both
        try realm.write {
            item.groups.append(objectsIn: groups)
            realm.add(item)
            RosterGroupProjectionSynchronizer.synchronize(
                item,
                groups: groups,
                owner: owner,
                realm: realm
            )
        }
        return item
    }
}

@MainActor
final class RosterCircleViewControllerTests: XCTestCase {
    func testCircleListUsesInsetGroupedRowsThreeAvatarsOverflowAndSafeSwipeOrder() throws {
        let members = (0..<8).map {
            circleMember("user\($0)@example.com", name: "User \($0)", groups: ["Work"])
        }
        let service = StubRosterCircleService(members: members)
        let controller = AccountCirclesViewController()
        controller.configure(for: "me@example.com", service: service)

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(RosterCircleInteractionPolicy.trailingActions, [.delete, .rename])
        let cell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? RosterCircleCell
        )
        XCTAssertEqual(cell.titleLabel.text, "Work")
        XCTAssertEqual(cell.avatarStrip.subviews.compactMap { $0 as? UIImageView }.count, 3)
        XCTAssertEqual(
            cell.avatarStrip.subviews.compactMap { ($0 as? UILabel)?.text }.first,
            "+5 more"
        )
        let swipe = try XCTUnwrap(controller.tableView(
            controller.tableView,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)
        ))
        XCTAssertFalse(swipe.performsFirstActionWithFullSwipe)
        XCTAssertEqual(swipe.actions.first?.style, .destructive)
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
    }

    func testCircleNameAndAvatarStripShareOneHorizontalRow() {
        let members = (0..<3).map {
            circleMember("user\($0)@example.com", name: "User \($0)", groups: ["Work"])
        }
        let cell = RosterCircleCell(style: .default, reuseIdentifier: nil)
        cell.configure(circle: RosterCircleSnapshot(name: "Work", members: members))
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 60)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.titleLabel.frame.midY, cell.avatarStrip.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(cell.avatarStrip.frame.minX, cell.titleLabel.frame.maxX)
        let avatarFrame = cell.avatarStrip.convert(cell.avatarStrip.bounds, to: cell.contentView)
        XCTAssertEqual(
            avatarFrame.maxX,
            cell.contentView.layoutMarginsGuide.layoutFrame.maxX,
            accuracy: 1
        )
    }

    func testMemberListReusesContactLayoutWithoutCircleTagsAndRowTapDoesNotNavigate() throws {
        let member = circleMember(
            "alice@example.com",
            name: "Alice",
            groups: ["Friends", "Work"]
        )
        let controller = RosterCircleMembersViewController(
            circleName: "Work",
            service: StubRosterCircleService(members: [member])
        )
        let navigationController = UINavigationController(rootViewController: controller)

        controller.loadViewIfNeeded()

        let indexPath = IndexPath(row: 0, section: 0)
        let cell = try XCTUnwrap(
            controller.tableView(controller.tableView, cellForRowAt: indexPath)
                as? ContactsViewController.ContactCell
        )
        XCTAssertEqual(cell.titleLabel.text, "Alice")
        XCTAssertEqual(cell.subtitleLabel.text, "alice@example.com")
        XCTAssertTrue(cell.tagScrollView.isHidden)
        controller.tableView(controller.tableView, didSelectRowAt: indexPath)
        XCTAssertTrue(navigationController.topViewController === controller)
    }

    func testSelectionSearchKeepsModelSelectionAndCheckmarkReflectsChanges() {
        let alice = circleMember("alice@example.com", name: "Álice", groups: ["Work"])
        let bob = circleMember("bob@example.com", name: "Bob", groups: ["Work"])
        let controller = RosterCircleSelectionViewController(
            mode: .edit(circleName: "Work"),
            service: StubRosterCircleService(members: [alice, bob]),
            members: [alice, bob],
            initiallySelected: [alice.primary, bob.primary]
        )

        controller.loadViewIfNeeded()
        XCTAssertFalse(controller.checkmarkItem.isEnabled)
        XCTAssertFalse(controller.navigationItem.searchController?.obscuresBackgroundDuringPresentation ?? true)

        controller.navigationItem.searchController?.searchBar.text = "alice@example"
        controller.updateSearchResults(for: try! XCTUnwrap(controller.navigationItem.searchController))
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertTrue(controller.checkmarkItem.isEnabled)

        controller.navigationItem.searchController?.searchBar.text = "bob"
        controller.updateSearchResults(for: try! XCTUnwrap(controller.navigationItem.searchController))
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
        XCTAssertTrue(controller.selectionState.selectedPrimaries.contains(bob.primary))
    }

    func testCreateEditorRequiresNameAndSelectionBeforeEnablingCheckmark() throws {
        let alice = circleMember("alice@example.com", name: "Alice")
        let controller = RosterCircleSelectionViewController(
            mode: .create(existingNames: ["Friends"]),
            service: StubRosterCircleService(members: [alice]),
            members: [alice]
        )

        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertEqual(controller.tableView.numberOfSections, 2)
        XCTAssertFalse(controller.checkmarkItem.isEnabled)

        let nameCell = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                cellForRowAt: IndexPath(row: 0, section: 0)
            ) as? RosterCircleNameCell
        )
        nameCell.textField.text = "Team"
        nameCell.textField.sendActions(for: .editingChanged)
        XCTAssertFalse(controller.checkmarkItem.isEnabled)

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 0, section: 1)
        )
        XCTAssertTrue(controller.checkmarkItem.isEnabled)

        nameCell.textField.text = " friends "
        nameCell.textField.sendActions(for: .editingChanged)
        XCTAssertFalse(controller.checkmarkItem.isEnabled)
    }
}

private final class StubRosterCircleService: RosterCircleServicing {
    var members: [RosterCircleMemberSnapshot]

    init(members: [RosterCircleMemberSnapshot]) {
        self.members = members
    }

    func loadMembers() throws -> [RosterCircleMemberSnapshot] { members }
    func loadCircles() throws -> [RosterCircleSnapshot] {
        RosterCircleCatalog.circles(from: members)
    }

    func create(
        name: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        completion(.success(.init(confirmedPrimaries: selectedPrimaries, failures: [])))
    }

    func setMembers(
        circleName: String,
        selectedPrimaries: Set<String>,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        completion(.success(.init(confirmedPrimaries: selectedPrimaries, failures: [])))
    }

    func rename(
        oldName: String,
        newName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        completion(.success(.init(confirmedPrimaries: [], failures: [])))
    }

    func delete(
        name: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        completion(.success(.init(confirmedPrimaries: [], failures: [])))
    }

    func removeMember(
        primary: String,
        circleName: String,
        completion: @escaping (Result<RosterCircleBatchResult, RosterCircleServiceError>) -> Void
    ) {
        completion(.success(.init(confirmedPrimaries: [primary], failures: [])))
    }
}

private func circleMember(
    _ jid: String,
    name: String,
    groups: [String] = []
) -> RosterCircleMemberSnapshot {
    RosterCircleMemberSnapshot(
        primary: RosterStorageItem.genPrimary(jid: jid, owner: "me@example.com"),
        owner: "me@example.com",
        jid: jid,
        displayName: name,
        rosterName: name,
        avatarURL: nil,
        groups: groups,
        kind: .contact,
        status: .offline
    )
}

private final class RosterCircleCapturingXMPPStream: XMPPStream {
    private(set) var sentIQs: [XMPPIQ] = []

    override func send(_ element: DDXMLElement) {
        if let iq = element as? XMPPIQ {
            sentIQs.append(iq)
        }
    }
}

private final class RosterCircleTestScheduler: AccountConnectionResilienceScheduling {
    private final class Scheduled: AccountConnectionResilienceCancellable {
        let due: TimeInterval
        let block: () -> Void
        var isCancelled = false

        init(due: TimeInterval, block: @escaping () -> Void) {
            self.due = due
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var scheduled: [Scheduled] = []

    func schedule(
        after delay: TimeInterval,
        _ block: @escaping () -> Void
    ) -> AccountConnectionResilienceCancellable {
        let item = Scheduled(due: now + max(0, delay), block: block)
        scheduled.append(item)
        return item
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let due = scheduled.filter { $0.isCancelled == false && $0.due <= now }
        due.forEach {
            $0.isCancelled = true
            $0.block()
        }
        scheduled.removeAll { $0.isCancelled }
    }
}

private final class ControlledCircleMutationSender: RosterCircleMutationSending {
    private var pending: [String: (Result<Void, RosterCircleMutationError>) -> Void] = [:]
    private(set) var maximumObservedInFlightCount = 0

    var inFlightCount: Int { pending.count }

    func send(
        _ mutation: RosterCircleMutation,
        completion: @escaping (Result<Void, RosterCircleMutationError>) -> Void
    ) {
        pending[mutation.primary] = completion
        maximumObservedInFlightCount = max(maximumObservedInFlightCount, pending.count)
    }

    func finish(
        primary: String,
        result: Result<Void, RosterCircleMutationError>
    ) {
        let completion = pending.removeValue(forKey: primary)
        completion?(result)
    }

    func finishAll(
        result: (String) -> Result<Void, RosterCircleMutationError>
    ) {
        while let primary = pending.keys.sorted().first {
            finish(primary: primary, result: result(primary))
        }
    }
}

private final class MutableRosterCircleSnapshotStore: RosterCircleSnapshotStoring {
    var members: [RosterCircleMemberSnapshot]

    init(members: [RosterCircleMemberSnapshot]) {
        self.members = members
    }

    func members(owner: String) throws -> [RosterCircleMemberSnapshot] {
        members
    }

    func apply(_ mutation: RosterCircleMutation) {
        guard let index = members.firstIndex(where: { $0.primary == mutation.primary }) else { return }
        let current = members[index]
        members[index] = RosterCircleMemberSnapshot(
            primary: current.primary,
            owner: current.owner,
            jid: current.jid,
            displayName: current.displayName,
            rosterName: current.rosterName,
            avatarURL: current.avatarURL,
            groups: mutation.groups,
            kind: current.kind,
            status: current.status
        )
    }
}

private final class ApplyingControlledCircleMutationSender: RosterCircleMutationSending {
    private let store: MutableRosterCircleSnapshotStore
    private var pending: [String: (
        mutation: RosterCircleMutation,
        completion: (Result<Void, RosterCircleMutationError>) -> Void
    )] = [:]

    var pendingPrimaries: [String] { pending.keys.sorted() }

    init(store: MutableRosterCircleSnapshotStore) {
        self.store = store
    }

    func send(
        _ mutation: RosterCircleMutation,
        completion: @escaping (Result<Void, RosterCircleMutationError>) -> Void
    ) {
        pending[mutation.primary] = (mutation, completion)
    }

    func finish(primary: String, result: Result<Void, RosterCircleMutationError>) {
        guard let item = pending.removeValue(forKey: primary) else { return }
        if case .success = result {
            store.apply(item.mutation)
        }
        item.completion(result)
    }
}
