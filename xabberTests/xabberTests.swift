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

import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class InfoScreenHeaderViewTests: XCTestCase {

    private func makeButton(icon: String, title: String) -> InfoHeaderButton {
        let button = InfoHeaderButton()
        button.configure(icon: icon, title: title)
        return button
    }

    private func makeHeader(
        width: CGFloat = 390,
        subtitle: String? = "redsolution.com",
        thirdLine: String? = nil,
        buttons: [UIButton] = []
    ) -> InfoScreenHeaderView {
        let header = InfoScreenHeaderView(frame: .zero)
        header.additionalTopOffset = 56
        header.titleButton.setTitle("Igor Boldin", for: .normal)
        header.titleButton.setTitleColor(.label, for: .normal)

        if !buttons.isEmpty {
            header.configureButtons { buttons }
        } else {
            header.showButtons = false
        }

        header.subtitleLabel.text = subtitle
        header.subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        if let thirdLine {
            header.thirdLineLabel.text = thirdLine
            header.thirdLineLabel.isHidden = false
        } else {
            header.thirdLineLabel.text = nil
            header.thirdLineLabel.isHidden = true
        }

        header.frame = CGRect(x: 0, y: 0, width: width, height: header.preferredHeight)
        header.updateSubviews()
        header.layoutIfNeeded()
        return header
    }

    func testCompactActionButtonsUseTheConfiguredSize() {
        let header = makeHeader(buttons: [
            makeButton(icon: "message.fill", title: "message"),
            makeButton(icon: "phone.fill", title: "call"),
            makeButton(icon: "bell.fill", title: "mute"),
            makeButton(icon: "ellipsis", title: "more"),
        ])

        XCTAssertFalse(header.buttonsStack.isHidden)
        XCTAssertEqual(header.buttons.count, 4)

        for button in header.buttons {
            XCTAssertEqual(button.frame.size.width, 76, accuracy: 0.5)
            XCTAssertEqual(button.frame.size.height, 56, accuracy: 0.5)
        }

        XCTAssertEqual(header.buttonsStack.frame.height, 56, accuracy: 0.5)
    }

    func testSubtitleAndThirdLineSpacingStaysAtEightPoints() {
        let header = makeHeader(thirdLine: "5 members")

        XCTAssertEqual(header.subtitleLabel.frame.minY - header.titleButton.frame.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(header.thirdLineLabel.frame.minY - header.subtitleLabel.frame.maxY, 8, accuracy: 0.5)

        let thirdLineOnlyHeader = makeHeader(subtitle: nil, thirdLine: "5 members")
        XCTAssertEqual(thirdLineOnlyHeader.thirdLineLabel.frame.minY - thirdLineOnlyHeader.titleButton.frame.maxY, 8, accuracy: 0.5)
    }

    func testPreferredHeightGrowsWhenButtonsAreVisible() {
        let headerWithoutButtons = makeHeader()
        let headerWithButtons = makeHeader(buttons: [
            makeButton(icon: "message.fill", title: "message"),
            makeButton(icon: "phone.fill", title: "call"),
            makeButton(icon: "bell.fill", title: "mute"),
            makeButton(icon: "ellipsis", title: "more"),
        ])

        XCTAssertTrue(headerWithoutButtons.buttonsStack.isHidden)
        XCTAssertFalse(headerWithButtons.buttonsStack.isHidden)
        XCTAssertEqual(headerWithButtons.preferredHeight - headerWithoutButtons.preferredHeight, 64, accuracy: 0.5)
    }

    func testEllipsisButtonUsesASymbolImage() {
        let button = makeButton(icon: "ellipsis", title: "more")

        XCTAssertEqual(button.title.text, "more")
        XCTAssertNotNil(button.icon.image)
        XCTAssertTrue(button.icon.image?.isSymbolImage ?? false)
    }
}

final class AccountBootstrapTests: XCTestCase {

    private let testLoginJid = "igor.boldin@xmppdev01.xabber.com"
    private let testLoginPassword = "1234"

    func testAccountUsernameFromJIDHandlesEmptyAndMalformedValues() {
        XCTAssertEqual(Account.username(from: ""), "")
        XCTAssertEqual(Account.username(from: "xmppdev01.xabber.com"), "xmppdev01.xabber.com")
        XCTAssertEqual(Account.username(from: testLoginJid), "igor.boldin")
    }

    func testNotifyManagerExcludedDomainsIgnoresMalformedJIDs() {
        let domains = NotifyManager.excludedDomains(
            from: [
                "",
                "not a jid",
                testLoginJid,
                "room@conference.xabber.com/resource"
            ]
        )

        XCTAssertEqual(domains, [
            "xmppdev01.xabber.com",
            "conference.xabber.com"
        ])
    }

    func testXTokenManagerServerJIDIgnoresMalformedOwners() {
        XCTAssertNil(XTokenManager.serverJID(from: ""))
        XCTAssertNil(XTokenManager.serverJID(from: "not a jid"))
        XCTAssertEqual(XTokenManager.serverJID(from: testLoginJid)?.domain, "xmppdev01.xabber.com")
    }

    func testInjectXMPPCredentials() {
        CredentialsManager.shared.setItem(for: testLoginJid, password: testLoginPassword)

        let stored = CredentialsManager.shared.getItem(for: testLoginJid)
        XCTAssertEqual(stored.kind, .password)
        XCTAssertEqual(stored.creditionalString, testLoginPassword)
    }
}

final class NotificationsFeatureTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "NotificationsFeatureTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "NotificationsFeatureTests", code: 1)
        }
        return XMPPMessage(from: root)
    }

    func testParsePayloadUsesOriginalSenderAndFallbackText() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-1'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='security@xmppdev01.xabber.com' to='\(owner)'>
                <nick xmlns='http://jabber.org/protocol/nick'>Security Bot</nick>
                <body>Login from Chrome on macOS</body>
                <device id='device-1'/>
              </message>
            </forwarded>
          </notification>
          <body>Fallback security text</body>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.jid, "security@xmppdev01.xabber.com")
        XCTAssertEqual(payload?.originalSenderJid, "security@xmppdev01.xabber.com")
        XCTAssertEqual(payload?.category, .device)
        XCTAssertEqual(payload?.notificationType, "alert")
        XCTAssertEqual(payload?.fallbackText, "Fallback security text")
        XCTAssertEqual(payload?.displayNick, "Security Bot")
        XCTAssertEqual(payload?.text, "Login from Chrome on macOS")
    }

    func testParsePayloadRejectsMismatchedOriginalSender() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-2'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='wrong@xmppdev01.xabber.com' to='\(owner)'>
                <body>Suspicious login</body>
                <device id='device-2'/>
              </message>
            </forwarded>
          </notification>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        XCTAssertNil(XMPPNotificationsManager.parsePayload(from: message, owner: owner))
    }

    func testReadStoresNewNotificationsAsUnread() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let oldNotification = NotificationStorageItem()
            oldNotification.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "security@xmppdev01.xabber.com", uniqueId: "old")
            oldNotification.owner = owner
            oldNotification.jid = "security@xmppdev01.xabber.com"
            oldNotification.uniqueId = "old"
            oldNotification.messageId = "old"
            oldNotification.category = .device
            oldNotification.isRead = true
            oldNotification.shouldShow = true
            oldNotification.date = ISO8601DateFormatter().date(from: "2026-03-23T10:00:00Z")!
            realm.add(oldNotification)
        }

        let manager = XMPPNotificationsManager(withOwner: owner)
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-3'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='security@xmppdev01.xabber.com' to='\(owner)'>
                <body>New login</body>
                <device id='device-3'/>
              </message>
            </forwarded>
          </notification>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        XCTAssertTrue(manager.read(withMessage: message))

        let stored = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@ AND uniqueId != %@", owner, "old")
            .first
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.isRead, false)
        XCTAssertEqual(stored?.notificationType, "alert")
        XCTAssertEqual(stored?.originalSenderJid, "security@xmppdev01.xabber.com")
    }

    func testCountersAndDatasourceIncludeMentions() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let mention = NotificationStorageItem()
            mention.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "romeo@xmppdev01.xabber.com", uniqueId: "mention-1")
            mention.owner = owner
            mention.jid = "romeo@xmppdev01.xabber.com"
            mention.originalSenderJid = "romeo@xmppdev01.xabber.com"
            mention.uniqueId = "mention-1"
            mention.messageId = "mention-1"
            mention.category = .mention
            mention.isRead = false
            mention.shouldShow = true
            mention.text = "You have been mentioned"
            mention.date = ISO8601DateFormatter().date(from: "2026-03-24T11:00:00Z")!
            realm.add(mention)

            let roster = RosterStorageItem()
            roster.primary = RosterStorageItem.genPrimary(jid: "romeo@xmppdev01.xabber.com", owner: owner)
            roster.owner = owner
            roster.jid = "romeo@xmppdev01.xabber.com"
            roster.username = "Romeo"
            realm.add(roster)
        }

        let counters = NotificationsSupport.unreadCounters(in: try WRealm.safe(), owners: [owner])
        XCTAssertEqual(counters.total, 1)
        XCTAssertEqual(counters.mentions, 1)

        let controller = NotificationsListViewController()
        let snapshot = controller.buildDatasourceSnapshot(filter: .mentions, filterAccount: owner)
        let rows = snapshot.flatMap(\.childs).filter { !$0.isHeader }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.category, .mention)
        XCTAssertEqual(rows.first?.title.string, "Romeo mentioned you")
    }

    func testAccountFilteringUsesOnlySelectedOwnersNotifications() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let first = NotificationStorageItem()
            first.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "first@xmppdev01.xabber.com", uniqueId: "first")
            first.owner = owner
            first.jid = "first@xmppdev01.xabber.com"
            first.uniqueId = "first"
            first.messageId = "first"
            first.category = .info
            first.isRead = false
            first.shouldShow = true
            first.date = ISO8601DateFormatter().date(from: "2026-03-24T08:00:00Z")!
            realm.add(first)

            let secondOwner = "second@xmppdev01.xabber.com"
            let second = NotificationStorageItem()
            second.primary = NotificationStorageItem.genPrimary(owner: secondOwner, jid: "second@xmppdev01.xabber.com", uniqueId: "second")
            second.owner = secondOwner
            second.jid = "second@xmppdev01.xabber.com"
            second.uniqueId = "second"
            second.messageId = "second"
            second.category = .info
            second.isRead = false
            second.shouldShow = true
            second.date = ISO8601DateFormatter().date(from: "2026-03-24T09:00:00Z")!
            realm.add(second)
        }

        let filtered = NotificationsSupport.notifications(in: try WRealm.safe(), owners: [owner], filter: .all, unreadOnly: true).toArray()
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.owner, owner)
    }
}

final class ContactsListSupportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ContactsListSupportTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeAccount(jid: String, username: String) -> AccountStorageItem {
        let account = AccountStorageItem()
        account.jid = jid
        account.username = username
        account.enabled = true
        return account
    }

    private func makeCircle(name: String, owner: String) -> RosterGroupStorageItem {
        let circle = RosterGroupStorageItem()
        circle.primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
        circle.owner = owner
        circle.name = name
        return circle
    }

    private func makeContact(owner: String, jid: String, subscription: RosterStorageItem.Subsccribtion, ask: RosterStorageItem.Ask, groups: [String]) -> RosterStorageItem {
        let contact = RosterStorageItem()
        contact.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        contact.owner = owner
        contact.jid = jid
        contact.username = jid
        contact.isContact = true
        contact.subscribtion = subscription
        contact.ask = ask
        contact.groups.append(objectsIn: groups)
        return contact
    }

    func testContactCategoryDatasourceCountsJoinedContactsAndRequestsSeparately() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(makeAccount(jid: "owner-1@example.com", username: "Owner 1"))
            realm.add(makeCircle(name: "Friends", owner: "owner-1@example.com"))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "alice@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "bob@example.com", subscription: .none, ask: .out, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "carol@example.com", subscription: .none, ask: .in, groups: []))
        }

        let context = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: [], filteredGroups: [], showOffline: true, isGroup: false)
        )
        let datasource = ContactsListSupport.categoryDatasource(context: context)

        XCTAssertEqual(datasource[1].first?.subtitle, "1")
        XCTAssertEqual(datasource[2].first?.subtitle, "1")
        XCTAssertEqual(datasource[2].last?.subtitle, "1")
        XCTAssertEqual(datasource[3].first?.subtitle, "1")
    }

    func testCircleCountsRespectSelectedAccountFilter() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(makeAccount(jid: "owner-1@example.com", username: "Owner 1"))
            realm.add(makeAccount(jid: "owner-2@example.com", username: "Owner 2"))
            realm.add(makeCircle(name: "Friends", owner: "owner-1@example.com"))
            realm.add(makeCircle(name: "Friends", owner: "owner-2@example.com"))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "alice@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-2@example.com", jid: "bob@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
        }

        let allContext = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: [], filteredGroups: [], showOffline: true, isGroup: false)
        )
        let filteredContext = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: ["owner-1@example.com"], filteredGroups: [], showOffline: true, isGroup: false)
        )

        XCTAssertEqual(ContactsListSupport.circleCounts(context: allContext).first?.count, 2)
        XCTAssertEqual(ContactsListSupport.circleCounts(context: filteredContext).first?.count, 1)
    }
}

final class ClientSynchronizationManagerTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ClientSynchronizationManagerTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "ClientSynchronizationManagerTests", code: 1)
        }
        return root
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try makeElement(xml: xml))
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    func testArchivedMessageDatePrefersMessageTimeStamp() throws {
        let message = try makeElement(xml: """
        <message from='romeo@xmppdev01.xabber.com' to='\(owner)'>
          <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-03-24T12:34:56Z'/>
        </message>
        """)

        let normalizedStamp = ClientSynchronizationManager.syncStamp(from: message, fallback: 1_700_000_000_000_000)
        let archivedDate = ClientSynchronizationManager.archivedMessageDate(from: message, fallbackSyncStamp: 1_700_000_000_000_000)

        XCTAssertEqual(normalizedStamp, 1_774_355_696_000_000, accuracy: 1)
        XCTAssertEqual(archivedDate.timeIntervalSince1970, 1_774_355_696, accuracy: 0.001)
    }

    func testReadSnapshotRejectsNonHttpsNamespace() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let iq = try makeIQ(xml: """
        <iq type='result' id='sync-1'>
          <query xmlns='http://xabber.com/protocol/synchronization' stamp='1711283296000000'>
          </query>
        </iq>
        """)

        XCTAssertFalse(manager.read(withIQ: iq))
    }

    func testDuplicateInviteIsIgnored() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let account = AccountStorageItem()
            account.jid = owner
            account.username = "igor.boldin"
            account.enabled = true
            realm.add(account, update: .modified)
        }

        let manager = GroupchatManager(withOwner: owner)
        let inviteMessage = try makeMessage(xml: """
        <message from='romeo@xmppdev01.xabber.com' to='\(owner)' id='invite-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='group@conference.xabber.com'>
            <reason>Join us</reason>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
        </message>
        """)
        let inviteDate = ISO8601DateFormatter().date(from: "2026-03-24T12:34:56Z")!

        XCTAssertTrue(manager.readInvite(in: inviteMessage, date: inviteDate, isRead: false))
        XCTAssertFalse(manager.readInvite(in: inviteMessage, date: inviteDate, isRead: false))

        let storedInvites = try WRealm.safe()
            .objects(GroupchatInvitesStorageItem.self)
            .filter("owner == %@", owner)
        XCTAssertEqual(storedInvites.count, 1)
    }
}
