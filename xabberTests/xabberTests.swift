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

final class MessageReceiverBatchingTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    private func makeMessage(id: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message type='chat' id='\(id)' from='alexey.boldin@xmppdev01.xabber.com' to='\(owner)'>
          <body>Hello</body>
        </message>
        """, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageReceiverBatchingTests", code: 1)
        }
        return XMPPMessage(from: root)
    }

    func testEnqueueCollectionBatchesIntoMessagesQueue() throws {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.unsubscribeReceiver()
        manager.clearQueue()

        let first = MessageManager.MessageQueueItem(
            try makeMessage(id: "m1"),
            messageId: "m1",
            archivedFrom: "alexey.boldin@xmppdev01.xabber.com",
            isRead: false,
            date: Date(timeIntervalSince1970: 1),
            state: .deliver,
            queryId: "history-1"
        )
        let second = MessageManager.MessageQueueItem(
            try makeMessage(id: "m2"),
            messageId: "m2",
            archivedFrom: "alexey.boldin@xmppdev01.xabber.com",
            isRead: false,
            date: Date(timeIntervalSince1970: 2),
            state: .deliver,
            queryId: "history-1"
        )

        manager.enqueue(collection: [first, second])

        XCTAssertEqual(manager.messagesQueue.value.count, 2)
    }
}

final class ChatDatasetPerformanceHelpersTests: XCTestCase {

    func testMapReferenceAttachmentsPartitionsReferencesInOnePass() {
        let image = MessageReferenceStorageItem()
        image.primary = "image"
        image.mimeType = MimeIconTypes.image.rawValue
        image.kind = .media

        let video = MessageReferenceStorageItem()
        video.primary = "video"
        video.mimeType = MimeIconTypes.video.rawValue
        video.kind = .media

        let audio = MessageReferenceStorageItem()
        audio.primary = "audio"
        audio.kind = .voice
        audio.kind_ = "voice"

        let file = MessageReferenceStorageItem()
        file.primary = "file"
        file.mimeType = "application/pdf"
        file.kind = .media
        file.name = "spec.pdf"

        let groupchatFile = MessageReferenceStorageItem()
        groupchatFile.primary = "group-file"
        groupchatFile.mimeType = "application/pdf"
        groupchatFile.kind = .media
        groupchatFile.kind_ = "groupchat"

        let result = ChatViewController.mapReferenceAttachments([image, video, audio, file, groupchatFile])

        XCTAssertEqual(result.images.map(\.primary), ["image"])
        XCTAssertEqual(result.videos.map(\.primary), ["video"])
        XCTAssertEqual(result.audio.map(\.primary), ["audio"])
        XCTAssertEqual(result.files.map(\.primary), ["file"])
    }

    func testChatDatasourceSnapshotBuildsLookupMaps() {
        let first = ChatViewController.Datasource(
            primary: "first",
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "1", displayName: "Romeo"),
            messageId: "m1",
            sentDate: Date(),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "one")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "a1",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: ""),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
        let second = ChatViewController.Datasource(
            primary: "second",
            jid: "juliet@example.com",
            owner: "owner@example.com",
            outgoing: true,
            sender: Sender(id: "2", displayName: "Juliet"),
            messageId: "m2",
            sentDate: Date(),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "two")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: true,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "a2",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: ""),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )

        let snapshot = ChatDatasourceCoordinator.makeSnapshot(items: [first, second])

        XCTAssertEqual(snapshot.primaryIndex["first"], 0)
        XCTAssertEqual(snapshot.primaryIndex["second"], 1)
        XCTAssertEqual(snapshot.archivedIdIndex["a1"], 0)
        XCTAssertEqual(snapshot.archivedIdIndex["a2"], 1)
    }
}

final class ChatBootstrapStateTests: XCTestCase {

    func testBootstrapStateShowsSkeletonWhenChatIsUnsyncedAndHasNoMessages() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: false,
                isInitialBootstrapInFlight: false
            ),
            .skeleton
        )
    }

    func testBootstrapStateShowsEmptyWhenChatIsSyncedAndHasNoMessages() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: true,
                isInitialBootstrapInFlight: false
            ),
            .empty
        )
    }

    func testBootstrapStateShowsSkeletonWhenChatIsSyncedButSessionBootstrapIsStillInFlight() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: true,
                isInitialBootstrapInFlight: true
            ),
            .skeleton
        )
    }

    func testBootstrapStateShowsContentWhenMessagesExistBeforeArchiveBootstrapCompletes() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 3,
                isSynced: false,
                isInitialBootstrapInFlight: true
            ),
            .content
        )
    }

    func testBootstrapStateShowsContentWhenMessagesExistAfterArchiveBootstrapCompletes() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 3,
                isSynced: true,
                isInitialBootstrapInFlight: false
            ),
            .content
        )
    }

    func testBootstrapStateIgnoresUnsyncedFlagWhenMessagesAlreadyExist() {
        let item = LastChatsStorageItem()
        item.isSynced = false

        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 2,
                isSynced: item.isSynced,
                isInitialBootstrapInFlight: false
            ),
            .content
        )
    }
}

final class ChatInitialHistoryAppearancePolicyTests: XCTestCase {

    func testInitialAppearanceStartsWhenDatasourceIsPlaceholder() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldStart(isShowingBootstrapPlaceholder: true)
        )
    }

    func testInitialAppearanceDoesNotStartWhenDatasourceAlreadyHasContent() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldStart(isShowingBootstrapPlaceholder: false)
        )
    }

    func testInitialAppearanceKeepsDatasourceApplyNonAnimatedWhilePending() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: true)
        )
    }

    func testInitialAppearanceRestoresDatasourceAnimationAfterFirstStableRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: false)
        )
    }

    func testInitialAppearanceUsesReloadFallbackForNonAnimatedTargetedDiff() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldUseReloadFallbackForTargetedDiff(animated: false)
        )
    }

    func testPostInitialTargetedDiffKeepsIncrementalUpdates() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldUseReloadFallbackForTargetedDiff(animated: true)
        )
    }

    func testBootstrapReloadSkipsImmediateFollowupChangeset() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldApplyFollowupChangesetAfterBootstrapReload(
                didReloadInitialWindow: true
            )
        )
    }

    func testNonBootstrapTransitionsStillAllowChangesets() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldApplyFollowupChangesetAfterBootstrapReload(
                didReloadInitialWindow: false
            )
        )
    }

    func testInitialAppearanceDoesNotCompleteBeforeViewDidAppear() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: false,
                hasRenderedStableHistory: true
            )
        )
    }

    func testInitialAppearanceDoesNotCompleteBeforeStableHistoryRender() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: true,
                hasRenderedStableHistory: false
            )
        )
    }

    func testInitialAppearanceCompletesAfterViewDidAppearAndStableRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: true,
                hasRenderedStableHistory: true
            )
        )
    }

    func testInitialPopulationForcesNonAnimatedApply() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
                oldItemCount: 0,
                newItemCount: 10
            )
        )
    }

    func testNonInitialPopulationCanStillAnimate() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
                oldItemCount: 4,
                newItemCount: 10
            )
        )
    }

    func testInitialAppearanceDoesNotFinishForSkeletonOnlyRender() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 6, containsOnlyFakeMessages: true)
        )
    }

    func testInitialAppearanceFinishesForRealHistoryRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 6, containsOnlyFakeMessages: false)
        )
    }

    func testInitialAppearanceFinishesForEmptyChatRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 0, containsOnlyFakeMessages: false)
        )
    }
}

final class MessageArchiveRequestClassificationTests: XCTestCase {

    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    private func queuedTask(
        _ manager: MessageArchiveManager,
        queryId: String
    ) -> MessageArchiveManager.MAMRequestItem? {
        manager.callbacksQueue.first(where: { $0.elementId == queryId })?.task
    }

    func testBootstrapPurposeMarksInitialArchiveLoaded() {
        XCTAssertTrue(MessageArchiveManager.RequestPurpose.bootstrap.marksInitialArchiveLoaded)
    }

    func testNonBootstrapPurposesDoNotMarkInitialArchiveLoaded() {
        let purposes: [MessageArchiveManager.RequestPurpose] = [
            .pageOlder,
            .pageNewer,
            .jump,
            .gapRepair,
            .search,
            .latest,
            .media
        ]

        XCTAssertTrue(purposes.allSatisfy { !$0.marksInitialArchiveLoaded })
    }

    func testPersistedOlderCursorUsesOldestRsmBoundaryForBootstrap() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .bootstrap,
                first: "newest-page-boundary",
                last: "oldest-archived-id",
                current: "existing-cursor"
            ),
            "oldest-archived-id"
        )
    }

    func testPersistedOlderCursorUsesOldestRsmBoundaryForOlderPaging() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: "newest-page-boundary",
                last: "older-boundary",
                current: "existing-cursor"
            ),
            "older-boundary"
        )
    }

    func testPersistedOlderCursorDoesNotOverwriteForNewerPaging() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageNewer,
                first: "newer-boundary",
                last: "older-boundary",
                current: "existing-cursor"
            ),
            "existing-cursor"
        )
    }

    func testPersistedOlderCursorFallsBackToFirstRsmBoundaryWhenLastIsMissing() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: "fallback-boundary",
                last: "",
                current: "existing-cursor"
            ),
            "fallback-boundary"
        )
    }

    func testBaselineOlderPageRequestCanMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "baseline-older"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, true)
    }

    func testBaselineBootstrapRequestCanMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "baseline-bootstrap"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .bootstrap,
            queryId: queryId,
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, true)
    }

    func testBootstrapRequestWithArchiveStartCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "filtered-bootstrap"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .omemo,
            purpose: .bootstrap,
            queryId: queryId,
            start: Date(timeIntervalSince1970: 1234),
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testOlderPageRequestWithArchiveStartCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "filtered-older-start"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: true,
            conversationType: .omemo,
            purpose: .pageOlder,
            queryId: queryId,
            start: Date(timeIntervalSince1970: 1234),
            nextPage: "archived-100"
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testBeforeIdFilteredRequestCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "before-id-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            beforeId: "stanza-42",
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testAfterIdFilteredRequestCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "after-id-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            afterId: "stanza-84",
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testSearchTextAndTagFiltersCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "search-tag-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            searchText: "needle",
            nextPage: "",
            tags: [.image]
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }
}

final class MessageArchivePagingRequestTests: XCTestCase {

    func testNewestBootstrapRequestUsesEmptyBeforePointer() {
        let request = MessageArchiveManager.newestBootstrapPageRequest(pageSize: 100)

        XCTAssertEqual(request.nextPage, "")
        XCTAssertNil(request.prevPage)
        XCTAssertEqual(request.max, 100)
    }

    func testOlderPageRequestUsesBeforePointerWithOldestLoadedId() {
        let request = MessageArchiveManager.olderPageRequest(messageId: "oldest-id", pageSize: 100)

        XCTAssertEqual(request.nextPage, "oldest-id")
        XCTAssertNil(request.prevPage)
        XCTAssertEqual(request.max, 100)
    }

    func testNewerPageRequestUsesAfterPointerWithNewestLoadedId() {
        let request = MessageArchiveManager.newerPageRequest(messageId: "newest-id", pageSize: 100)

        XCTAssertNil(request.nextPage)
        XCTAssertEqual(request.prevPage, "newest-id")
        XCTAssertEqual(request.max, 100)
    }

    func testChatHistoryPagingUsesSharedPageSizeConstant() {
        XCTAssertEqual(ChatHistoryPagingConfiguration.pageSize, 100)
    }
}

final class MessageArchiveQueryCallbackTests: XCTestCase {

    private let owner = "owner@example.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "MessageArchiveQueryCallbackTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageArchiveQueryCallbackTests", code: 1)
        }
        return root
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try makeElement(xml: xml))
    }

    private func insertLastChat(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        fullArchiveLoaded: Bool = false,
        lastLoadedMessageHistoryId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.fullArchiveLoaded = fullArchiveLoaded
        chat.lastLoadedMessageHistoryId = lastLoadedMessageHistoryId

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func fullArchiveLoaded(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws -> Bool {
        let realm = try WRealm.safe()
        return realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        )?.fullArchiveLoaded ?? false
    }

    private func persistedHistoryCursorId(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws -> String? {
        let realm = try WRealm.safe()
        return realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        )?.lastLoadedMessageHistoryId
    }

    private func queuedTask(
        _ manager: MessageArchiveManager,
        queryId: String
    ) -> MessageArchiveManager.MAMRequestItem? {
        manager.callbacksQueue.first(where: { $0.elementId == queryId })?.task
    }

    func testSyncChatDoesNotStartGapRepairForAlreadySyncedChat() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let jid = "romeo@example.com"
        let conversationType: ClientSynchronizationManager.ConversationType = .regular
        let realm = try WRealm.safe()

        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.isSynced = true

        try realm.write {
            realm.add(chat, update: .modified)
        }

        let result = manager.syncChat(
            XMPPStream(),
            jid: jid,
            conversationType: conversationType,
            callback: nil
        )

        XCTAssertEqual(result, .noop)
        XCTAssertTrue(manager.callbacksQueue.isEmpty)
    }

    func testSyncChatUsesInjectedPageSizeForBootstrapRequest() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let jid = "romeo@example.com"
        let conversationType: ClientSynchronizationManager.ConversationType = .regular
        let realm = try WRealm.safe()

        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.isSynced = false

        try realm.write {
            realm.add(chat, update: .modified)
        }

        let result = manager.syncChat(
            XMPPStream(),
            jid: jid,
            conversationType: conversationType,
            pageSize: 42,
            callback: nil
        )

        guard case let .bootstrapStarted(queryId) = result else {
            return XCTFail("Expected bootstrap request to start")
        }
        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 42)
    }

    func testGetNextHistoryUsesInjectedPageSize() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = manager.getNextHistory(
            XMPPStream(),
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            pageSize: 64
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 64)
    }

    func testGetPrevHistoryUsesInjectedPageSize() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = manager.getPrevHistory(
            XMPPStream(),
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: "newest-id",
            pageSize: 58
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 58)
    }

    func testEndPageCallbackFiresOnlyForMatchingQuery() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var receivedQueryId: String?
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "matching end-page callback")

        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "query-1",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { queryId, state, _, _, _ in
                    receivedQueryId = queryId
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )
        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "query-2",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { queryId, _, _, _, _ in
                    XCTFail("Unexpected callback for \(queryId)")
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='query-1'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='query-1'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedQueryId, "query-1")
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil))
    }

    func testMessageCallbackFiresOnlyForMatchingQuery() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var received: [String] = []
        let callbackExpectation = expectation(description: "matching message callback")

        let matchingQuery = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "hello",
            max: 20,
            loadFull: false,
            requestCallbacks: .init(
                onMessage: { item, _ in
                    received.append(item.archivedId)
                    callbackExpectation.fulfill()
                },
                onEndPage: nil
            )
        )
        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "hello",
            max: 20,
            loadFull: false,
            requestCallbacks: .init(
                onMessage: { item, _ in
                    received.append("unexpected-\(item.archivedId)")
                },
                onEndPage: nil
            )
        )

        let message = try makeMessage(xml: """
        <message to='\(owner)' from='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(matchingQuery)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' to='\(owner)' from='romeo@example.com' type='chat' id='message-1'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='archived-1'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='archived-1'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-31T10:00:00Z'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='message-1'/>
                <body>Hello</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-03-31T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """)

        XCTAssertTrue(manager.readMessage(message))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(received, ["archived-1"])
    }

    func testEligibleCompleteResponseMarksArchiveEndedAndPersistsFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "eligible completion state")

        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "eligible-complete",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='eligible-complete'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='eligible-complete'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertTrue(try fullArchiveLoaded())
    }

    func testStartFilteredCompleteResponseDoesNotMarkArchiveEndedOrFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat(jid: "omemo@example.com", conversationType: .omemo)
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "filtered completion state")

        manager.requestArchive(
            stream,
            jid: "omemo@example.com",
            isContinues: false,
            conversationType: .omemo,
            purpose: .bootstrap,
            queryId: "filtered-complete",
            start: Date(timeIntervalSince1970: 1234),
            nextPage: "",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='filtered-complete'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='filtered-complete'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: false, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertFalse(try fullArchiveLoaded(jid: "omemo@example.com", conversationType: .omemo))
    }

    func testBeforeIdFilteredZeroCountResponseDoesNotMarkArchiveEndedOrFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "zero-count filtered completion")

        manager.requestArchive(
            stream,
            jid: "romeo@example.com",
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: "filtered-zero-count",
            beforeId: "stanza-42",
            nextPage: "",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='filtered-zero-count'>
          <fin xmlns='urn:xmpp:mam:2' complete='false' queryid='filtered-zero-count'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>0</count>
              <first></first>
              <last></last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: false, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertFalse(try fullArchiveLoaded())
    }

    func testConsumerManagedOlderPageDoesNotPersistArchiveEndOrTransportCursor() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat(fullArchiveLoaded: false, lastLoadedMessageHistoryId: "persisted-oldest")
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "consumer managed older page completion")

        manager.requestArchive(
            stream,
            jid: "romeo@example.com",
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: "consumer-managed-page",
            nextPage: "requested-oldest",
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='consumer-managed-page'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='consumer-managed-page'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>transport-first</first>
              <last>transport-last</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(
            receivedState,
            .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil)
        )
        XCTAssertFalse(try fullArchiveLoaded())
        XCTAssertEqual(try persistedHistoryCursorId(), "persisted-oldest")
    }
}

final class ChatHistoryPagingPolicyTests: XCTestCase {

    private func boundaryContext(
        firstRealSection: Int? = 0,
        lastRealSection: Int? = 9,
        visibleRealSections: [Int]
    ) -> ChatHistoryPagingBoundaryContext {
        ChatHistoryPagingBoundaryContext(
            firstRealSection: firstRealSection,
            lastRealSection: lastRealSection,
            visibleRealSections: visibleRealSections
        )
    }

    func testOlderPagingTriggersWhenOldestVisibleSectionIsReachedWhileScrollingOlder() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 48,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testNewerPagingTriggersWhenNewestVisibleSectionIsReachedWhileScrollingNewer() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: -32,
                boundaryContext: boundaryContext(visibleRealSections: [0, 1, 2]),
                currentPageMinIndex: 100
            ),
            .newer
        )
    }

    func testPagingDoesNotTriggerAwayFromVisibleBoundary() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 44,
                boundaryContext: boundaryContext(visibleRealSections: [2, 3, 4]),
                currentPageMinIndex: 0
            )
        )
    }

    func testPagingDoesNotTriggerAfterGestureStopsEvenIfBoundaryIsVisible() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: false,
                canLoadDatasource: true,
                gestureTranslationY: 44,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            )
        )
    }

    func testOlderPagingTriggersWhenOlderBoundaryIsTheOnlyAvailableDirection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: -44,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testOlderPagingTriggersWhenLastVisibleRealMessageReachesBoundaryEvenWithTrailingFakeSection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 32,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 8,
                    visibleRealSections: [6, 7, 8]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testPagingDoesNotTriggerWhenOnlyFakeSectionsAreVisible() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 32,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 8,
                    visibleRealSections: []
                ),
                currentPageMinIndex: 0
            )
        )
    }

    func testRequestedOlderWindowCanRunPastLocalObserverWithoutBeingClamped() {
        let coordinator = ChatDatasetCoordinator(pageSize: 100)

        XCTAssertEqual(
            coordinator.nextWindow(
                from: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                direction: .older
            ),
            ChatDatasetWindow(minIndex: 0, maxIndex: 150)
        )
    }

    func testOlderPagingRequestsRemoteArchiveWhenLocalHistoryIsExhausted() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                totalCount: 50,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testOlderPagingStopsCleanlyWhenArchiveEndWasAlreadyReached() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                totalCount: 50,
                isArchiveEnded: true
            ),
            .endReached
        )
    }

    func testOlderPagingUsesRemainingLocalMessagesBeforeRemoteArchive() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 200),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                totalCount: 150,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testOlderPagingDoesNotSplitLocalRemainderAndRemotePageIntoSeparateInteractions() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 200),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 120),
                totalCount: 120,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testShortContentDragFallbackRequestsOlderPageWhenOldestBoundaryIsVisible() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: 52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 6,
                    visibleRealSections: [4, 5, 6]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testShortContentDragFallbackUsesLastVisibleRealMessageWhenDatasourceEndsWithFakeSection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: 52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 5,
                    visibleRealSections: [4, 5]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testShortContentDragFallbackUsesOnlyAvailableOlderBoundaryRegardlessOfGestureSign() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: -52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 6,
                    visibleRealSections: [4, 5, 6]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }
}

final class ChatArchiveEndVerificationPolicyTests: XCTestCase {

    func testPersistedArchiveEndIsProbedOncePerSessionUntilConfirmed() {
        XCTAssertTrue(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: false,
                hasUsedVerificationProbe: false
            )
        )
    }

    func testPersistedArchiveEndIsTrustedAfterSessionConfirmation() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: true,
                hasUsedVerificationProbe: false
            )
        )
    }

    func testPersistedArchiveEndIsNotProbedAgainAfterVerificationAttempt() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: false,
                hasUsedVerificationProbe: true
            )
        )
    }

    func testEffectiveArchiveEndIgnoresPersistedFlagDuringVerificationProbe() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
                persistedArchiveEnded: true,
                shouldProbePersistedArchiveEnd: true
            )
        )
    }

    func testEffectiveArchiveEndKeepsPersistedFlagWhenNoProbeIsNeeded() {
        XCTAssertTrue(
            ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
                persistedArchiveEnded: true,
                shouldProbePersistedArchiveEnd: false
            )
        )
    }
}

final class ChatHistoryCursorSelectionPolicyTests: XCTestCase {

    func testOldestCursorUsesLastObservedArchivedIdWhenTailMessagesHaveArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["newest-1", "middle-1", "oldest-1"],
                persistedCursorId: "persisted-oldest"
            ),
            "oldest-1"
        )
    }

    func testOldestCursorSkipsTailMessagesWithoutArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["newest-1", "oldest-with-archive", "", ""],
                persistedCursorId: "persisted-oldest"
            ),
            "oldest-with-archive"
        )
    }

    func testOldestCursorFallsBackToPersistedHistoryCursorWhenObservedMessagesHaveNoArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["", "", ""],
                persistedCursorId: "persisted-oldest"
            ),
            "persisted-oldest"
        )
    }

    func testOldestCursorReturnsNilWhenNoObservedOrPersistedCursorExists() {
        XCTAssertNil(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["", ""],
                persistedCursorId: nil
            )
        )
    }
}

final class ChatObserverLookupPolicyTests: XCTestCase {

    private func makeMessage(primary: String, archivedId: String) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.archivedId = archivedId
        return message
    }

    func testObserverLookupBuildCapturesOldestArchivedIdDuringSinglePass() {
        let lookup = ChatObserverLookupPolicy.build(
            from: [
                makeMessage(primary: "primary-1", archivedId: "archived-3"),
                makeMessage(primary: "primary-2", archivedId: ""),
                makeMessage(primary: "primary-3", archivedId: "archived-2"),
                makeMessage(primary: "primary-4", archivedId: "archived-1")
            ]
        )

        XCTAssertEqual(lookup.primaryIndex["primary-2"], 1)
        XCTAssertEqual(lookup.archivedIdIndex["archived-1"], 3)
        XCTAssertEqual(lookup.oldestArchivedId, "archived-1")
    }
}

final class ChatArchiveStateMutationPolicyTests: XCTestCase {

    func testMutationPlanSkipsWriteWhenCursorAndArchiveStateAreUnchanged() {
        let snapshot = ChatArchiveStateSnapshot(
            primaryKey: "chat-primary",
            persistedCursorId: "cursor-1",
            fullArchiveLoaded: false
        )
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: nil,
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: false
        )

        XCTAssertEqual(resolvedCursorId, "cursor-1")
        XCTAssertFalse(plan.shouldWriteCursor)
        XCTAssertFalse(plan.shouldWriteFullArchiveLoaded)
        XCTAssertFalse(plan.needsWrite)
    }

    func testMutationPlanWritesCursorAndArchiveStateTogetherWhenBothChange() {
        let snapshot = ChatArchiveStateSnapshot(
            primaryKey: "chat-primary",
            persistedCursorId: nil,
            fullArchiveLoaded: false
        )
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: "cursor-2",
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: true
        )

        XCTAssertEqual(resolvedCursorId, "cursor-2")
        XCTAssertTrue(plan.shouldWriteCursor)
        XCTAssertTrue(plan.shouldWriteFullArchiveLoaded)
        XCTAssertTrue(plan.needsWrite)
    }
}

final class ChatHistoryPageOutcomePolicyTests: XCTestCase {

    func testOlderPageAdvancedWhenPersistedBoundaryMoves() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: false,
                didAdvance: true,
                persistedMessageCount: 100,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-2"
            ),
            .advanced(persistedCursorId: "cursor-2")
        )
    }

    func testOlderPageMarksArchiveEndOnlyWhenQueryExhaustedAndBoundaryDidNotMove() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: true,
                didAdvance: false,
                persistedMessageCount: 0,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-1"
            ),
            .emptyExhausted(persistedCursorId: "cursor-1")
        )
    }

    func testOlderPageTreatsNonAdvancingPersistedMessagesAsDuplicateInsteadOfArchiveEnd() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: true,
                didAdvance: false,
                persistedMessageCount: 3,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-1"
            ),
            .duplicateOrNoAdvance(persistedCursorId: "cursor-1")
        )
    }
}

final class ChatHistoryPageCompletionPolicyTests: XCTestCase {

    func testInteractiveHistoryPageCompletionWaitsWhenObserverAdvancesBeforeFin() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: false,
                didAdvance: true,
                persistedMessageCount: 1,
                isMessagePipelineIdle: true
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 1,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsWhenFinArrivesBeforeObserverAdvance() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 3,
                isMessagePipelineIdle: true
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 3,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionFinishesImmediatelyWhenServerPagePersistsNoMessages() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 0,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsUntilMessagePipelineIsIdle() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: false
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsForObserverSettleAfterPipelineBecomesIdle() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: true,
                requiresObserverSettle: true,
                didObservePostIdleTick: false
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: true,
                requiresObserverSettle: true,
                didObservePostIdleTick: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionDoesNotRequireObserverSettleForEmptyPage() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 0,
                isMessagePipelineIdle: true,
                requiresObserverSettle: false,
                didObservePostIdleTick: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenObserverCountGrows() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 180,
                previousOldestArchivedId: "100",
                currentOldestArchivedId: "100",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenOldestArchivedIdChangesWithoutCountGrowth() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1770722527493600",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenArchiveEndBecomesKnown() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1771925790869010",
                previousArchiveEnded: false,
                currentArchiveEnded: true
            )
        )
    }

    func testOlderPageCompletionWaitsWhenFinArrivesBeforeObserverStateChanges() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1771925790869010",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }
}

final class ChatHistoryPageApplyPolicyTests: XCTestCase {

    func testOlderPagingDoesNotKeepOffsetInInvertedTimeline() {
        XCTAssertFalse(ChatHistoryPageApplyPolicy.keepOffset(direction: .older))
    }

    func testNewerPagingKeepsOffsetInInvertedTimeline() {
        XCTAssertTrue(ChatHistoryPageApplyPolicy.keepOffset(direction: .newer))
    }
}

final class ChatHistoryPageAnchorRestorePolicyTests: XCTestCase {

    func testAnchorRestoreUsesCapturedViewportOffset() {
        XCTAssertEqual(
            ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
                anchorMinY: 420,
                offsetFromViewportTop: 120,
                minContentOffsetY: 0,
                maxContentOffsetY: 800
            ),
            300
        )
    }

    func testAnchorRestoreClampsToScrollableBounds() {
        XCTAssertEqual(
            ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
                anchorMinY: 40,
                offsetFromViewportTop: 120,
                minContentOffsetY: -16,
                maxContentOffsetY: 200
            ),
            -16
        )
    }
}

final class ChatHistoryLoadingTimeoutPolicyTests: XCTestCase {

    func testInteractivePageLoadDoesNotAbortAtSoftTimeout() {
        XCTAssertFalse(
            ChatHistoryLoadingTimeoutPolicy.shouldAbortInteractivePageLoad(
                elapsed: ChatHistoryLoadingTimeoutPolicy.checkInterval
            )
        )
    }

    func testInteractivePageLoadAbortsAtHardTimeout() {
        XCTAssertTrue(
            ChatHistoryLoadingTimeoutPolicy.shouldAbortInteractivePageLoad(
                elapsed: ChatHistoryLoadingTimeoutPolicy.interactiveHardTimeout
            )
        )
    }
}

final class ChatDatasourceApplyGenerationPolicyTests: XCTestCase {

    func testSupersededGenerationDoesNotApply() {
        XCTAssertFalse(
            ChatDatasourceApplyGenerationPolicy.shouldApply(
                requestGeneration: 3,
                currentGeneration: 4
            )
        )
    }

    func testCurrentGenerationApplies() {
        XCTAssertTrue(
            ChatDatasourceApplyGenerationPolicy.shouldApply(
                requestGeneration: 4,
                currentGeneration: 4
            )
        )
    }
}

final class MessageManagerQueueSynchronizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "MessageManagerQueueSynchronizationTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageManagerQueueSynchronizationTests", code: 1)
        }
        return root
    }

    private func makeMessage(index: Int) throws -> XMPPMessage {
        try XMPPMessage(from: makeElement(xml: """
        <message from='romeo@example.com' to='owner@example.com' type='chat' id='message-\(index)'>
          <origin-id xmlns='urn:xmpp:sid:0' id='message-\(index)'/>
          <body>\(index)</body>
        </message>
        """))
    }

    private func makeQueueItem(index: Int) throws -> MessageManager.MessageQueueItem {
        MessageManager.MessageQueueItem(
            try makeMessage(index: index),
            messageId: "message-\(index)",
            archivedFrom: "romeo@example.com",
            isRead: false,
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            state: .deliver,
            queryId: "query-\(index)"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.02,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func testConcurrentEnqueueKeepsEveryUniqueMessageInSerializedBuffer() throws {
        let manager = MessageManager(withOwner: "owner@example.com", activeStream: false)
        manager.unsubscribeReceiver()

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "MessageManagerQueueSynchronizationTests.enqueue", attributes: .concurrent)

        for index in 0..<100 {
            group.enter()
            concurrentQueue.async {
                defer { group.leave() }
                if let item = try? self.makeQueueItem(index: index) {
                    manager.enqueue(item)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let snapshot = manager.performMessageQueueSync { manager.queuedMessages }
        XCTAssertEqual(snapshot.count, 100)
        XCTAssertEqual(Set(snapshot.compactMap(\.messageId)).count, 100)
        XCTAssertEqual(manager.messagesQueue.value.count, 100)
    }

    func testEnqueueSchedulesAutomaticDrainWithoutManualFlush() throws {
        let manager = MessageManager(withOwner: "owner@example.com", activeStream: false)
        manager.clearQueue()

        let item = try makeQueueItem(index: 1)
        manager.enqueue(item)

        XCTAssertTrue(
            waitUntil {
                manager.performMessageQueueSync {
                    manager.queuedMessages.isEmpty &&
                    !manager.hasPendingMessages(forQueryId: "query-1")
                }
            }
        )
        XCTAssertTrue(manager.messagesQueue.value.isEmpty)
        XCTAssertFalse(manager.performMessageQueueSync { manager.isQueuedMessagesDrainScheduled })
    }
}

final class ChatMarkersCleanupSchedulingTests: XCTestCase {

    private final class SpyChatMarkersManager: ChatMarkersManager {
        private let lock = NSLock()
        private var runCountStorage = 0
        private var activeRunsStorage = 0
        private var maxConcurrentRunsStorage = 0

        var onRun: (() -> Void)?
        var gate: DispatchSemaphore?

        init(owner: String) {
            super.init(withOwner: owner, withoutAfterburnTimer: true)
        }

        override func runEphemeralCleanup() {
            self.lock.lock()
            self.runCountStorage += 1
            self.activeRunsStorage += 1
            self.maxConcurrentRunsStorage = max(self.maxConcurrentRunsStorage, self.activeRunsStorage)
            let callback = self.onRun
            self.lock.unlock()

            callback?()
            if let gate = self.gate {
                _ = gate.wait(timeout: .now() + 2)
            }

            self.lock.lock()
            self.activeRunsStorage -= 1
            self.lock.unlock()
        }

        var runCount: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.runCountStorage
        }

        var activeRuns: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.activeRunsStorage
        }

        var maxConcurrentRuns: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.maxConcurrentRunsStorage
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.02,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func testRapidTriggersCoalesceIntoSingleFollowupPassWithoutOverlap() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")
        let firstRunStarted = expectation(description: "first run started")
        let secondRunStarted = expectation(description: "second run started")
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate

        manager.onRun = {
            let runCount = manager.runCount
            if runCount == 1 {
                firstRunStarted.fulfill()
            } else if runCount == 2 {
                secondRunStarted.fulfill()
            }
        }

        manager.deleteEphemeralMessages()
        wait(for: [firstRunStarted], timeout: 1)

        for _ in 0..<30 {
            manager.deleteEphemeralMessages()
        }

        gate.signal()
        wait(for: [secondRunStarted], timeout: 1)
        gate.signal()

        XCTAssertTrue(
            waitUntil {
                manager.runCount == 2 && manager.activeRuns == 0
            }
        )
        XCTAssertEqual(manager.runCount, 2)
        XCTAssertEqual(manager.maxConcurrentRuns, 1)
        manager.stopAfterburnTimerForTests()
    }

    func testCleanupTriggerReturnsQuickly() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")
        let runStarted = expectation(description: "run started")
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate
        manager.onRun = {
            runStarted.fulfill()
        }

        let start = Date()
        manager.deleteEphemeralMessages()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.05)
        wait(for: [runStarted], timeout: 1)
        gate.signal()
        XCTAssertTrue(waitUntil { manager.activeRuns == 0 && manager.runCount == 1 })
        manager.stopAfterburnTimerForTests()
    }

    func testTimerRescheduleKeepsSingleActiveTimerAtOneSecondCadenceAndTriggersImmediateCleanup() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")

        manager.updateDeleteEphemeralMessagesTimer()
        XCTAssertTrue(waitUntil { manager.runCount >= 1 })
        XCTAssertTrue(manager.hasAfterburnTimerForTests())
        XCTAssertEqual(manager.afterburnCleanupIntervalSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(manager.afterburnCleanupLeewayMilliseconds, 250)

        let firstTimerId = manager.afterburnTimerDebugIdentifierForTests()
        let firstRunCount = manager.runCount

        manager.updateDeleteEphemeralMessagesTimer()
        XCTAssertTrue(waitUntil { manager.runCount >= firstRunCount + 1 })
        XCTAssertTrue(manager.hasAfterburnTimerForTests())

        let secondTimerId = manager.afterburnTimerDebugIdentifierForTests()
        XCTAssertNotNil(firstTimerId)
        XCTAssertNotNil(secondTimerId)
        XCTAssertNotEqual(firstTimerId, secondTimerId)
        manager.stopAfterburnTimerForTests()
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

    func testClientSyncPageParserParsesSnapshotPage() throws {
        let iq = try makeIQ(xml: """
        <iq type='result' id='sync-2'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000000'>
            <conversation jid='romeo@example.com' type='regular' status='active'/>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
            </set>
          </query>
        </iq>
        """)

        let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: 200,
            namespace: ClientSynchronizationManager.primaryNamespace,
            updateOmemo: { $0 }
        )

        XCTAssertEqual(page?.stamp, "1711283296000000")
        XCTAssertEqual(page?.conversations.count, 1)
        XCTAssertEqual(page?.isFinalPage, true)
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

final class GroupchatRequestSchedulerTests: XCTestCase {

    func testCancelPreventsScheduledTimeoutCallback() {
        let scheduler = GroupchatRequestScheduler()
        let invertedExpectation = expectation(description: "timeout should be cancelled")
        invertedExpectation.isInverted = true

        scheduler.schedule(elementId: "timeout-1", timeout: 0.05) {
            invertedExpectation.fulfill()
        }
        scheduler.cancel(elementId: "timeout-1")

        wait(for: [invertedExpectation], timeout: 0.15)
    }
}

final class FavoritesFeatureTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "FavoritesFeatureTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "FavoritesFeatureTests", code: 1)
        }
        return root
    }

    func testFavoritesDiscoRequiresArchiveIdentityAndFeature() throws {
        let validQuery = try makeElement(xml: """
        <query xmlns='http://jabber.org/protocol/disco#info'>
          <identity category='component' type='archive' name='Saved messages'/>
          <feature var='urn:xabber:favorites:0'/>
        </query>
        """)

        let missingFeatureQuery = try makeElement(xml: """
        <query xmlns='http://jabber.org/protocol/disco#info'>
          <identity category='component' type='archive' name='Saved messages'/>
        </query>
        """)

        XCTAssertTrue(XMPPFavoritesManager.supportsService(validQuery))
        XCTAssertFalse(XMPPFavoritesManager.supportsService(missingFeatureQuery))
    }

    func testIgnoredServiceJidsIncludeFavoritesNode() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let abuse = XMPPAbuseConfigStorageItem()
            abuse.primary = "abuse"
            abuse.owner = owner
            abuse.abuseAddress = "abuse.xmppdev01.xabber.com"
            realm.add(abuse)
        }

        let ignored = XMPPServiceJidsSupport.ignoredServiceJids(
            in: realm,
            accountJids: [owner],
            serviceNodes: ["favorites.xmppdev01.xabber.com", "notifications.xmppdev01.xabber.com"]
        )

        XCTAssertTrue(ignored.contains(owner))
        XCTAssertTrue(ignored.contains("favorites.xmppdev01.xabber.com"))
        XCTAssertTrue(ignored.contains("notifications.xmppdev01.xabber.com"))
        XCTAssertTrue(ignored.contains("abuse.xmppdev01.xabber.com"))
    }

    func testBuildForwardMessageTargetsFavoritesNodeAndAddsForwardReference() throws {
        let realm = try WRealm.safe()
        let forwardedPrimary = "forwarded-message-primary"
        let stanzaPrimary = [forwardedPrimary, "stanza"].prp()
        try realm.write {
            let stanza = MessageStanzaStorageItem()
            stanza.primary = stanzaPrimary
            stanza.timestamp = ISO8601DateFormatter().date(from: "2026-03-24T12:34:56Z")!
            stanza.stanza = """
            <message from='romeo@xmppdev01.xabber.com/orchard' to='juliet@xmppdev01.xabber.com/balcony' type='chat' id='msg-1'>
              <body>Hello Juliet</body>
            </message>
            """
            realm.add(stanza)
        }

        let manager = XMPPFavoritesManager(withOwner: owner)
        manager.node = "favorites.xmppdev01.xabber.com"

        let stanza = manager.buildForwardMessage(for: [forwardedPrimary])

        XCTAssertEqual(stanza?.to?.bare, "favorites.xmppdev01.xabber.com")
        XCTAssertEqual(stanza?.type, "chat")
        XCTAssertNotNil(stanza?.body)
        let reference = stanza?.element(forName: "reference")
        XCTAssertNotNil(reference)
        XCTAssertEqual(reference?.xmlns(), "https://xabber.com/protocol/references")
        XCTAssertEqual(reference?.attributeStringValue(forName: "type"), "mutable")
        XCTAssertNotNil(reference?.element(forName: "forwarded"))
    }
}
