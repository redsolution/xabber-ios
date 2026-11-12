import XCTest
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
@testable import xabber

/// Exercises the real Realm/notification/controller projection path. The table
/// stays detached, where each actual dataset apply is observable as reloadData.
/// No account is connected and no production performance hooks are required.
@MainActor
final class LastChatsSyncLatencyRemediationTests: XCTestCase {
    private final class DatasetApplyTableView: UITableView {
        private(set) var applyCount = 0
        var didApply: (() -> Void)?

        override func reloadData() {
            applyCount += 1
            super.reloadData()
            didApply?()
        }

        func resetApplyCount() { applyCount = 0 }
    }

    private struct Fixture {
        let owner: String
        let chat: LastChatsStorageItem
        let message: MessageStorageItem
    }

    private var previousRealmConfiguration: Realm.Configuration!
    private var previousConnectingAccounts: Set<String>!
    private var previousChatStates: Set<CommonChatStatesManager.ChatStateMetadata>!
    private var controllers: [LastChatsViewController] = []
    private var ownersToClear = Set<String>()

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsSyncLatencyRemediationTests-\(UUID().uuidString)"
        )
        previousConnectingAccounts = AccountManager.shared.connectingUsers.value
        AccountManager.shared.connectingUsers.accept([])
        previousChatStates = CommonChatStatesManager.shared.observed.value
        CommonChatStatesManager.shared.observed.accept([])
        ChatUIResponsivenessGate.shared.resetForTesting()
    }

    override func tearDown() {
        controllers.forEach { $0.unsubscribe() }
        pumpMainRunLoop(for: 0.1)
        controllers.removeAll()
        ownersToClear.forEach { LastChatListSyncPreviewStore.shared.removeAll(for: $0) }
        ownersToClear.removeAll()
        CommonChatStatesManager.shared.observed.accept(previousChatStates)
        AccountManager.shared.connectingUsers.accept(previousConnectingAccounts)
        ChatUIResponsivenessGate.shared.resetForTesting()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        previousChatStates = nil
        previousConnectingAccounts = nil
        super.tearDown()
    }

    func testUnrelatedTypingDoesNotRebuildTheRecentChatsDataset() throws {
        let fixture = try makeFixture()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        CommonChatStatesManager.shared.update(
            jid: "not-a-visible-chat@example.invalid",
            owner: fixture.owner,
            state: .typing
        )
        pumpMainRunLoop(for: 0.65)

        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)
        XCTAssertEqual(table.applyCount, 0, "Typing for a conversation outside the rendered list must not map the list.")
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
    }

    func testOldOutgoingReceiptDoesNotRebuildAnUnchangedLastMessage() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let old = message(owner: fixture.owner, jid: fixture.chat.jid,
            primary: "old-outgoing", messageID: "old-id", body: "Earlier message", date: 10)
        old.outgoing = true
        old.state = .sended
        try realm.write { realm.add(old) }
        let (controller, table) = subscribedController(owners: [fixture.owner])
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        try realm.write { old.state = .deliver }
        pumpMainRunLoop(for: 0.65)

        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)
        XCTAssertEqual(table.applyCount, 0, "A receipt for an older outgoing row must not remap the current preview.")
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
    }

    func testArchivedOnlySyncPreviewDoesNotRebuildTheActiveChatsFilter() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let archived = LastChatsStorageItem()
        archived.owner = fixture.owner
        archived.jid = "archived-peer@example.invalid"
        archived.conversationType = .regular
        archived.setPrimary(withOwner: fixture.owner)
        archived.isArchived = true
        archived.lastMessageId = "archived-sync-message"
        archived.messageDate = Date(timeIntervalSince1970: 100)
        try realm.write { realm.add(archived) }
        let (controller, table) = subscribedController(owners: [fixture.owner])
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        LastChatListSyncPreviewStore.shared.apply([.upsert(.init(
            owner: fixture.owner,
            conversationPrimary: archived.primary,
            lastMessageID: archived.lastMessageId,
            text: "Changed archived preview"
        ))], for: fixture.owner)
        pumpMainRunLoop(for: 0.65)

        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)
        XCTAssertEqual(table.applyCount, 0, "The changed-primary notification must not invalidate an unrelated visible filter.")
        XCTAssertEqual(controller.datasource.map(\.jid), [fixture.chat.jid])
    }

    func testOneCommittedPageRealmAndPreviewChangesProduceAtMostOneDatasetApply() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        // These are the two existing notifications for one committed sync page:
        // a durable chat mutation and its detached list-preview batch.
        try realm.write {
            fixture.chat.lastMessage = nil
            fixture.chat.lastMessageId = "new-page-message"
            fixture.chat.messageDate = Date(timeIntervalSince1970: 300)
        }
        LastChatListSyncPreviewStore.shared.apply([.upsert(.init(
            owner: fixture.owner,
            conversationPrimary: fixture.chat.primary,
            lastMessageID: fixture.chat.lastMessageId,
            text: "Newest page preview"
        ))], for: fixture.owner)
        pumpMainRunLoop(for: 0.65)

        XCTAssertEqual(controller.datasource.first?.message, "Newest page preview")
        XCTAssertLessThanOrEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 1,
            "Late callbacks must avoid the actual mapping operation, not merely discard its UI output.")
        XCTAssertLessThanOrEqual(table.applyCount, 1,
            "A single committed page must not trigger separate Realm and preview full rebuilds.")
        XCTAssertGreaterThan(table.applyCount, 0, "The changed page still has to reach the dataset.")
    }

    func testRetiringDatasetSubscriptionsAlsoRetiresTheSkeletonListener() throws {
        let fixture = try makeFixture()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        controller.datasetBag = DisposeBag()
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        controller.showSkeleton.accept(true)
        pumpMainRunLoop(for: 0.4)

        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)
        XCTAssertEqual(table.applyCount, 0,
            "A retired dataset must not keep a skeleton-triggered full rebuild listener in the wider lifecycle bag.")
    }

    func testMaterializedPreviewRefreshesAfterSameMessageIDContentEdit() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")
        let realm = try WRealm.safe()

        try realm.write { fixture.message.body = "Edited without changing the message ID" }

        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message,
            "Edited without changing the message ID")
        XCTAssertNil(fixture.chat.lastMessage, "Read-only resolution must not repair a Realm link.")
    }

    func testMaterializedPreviewDoesNotReuseADeletedCachedMessage() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")
        let realm = try WRealm.safe()

        try realm.write { fixture.message.isDeleted = true }

        XCTAssertNotEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")
        XCTAssertNil(fixture.chat.lastMessage)
    }

    func testMaterializedPreviewInvalidatesWhenReportVisibilityChanges() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")
        let realm = try WRealm.safe()

        try realm.write { fixture.message.isLocallyHiddenByReport = true }

        XCTAssertNotEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview",
            "A previously cached body must not survive a local report visibility change.")
    }

    func testMaterializedPreviewDoesNotCrossAccountsWithEqualMessageIDs() throws {
        let first = try makeFixture(owner: "first-owner@example.invalid", body: "First owner body", linkMessage: false)
        let second = try makeFixture(owner: "second-owner@example.invalid", body: "Second owner body", linkMessage: false)
        let controller = mappingController(owners: [first.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: first).message, "First owner body")

        controller.enabledAccounts.accept([second.owner])

        let rows = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
        XCTAssertEqual(rows.map(\.owner), [second.owner])
        XCTAssertEqual(rows.first?.message, "Second owner body")
    }

    func testMaterializedPreviewDoesNotCrossRealmInstancesWithEqualRowIdentities() throws {
        let first = try makeFixture(linkMessage: false)
        let firstRealm = try WRealm.safe()
        let snapshot = LastChatsViewController.makeDatasetReadSnapshot(from: firstRealm)
        let controller = mappingController(owners: [first.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: first, realm: snapshot).message, "Initial preview")
        let nextRealm = try Realm(configuration: .init(inMemoryIdentifier: "other-preview-\(UUID().uuidString)"))
        let nextMessage = message(owner: first.owner, jid: first.chat.jid,
            primary: first.message.primary, messageID: first.message.messageId,
            body: "Different Realm body", date: 200)
        let nextChat = LastChatsStorageItem()
        nextChat.owner = first.owner
        nextChat.jid = first.chat.jid
        nextChat.conversationType = .regular
        nextChat.setPrimary(withOwner: first.owner)
        nextChat.lastMessageId = nextMessage.messageId
        nextChat.messageDate = nextMessage.date
        try nextRealm.write { nextRealm.add(nextMessage); nextRealm.add(nextChat) }

        let rows = controller.mapDataset(in: nextRealm, showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])

        XCTAssertEqual(rows.first?.message, "Different Realm body")
        XCTAssertNil(nextChat.lastMessage)
    }

    func testActiveSyncPageDefersActualMappingAndLateNotificationsDoNotRebuildItAgain() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()
        let token = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(token) }

        try realm.write {
            fixture.chat.lastMessage = nil
            fixture.chat.lastMessageId = "page-batch-message"
            fixture.chat.messageDate = Date(timeIntervalSince1970: 300)
        }
        LastChatListSyncPreviewStore.shared.apply([.upsert(.init(owner: fixture.owner,
            conversationPrimary: fixture.chat.primary, lastMessageID: fixture.chat.lastMessageId,
            text: "Atomic page preview"))], for: fixture.owner)
        pumpMainRunLoop(for: 0.25)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)

        ClientSyncPageBatch.shared.commit(token, changedConversationPrimaries: [fixture.chat.primary])
        pumpMainRunLoop(for: 0.65)

        XCTAssertEqual(controller.datasource.first?.message, "Atomic page preview")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 1)
        XCTAssertEqual(table.applyCount, 1)
        controller.syncLatencyWorkCounter.reset()
        try realm.write { fixture.chat.draftMessage = "Independent live draft" }
        pumpMainRunLoop(for: 0.4)
        XCTAssertEqual(controller.datasource.first?.message, "Independent live draft",
            "A later live notification must not be swallowed as the already-rendered page callback.")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 1)
    }

    func testCancellingPageBatchReleasesAnIndependentlyDeferredLiveChange() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let (controller, _) = subscribedController(owners: [fixture.owner])
        controller.syncLatencyWorkCounter.reset()
        let token = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(token) }
        try realm.write { fixture.chat.draftMessage = "Live change during failed page" }
        pumpMainRunLoop(for: 0.25)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)

        ClientSyncPageBatch.shared.cancel(token)
        pumpMainRunLoop(for: 0.5)

        XCTAssertEqual(controller.datasource.first?.message, "Live change during failed page")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 1)
    }

    func testUnchangedSnapshotAvoidsActualMappingAndMaterializedCandidateQueries() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        _ = try mappedRow(controller, fixture: fixture)
        _ = try mappedRow(controller, fixture: fixture)

        let work = controller.syncLatencyWorkCounter.snapshot
        XCTAssertEqual(work.fullDatasetBuilds, 1)
        XCTAssertEqual(work.rowBuilds, 1)
        XCTAssertEqual(work.candidateQueries, 1)
        XCTAssertEqual(work.datasetHits, 1)
    }

    func testChangedRowDoesNotRepeatRichRenderingOfAnUnchangedAccountRow() throws {
        let first = try makeFixture(owner: "render-first@example.invalid", body: "First")
        let second = try makeFixture(owner: "render-second@example.invalid", body: "Second")
        let controller = mappingController(owners: [first.owner, second.owner])
        _ = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
        controller.syncLatencyWorkCounter.reset()
        let realm = try WRealm.safe()

        try realm.write { first.message.body = "First edited" }
        let rows = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])

        XCTAssertEqual(rows.first { $0.owner == first.owner }?.message, "First edited")
        XCTAssertEqual(rows.first { $0.owner == second.owner }?.message, "Second")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.rowBuilds, 1)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.rowHits, 1)
    }

    func testPersistedRecentChatStaysSkeletonAfterConnectionIndicatorClears() throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        try realm.write { fixture.chat.unread = 1 }
        AccountManager.shared.connectingUsers.accept([fixture.owner])
        var isAwaitingStartupSync = true
        let presentation = LastChatsStartupPresentation()
        presentation.begin(owners: [fixture.owner])
        let controller = LastChatsViewController()
        controller.startupRecentsPresentation = presentation
        controller.startupRecentsSyncPendingForTesting = { owner in
            owner == fixture.owner && isAwaitingStartupSync
        }
        controllers.append(controller)

        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.datasourceShowsSkeleton, "The first frame is ready before list subscriptions run.")
        XCTAssertGreaterThan(controller.datasource.count, 0)
        controller.subscribe()
        pumpMainRunLoop(for: 0.5)

        XCTAssertTrue(controller.datasourceShowsSkeleton)
        XCTAssertFalse(controller.datasource.contains { $0.jid == fixture.chat.jid })

        AccountManager.shared.connectingUsers.accept([])
        pumpMainRunLoop(for: 0.3)

        XCTAssertTrue(controller.datasourceShowsSkeleton,
            "An unrelated connection or disco signal must leave the recents skeleton in place.")
        XCTAssertFalse(controller.datasource.contains { $0.jid == fixture.chat.jid })

        controller.filter.accept(.unread)
        pumpMainRunLoop(for: 0.3)
        XCTAssertEqual(controller.filter.value, .unread)
        XCTAssertTrue(controller.datasourceShowsSkeleton, "Unread recents must share the same startup gate.")
        XCTAssertFalse(controller.datasource.contains { $0.jid == fixture.chat.jid })

        let ordinaryBatch = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        ClientSyncPageBatch.shared.commit(ordinaryBatch, changedConversationPrimaries: [fixture.chat.primary])
        pumpMainRunLoop(for: 0.3)
        XCTAssertTrue(controller.datasourceShowsSkeleton, "An ordinary live batch is not startup response evidence.")

        let startupBatch = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(startupBatch) }
        isAwaitingStartupSync = false
        NotificationCenter.default.post(name: ClientSynchronizationManager.startupRecentsReadinessDidChange,
            object: fixture.owner)
        pumpMainRunLoop(for: 0.3)
        XCTAssertTrue(controller.datasourceShowsSkeleton, "An active batch still owns publication.")

        ClientSyncPageBatch.shared.commit(startupBatch, changedConversationPrimaries: [])
        pumpMainRunLoop(for: 0.5)
        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)

        AccountManager.shared.connectingUsers.accept([fixture.owner])
        pumpMainRunLoop(for: 0.3)
        XCTAssertFalse(controller.datasourceShowsSkeleton, "A warm reconnect must preserve the released list.")
    }

    func testBackgroundRetiresPendingColdSkeletonForVisibleAndRecreatedRecents() throws {
        let fixture = try makeFixture()
        let presentation = LastChatsStartupPresentation()
        presentation.begin(owners: [fixture.owner])
        let controller = LastChatsViewController()
        controller.startupRecentsPresentation = presentation
        controller.startupRecentsSyncPendingForTesting = { $0 == fixture.owner }
        controllers.append(controller)
        let activePage = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(activePage) }
        controller.loadViewIfNeeded()
        controller.subscribe()
        XCTAssertTrue(controller.datasourceShowsSkeleton)

        presentation.end()

        XCTAssertFalse(controller.datasourceShowsSkeleton, "The pending first page cannot keep a skeleton on return.")
        ClientSyncPageBatch.shared.commit(activePage, changedConversationPrimaries: [])
        controller.unsubscribe()
        controller.subscribe()
        pumpMainRunLoop(for: 0.5)
        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)

        let recreated = LastChatsViewController()
        recreated.startupRecentsPresentation = presentation
        recreated.startupRecentsSyncPendingForTesting = { $0 == fixture.owner }
        controllers.append(recreated)
        recreated.loadViewIfNeeded()
        XCTAssertFalse(recreated.datasourceShowsSkeleton)
        recreated.subscribe()
        pumpMainRunLoop(for: 0.5)
        XCTAssertFalse(recreated.datasourceShowsSkeleton)
        XCTAssertEqual(recreated.datasource.first?.message, fixture.message.body)
    }

    func testColdStartupDeadlineShowsCachedRecentsWhileSyncIsStillPending() throws {
        let fixture = try makeFixture()
        AccountManager.shared.connectingUsers.accept([fixture.owner])
        var scheduledDeadlines: [() -> Void] = []
        let presentation = LastChatsStartupPresentation(scheduleDeadline: { deadline in
            scheduledDeadlines.append(deadline)
        })
        presentation.begin(owners: [fixture.owner])
        presentation.begin(owners: [fixture.owner])
        let controller = LastChatsViewController()
        controller.startupRecentsPresentation = presentation
        controller.startupRecentsSyncPendingForTesting = { $0 == fixture.owner }
        controllers.append(controller)

        controller.loadViewIfNeeded()
        controller.subscribe()
        pumpMainRunLoop(for: 0.5)

        XCTAssertTrue(controller.datasourceShowsSkeleton)
        XCTAssertFalse(controller.datasource.contains { $0.jid == fixture.chat.jid })
        XCTAssertEqual(scheduledDeadlines.count, 1)

        try XCTUnwrap(scheduledDeadlines.first)()
        pumpMainRunLoop(for: 0.5)

        XCTAssertEqual(AccountManager.shared.connectingUsers.value, [fixture.owner])
        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)

        presentation.begin(owners: [fixture.owner])
        NotificationCenter.default.post(
            name: ClientSynchronizationManager.startupRecentsReadinessDidChange,
            object: fixture.owner
        )
        pumpMainRunLoop(for: 0.3)

        XCTAssertEqual(scheduledDeadlines.count, 1)
        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
    }

    func testColdStartupDeadlineRemovesSkeletonWithoutPublishingAnActiveSyncBatch() throws {
        let fixture = try makeFixture()
        var scheduledDeadline: (() -> Void)?
        let presentation = LastChatsStartupPresentation(scheduleDeadline: { scheduledDeadline = $0 })
        presentation.begin(owners: [fixture.owner])
        let controller = LastChatsViewController()
        controller.startupRecentsPresentation = presentation
        controller.startupRecentsSyncPendingForTesting = { $0 == fixture.owner }
        controllers.append(controller)
        let activePage = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(activePage) }

        controller.loadViewIfNeeded()
        controller.subscribe()
        XCTAssertTrue(controller.datasourceShowsSkeleton)

        try XCTUnwrap(scheduledDeadline)()
        pumpMainRunLoop(for: 0.3)

        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertFalse(controller.datasource.contains { $0.jid == fixture.chat.jid })

        ClientSyncPageBatch.shared.commit(activePage, changedConversationPrimaries: [])
        pumpMainRunLoop(for: 0.5)

        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
    }

    func testNoActiveStartupSyncShowsCachedRecentsWhenTheListSubscribes() throws {
        let fixture = try makeFixture()
        AccountManager.shared.connectingUsers.accept([fixture.owner])
        let controller = LastChatsViewController()
        controller.startupRecentsSyncPendingForTesting = { _ in false }
        controllers.append(controller)
        controller.enabledAccounts.accept([fixture.owner])
        controller.tableView = DatasetApplyTableView(frame: .zero, style: .plain)

        controller.subscribe()
        pumpMainRunLoop(for: 0.5)

        XCTAssertFalse(controller.datasourceShowsSkeleton)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
    }

    func testInitialEmptyBannerObservationsDoNotRequestAdditionalDatasetPasses() throws {
        let fixture = try makeFixture()
        let controller = mappingController(owners: [fixture.owner])
        controller.tableView = DatasetApplyTableView(frame: .zero, style: .plain)
        // The real controller completes viewDidLoad before subscribing in viewWillAppear.
        controller.loadViewIfNeeded()
        controller.subscribe()
        pumpMainRunLoop(for: 1.15)

        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
        let work = controller.syncLatencyWorkCounter.snapshot
        XCTAssertEqual(work.fullDatasetBuilds + work.datasetHits, 1)
    }

    func testChangingOnePreviewScopeRequestsOnlyOneDatasetPass() throws {
        let fixture = try makeFixture()
        let (controller, _) = subscribedController(owners: [fixture.owner])
        let realm = try WRealm.safe()
        controller.syncLatencyWorkCounter.reset()

        try realm.write {
            fixture.chat.lastMessageId = "replacement-preview-id"
            fixture.chat.lastMessage = nil
        }
        pumpMainRunLoop(for: 0.45)

        XCTAssertNotEqual(controller.datasource.first?.message, fixture.message.body)
        let work = controller.syncLatencyWorkCounter.snapshot
        XCTAssertEqual(work.fullDatasetBuilds + work.datasetHits, 1)
    }

    func testUnchangedRowsDoNotReloadDetachedTableAfterAnUnrelatedWrite() throws {
        let fixture = try makeFixture()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        let realm = try WRealm.safe()
        let unrelated = message(owner: fixture.owner, jid: "other-peer@example.invalid",
            primary: "unrelated-realm-version", messageID: "unrelated-id", body: "Other history", date: 100)
        table.resetApplyCount()

        try realm.write { realm.add(unrelated) }
        controller.runDatasetUpdateTask()
        pumpMainRunLoop(for: 0.45)

        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
        XCTAssertEqual(table.applyCount, 0)
    }

    func testMaterializedCandidateCacheIsBoundedAndUsesNoQueryForTheSameReadVersion() throws {
        let realm = try WRealm.safe()
        var chats: [LastChatsStorageItem] = []
        try realm.write {
            for index in 0..<3 {
                let row = LastChatsStorageItem()
                row.owner = "bounded-cache@example.invalid"
                row.jid = "peer-\(index)@example.invalid"
                row.conversationType = .regular
                row.setPrimary(withOwner: row.owner)
                row.lastMessageId = "message-\(index)"
                let item = message(owner: row.owner, jid: row.jid,
                    primary: "bounded-\(index)", messageID: row.lastMessageId,
                    body: "Body \(index)", date: 200)
                realm.add(row); realm.add(item); chats.append(row)
            }
        }
        let read = LastChatsViewController.makeDatasetReadSnapshot(from: realm)
        let frozenChats = chats.compactMap { read.object(ofType: LastChatsStorageItem.self, forPrimaryKey: $0.primary) }
        let cache = LastChatsMaterializedPreviewCache(capacity: 2)
        let counter = LastChatsProjectionWorkCounter()
        _ = cache.resolve(in: read, for: frozenChats, counter: counter)
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(counter.snapshot.candidateQueries, 1)
        counter.reset()

        let result = cache.resolve(in: read, for: Array(frozenChats.suffix(2)), counter: counter)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(counter.snapshot.candidateQueries, 0)
        XCTAssertEqual(counter.snapshot.candidateHits, 2)
        cache.removeAll()
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testNewMatchingCandidateInvalidatesThePreviousReadVersionWinner() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")
        let realm = try WRealm.safe()
        let newer = message(owner: fixture.owner, jid: fixture.chat.jid,
            primary: "new-winning-candidate", messageID: fixture.message.messageId,
            body: "Newer candidate", date: 400)

        try realm.write { realm.add(newer) }

        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Newer candidate")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.candidateQueries, 2,
            "A new Realm version must not reuse an old candidate-membership proof.")
    }

    func testExactPreviewPrecedesNewerArchiveMatchAndDeletionRevealsOnlyItsConversation() throws {
        let fixture = try makeFixture(linkMessage: false)
        let controller = mappingController(owners: [fixture.owner])
        let realm = try WRealm.safe()
        let archived = message(owner: fixture.owner, jid: fixture.chat.jid,
            primary: "archived-fallback", messageID: "different-origin", body: "Archived preview", date: 300)
        archived.archivedId = fixture.message.messageId
        let otherChat = message(owner: fixture.owner, jid: "other-peer@example.invalid",
            primary: "wrong-preview-chat", messageID: fixture.message.messageId, body: "Other chat", date: 400)
        let otherType = message(owner: fixture.owner, jid: fixture.chat.jid,
            primary: "wrong-preview-type", messageID: fixture.message.messageId, body: "Other type", date: 500)
        otherType.conversationType = .group
        try realm.write { realm.add([archived, otherChat, otherType]) }

        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Initial preview")

        try realm.write { realm.delete(fixture.message) }
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Archived preview")

        try realm.write { archived.body = "Edited archived preview" }
        XCTAssertEqual(try mappedRow(controller, fixture: fixture).message, "Edited archived preview")
    }

    func testResourcePresentationUsesOneBatchedQueryForMultipleRows() throws {
        let first = try makeFixture(owner: "resource-first@example.invalid")
        let second = try makeFixture(owner: "resource-second@example.invalid")
        let realm = try WRealm.safe()
        try realm.write {
            for fixture in [first, second] {
                let roster = RosterStorageItem()
                roster.owner = fixture.owner; roster.jid = fixture.chat.jid
                roster.primary = RosterStorageItem.genPrimary(jid: roster.jid, owner: roster.owner)
                let resource = ResourceStorageItem()
                resource.primary = "resource-\(fixture.owner)"
                resource.owner = fixture.owner; resource.jid = fixture.chat.jid
                resource.status_ = ResourceStatus.online.rawValue
                realm.add(roster); realm.add(resource); fixture.chat.rosterItem = roster
            }
        }
        let controller = mappingController(owners: [first.owner, second.owner])

        let rows = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.status == .online })
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.resourceQueries, 1)
    }

    func testSavedEmptyPreviewInvalidatesWhenEnabledAccountCountChanges() throws {
        let previousUsers = AccountManager.shared.users
        AccountManager.shared.users = []
        defer { AccountManager.shared.users = previousUsers }
        let owner = "saved-cache-owner@example.invalid"
        let secondOwner = "saved-cache-second@example.invalid"
        ownersToClear.formUnion([owner, secondOwner])
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = "favorites-cache@example.invalid"
        chat.conversationType = .saved
        chat.setPrimary(withOwner: owner)
        let favorites = XMPPFavoritesManagerStorageItem()
        favorites.primary = XMPPFavoritesManagerStorageItem.genPrimary(owner: owner)
        favorites.owner = owner; favorites.node = chat.jid
        try realm.write {
            for jid in [owner, secondOwner] {
                let account = AccountStorageItem(); account.jid = jid; account.enabled = true
                realm.add(account)
            }
            realm.add(favorites); realm.add(chat)
        }
        let controller = mappingController(owners: [owner])
        controller.filter.accept(.saved)
        let first = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
        XCTAssertEqual(first.first?.message, SavedMessagesChatListPresentationPolicy.singleAccountPlaceholder)

        controller.enabledAccounts.accept([owner, secondOwner])
        let second = controller.mapDataset(showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])

        XCTAssertEqual(second.first?.message, owner,
            "The saved empty subtitle depends on enabled account count even when AccountManager.users is unchanged.")
    }

    func testPageBeginningDuringMappingPreventsStaleDatasetApply() throws {
        try assertPageChangeDuringMapping(commitBeforeResume: false)
    }

    func testPageCommittedDuringMappingPreventsStaleDatasetApply() throws {
        try assertPageChangeDuringMapping(commitBeforeResume: true)
    }

    private func assertPageChangeDuringMapping(commitBeforeResume: Bool) throws {
        let fixture = try makeFixture()
        let realm = try WRealm.safe()
        let (controller, table) = subscribedController(owners: [fixture.owner])
        let entered = expectation(description: "Rich mapping has prepared its immutable rows")
        let resume = DispatchSemaphore(value: 0)
        let once = NSLock()
        var hasPaused = false
        controller.projectionMappingDidPrepareForTesting = {
            once.lock()
            let pause = !hasPaused
            hasPaused = true
            once.unlock()
            guard pause else { return }
            entered.fulfill()
            _ = resume.wait(timeout: .now() + 5)
        }
        defer { resume.signal(); controller.projectionMappingDidPrepareForTesting = nil }
        var appliedMessages: [String] = []
        table.didApply = { appliedMessages.append(controller.datasource.first?.message ?? "") }
        try realm.write { fixture.chat.draftMessage = "Pre-page prepared row" }
        controller.runDatasetUpdateTask()
        wait(for: [entered], timeout: 2)
        let token = ClientSyncPageBatch.shared.begin(owner: fixture.owner, generation: 1)
        defer { ClientSyncPageBatch.shared.cancel(token) }
        try realm.write { fixture.chat.draftMessage = "Committed page row" }
        if commitBeforeResume {
            ClientSyncPageBatch.shared.commit(token, changedConversationPrimaries: [fixture.chat.primary])
        }

        resume.signal()
        pumpMainRunLoop(for: 0.25)
        XCTAssertFalse(appliedMessages.contains("Pre-page prepared row"),
            "A row prepared against an earlier page revision must not be cached/applied after the page changes.")
        if !commitBeforeResume {
            XCTAssertTrue(appliedMessages.isEmpty, "No dataset apply may escape while the page boundary is active.")
            ClientSyncPageBatch.shared.commit(token, changedConversationPrimaries: [fixture.chat.primary])
        }
        pumpMainRunLoop(for: 0.6)
        XCTAssertEqual(controller.datasource.first?.message, "Committed page row")
        XCTAssertFalse(appliedMessages.contains("Pre-page prepared row"))
        table.didApply = nil
    }

    func testIdleProjectionCacheExpiresWithoutForcingAnotherDatasetApply() throws {
        let fixture = try makeFixture(linkMessage: false)
        let (controller, table) = subscribedController(owners: [fixture.owner])
        XCTAssertGreaterThan(controller.retainedProjectionSnapshotCountForTesting, 0)
        table.resetApplyCount()
        controller.syncLatencyWorkCounter.reset()

        pumpMainRunLoop(for: 2.2)

        XCTAssertEqual(controller.retainedProjectionSnapshotCountForTesting, 0,
            "Idle UI must release pinned Realm versions as well as bounded DTO entries.")
        XCTAssertEqual(table.applyCount, 0)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.fullDatasetBuilds, 0)
        XCTAssertEqual(controller.datasource.first?.message, fixture.message.body)
        controller.syncLatencyWorkCounter.reset()

        let row = try mappedRow(controller, fixture: fixture)

        XCTAssertEqual(row.message, fixture.message.body)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.rowBuilds, 0,
            "Expiring Realm read proofs must preserve bounded immutable rich rendering.")
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.rowHits, 1)
        XCTAssertEqual(controller.syncLatencyWorkCounter.snapshot.candidateQueries, 1,
            "A new read must establish candidate membership again after its version proof expired.")
        XCTAssertEqual(table.applyCount, 0)
    }

    func testUnsubscribedControllerCanDeallocateWithoutCreatingANewWeakReference() {
        weak var released: LastChatsViewController?
        autoreleasepool {
            let controller = LastChatsViewController()
            released = controller
            controller.unsubscribe()
        }
        XCTAssertNil(released)
    }

    private func makeFixture(
        owner: String = "sync-latency-owner@example.invalid",
        body: String = "Initial preview",
        linkMessage: Bool = true
    ) throws -> Fixture {
        let realm = try WRealm.safe()
        ownersToClear.insert(owner)
        let account = AccountStorageItem()
        account.jid = owner
        account.enabled = true
        let item = message(owner: owner, jid: "visible-peer@example.invalid",
            primary: "message-\(owner)", messageID: "shared-message-id", body: body, date: 200)
        item.outgoing = true
        item.state = .sended
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = item.opponent
        chat.conversationType = .regular
        chat.setPrimary(withOwner: owner)
        chat.lastMessageId = item.messageId
        chat.lastMessage = linkMessage ? item : nil
        chat.messageDate = item.date
        try realm.write { realm.add(account); realm.add(item); realm.add(chat) }
        return Fixture(owner: owner, chat: chat, message: item)
    }

    private func message(owner: String, jid: String, primary: String,
        messageID: String, body: String, date: TimeInterval) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.messageId = messageID
        item.body = body
        item.date = Date(timeIntervalSince1970: date)
        return item
    }

    private func mappingController(owners: Set<String>) -> LastChatsViewController {
        let controller = LastChatsViewController()
        controllers.append(controller)
        controller.enabledAccounts.accept(owners)
        controller.showSkeleton.accept(false)
        return controller
    }

    private func subscribedController(owners: Set<String>) -> (LastChatsViewController, DatasetApplyTableView) {
        let controller = mappingController(owners: owners)
        let table = DatasetApplyTableView(frame: .zero, style: .plain)
        controller.tableView = table
        controller.subscribe()
        // Includes the preexisting 800/900-ms initial request/invite debounce.
        pumpMainRunLoop(for: 1.15)
        return (controller, table)
    }

    private func mappedRow(_ controller: LastChatsViewController, fixture: Fixture,
        realm: Realm? = nil) throws -> LastChatsViewController.Datasource {
        try XCTUnwrap(controller.mapDataset(in: realm,
            showsSpecialMessageBanners: false, dismissedInvitePrimaries: [])
            .first { $0.owner == fixture.owner && $0.jid == fixture.chat.jid })
    }

    private func pumpMainRunLoop(for interval: TimeInterval) {
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            _ = RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.005)))
        }
    }
}
