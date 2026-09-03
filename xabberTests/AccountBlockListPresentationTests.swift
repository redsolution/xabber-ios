import UIKit
import XCTest
import RealmSwift

@testable import xabber

final class AccountBlockListPresentationTests: XCTestCase {

    func testPresentationUsesRosterNicknameMaximumAvatarAndNoCircles() {
        let rosterItem = RosterStorageItem()
        rosterItem.owner = "owner@example.com"
        rosterItem.jid = "blocked@example.com"
        rosterItem.username = "Blocked User"
        rosterItem.avatarMinUrl = "https://example.com/avatar-small.jpg"
        rosterItem.avatarMaxUrl = "https://example.com/avatar-large.jpg"

        let presentation = AccountBlockListPresentationFactory.make(
            blockedJID: rosterItem.jid,
            rosterItem: rosterItem,
            status: .away,
            entity: .contact
        )

        XCTAssertEqual(presentation.title, "Blocked User")
        XCTAssertEqual(presentation.jid, "blocked@example.com")
        XCTAssertEqual(presentation.avatarURL, "https://example.com/avatar-large.jpg")
        XCTAssertEqual(presentation.groups, [])
        XCTAssertEqual(presentation.status, .away)
        XCTAssertEqual(presentation.entity, .contact)
    }

    func testPresentationFallsBackToPreparedJIDWhenRosterItemIsMissing() {
        let presentation = AccountBlockListPresentationFactory.make(
            blockedJID: "missing@example.com/resource",
            rosterItem: nil,
            status: nil,
            entity: nil
        )

        XCTAssertEqual(
            presentation.title,
            JidManager.shared.prepareJid(jid: "missing@example.com/resource")
        )
        XCTAssertEqual(presentation.jid, "missing@example.com/resource")
        XCTAssertNil(presentation.avatarURL)
        XCTAssertEqual(presentation.status, .offline)
        XCTAssertEqual(presentation.entity, .contact)
    }

    func testContactCellRendersNicknameAndJIDWithoutCircleTags() {
        let cell = ContactsViewController.ContactCell(style: .default, reuseIdentifier: nil)
        let presentation = AccountBlockListContactPresentation(
            title: "Blocked User",
            jid: "blocked@example.com",
            avatarURL: nil,
            groups: [],
            status: .offline,
            entity: .contact
        )

        AccountBlockListPresentationFactory.configure(
            cell: cell,
            presentation: presentation,
            owner: "owner@example.com"
        )

        XCTAssertEqual(cell.titleLabel.text, "Blocked User")
        XCTAssertEqual(cell.subtitleLabel.text, "blocked@example.com")
        XCTAssertTrue(cell.tagScrollView.isHidden)
        XCTAssertEqual(cell.avatarContainer.bounds.size, .zero)

        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 84)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.avatarView.bounds.width, 64, accuracy: 0.5)
        XCTAssertEqual(cell.avatarView.bounds.height, 64, accuracy: 0.5)
    }

    func testTrailingSwipePlacesUnblockAtTheTrailingEdgeBeforeReport() {
        XCTAssertEqual(
            AccountBlockListInteractionPolicy.trailingActions,
            [.unblock, .report]
        )
    }

    func testControllerBuildsOrderedSwipeActionsAndDisablesFullSwipe() throws {
        let realm = try Realm(
            configuration: Realm.Configuration(
                inMemoryIdentifier: UUID().uuidString
            )
        )
        let blockedItem = BlockStorageItem()
        blockedItem.set(jid: "blocked@example.com", owner: "owner@example.com")
        try realm.write {
            realm.add(blockedItem)
        }
        let controller = AccountBlockListViewController()
        controller.datasource = realm.objects(BlockStorageItem.self)

        let configuration = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                trailingSwipeActionsConfigurationForRowAt: IndexPath(
                    row: 0,
                    section: 0
                )
            )
        )

        XCTAssertEqual(
            configuration.actions.compactMap(\.title),
            [
                "Unblock".localizeString(
                    id: "contact_bar_unblock",
                    arguments: []
                ),
                "Report User".localizeString(
                    id: "report_user_action",
                    arguments: []
                )
            ]
        )
        XCTAssertFalse(configuration.performsFirstActionWithFullSwipe)
    }

    func testContactRoutePreservesOwnerAndBlockedJID() {
        let route = AccountBlockListInteractionPolicy.contactRoute(
            owner: "owner@example.com",
            jid: "blocked@example.com"
        )

        XCTAssertEqual(route.owner, "owner@example.com")
        XCTAssertEqual(route.jid, "blocked@example.com")
        XCTAssertEqual(route.conversationType, .regular)
    }

    func testBlockedContactSectionIsInsertedBeforeSafetyAndContainsUnblock() throws {
        let safety = ContactInfoViewController.Datasource(
            .text,
            title: "Safety",
            key: ContactInfoBlockedSectionPolicy.safetySectionKey,
            childs: []
        )

        let result = ContactInfoBlockedSectionPolicy.reconcile(
            sections: [safety],
            isBlocked: true
        )

        XCTAssertEqual(
            result.compactMap(\.key),
            [
                ContactInfoBlockedSectionPolicy.blockedSectionKey,
                ContactInfoBlockedSectionPolicy.safetySectionKey
            ]
        )
        let blockedSection = try XCTUnwrap(result.first)
        XCTAssertEqual(
            blockedSection.title,
            "Contact blocked".localizeString(
                id: "blocked_contact_message",
                arguments: []
            )
        )
        XCTAssertEqual(blockedSection.childs.count, 1)
        XCTAssertEqual(
            blockedSection.childs[0].key,
            ContactInfoBlockedSectionPolicy.unblockRowKey
        )
        XCTAssertEqual(
            blockedSection.childs[0].title,
            "Unblock".localizeString(id: "contact_bar_unblock", arguments: [])
        )
        XCTAssertTrue(blockedSection.childs[0].isDanger)
    }

    func testBlockedContactSectionIsRemovedAfterUnblock() {
        let blocked = ContactInfoBlockedSectionPolicy.reconcile(
            sections: [],
            isBlocked: true
        )

        let unblocked = ContactInfoBlockedSectionPolicy.reconcile(
            sections: blocked,
            isBlocked: false
        )

        XCTAssertFalse(
            unblocked.contains {
                $0.key == ContactInfoBlockedSectionPolicy.blockedSectionKey
            }
        )
    }
}
