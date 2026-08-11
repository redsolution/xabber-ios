import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class GroupchatInviteV3Tests: XCTestCase {
    private let owner = "romeo@example.com"
    private var infoRequests: [String] = []
    private var membersRequests: [String] = []

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "GroupchatInviteV3Tests-\(name)")
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        infoRequests.removeAll()
        membersRequests.removeAll()
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
            let account = AccountStorageItem()
            account.jid = owner
            account.enabled = true
            realm.add(account, update: .modified)
        }
    }

    private func makeMessage(_ xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeElement(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }

    private func service(
        now: @escaping () -> Date = Date.init,
        showLocalNotification: @escaping (PushNotificationPreview) -> Void = { _ in }
    ) -> GroupchatInvitePersistenceService {
        GroupchatInvitePersistenceService(
            owner: owner,
            followUp: GroupchatInviteFollowUp(
                requestGroupInfo: { [weak self] groupchat in self?.infoRequests.append(groupchat) },
                requestMembers: { [weak self] groupchat in self?.membersRequests.append(groupchat) }
            ),
            now: now,
            showLocalNotification: showLocalNotification
        )
    }

    private func storedInvites() throws -> Results<GroupchatInvitesStorageItem> {
        try WRealm.safe().objects(GroupchatInvitesStorageItem.self).filter("owner == %@", owner)
    }

    func testLiveV3DirectInviteStoresOnePendingInvite() throws {
        let date = Date(timeIntervalSince1970: 100)
        let message = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='direct-1'>
          <origin-id xmlns='urn:xmpp:sid:0' id='origin-direct-1'/>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <reason>Join us</reason>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
        </message>
        """)

        XCTAssertEqual(service().receive(message: message, date: date, isRead: false), .inserted)

        let invite = try XCTUnwrap(storedInvites().first)
        XCTAssertEqual(try storedInvites().count, 1)
        XCTAssertEqual(invite.primary, GroupchatInvitesStorageItem.genIncomingPrimary(groupchat: "stage@example.com", owner: owner))
        XCTAssertEqual(invite.groupchat, "stage@example.com")
        XCTAssertEqual(invite.jid, "juliet@example.com")
        XCTAssertEqual(invite.sender, "juliet@example.com")
        XCTAssertEqual(invite.reason, "Join us")
        XCTAssertEqual(invite.messageId, "direct-1")
        XCTAssertEqual(invite.originId, "origin-direct-1")
        XCTAssertFalse(invite.outgoing)
        XCTAssertFalse(invite.isRead)
        XCTAssertFalse(invite.isAnonymous)
    }

    func testOnlyFreshCommittedUnreadLiveInviteSchedulesTypedLocalNotification() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var previews: [PushNotificationPreview] = []
        let inviteService = service(
            now: { now },
            showLocalNotification: { previews.append($0) }
        )
        let fresh = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='local-invite'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <user id='member-7' jid='juliet@example.com'><nickname>Juliet</nickname></user>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'>
            <info><name>Stage</name></info>
          </group>
        </message>
        """)

        XCTAssertEqual(
            inviteService.receive(
                message: fresh,
                date: now.addingTimeInterval(-1),
                isRead: false,
                notifyLocally: true
            ),
            .inserted
        )
        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews.first?.route.kind, .groupInvite)
        XCTAssertEqual(previews.first?.route.groupchat, "stage@example.com")
        XCTAssertEqual(previews.first?.route.inviterJid, "juliet@example.com")

        XCTAssertEqual(
            inviteService.receive(
                message: fresh,
                date: now.addingTimeInterval(-1),
                isRead: false,
                notifyLocally: true
            ),
            .duplicate
        )
        XCTAssertEqual(previews.count, 1)
    }

    func testLiveV3ServerMediatedInviteStoresGroupSender() throws {
        let message = try makeMessage("""
        <message from='stage@example.com/Group' to='\(owner)' id='server-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
        </message>
        """)

        XCTAssertEqual(service().receive(message: message, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)

        let invite = try XCTUnwrap(storedInvites().first)
        XCTAssertEqual(try storedInvites().count, 1)
        XCTAssertEqual(invite.groupchat, "stage@example.com")
        XCTAssertEqual(invite.jid, "stage@example.com")
        XCTAssertEqual(invite.sender, "stage@example.com")
        XCTAssertTrue(invite.isFromGroupchat)
    }

    func testIncognitoV3InviteStoresAnonymousFlag() throws {
        let message = try makeMessage("""
        <message from='stage@example.com/Group' to='\(owner)' id='incognito-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
          <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'/>
        </message>
        """)

        XCTAssertEqual(service().receive(message: message, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)

        XCTAssertTrue(try XCTUnwrap(storedInvites().first).isAnonymous)
    }

    func testDuplicateOwnerAndGroupInviteDoesNotCreateDuplicateRows() throws {
        let first = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='invite-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)
        let duplicate = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='invite-2'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)

        let inviteService = service()
        XCTAssertEqual(inviteService.receive(message: first, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)
        XCTAssertEqual(inviteService.receive(message: duplicate, date: Date(timeIntervalSince1970: 100), isRead: false), .duplicate)

        XCTAssertEqual(try storedInvites().count, 1)
    }

    func testNewerInviteUpdatesExistingRowAndOlderInviteDoesNotOverwrite() throws {
        let older = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='older'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <reason>Old</reason>
          </invite>
        </message>
        """)
        let newer = try makeMessage("""
        <message from='stage@example.com/Group' to='\(owner)' id='newer'>
          <stanza-id xmlns='urn:xmpp:sid:0' by='stage@example.com' id='archive-newer'/>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <reason>New</reason>
          </invite>
        </message>
        """)
        let stale = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='stale'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'>
            <reason>Stale</reason>
          </invite>
        </message>
        """)

        let inviteService = service()
        XCTAssertEqual(inviteService.receive(message: older, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)
        XCTAssertEqual(inviteService.receive(message: newer, date: Date(timeIntervalSince1970: 200), isRead: false), .updated)
        XCTAssertEqual(inviteService.receive(message: stale, date: Date(timeIntervalSince1970: 150), isRead: false), .older)

        let invite = try XCTUnwrap(storedInvites().first)
        XCTAssertEqual(try storedInvites().count, 1)
        XCTAssertEqual(invite.messageId, "newer")
        XCTAssertEqual(invite.stanzaId, "archive-newer")
        XCTAssertEqual(invite.sender, "stage@example.com")
        XCTAssertEqual(invite.reason, "New")
        XCTAssertEqual(invite.date.timeIntervalSince1970, 200, accuracy: 0.001)
    }

    func testArchivedMamV3InviteUsesInviteStorageAndDoesNotCreateNormalMessage() throws {
        let archived = try makeMessage("""
        <message from='\(owner)' to='\(owner)' id='mam-outer'>
          <result xmlns='urn:xmpp:mam:2' queryid='invite-recovery' id='9001'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2026-03-24T12:34:56Z'/>
              <message from='juliet@example.com/balcony' to='\(owner)' id='mam-inner'>
                <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
              </message>
            </forwarded>
          </result>
        </message>
        """)

        XCTAssertEqual(service().receiveArchivedEnvelope(archived, isRead: nil), .inserted)

        let invite = try XCTUnwrap(storedInvites().first)
        XCTAssertEqual(invite.archiveId, "9001")
        XCTAssertEqual(invite.messageId, "mam-inner")
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).count, 0)
    }

    func testSyncSnapshotLastMessageInviteStoresInviteAndDoesNotCreateChat() throws {
        let conversation = try makeElement("""
        <conversation jid='stage@example.com' type='https://xabber.com/protocol/groups' stamp='1774355696000000'>
          <metadata node='https://xabber.com/protocol/synchronization'>
            <last-message>
              <message from='stage@example.com/Group' to='\(owner)' id='sync-invite'>
                <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
              </message>
            </last-message>
          </metadata>
        </conversation>
        """)
        let manager = ClientSynchronizationManager(withOwner: owner)
        let realm = try WRealm.safe()

        try realm.write {
            XCTAssertTrue(manager.readInvites(conversation, realm: realm))
        }

        XCTAssertEqual(try storedInvites().count, 1)
        XCTAssertNil(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "stage@example.com", owner: owner, conversationType: .group)
        ))
    }

    func testLegacyInviteNamespacesAndOldXMetadataAreNotAccepted() throws {
        let legacyInvite = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='legacy'>
          <invite xmlns='https://xabber.com/protocol/groups#invite' jid='stage@example.com'/>
        </message>
        """)
        let oldXOnly = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='old-x'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <jid>stage@example.com</jid>
            <privacy>incognito</privacy>
          </x>
        </message>
        """)

        XCTAssertEqual(service().receive(message: legacyInvite, date: Date(timeIntervalSince1970: 100), isRead: false), .invalid)
        XCTAssertEqual(service().receive(message: oldXOnly, date: Date(timeIntervalSince1970: 100), isRead: false), .invalid)
        XCTAssertEqual(try storedInvites().count, 0)
    }

    func testInviteReceiptDoesNotCreateFakeChatRosterResourceOrMessageRows() throws {
        let message = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='direct-1'>
          <body>Join stage</body>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
        </message>
        """)

        XCTAssertEqual(service().receive(message: message, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)

        let realm = try WRealm.safe()
        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 0)
        XCTAssertEqual(realm.objects(RosterStorageItem.self).filter("owner == %@ AND jid == %@", owner, "stage@example.com").count, 0)
        XCTAssertEqual(realm.objects(ResourceStorageItem.self).filter("owner == %@ AND jid == %@", owner, "stage@example.com").count, 0)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).count, 0)
    }

    func testNewAndUpdatedInviteRequestsGroupInfoAndMembersExactlyOnce() throws {
        let first = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='first'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)
        let duplicate = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='duplicate'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)
        let newer = try makeMessage("""
        <message from='stage@example.com/Group' to='\(owner)' id='newer'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)

        let inviteService = service()
        XCTAssertEqual(inviteService.receive(message: first, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)
        XCTAssertEqual(infoRequests, ["stage@example.com"])
        XCTAssertEqual(membersRequests, ["stage@example.com"])

        XCTAssertEqual(inviteService.receive(message: duplicate, date: Date(timeIntervalSince1970: 100), isRead: false), .duplicate)
        XCTAssertEqual(infoRequests, ["stage@example.com"])
        XCTAssertEqual(membersRequests, ["stage@example.com"])

        XCTAssertEqual(inviteService.receive(message: newer, date: Date(timeIntervalSince1970: 200), isRead: false), .updated)
        XCTAssertEqual(infoRequests, ["stage@example.com", "stage@example.com"])
        XCTAssertEqual(membersRequests, ["stage@example.com", "stage@example.com"])
    }

    func testAcceptAndDeclineRequestsStillUseStableInviteRow() throws {
        let message = try makeMessage("""
        <message from='juliet@example.com/balcony' to='\(owner)' id='direct-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='stage@example.com'/>
        </message>
        """)
        XCTAssertEqual(service().receive(message: message, date: Date(timeIntervalSince1970: 100), isRead: false), .inserted)

        let primary = GroupchatInvitesStorageItem.genIncomingPrimary(groupchat: "stage@example.com", owner: owner)
        let invite = try XCTUnwrap(try WRealm.safe().object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(invite.groupchat, "stage@example.com")

        let manager = GroupchatManager(withOwner: owner)
        let stream = XMPPStream()
        manager.join(stream, uiConnection: false, groupchat: invite.groupchat) { _ in }
        manager.decline(stream, groupchat: invite.groupchat) { _ in }

        XCTAssertTrue(manager.queryIds.isNotEmpty)
        XCTAssertNotNil(try WRealm.safe().object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary))
    }
}
