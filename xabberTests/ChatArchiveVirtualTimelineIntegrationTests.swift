import XCTest
import RealmSwift
@testable import xabber

final class ChatArchiveVirtualTimelineIntegrationTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "chat@example.com"
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatArchiveVirtualTimelineIntegrationTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testOlderThenNewerRematerializesEvictedRowsFromRealm() throws {
        try insertMessages(1...1_000)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        let actorWindow = try makeWindow(
            primaryIDs: primaryIDs(501...1_000),
            target: .latest,
            generation: 1
        )
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            actorWindow
        ))

        let firstOlder = try localSessionSnapshot(
            session.loadVerifiedLocalBoundary(.older)
        )
        XCTAssertEqual(firstOlder.items.map(\.primary), primaryIDs(401...1_000))

        let secondOlder = try localSessionSnapshot(
            session.loadVerifiedLocalBoundary(.older)
        )
        XCTAssertEqual(secondOlder.items.map(\.primary), primaryIDs(301...900))
        XCTAssertNil(secondOlder.item(primary: "primary-1000"))

        let newer = try localSessionSnapshot(
            session.loadVerifiedLocalBoundary(.newer)
        )
        XCTAssertEqual(newer.items.map(\.primary), primaryIDs(401...1_000))
        XCTAssertNotNil(newer.item(primary: "primary-1000"))
        XCTAssertTrue(newer.state.isResidentAtLiveTail)
    }

    func testSixHundredOneLiveIDsReverseLocallyWithoutArchiveExpansion() throws {
        try insertMessages(1...601)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        _ = session.installArchiveEngineAuthoritativeEmpty()
        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 42,
            queryID: "live-601"
        )
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: "1")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "601")),
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: freshnessToken.fingerprint,
            isVerified: true
        ))
        let conversation = ArchiveConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let admission = ArchiveLiveEdgeAdmission(
            conversation: conversation,
            primaryID: "primary-601",
            latestWindow: ArchiveWindowSnapshot(
                messagePrimaryIDs: primaryIDs(1...601),
                target: .latest,
                verifiedSegment: segment,
                coverageGeneration: 1,
                freshnessToken: freshnessToken
            ),
            presentationIntent: ArchiveIntentDescriptor(
                conversation: conversation,
                locator: .latest,
                contextBefore: ArchivePageSizing.initial,
                contextAfter: 0
            )
        )
        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(admission)
        )
        _ = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(session.snapshot.items.map(\.primary), primaryIDs(102...601))
        XCTAssertTrue(session.snapshot.state.isResidentAtLiveTail)

        guard case .local(let firstOlder) =
                session.loadVerifiedLocalBoundary(.older)
        else {
            return XCTFail("The evicted older row must come from Realm, not MAM")
        }
        XCTAssertEqual(firstOlder.items.map(\.primary), primaryIDs(2...601))
        XCTAssertTrue(firstOlder.state.isResidentAtLiveTail)

        guard case .local(let secondOlder) =
                session.loadVerifiedLocalBoundary(.older)
        else {
            return XCTFail("The hard-limit eviction must still stay inside Realm")
        }
        XCTAssertEqual(secondOlder.items.map(\.primary), primaryIDs(1...600))
        XCTAssertFalse(secondOlder.state.isResidentAtLiveTail)

        guard case .local(let newer) =
                session.loadVerifiedLocalBoundary(.newer)
        else {
            return XCTFail("Reverse paging inside proof must stay local with MAM 0")
        }
        XCTAssertEqual(newer.items.map(\.primary), primaryIDs(2...601))
        XCTAssertTrue(newer.state.isResidentAtLiveTail)
    }

    func testLiveEdgeAfterOlderPagingAppendsDirectionallyWhileResidentTailIsPresent() throws {
        try insertMessages(1...1_001)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(801...1_000),
                target: .latest,
                generation: 1
            )
        ))
        _ = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.older))
        XCTAssertEqual(session.snapshot.items.map(\.primary), primaryIDs(701...1_000))
        XCTAssertTrue(session.snapshot.state.isResidentAtLiveTail)

        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: "primary-1001",
                    presentationTarget: .older(
                        before: XCTUnwrap(ArchiveCursor(rawValue: "1"))
                    ),
                    generation: 2
                )
            )
        )
        let candidate = try XCTUnwrap(
            session.inspectPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(candidate.mode, .residentNewer)
        XCTAssertEqual(candidate.snapshot.items.map(\.primary), primaryIDs(701...1_001))

        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(committed.mode, .residentNewer)
        XCTAssertFalse(committed.shouldExposeNewMessageBadge)
        XCTAssertEqual(committed.snapshot.items.map(\.primary), primaryIDs(701...1_001))
        XCTAssertTrue(committed.snapshot.state.isResidentAtLiveTail)
        XCTAssertEqual(session.verifiedScope?.newest, ArchiveCursor(rawValue: "1001"))
    }

    func testAuthoritativeEmptyLiveAdmissionBecomesCommittedPresentationProof() throws {
        try insertMessages(1_001...1_001)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        let emptySnapshot = session.installArchiveEngineAuthoritativeEmpty()
        XCTAssertTrue(emptySnapshot.items.isEmpty)
        XCTAssertNil(session.verifiedScope)

        let freshnessToken = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 42,
            queryID: "empty-query"
        )
        let emptyState = ArchiveWindowState.authoritativeEmpty(
            target: .latest,
            freshnessToken: freshnessToken
        )
        let conversation = ArchiveConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let latestIntent = ArchiveWindowIntent(
            conversation: conversation,
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let liveSegment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: "1001")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "1001")),
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: freshnessToken.fingerprint,
            isVerified: true
        ))
        let admission = ArchiveLiveEdgeAdmission(
            conversation: conversation,
            primaryID: "primary-1001",
            latestWindow: ArchiveWindowSnapshot(
                messagePrimaryIDs: ["primary-1001"],
                target: .latest,
                verifiedSegment: liveSegment,
                coverageGeneration: 2,
                freshnessToken: .sessionMAM(
                    connectionGeneration: 42,
                    queryID: "live-query"
                )
            ),
            presentationIntent: latestIntent.semanticDescriptor
        )
        XCTAssertTrue(ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
            admission,
            currentIntent: latestIntent,
            currentScope: nil,
            currentState: emptyState
        ))

        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(admission)
        )
        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        let committedScope = try XCTUnwrap(session.verifiedScope)
        XCTAssertEqual(committed.mode, .residentNewer)
        XCTAssertEqual(
            committed.snapshot.items.map(\.primary),
            ["primary-1001"]
        )
        XCTAssertEqual(committedScope.coverageGeneration, 2)
        XCTAssertTrue(ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
            admission,
            currentIntent: latestIntent,
            currentScope: committedScope,
            currentState: emptyState
        ))
        XCTAssertFalse(ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
            for: emptyState,
            committedCoverageGeneration: 2,
            verifiedScope: committedScope
        ))
        XCTAssertFalse(ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
            isPresentationActive: true,
            state: emptyState,
            committedCoverageGeneration: 2,
            pendingSnapshot: nil,
            isShowingSkeleton: false,
            verifiedScope: committedScope
        ))

        let staleEmptyState = ArchiveWindowState.authoritativeEmpty(
            target: .latest,
            freshnessToken: .sessionMAM(
                connectionGeneration: 43,
                queryID: "stale-empty-query"
            )
        )
        XCTAssertTrue(ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
            for: staleEmptyState,
            committedCoverageGeneration: 2,
            verifiedScope: committedScope
        ))
        XCTAssertTrue(ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
            isPresentationActive: true,
            state: staleEmptyState,
            committedCoverageGeneration: 2,
            pendingSnapshot: nil,
            isShowingSkeleton: false,
            verifiedScope: committedScope
        ))
    }

    func testLiveEdgeAfterNewerEdgeEvictionAdvancesProofWithoutMutatingViewport() throws {
        try insertMessages(1...1_001)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        let actorWindow = try makeWindow(
            primaryIDs: primaryIDs(501...1_000),
            target: .latest,
            generation: 1
        )
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            actorWindow
        ))
        _ = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.older))
        _ = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.older))
        let evicted = session.snapshot
        XCTAssertEqual(evicted.items.map(\.primary), primaryIDs(301...900))
        XCTAssertFalse(evicted.state.isResidentAtLiveTail)

        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: "primary-1001",
                    presentationTarget: .older(
                        before: XCTUnwrap(ArchiveCursor(rawValue: "1"))
                    ),
                    generation: 2
                )
            )
        )
        let candidate = try XCTUnwrap(
            session.inspectPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(candidate.mode, .proofOnly)
        XCTAssertEqual(candidate.snapshot.items.map(\.primary), evicted.items.map(\.primary))
        XCTAssertEqual(candidate.snapshot.state, evicted.state)

        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(committed.mode, .proofOnly)
        XCTAssertTrue(
            committed.shouldExposeNewMessageBadge,
            "Only the proof-admitted nonresident live primary drives the badge"
        )
        XCTAssertEqual(committed.snapshot.items.map(\.primary), evicted.items.map(\.primary))
        XCTAssertFalse(committed.snapshot.state.isResidentAtLiveTail)
        XCTAssertEqual(session.verifiedScope?.newest, ArchiveCursor(rawValue: "1001"))
        XCTAssertTrue(ChatArchiveWindowPresentationPolicy.hasCommittedVerifiedScope(
            snapshot: actorWindow,
            committedCoverageGeneration: 2,
            scope: try XCTUnwrap(session.verifiedScope)
        ))
        XCTAssertFalse(ChatArchiveWindowPresentationPolicy.shouldShowFullSkeleton(
            for: .verified(actorWindow),
            committedCoverageGeneration: 2,
            verifiedScope: session.verifiedScope
        ))
        XCTAssertTrue(ChatArchiveWindowPresentationPolicy.canPrefetch(
            snapshot: actorWindow,
            committedCoverageGeneration: 2,
            isShowingSkeleton: false,
            verifiedScope: session.verifiedScope
        ))
        XCTAssertFalse(ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
            isPresentationActive: true,
            state: .verified(actorWindow),
            committedCoverageGeneration: 2,
            pendingSnapshot: nil,
            isShowingSkeleton: false,
            verifiedScope: session.verifiedScope
        ))

        _ = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.newer))
        let liveTail = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.newer))
        XCTAssertEqual(liveTail.items.map(\.primary), primaryIDs(402...1_001))
        XCTAssertTrue(liveTail.state.isResidentAtLiveTail)
    }

    func testArchiveIDWindowReachesTailLocallyThenAdmitsLiveEdgeAsNewer() throws {
        try insertMessages(1...1_001)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(470...530),
                target: .archiveID(try XCTUnwrap(ArchiveCursor(rawValue: "500"))),
                generation: 1
            )
        ))
        XCTAssertFalse(session.snapshot.state.isResidentAtLiveTail)

        while !session.snapshot.state.isResidentAtLiveTail {
            _ = try localSessionSnapshot(session.loadVerifiedLocalBoundary(.newer))
        }
        XCTAssertEqual(session.snapshot.items.map(\.primary), primaryIDs(470...1_000))

        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: "primary-1001",
                    presentationTarget: .archiveID(
                        try XCTUnwrap(ArchiveCursor(rawValue: "500"))
                    ),
                    generation: 2
                )
            )
        )
        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(committed.mode, .residentNewer)
        XCTAssertEqual(committed.snapshot.items.map(\.primary), primaryIDs(470...1_001))
        XCTAssertTrue(committed.snapshot.state.isResidentAtLiveTail)
    }

    func testLiveEdgeOwnershipContinuesAcrossDirectionalPagingButRejectsStableReplacement() throws {
        try insertMessages(1...1_001)
        let store = RealmChatTimelineSessionStore(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(801...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let latestIntent = ArchiveWindowIntent(
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            locator: .latest,
            contextBefore: ArchivePageSizing.initial,
            contextAfter: 0,
            priority: .visibleIntegrity
        )
        let admission = try makeLiveEdgeAdmission(
            primaryID: "primary-1001",
            presentationTarget: .latest,
            generation: 2
        )
        let ownedAdmission = ArchiveLiveEdgeAdmission(
            conversation: admission.conversation,
            primaryID: admission.primaryID,
            latestWindow: admission.latestWindow,
            presentationIntent: latestIntent.semanticDescriptor
        )
        let olderIntent = ArchiveWindowIntent(
            conversation: latestIntent.conversation,
            locator: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "1"))),
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.initial,
            priority: .visibleIntegrity
        )
        XCTAssertTrue(ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
            ownedAdmission,
            currentIntent: olderIntent,
            currentScope: session.verifiedScope,
            currentState: .verified(try makeWindow(
                primaryIDs: primaryIDs(801...1_000),
                target: .latest,
                generation: 1
            ))
        ))

        let replacementIntent = ArchiveWindowIntent(
            conversation: latestIntent.conversation,
            locator: .archiveID(
                try XCTUnwrap(ArchiveCursor(rawValue: "500"))
            ),
            contextBefore: ArchivePageSizing.anchorBefore,
            contextAfter: ArchivePageSizing.anchorAfter,
            priority: .target
        )
        XCTAssertFalse(ChatArchiveLiveEdgePresentationPolicy.shouldAccept(
            ownedAdmission,
            currentIntent: replacementIntent,
            currentScope: session.verifiedScope,
            currentState: nil
        ))
    }

    func testPreparedBoundaryBecomesStaleWhenVerifiedProofChanges() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1,
                connectionGeneration: 1
            )
        ))
        let completion = expectation(description: "stale preparation")
        let baseGeneration = session.snapshot.generation

        XCTAssertEqual(
            session.prepareVerifiedLocalBoundary(
                .older,
                expectedGeneration: baseGeneration
            ) { result in
                guard case .stale = result else {
                    return XCTFail("Expected stale preparation after proof replacement")
                }
                completion.fulfill()
            },
            .started
        )
        XCTAssertEqual(store.olderStarted.wait(timeout: .now() + 2), .success)

        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 2,
                connectionGeneration: 2
            )
        ))
        store.releaseOlder.signal()

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(store.olderCallCount, 1)
        XCTAssertEqual(session.verifiedScope?.coverageGeneration, 2)
    }

    func testIdenticalPreparedBoundaryRequestsCoalesceIntoOneStoreQuery() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let first = expectation(description: "first joined completion")
        let second = expectation(description: "second joined completion")
        let generation = session.snapshot.generation

        XCTAssertEqual(
            session.prepareVerifiedLocalBoundary(
                .older,
                expectedGeneration: generation
            ) { result in
                guard case .prepared = result else {
                    return XCTFail("First joined request must receive prepared page")
                }
                first.fulfill()
            },
            .started
        )
        XCTAssertEqual(store.olderStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            session.prepareVerifiedLocalBoundary(
                .older,
                expectedGeneration: generation
            ) { result in
                guard case .prepared = result else {
                    return XCTFail("Second joined request must receive the same prepared page")
                }
                second.fulfill()
            },
            .coalesced
        )

        store.releaseOlder.signal()

        wait(for: [first, second], timeout: 2)
        XCTAssertEqual(store.olderCallCount, 1)
    }

    func testPreparedVerifiedWindowDoesNotMutateSessionUntilCommit() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let base = session.snapshot
        let baseScope = try XCTUnwrap(session.verifiedScope)
        let prepared = try XCTUnwrap(session.prepareArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(401...500),
                target: .older(before: try XCTUnwrap(ArchiveCursor(rawValue: "501"))),
                generation: 2
            )
        ))

        let candidate = try XCTUnwrap(
            session.inspectPreparedArchiveEngineVerifiedWindow(prepared)
        )
        XCTAssertEqual(candidate.items.map(\.primary), primaryIDs(401...1_000))
        XCTAssertEqual(session.snapshot.generation, base.generation)
        XCTAssertEqual(session.snapshot.items.map(\.primary), base.items.map(\.primary))
        XCTAssertEqual(session.verifiedScope, baseScope)

        let committed = try XCTUnwrap(
            session.commitPreparedArchiveEngineVerifiedWindow(prepared)
        )
        XCTAssertEqual(committed.items.map(\.primary), primaryIDs(401...1_000))
        XCTAssertEqual(session.verifiedScope?.coverageGeneration, 2)
        XCTAssertNil(session.commitPreparedArchiveEngineVerifiedWindow(prepared))
    }

    func testGenericUnknownUpsertCannotEnterVerifiedResidentWindow() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...101)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(1...100),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()
        let base = session.snapshot
        let unknown = makeMessages(101...101)[0]

        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(message: unknown),
                        revision: 1,
                        payload: unknown
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))

        XCTAssertEqual(session.snapshot.generation, base.generation)
        XCTAssertEqual(session.snapshot.items.map(\.primary), primaryIDs(1...100))
        XCTAssertNil(session.snapshot.item(primary: unknown.primary))

        let residentEdit = makeMessages(100...100)[0]
        residentEdit.body = "edited resident"
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(message: residentEdit),
                        revision: 2,
                        payload: residentEdit
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))

        XCTAssertEqual(session.snapshot.item(primary: residentEdit.primary)?.body, "edited resident")
        XCTAssertEqual(
            session.snapshot.residentChangeSet?.updatedStablePrimaries,
            [residentEdit.primary]
        )
    }

    func testPreparedLiveEdgeAdmissionSurvivesUnreadPublicationForRejectedGenericPrimary() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_001)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()

        let incoming = makeMessages(1_001...1_001)[0]
        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: incoming.primary,
                    presentationTarget: .latest,
                    generation: 2
                )
            )
        )

        store.emit(.incrementalWithUnreadMetadata(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(message: incoming),
                        revision: 1,
                        payload: incoming
                    )
                ],
                enqueuedMutationCount: 1
            ),
            unreadMetadata: ChatTimelineUnreadMetadata(
                unreadCount: 1,
                mentions: [],
                candidateCount: 1
            )
        ))

        XCTAssertNil(
            session.snapshot.item(primary: incoming.primary),
            "The generic Realm observer must not admit the new primary"
        )
        XCTAssertEqual(session.snapshot.unreadMetadata.unreadCount, 1)
        XCTAssertNotNil(
            session.inspectPreparedArchiveLiveEdgeAdmission(prepared),
            "Unread-only publication must not invalidate XMPP-proved live admission"
        )

        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(committed.mode, .residentNewer)
        XCTAssertNotNil(committed.snapshot.item(primary: incoming.primary))
        XCTAssertEqual(committed.snapshot.unreadMetadata.unreadCount, 1)
    }

    func testPreparedLiveEdgeAdmissionStillFailsClosedAfterResidentContentChange() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_001)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()
        let prepared = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: "primary-1001",
                    presentationTarget: .latest,
                    generation: 2
                )
            )
        )

        let editedResident = makeMessages(1_000...1_000)[0]
        editedResident.body = "edited while live proof was prepared"
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(
                            message: editedResident
                        ),
                        revision: 1,
                        payload: editedResident
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))

        XCTAssertNil(session.inspectPreparedArchiveLiveEdgeAdmission(prepared))
        XCTAssertNil(session.commitPreparedArchiveLiveEdgeAdmission(prepared))
        XCTAssertNil(session.snapshot.item(primary: "primary-1001"))

        let reparsed = try XCTUnwrap(
            session.prepareArchiveLiveEdgeAdmission(
                try makeLiveEdgeAdmission(
                    primaryID: "primary-1001",
                    presentationTarget: .latest,
                    generation: 2
                )
            )
        )
        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(reparsed)
        )
        XCTAssertEqual(
            committed.snapshot.item(primary: editedResident.primary)?.body,
            editedResident.body,
            "Reprepare must preserve the newer resident edit"
        )
        XCTAssertNotNil(committed.snapshot.item(primary: "primary-1001"))
    }

    func testLocalOutgoingAdmissionIsImmediateUnprovedAndReceiptProofDoesNotDuplicate() throws {
        let messages = makeMessages(1...1_003)
        let localOutgoing = messages[1_000]
        localOutgoing.archivedId = ""
        localOutgoing.outgoing = true
        localOutgoing.state = .sending
        let unknownIncoming = messages[1_001]
        let secondLocalOutgoing = messages[1_002]
        secondLocalOutgoing.archivedId = ""
        secondLocalOutgoing.outgoing = true
        secondLocalOutgoing.state = .sending
        let store = BlockingVirtualTimelineSessionStore(messages: messages)
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()
        let verifiedBeforeSend = try XCTUnwrap(session.verifiedScope)
        let presentedBeforeSend = Set(session.snapshot.items.map(\.primary))

        let admitted = try XCTUnwrap(session.admitLocalOutgoing(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                primaryID: localOutgoing.primary
            )
        ))

        XCTAssertEqual(admitted.cause, .localOutgoingAdmission)
        XCTAssertNotNil(admitted.item(primary: localOutgoing.primary))
        XCTAssertEqual(session.verifiedScope, verifiedBeforeSend)
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: admitted,
                currentSessionGeneration: admitted.generation,
                presentedPrimaryIDs: presentedBeforeSend,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .apply
        )

        let rapidAdmission = try XCTUnwrap(session.admitLocalOutgoing(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                primaryID: secondLocalOutgoing.primary
            )
        ))
        XCTAssertEqual(
            ChatTimelineStoreSnapshotPresentationPolicy.action(
                for: rapidAdmission,
                currentSessionGeneration: rapidAdmission.generation,
                presentedPrimaryIDs: presentedBeforeSend,
                hasCommittedArchivePresentation: true,
                isShowingSkeleton: false,
                hasPendingArchiveApply: false
            ),
            .apply,
            "A coalesced snapshot may contain several typed local sends"
        )
        XCTAssertEqual(
            rapidAdmission.provisionalLocalOutgoingPrimaryIDs,
            Set([localOutgoing.primary, secondLocalOutgoing.primary])
        )

        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(
                            message: unknownIncoming
                        ),
                        revision: 1,
                        payload: unknownIncoming
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))
        XCTAssertNil(session.snapshot.item(primary: unknownIncoming.primary))

        localOutgoing.state = .error
        localOutgoing.messageError = "send failed"
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(
                            message: localOutgoing
                        ),
                        revision: 2,
                        payload: localOutgoing
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))
        XCTAssertEqual(
            session.snapshot.item(primary: localOutgoing.primary)?.state,
            .error
        )

        localOutgoing.archivedId = "1001"
        localOutgoing.state = .sended
        localOutgoing.messageError = nil
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(
                            message: localOutgoing
                        ),
                        revision: 3,
                        payload: localOutgoing
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))
        let proof = try XCTUnwrap(session.prepareArchiveLiveEdgeAdmission(
            try makeLiveEdgeAdmission(
                primaryID: localOutgoing.primary,
                presentationTarget: .latest,
                generation: 2
            )
        ))
        let proved = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(proof)
        )

        XCTAssertEqual(
            proved.snapshot.items.filter {
                $0.primary == localOutgoing.primary
            }.count,
            1
        )
        XCTAssertEqual(proved.snapshot.items.count, rapidAdmission.items.count)
        XCTAssertEqual(session.verifiedScope?.coverageGeneration, 2)
    }

    func testLocalOutgoingPresentationRepreparesAcrossMetadataCommandGeneration() throws {
        let messages = makeMessages(1...1_001)
        let outgoing = messages[1_000]
        outgoing.archivedId = ""
        outgoing.outgoing = true
        let store = BlockingVirtualTimelineSessionStore(messages: messages)
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let local = try XCTUnwrap(session.admitLocalOutgoing(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                primaryID: outgoing.primary
            )
        ))

        let metadata = session.refreshUnreadMetadata()
        XCTAssertEqual(metadata.cause, .command)
        XCTAssertGreaterThan(metadata.generation, local.generation)
        let reprepared = try XCTUnwrap(
            session.reprepareLocalOutgoingPresentation(local)
        )
        XCTAssertEqual(reprepared.generation, metadata.generation)
        XCTAssertEqual(reprepared.cause, .localOutgoingAdmission)
        XCTAssertNotNil(reprepared.item(primary: outgoing.primary))
        XCTAssertEqual(
            reprepared.provisionalLocalOutgoingPrimaryIDs,
            local.provisionalLocalOutgoingPrimaryIDs
        )
    }

    func testAuthoritativeEmptyAdmitsFirstLocalOutgoingAndReceiptPromotesIt() throws {
        let messages = makeMessages(1...1_001)
        let outgoing = messages[1_000]
        outgoing.archivedId = ""
        outgoing.outgoing = true
        outgoing.state = .sending
        let store = BlockingVirtualTimelineSessionStore(messages: messages)
        let session = makeSession(store: store)
        let admission = ChatTimelineLocalOutgoingAdmission(
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            primaryID: outgoing.primary
        )
        XCTAssertNil(
            session.admitLocalOutgoing(admission),
            "An event received before local live-tail authority must stay pending"
        )
        let token = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 42,
            queryID: "empty-proof"
        )
        _ = session.installArchiveEngineAuthoritativeEmpty(
            freshnessToken: token
        )

        let local = try XCTUnwrap(session.admitLocalOutgoing(admission))
        XCTAssertNotNil(local.item(primary: outgoing.primary))
        XCTAssertTrue(local.state.residentPrimaryKeys.isEmpty)
        XCTAssertEqual(local.authoritativeEmptyLiveTailAuthority?.connectionGeneration, 42)

        outgoing.archivedId = "1001"
        outgoing.state = .sended
        let prepared = try XCTUnwrap(session.prepareArchiveLiveEdgeAdmission(
            try makeLiveEdgeAdmission(
                primaryID: outgoing.primary,
                presentationTarget: .latest,
                generation: 1
            )
        ))
        let proved = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(proved.snapshot.items.map(\.primary).filter {
            $0 == outgoing.primary
        }.count, 1)
        XCTAssertTrue(proved.snapshot.provisionalLocalOutgoingPrimaryIDs.isEmpty)
        XCTAssertEqual(proved.snapshot.state.newest?.archivedId, "1001")
    }

    func testReceiptProofCandidateWinsFrozenProvisionalBeforeRealmObserver() throws {
        let messages = makeMessages(1...1_001)
        let provisional = messages[1_000]
        provisional.archivedId = ""
        provisional.messageId = "1"
        provisional.outgoing = true
        provisional.state = .sending
        let store = BlockingVirtualTimelineSessionStore(messages: messages)
        let session = makeSession(store: store)
        _ = session.installArchiveEngineAuthoritativeEmpty(
            freshnessToken: .sessionMAM(
                connectionGeneration: 42,
                queryID: "empty-proof"
            )
        )
        _ = try XCTUnwrap(session.admitLocalOutgoing(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                primaryID: provisional.primary
            )
        ))

        let persisted = makeMessages(1_001...1_001)[0]
        persisted.messageId = provisional.messageId
        persisted.outgoing = true
        persisted.state = .sended
        store.replaceMessage(persisted)

        XCTAssertEqual(
            session.snapshot.item(primary: provisional.primary)?.archivedId,
            "",
            "The already-published presentation value models a frozen pre-receipt row"
        )
        let prepared = try XCTUnwrap(session.prepareArchiveLiveEdgeAdmission(
            try makeLiveEdgeAdmission(
                primaryID: provisional.primary,
                presentationTarget: .latest,
                generation: 1
            )
        ))
        let candidate = try XCTUnwrap(
            session.inspectPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(
            candidate.snapshot.items.first {
                $0.primary == provisional.primary
            }?.archivedId,
            "1001",
            "The verified Realm row must win dedupe even before its generic observer update"
        )

        let committed = try XCTUnwrap(
            session.commitPreparedArchiveLiveEdgeAdmission(prepared)
        )
        XCTAssertEqual(
            committed.snapshot.item(primary: provisional.primary)?.archivedId,
            "1001"
        )
        XCTAssertTrue(
            committed.snapshot.provisionalLocalOutgoingPrimaryIDs.isEmpty
        )
        XCTAssertEqual(committed.snapshot.state.newest?.archivedId, "1001")
    }

    func testProvisionalOutgoingSurvivesOlderReverseNewerWithoutBecomingBoundary() throws {
        let messages = makeMessages(1...1_001)
        let outgoing = messages[1_000]
        outgoing.archivedId = ""
        outgoing.outgoing = true
        let store = BlockingVirtualTimelineSessionStore(messages: messages)
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        _ = try XCTUnwrap(session.admitLocalOutgoing(
            ChatTimelineLocalOutgoingAdmission(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                primaryID: outgoing.primary
            )
        ))

        var older = session.snapshot
        for _ in 0..<6 {
            older = try localSessionSnapshot(
                session.loadVerifiedLocalBoundary(.older)
            )
        }
        XCTAssertFalse(older.state.isResidentAtLiveTail)
        XCTAssertNotNil(older.item(primary: outgoing.primary))
        XCTAssertFalse(older.state.residentPrimaryKeys.contains(outgoing.primary))
        XCTAssertLessThanOrEqual(older.items.count, older.residentHardLimit)

        let newer = try localSessionSnapshot(
            session.loadVerifiedLocalBoundary(.newer)
        )
        XCTAssertTrue(newer.state.isResidentAtLiveTail)
        XCTAssertNotNil(newer.item(primary: outgoing.primary))
        XCTAssertEqual(newer.state.newest?.archivedId, "1000")
        XCTAssertFalse(newer.state.residentPrimaryKeys.contains(outgoing.primary))
        XCTAssertLessThanOrEqual(newer.items.count, newer.residentHardLimit)
    }

    func testGenericResidentUpdateWithEmptyArchiveIDCannotCorruptVerifiedBoundary() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()

        let malformed = makeMessages(1_000...1_000)[0]
        malformed.archivedId = ""
        malformed.body = "must not replace proof"
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(
                            message: malformed
                        ),
                        revision: 1,
                        payload: malformed
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))

        XCTAssertNotEqual(
            session.snapshot.item(primary: malformed.primary)?.body,
            malformed.body
        )
        XCTAssertEqual(session.snapshot.state.newest?.archivedId, "1000")
    }

    func testGenericAliasUpdateFromWrongConversationCannotReplaceResident() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(922...1_000),
                target: .latest,
                generation: 1
            )
        ))
        session.activateStoreObservation()

        let alias = makeMessages(1_000...1_000)[0]
        alias.primary = "wrong-conversation-primary"
        alias.opponent = "different@example.com"
        alias.body = "must not replace resident by messageId alias"
        store.emit(.incremental(
            ChatIncrementalMessageMutationBatch(
                mutations: [
                    .upsert(
                        identity: ChatIncrementalMessageIdentity(message: alias),
                        revision: 1,
                        payload: alias
                    )
                ],
                enqueuedMutationCount: 1
            ),
            refreshUnread: false
        ))

        XCTAssertNotNil(session.snapshot.item(primary: "primary-1000"))
        XCTAssertNil(session.snapshot.item(primary: alias.primary))
        XCTAssertEqual(session.snapshot.state.newest?.archivedId, "1000")
    }

    func testEvictedSearchTargetInsideProofOpensLocallyAndOutsideNeedsArchiveID() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_001)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1
            )
        ))
        XCTAssertNil(session.snapshot.item(primary: "primary-100"))

        let localCompletion = expectation(description: "local target prepared")
        var localPrepared: ChatTimelinePreparedVerifiedLocalTarget?
        XCTAssertEqual(
            session.prepareVerifiedLocalTarget(
                primary: "primary-100",
                archiveCursor: try XCTUnwrap(ArchiveCursor(rawValue: "100")),
                expectedGeneration: session.snapshot.generation
            ) { result in
                guard case .prepared(let prepared) = result else {
                    return XCTFail("Expected proof-scoped local target")
                }
                localPrepared = prepared
                localCompletion.fulfill()
            },
            .started
        )
        wait(for: [localCompletion], timeout: 2)
        let prepared = try XCTUnwrap(localPrepared)
        guard case .local(let candidate) =
                session.inspectPreparedVerifiedLocalTarget(prepared) else {
            return XCTFail("Evicted target inside proof must materialize from Realm")
        }
        XCTAssertNotNil(candidate.items.first { $0.primary == "primary-100" })
        XCTAssertEqual(candidate.items.map(\.primary), primaryIDs(70...130))
        XCTAssertNil(session.snapshot.item(primary: "primary-100"))

        guard case .local(let committed) =
                session.commitPreparedVerifiedLocalTarget(prepared) else {
            return XCTFail("Prepared target must commit exactly once")
        }
        XCTAssertNotNil(committed.item(primary: "primary-100"))
        XCTAssertEqual(store.aroundCallCount, 1)
        guard case .invalidProof =
                session.commitPreparedVerifiedLocalTarget(prepared) else {
            return XCTFail("Prepared target receipt must be one-shot")
        }

        let remoteCompletion = expectation(description: "remote target required")
        var remotePrepared: ChatTimelinePreparedVerifiedLocalTarget?
        let outside = try XCTUnwrap(ArchiveCursor(rawValue: "1001"))
        XCTAssertEqual(
            session.prepareVerifiedLocalTarget(
                primary: "primary-1001",
                archiveCursor: outside,
                expectedGeneration: session.snapshot.generation
            ) { result in
                guard case .prepared(let prepared) = result else {
                    return XCTFail("Expected target disposition")
                }
                remotePrepared = prepared
                remoteCompletion.fulfill()
            },
            .started
        )
        wait(for: [remoteCompletion], timeout: 2)
        guard case .needsArchiveTarget(let cursor) =
                session.inspectPreparedVerifiedLocalTarget(
                    try XCTUnwrap(remotePrepared)
                ) else {
            return XCTFail("Outside-proof target must hand off one archiveID")
        }
        XCTAssertEqual(cursor, outside)
        XCTAssertEqual(store.aroundCallCount, 1)
    }

    func testDisconnectInvalidatesScopeAndLateBoundaryPreparation() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let completion = expectation(description: "late preparation is stale")
        XCTAssertEqual(
            session.prepareVerifiedLocalBoundary(
                .older,
                expectedGeneration: session.snapshot.generation
            ) { result in
                guard case .stale = result else {
                    return XCTFail("Disconnect must revoke the prepared proof")
                }
                completion.fulfill()
            },
            .started
        )
        XCTAssertEqual(store.olderStarted.wait(timeout: .now() + 2), .success)

        session.invalidateVerifiedScope()
        store.releaseOlder.signal()

        wait(for: [completion], timeout: 2)
        XCTAssertNil(session.verifiedScope)
        XCTAssertTrue(session.snapshot.items.isEmpty)
        XCTAssertTrue(session.snapshot.state.isEmpty)
    }

    func testDisconnectRejectsAlreadyPreparedRemoteWindowReceipt() throws {
        let store = BlockingVirtualTimelineSessionStore(
            messages: makeMessages(1...1_000)
        )
        let session = makeSession(store: store)
        _ = try XCTUnwrap(session.installArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(501...1_000),
                target: .latest,
                generation: 1
            )
        ))
        let prepared = try XCTUnwrap(session.prepareArchiveEngineVerifiedWindow(
            try makeWindow(
                primaryIDs: primaryIDs(401...500),
                target: .older(
                    before: try XCTUnwrap(ArchiveCursor(rawValue: "501"))
                ),
                generation: 2
            )
        ))
        XCTAssertNotNil(session.inspectPreparedArchiveEngineVerifiedWindow(prepared))

        session.invalidateVerifiedScope()

        XCTAssertNil(session.inspectPreparedArchiveEngineVerifiedWindow(prepared))
        XCTAssertNil(session.commitPreparedArchiveEngineVerifiedWindow(prepared))
        XCTAssertNil(session.verifiedScope)
        XCTAssertTrue(session.snapshot.items.isEmpty)
    }

    private var conversationKey: ChatTimelineConversationKey {
        ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: .regular
        )
    }

    private func makeSession(store: ChatTimelineSessionStore) -> ChatTimelineSession {
        ChatTimelineSession(
            store: store,
            pageSize: 100,
            conversationKey: conversationKey,
            observesStoreImmediately: false
        )
    }

    private func makeWindow(
        primaryIDs: [String],
        target: ArchiveWindowLocator,
        generation: UInt64,
        connectionGeneration: UInt64 = 42
    ) throws -> ArchiveWindowSnapshot {
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: "1")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "1000")),
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: "session:\(connectionGeneration)",
            isVerified: true
        ))
        return ArchiveWindowSnapshot(
            messagePrimaryIDs: primaryIDs,
            target: target,
            verifiedSegment: segment,
            coverageGeneration: generation,
            freshnessToken: .sessionMAM(
                connectionGeneration: connectionGeneration,
                queryID: "query-\(generation)"
            )
        )
    }

    private func makeLiveEdgeAdmission(
        primaryID: String,
        presentationTarget: ArchiveWindowLocator,
        generation: UInt64,
        connectionGeneration: UInt64 = 42
    ) throws -> ArchiveLiveEdgeAdmission {
        let latestWindow = try makeWindow(
            primaryIDs: primaryIDs(922...1_001),
            target: .latest,
            generation: generation,
            connectionGeneration: connectionGeneration
        )
        let extendedSegment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: "1")),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: "1001")),
            reachesArchiveStart: true,
            reachesLiveEdge: true,
            fingerprint: "session:\(connectionGeneration)",
            isVerified: true
        ))
        return ArchiveLiveEdgeAdmission(
            conversation: ArchiveConversationKey(
                owner: owner,
                jid: jid,
                conversationType: .regular
            ),
            primaryID: primaryID,
            latestWindow: ArchiveWindowSnapshot(
                messagePrimaryIDs: latestWindow.messagePrimaryIDs,
                target: .latest,
                verifiedSegment: extendedSegment,
                coverageGeneration: generation,
                freshnessToken: latestWindow.freshnessToken
            ),
            presentationIntent: ArchiveIntentDescriptor(
                conversation: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: .regular
                ),
                locator: presentationTarget,
                contextBefore: ArchivePageSizing.history,
                contextAfter: ArchivePageSizing.initial
            )
        )
    }

    private func insertMessages(_ range: ClosedRange<Int>) throws {
        let realm = try Realm()
        try realm.write {
            realm.add(makeMessages(range))
        }
    }

    private func makeMessages(_ range: ClosedRange<Int>) -> [MessageStorageItem] {
        range.map { value in
            let item = MessageStorageItem()
            item.primary = "primary-\(value)"
            item.owner = owner
            item.opponent = jid
            item.archivedId = String(value)
            item.messageId = "message-\(value)"
            item.date = Date(timeIntervalSince1970: TimeInterval(value))
            item.sentDate = item.date
            item.conversationType = .regular
            return item
        }
    }

    private func primaryIDs(_ range: ClosedRange<Int>) -> [String] {
        range.map { "primary-\($0)" }
    }

    private func localSessionSnapshot(
        _ outcome: ChatVirtualTimelineBoundaryOutcome<ChatTimelineSessionSnapshot>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatTimelineSessionSnapshot {
        guard case .local(let snapshot) = outcome else {
            XCTFail("Expected local boundary outcome, got \(outcome)", file: file, line: line)
            throw ChatArchiveVirtualTimelineTestError.unexpectedOutcome
        }
        return snapshot
    }
}

private enum ChatArchiveVirtualTimelineTestError: Error {
    case unexpectedOutcome
}

private final class BlockingVirtualTimelineSessionStore: ChatTimelineSessionStore {
    let olderStarted = DispatchSemaphore(value: 0)
    let releaseOlder = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var messages: [MessageStorageItem]
    private(set) var diagnosticsSnapshot = ChatTimelineStoreDiagnosticsSnapshot.empty
    private var storedOlderCallCount = 0
    private var storedAroundCallCount = 0
    private var changeHandler: ((ChatTimelineStoreChange) -> Void)?

    var olderCallCount: Int {
        lock.withLock { storedOlderCallCount }
    }

    var aroundCallCount: Int {
        lock.withLock { storedAroundCallCount }
    }

    init(messages: [MessageStorageItem]) {
        self.messages = ChatTimelineOrdering.deduplicatedChronological(messages)
    }

    func replaceMessage(_ replacement: MessageStorageItem) {
        lock.withLock {
            messages = ChatTimelineOrdering.deduplicatedChronological(
                messages.filter { $0.primary != replacement.primary } +
                    [replacement]
            )
        }
    }

    func latest(limit: Int) -> [MessageStorageItem] {
        Array(messages.suffix(limit))
    }

    func older(before boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        lock.withLock { storedOlderCallCount += 1 }
        olderStarted.signal()
        _ = releaseOlder.wait(timeout: .now() + 5)
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }) else {
            return []
        }
        return Array(messages.prefix(index).suffix(limit))
    }

    func newer(after boundary: ChatTimelineBoundary, limit: Int) -> [MessageStorageItem] {
        guard let index = messages.firstIndex(where: { $0.primary == boundary.primary }),
              index + 1 < messages.count else {
            return []
        }
        return Array(messages[(index + 1)...].prefix(limit))
    }

    func around(anchor: MessageStorageItem, before: Int, after: Int) -> [MessageStorageItem] {
        lock.withLock { storedAroundCallCount += 1 }
        guard let index = messages.firstIndex(where: { $0.primary == anchor.primary }) else {
            return []
        }
        let lower = max(0, index - before)
        let upper = min(messages.count, index + after + 1)
        return Array(messages[lower..<upper])
    }

    func message(primary: String?, archivedId: String?, messageId: String?) -> MessageStorageItem? {
        if let primary, let result = messages.first(where: { $0.primary == primary }) {
            return result
        }
        if let archivedId, let result = messages.first(where: { $0.archivedId == archivedId }) {
            return result
        }
        if let messageId, let result = messages.first(where: { $0.messageId == messageId }) {
            return result
        }
        return nil
    }

    func items(primaryKeys: [String]) -> [MessageStorageItem] {
        let byPrimary = Dictionary(uniqueKeysWithValues: messages.map { ($0.primary, $0) })
        return primaryKeys.compactMap { byPrimary[$0] }
    }

    func unreadMetadata(limit: Int) -> ChatTimelineUnreadMetadata {
        .empty
    }

    func firstIncoming(afterArchiveBoundaryId boundaryArchivedId: String) -> MessageStorageItem? {
        nil
    }

    func observe(
        baseline: ChatTimelineStoreObservationBaseline,
        onChange: @escaping (ChatTimelineStoreChange) -> Void
    ) -> ChatTimelineStoreObservation {
        lock.withLock { changeHandler = onChange }
        return BlockingVirtualTimelineObservation()
    }

    func emit(_ change: ChatTimelineStoreChange) {
        lock.withLock { changeHandler }?(change)
    }
}

private final class BlockingVirtualTimelineObservation: ChatTimelineStoreObservation {
    func replaceResidentItems(_ items: [MessageStorageItem]) {}
    func invalidate() {}
}

private extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
