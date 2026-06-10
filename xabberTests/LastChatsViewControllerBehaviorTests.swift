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
@testable import xabber

@MainActor
final class LastChatsViewControllerBehaviorTests: XCTestCase {
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

    func testFloatingBottomBarTitleUsesConnectingAndUnreadCounts() {
        let controller = LastChatsViewController()
        let previousEnabledAccounts = controller.enabledAccounts.value
        let previousConnectingAccounts = AccountManager.shared.connectingUsers.value

        defer {
            controller.enabledAccounts.accept(previousEnabledAccounts)
            AccountManager.shared.connectingUsers.accept(previousConnectingAccounts)
        }

        let ownerJid = "owner@example.com"
        controller.enabledAccounts.accept([ownerJid])

        AccountManager.shared.connectingUsers.accept([ownerJid])
        XCTAssertEqual(
            controller.floatingBottomBarTitle(forUnreadChatsCount: 2),
            "Connecting".localizeString(id: "plurals.accounts_of_connecting.item_0", arguments: [])
        )

        AccountManager.shared.connectingUsers.accept([])
        XCTAssertEqual(
            controller.floatingBottomBarTitle(forUnreadChatsCount: 0),
            CommonConfigManager.shared.config.app_name
        )
        XCTAssertEqual(
            controller.floatingBottomBarTitle(forUnreadChatsCount: 1),
            "1 unread chat"
        )
        XCTAssertEqual(
            controller.floatingBottomBarTitle(forUnreadChatsCount: 2),
            "2 unread chats"
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
