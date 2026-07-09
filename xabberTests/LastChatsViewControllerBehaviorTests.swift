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

import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LastChatsViewControllerBehaviorTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsViewControllerBehaviorTests-\(name)-\(UUID().uuidString)"
        )
        ChatUIResponsivenessGate.shared.resetForTesting()
    }

    override func tearDown() {
        ChatUIResponsivenessGate.shared.resetForTesting()
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testConfigureBarsTabsWithNoSecurityShowsOnlyAddButton() {
        withInterfaceType(.tabs, useYubikey: false) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 1)
            XCTAssertFalse(rightItems.contains(controller.securityButton))
        }
    }

    func testConfigureBarsTabsWithSecurityShowsAddAndSecurityButtons() {
        withInterfaceType(.tabs, useYubikey: true) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 2)
            XCTAssertTrue(rightItems.contains(controller.securityButton))
        }
    }

    func testConfigureBarsSplitShowsOnlyAddButton() {
        withInterfaceType(.split, useYubikey: true) {
            let controller = LastChatsViewController()
            controller.configureBars()

            let rightItems = navigationBarItems(controller.navigationItem.rightBarButtonItems,
                                               controller.navigationItem.rightBarButtonItem)

            XCTAssertEqual(rightItems.count, 1)
            XCTAssertFalse(rightItems.contains(controller.securityButton))
        }
    }

    func testUpdateTitleAlwaysShowsChats() {
        let controller = LastChatsViewController()
        let expected = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])

        controller.updateTitle(.unread)
        XCTAssertEqual(controller.title, expected)

        controller.updateTitle(.archived)
        XCTAssertEqual(controller.title, expected)

        controller.updateTitle(.saved)
        XCTAssertEqual(controller.title, expected)
    }

    func testRootLargeTitleFollowsCommonConfig() {
        assertLargeTitle(useLargeTitle: true)
        assertLargeTitle(useLargeTitle: false)
    }

    func testFloatingBottomBarTitleShowsMarkAllAsReadAction() {
        let controller = LastChatsViewController()

        XCTAssertEqual(
            controller.floatingBottomBarTitle,
            "Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: [])
        )
    }

    func testMarkAllAsReadButtonStateFollowsUnreadAndConnectingState() {
        let controller = LastChatsViewController()
        let previousEnabledAccounts = controller.enabledAccounts.value
        let previousConnectingAccounts = AccountManager.shared.connectingUsers.value

        defer {
            controller.enabledAccounts.accept(previousEnabledAccounts)
            AccountManager.shared.connectingUsers.accept(previousConnectingAccounts)
        }

        let ownerJid = "owner@example.com"
        controller.enabledAccounts.accept([ownerJid])
        AccountManager.shared.connectingUsers.accept([])

        controller.updateUnreadChatsCounter(count: 0)
        XCTAssertFalse(controller.isMarkAllReadButtonEnabled)

        controller.updateUnreadChatsCounter(count: 1)
        XCTAssertTrue(controller.isMarkAllReadButtonEnabled)

        AccountManager.shared.connectingUsers.accept([ownerJid])
        controller.updateUnreadChatsCounter(count: 1)
        XCTAssertFalse(controller.isMarkAllReadButtonEnabled)
    }

    func testBottomSearchExpansionHidesAndRestoresLastChatsActionBar() {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()

        XCTAssertFalse(controller.isFloatingBottomBarHidden)

        controller.bottomSearchHostView.setExpanded(true, animated: false)
        controller.bottomSearchPresentationStateDidChange()

        XCTAssertTrue(controller.isFloatingBottomBarHidden)
        XCTAssertFalse(controller.bottomSearchHostView.surfaceView.isHidden)

        controller.bottomSearchHostView.cancelButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(controller.isFloatingBottomBarHidden)
        XCTAssertFalse(controller.bottomSearchHostView.collapsedButton.isHidden)
    }

    func testBottomSearchCollapsedPassesHitsToLastChatsActionButtons() {
        let controller = LastChatsViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.loadViewIfNeeded()
        controller.updateUnreadChatsCounter(count: 1)
        controller.view.layoutIfNeeded()

        let filterButton = controller.floatingBottomBarFilterButton
        let markAllButton = controller.markAllReadButton
        let filterPoint = controller.view.convert(
            CGPoint(x: filterButton.bounds.midX, y: filterButton.bounds.midY),
            from: filterButton
        )
        let markAllPoint = controller.view.convert(
            CGPoint(x: markAllButton.bounds.midX, y: markAllButton.bounds.midY),
            from: markAllButton
        )

        XCTAssertTrue(controller.view.hitTest(filterPoint, with: nil) === filterButton)
        XCTAssertTrue(controller.view.hitTest(markAllPoint, with: nil) === markAllButton)
    }

    func testChatSearchMapsGroupMessagesIntoMessageResults() throws {
        let owner = "owner@example.com"
        let groupJid = "group@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(jid: groupJid, owner: owner, conversationType: .group)
        chat.owner = owner
        chat.jid = groupJid
        chat.conversationType = .group

        let message = MessageStorageItem()
        message.primary = "group-message-primary"
        message.owner = owner
        message.opponent = groupJid
        message.conversationType = .group
        message.body = "group search needle"
        message.date = Date(timeIntervalSince1970: 10)
        message.archivedId = "archive-group-message"

        try realm.write {
            realm.add(chat, update: .modified)
            realm.add(message, update: .modified)
        }

        let updater = ChatSearchResultsController()
        updater.messagesQueue = [message]
        try updater.updateMessagesSearchResults()

        XCTAssertEqual(updater.numberOfSections(), 1)
        XCTAssertEqual(updater.titleForHeader(in: 0), "Messages".localizeString(id: "groupchat_member_messages", arguments: []))
        let result = try XCTUnwrap(updater.item(at: IndexPath(row: 0, section: 0)))
        XCTAssertEqual(result.jid, groupJid)
        XCTAssertEqual(result.conversationType, .group)
        XCTAssertEqual(result.entity, .groupchat)
        XCTAssertEqual(result.messageArchiveId, "archive-group-message")
    }

    func testMarkAllAsReadTargetsOnlyUnreadNonArchivedEnabledChats() {
        let targets = LastChatsViewController.unreadChatReadTargets(
            from: [
                .init(
                    owner: "enabled@example.com",
                    jid: "unread@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 2,
                    lastMessagePrimary: "primary-1",
                    lastMessageId: "message-1"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "read@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 0,
                    lastMessagePrimary: "primary-2",
                    lastMessageId: "message-2"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "archived@example.com",
                    conversationType: .regular,
                    isArchived: true,
                    unread: 3,
                    lastMessagePrimary: "primary-3",
                    lastMessageId: "message-3"
                ),
                .init(
                    owner: "disabled@example.com",
                    jid: "disabled@example.com",
                    conversationType: .regular,
                    isArchived: false,
                    unread: 1,
                    lastMessagePrimary: "primary-4",
                    lastMessageId: "message-4"
                ),
                .init(
                    owner: "enabled@example.com",
                    jid: "fallback@example.com",
                    conversationType: .omemo,
                    isArchived: false,
                    unread: 1,
                    lastMessagePrimary: nil,
                    lastMessageId: "server-last-id"
                )
            ],
            enabledAccounts: ["enabled@example.com"]
        )

        XCTAssertEqual(
            targets,
            [
                .init(
                    owner: "enabled@example.com",
                    messageTarget: .init(
                        jid: "unread@example.com",
                        conversationType: .regular,
                        lastMessagePrimary: "primary-1",
                        lastMessageId: "message-1"
                    )
                ),
                .init(
                    owner: "enabled@example.com",
                    messageTarget: .init(
                        jid: "fallback@example.com",
                        conversationType: .omemo,
                        lastMessagePrimary: nil,
                        lastMessageId: "server-last-id"
                    )
                )
            ]
        )
    }

    func testReconfigureVisibleRowAppliesImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com", message: "old")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        XCTAssertNotNil(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))

        let wasReconfigured = controller.reconfigureVisibleRow(at: IndexPath(row: 0, section: 0))

        XCTAssertTrue(wasReconfigured)
    }

    func testReloadTableViewOrDeferReloadsImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        controller.reloadTableViewOrDeferForActiveSwipe()

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
    }

    func testCompactChatReturnClearsSelectedChatRow() throws {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
        XCTAssertTrue(controller.isSelectedChat(item))

        controller.clearSelectedChatSelectionOnReturnIfNeeded(route: .currentNavigationPush, animated: false)

        XCTAssertNil(controller.tableView.indexPathForSelectedRow)
        XCTAssertFalse(controller.isSelectedChat(item))
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath) as? ChatListTableViewCell)
        XCTAssertEqual(cell.backgroundColor, .systemBackground)
    }

    func testSplitDetailChatReturnKeepsSelectedChatRow() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let sections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: sections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        controller.setSelectedChat(jid: item.jid, owner: item.owner, conversationType: item.conversationType, animated: false)

        controller.clearSelectedChatSelectionOnReturnIfNeeded(route: .splitDetailReplacement, animated: false)

        XCTAssertEqual(controller.tableView.indexPathForSelectedRow, indexPath)
        XCTAssertTrue(controller.isSelectedChat(item))
    }

    func testApplyReplacementUpdatesExecutesImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let indexPath = IndexPath(row: 0, section: 0)
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: oldSections, showsSkeleton: false)
        controller.tableView.reloadData()

        let changes = ChangesWithIndexPath(
            inserts: [],
            deletes: [],
            replaces: [indexPath],
            moves: []
        )
        controller.applyReplacementUpdates(
            changes: changes,
            oldSections: oldSections,
            newSections: oldSections,
            reloads: [indexPath],
            reconfigures: []
        )

        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
    }

    func testApplyStructuralUpdatesRunImmediately() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let newSections: [LastChatsViewController.DatasourceSection] = []
        let done = expectation(description: "apply structural updates applied")
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([item], sections: oldSections, showsSkeleton: false)
        controller.tableView.reloadData()

        let changes = ChangesWithIndexPath(
            insertedSections: [],
            deletedSections: [0],
            inserts: [],
            deletes: [],
            replaces: [],
            moves: []
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertTrue(controller.datasource.isEmpty)
    }

    func testQuietModeStructuralChangesUseReloadFallback() {
        let structural = ChangesWithIndexPath(
            inserts: [IndexPath(row: 0, section: 0)],
            deletes: [],
            replaces: [],
            moves: []
        )
        let replacementOnly = ChangesWithIndexPath(
            inserts: [],
            deletes: [],
            replaces: [IndexPath(row: 0, section: 0)],
            moves: []
        )

        XCTAssertTrue(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                structural,
                isQuietModeActive: true
            )
        )
        XCTAssertFalse(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                structural,
                isQuietModeActive: false
            )
        )
        XCTAssertFalse(
            LastChatsViewController.shouldReloadStructuralTableChanges(
                replacementOnly,
                isQuietModeActive: true
            )
        )
    }

    func testApplyQuietModeStructuralUpdatesReloadsTable() {
        let controller = LastChatsViewController()
        let oldItem = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let newItem = makeDatasource(jid: "juliet@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [oldItem], showsSkeleton: false)
        let newSections = LastChatsViewController.makeDatasourceSections(from: [oldItem, newItem], showsSkeleton: false)
        let staleVisibleSections = LastChatsViewController.makeDatasourceSections(from: [], showsSkeleton: false)
        let done = expectation(description: "quiet mode structural reload applied")
        controller.loadViewIfNeeded()
        controller.showSkeleton.accept(false)
        controller.setDatasource([], sections: staleVisibleSections, showsSkeleton: false)
        controller.tableView.reloadData()
        controller.beginLeftMenuFirstPresentationQuietMode()

        let changes = LastChatsViewController.sectionedChanges(
            oldSections: oldSections,
            newSections: newSections
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([oldItem, newItem], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertEqual(controller.datasource.map(\.jid), ["romeo@example.com", "juliet@example.com"])
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 2)
    }

    func testApplyWithDisconnectedTableViewUpdatesDatasourceWithoutBatching() {
        let controller = LastChatsViewController()
        let item = makeDatasource(jid: "romeo@example.com", owner: "owner@example.com")
        let oldSections = LastChatsViewController.makeDatasourceSections(from: [], showsSkeleton: false)
        let newSections = LastChatsViewController.makeDatasourceSections(from: [item], showsSkeleton: false)
        let done = expectation(description: "disconnected table update applied")
        XCTAssertNil(controller.tableView.dataSource)

        let changes = LastChatsViewController.sectionedChanges(
            oldSections: oldSections,
            newSections: newSections
        )

        controller.apply(
            changes: changes,
            oldSections: oldSections,
            newSections: newSections,
            oldShowsSkeleton: false,
            newShowsSkeleton: false,
            prepare: {
                controller.setDatasource([item], sections: newSections, showsSkeleton: false)
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 1.0)

        XCTAssertEqual(controller.datasource.map(\.jid), ["romeo@example.com"])
        XCTAssertNil(controller.tableView.dataSource)
    }

    func testChatListCellUsesCachedAvatarSynchronously() {
        let avatarURL = "https://example.com/chat-avatar-\(UUID().uuidString).png"
        let cachedImage = makeSolidAvatarImage(color: .systemPurple)
        DefaultAvatarManager.shared.storeImage(for: avatarURL, image: cachedImage)
        let cell = ChatListTableViewCell(style: .default, reuseIdentifier: ChatListTableViewCell.cellName)

        cell.configure(
            "romeo@example.com",
            owner: "owner@example.com",
            username: "Romeo",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            deliveryState: nil,
            isMute: false,
            isSynced: true,
            isGroupchat: false,
            status: .online,
            entity: .contact,
            conversationType: .regular,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            indicator: .clear,
            isDraft: false,
            isAttachment: false,
            groupchatNickname: nil,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: avatarURL,
            hasErrorInChat: false,
            verAction: false
        )

        assertImage(cell.avatarView.image, matches: cachedImage)
    }

    func testLastChatPreviewUsesItalicLocationLabelInsteadOfGeoFallback() {
        let message = MessageStorageItem()
        message.body = "geo:51.5007,-0.1246"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .geoloc
        reference.url = message.body
        reference.metadata = [
            "lat": 51.5007,
            "lon": -0.1246,
            "uri": message.body
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(preview.text, MessageStorageItem.locationDisplayText)
        XCTAssertTrue(preview.isItalic)
    }

    func testLastChatPreviewUsesItalicContactLabelWithNicknameBeforeFallbackBody() {
        let message = MessageStorageItem()
        message.body = "Alice Capulet (alice@example.com)"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.metadata = [
            "contact_jid": "alice@example.com",
            "nickname": "Ally",
            "given": "Alice",
            "family": "Capulet"
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "Contact: %@".localizeString(id: "recent_chat__last_message__contact", arguments: ["Ally"])
        )
        XCTAssertTrue(preview.isItalic)
    }

    func testLastChatPreviewUsesContactFullNameWhenNicknameIsMissing() {
        let message = MessageStorageItem()
        message.body = "Alice Capulet (alice@example.com)"
        message.legacyBody = message.body
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.metadata = [
            "contact_jid": "alice@example.com",
            "given": "Alice",
            "family": "Capulet"
        ]
        message.references.append(reference)

        let preview = LastChatMessagePreviewPolicy.preview(
            for: message,
            blankMessageText: "Start messaging here"
        )

        XCTAssertEqual(
            preview.text,
            "Contact: %@".localizeString(id: "recent_chat__last_message__contact", arguments: ["Alice Capulet"])
        )
        XCTAssertTrue(preview.isItalic)
    }

    func testBootstrapDatasetUpdatePolicySuppressesExpensiveAnimatedWorkOnlyDuringBootstrap() {
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: true, isBootstrapActive: true))
        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: true, isBootstrapActive: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(requestedAnimated: false, isBootstrapActive: false))

        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(isBootstrapActive: true))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(isBootstrapActive: false))
        XCTAssertTrue(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: true, hasScheduledUpdate: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: false, hasScheduledUpdate: false))
        XCTAssertFalse(LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(isBootstrapActive: true, hasScheduledUpdate: true))
    }

    func testBootstrapDatasetUpdatePolicyTreatsActiveChatHistoryLoadAsPressure() {
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: true,
                isChatUIResponsivenessGateActive: false
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: true,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: false
            )
        )
        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: false
            )
        )

        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(
                requestedAnimated: true,
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(
                isDatasetUpdatePressureActive: true,
                hasScheduledUpdate: false
            )
        )
    }

    func testBootstrapDatasetUpdatePolicyTreatsActiveChatInteractionGateAsPresentationPressure() {
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.isDatasetUpdatePressureActive(
                isAccountSyncBootstrapActive: false,
                isChatHistoryLoadActive: false,
                isChatUIResponsivenessGateActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldCoalesceDatasetUpdate(
                isDatasetUpdatePressureActive: true,
                hasScheduledUpdate: false
            )
        )
        XCTAssertFalse(
            LastChatsBootstrapDatasetUpdatePolicy.shouldAnimateDatasetMutation(
                requestedAnimated: true,
                isDatasetUpdatePressureActive: true
            )
        )
        XCTAssertTrue(
            LastChatsBootstrapDatasetUpdatePolicy.shouldSkipVisibleRowReconfigure(
                isDatasetUpdatePressureActive: true
            )
        )
    }

    func testOutgoingChatOpenBeginsLastChatsMutationDeferralBeforePush() {
        let controller = LastChatsViewController()

        XCTAssertFalse(controller.isNavigationTransitionActive)

        controller.beginOutgoingChatOpenNavigationDeferral()

        XCTAssertTrue(controller.isNavigationTransitionActive)
        XCTAssertTrue(
            LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
                isTransitionActive: controller.isNavigationTransitionActive,
                isCriticalForFirstFrame: false
            )
        )
        XCTAssertFalse(
            LastChatsNavigationTransitionMutationPolicy.shouldDeferMutation(
                isTransitionActive: controller.isNavigationTransitionActive,
                isCriticalForFirstFrame: true
            )
        )
    }

    private func withInterfaceType(_ interfaceType: CommonConfigManager.InterfaceType, useYubikey: Bool, block: () -> Void) {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousUseYubikey = CommonConfigManager.shared.config.use_yubikey
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            CommonConfigManager.shared.config.use_yubikey = previousUseYubikey
        }

        CommonConfigManager.shared.config.interface_type = interfaceType.rawValue
        CommonConfigManager.shared.config.use_yubikey = useYubikey
        block()
    }

    private func assertLargeTitle(
        useLargeTitle: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let previousUseLargeTitle = CommonConfigManager.shared.config.use_large_title
        defer {
            CommonConfigManager.shared.config.use_large_title = previousUseLargeTitle
        }
        CommonConfigManager.shared.config.use_large_title = useLargeTitle
        let controller = LastChatsViewController()
        let navigationController = UINavigationController(rootViewController: controller)

        navigationController.loadViewIfNeeded()
        controller.loadViewIfNeeded()

        XCTAssertEqual(navigationController.navigationBar.prefersLargeTitles, useLargeTitle, file: file, line: line)
        XCTAssertEqual(
            controller.navigationItem.largeTitleDisplayMode,
            useLargeTitle ? .automatic : .never,
            file: file,
            line: line
        )
    }

    private func navigationBarItems(
        _ items: [UIBarButtonItem]?,
        _ singleItem: UIBarButtonItem?
    ) -> [UIBarButtonItem] {
        if let items, !items.isEmpty {
            return items
        }

        return singleItem.map { [$0] } ?? []
    }

    private func makeSolidAvatarImage(color: UIColor, size: CGSize = CGSize(width: 64, height: 64)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func assertImage(
        _ image: UIImage?,
        matches expectedImage: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(image?.size, expectedImage.size, file: file, line: line)
        XCTAssertEqual(image?.pngData(), expectedImage.pngData(), file: file, line: line)
    }

    private func makeDatasource(
        jid: String,
        owner: String = "owner@example.com",
        message: String = "Hello",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> LastChatsViewController.Datasource {
        LastChatsViewController.Datasource(
            jid: jid,
            owner: owner,
            username: "Romeo",
            attributedUsername: nil,
            message: message,
            date: Date(timeIntervalSince1970: 1_711_283_200),
            state: nil,
            isMute: false,
            isSynced: true,
            status: .offline,
            entity: conversationType == .regular || conversationType.isEncrypted ? .contact : .groupchat,
            conversationType: conversationType,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: false,
            color: .clear,
            isDraft: false,
            hasAttachment: false,
            userNickname: nil,
            isSystemMessage: false,
            isPinned: false,
            subRequest: false,
            isEncrypted: conversationType.isEncrypted,
            avatarUrl: nil,
            hasErrorInChat: false,
            updateTS: 0,
            isVerificationActionRequired: false,
            specialMessageKind: .none,
            avatars: []
        )
    }
}
