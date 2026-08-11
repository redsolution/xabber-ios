import UIKit
import XCTest
@testable import xabber

final class PushExtensionRichContentTests: XCTestCase {
    private let owner = "romeo@example.com"
    private var temporaryDirectory: URL!

    private final class RootSelectionSpy: LeftMenuSelectRootScreenDelegate {
        private(set) var selections: [(screen: String, category: String?)] = []
        private(set) var openChatCount = 0

        func selectRootScreenAndCategory(screen key: String, category: String?) -> Bool {
            selections.append((key, category))
            return true
        }

        func openChatlistWithChat(
            owner: String,
            jid: String,
            conversationType: ClientSynchronizationManager.ConversationType,
            openMessageRequest: ChatOpenMessageRequest?,
            navigationSource: ChatOpenNavigationSource,
            configure: ((ChatViewController?) -> Void)?
        ) -> Bool {
            openChatCount += 1
            return true
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PushExtensionRichContentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testVideoUsesThumbnailAndVideoFallbackWithoutChangingExactRoute() throws {
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com' id='video-message-1'>
              <body>video</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file>
                    <media-type>video/mp4</media-type>
                    <name>balcony.mp4</name>
                    <duration>12</duration>
                    <thumbnail xmlns='urn:xmpp:thumbs:1' media-type='image/jpeg' uri='https://cdn.example.com/balcony-preview.jpg'/>
                  </file>
                  <sources><uri>https://cdn.example.com/balcony.mp4</uri></sources>
                </file-sharing>
              </reference>
              <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='video-archive-1'/>
            </message>
            """
        )

        XCTAssertEqual(preview.mediaItems.first?.kind, .video)
        XCTAssertEqual(preview.body, "Video, 0:12s")
        XCTAssertEqual(preview.imageURLs, ["https://cdn.example.com/balcony-preview.jpg"])
        assertExactMessageRoute(preview, archivedId: "video-archive-1", messageId: "video-message-1")
    }

    func testLegacyMemojiStickerGetsStickerPreviewAndExactRoute() throws {
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com' id='sticker-message-1'>
              <body>sticker</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='7'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file>
                    <media-type>image/png</media-type>
                    <name>Memoji</name>
                  </file>
                  <sources><uri>https://cdn.example.com/memoji.png</uri></sources>
                </file-sharing>
              </reference>
              <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='sticker-archive-1'/>
            </message>
            """
        )

        XCTAssertEqual(preview.mediaItems.first?.kind, .sticker)
        XCTAssertEqual(preview.body, "Sticker")
        XCTAssertEqual(preview.imageURLs, ["https://cdn.example.com/memoji.png"])
        assertExactMessageRoute(preview, archivedId: "sticker-archive-1", messageId: "sticker-message-1")
    }

    func testLocalFileMediaURLIsNotExposedButImageFallbackIsPreserved() throws {
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <body>photo</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='5'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><media-type>image/jpeg</media-type><name>private.jpg</name></file>
                  <sources><uri>file:///private/var/mobile/private.jpg</uri></sources>
                </file-sharing>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.body, "Image")
        XCTAssertEqual(preview.mediaItems.count, 1)
        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertNil(preview.mediaItems.first?.url)
        XCTAssertTrue(preview.imageURLs.isEmpty)
    }

    func testEncryptedMediaSourceIsNotExposedButInlineThumbnailAndFallbackArePreserved() throws {
        let inlineThumbnail = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file>
                    <media-type>image/jpeg</media-type>
                    <name>secret.jpg</name>
                    <encrypted xmlns='urn:xmpp:esfs:0'>
                      <key>a2V5</key>
                      <iv>aXY=</iv>
                    </encrypted>
                    <thumbnail xmlns='urn:xmpp:thumbs:1' media-type='image/png' uri='\(inlineThumbnail)'/>
                  </file>
                  <sources><uri>https://cdn.example.com/secret.ciphertext</uri></sources>
                </file-sharing>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.body, "Image")
        XCTAssertEqual(preview.mediaItems.count, 1)
        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertNil(preview.mediaItems.first?.url)
        XCTAssertEqual(preview.mediaItems.first?.thumbnailURL, inlineThumbnail)
        XCTAssertEqual(preview.imageURLs, [inlineThumbnail])
    }

    func testMixedMediaUsesLocalizedAttachedFilesFallback() throws {
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com'>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><media-type>image/jpeg</media-type><name>balcony.jpg</name></file>
                  <sources><uri>https://cdn.example.com/balcony.jpg</uri></sources>
                </file-sharing>
              </reference>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable'>
                <file-sharing xmlns='https://xabber.com/protocol/files'>
                  <file><media-type>video/mp4</media-type><name>balcony.mp4</name></file>
                  <sources><uri>https://cdn.example.com/balcony.mp4</uri></sources>
                </file-sharing>
              </reference>
            </message>
            """
        )

        XCTAssertEqual(preview.mediaItems.map(\.kind), [.image, .video])
        XCTAssertEqual(
            preview.body,
            PushNotificationLocalization.string(
                "chat_message_attached_files",
                fallback: "%@ attached files",
                "2"
            )
        )
    }

    func testOnlyPublicHTTPSMediaURLsAreAccepted() {
        XCTAssertEqual(
            PushNotificationMediaURLPolicy.remoteURLString("https://cdn.example.com/photo.jpg"),
            "https://cdn.example.com/photo.jpg"
        )
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("http://cdn.example.com/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://localhost/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://127.0.0.1/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://127.1/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://2130706433/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://0x7f000001/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://10.1.2.3/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString("https://[::1]/photo.jpg"))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString(
            "https://[0:0:0:0:0:0:0:1]/photo.jpg"
        ))
        XCTAssertNil(PushNotificationMediaURLPolicy.remoteURLString(
            "https://[0:0:0:0:0:ffff:7f00:1]/photo.jpg"
        ))
    }

    func testMAMResultIdCentersCaptionedImageNotificationOnExactMessage() throws {
        let preview = try parse(
            """
            <message from='archive.example.com' to='romeo@example.com'>
              <result xmlns='urn:xmpp:mam:2' id='image-archive-1'>
                <forwarded xmlns='urn:xmpp:forward:0'>
                  <message from='juliet@example.com/mobile' to='romeo@example.com' id='image-message-1'>
                    <body>Balcony</body>
                    <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>
                      <file-sharing xmlns='https://xabber.com/protocol/files'>
                        <file><media-type>image/jpeg</media-type><name>balcony.jpg</name></file>
                        <sources><uri>https://cdn.example.com/balcony.jpg</uri></sources>
                      </file-sharing>
                    </reference>
                  </message>
                </forwarded>
              </result>
            </message>
            """
        )

        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertEqual(preview.body, "Balcony")
        XCTAssertEqual(preview.imageURLs, ["https://cdn.example.com/balcony.jpg"])
        assertExactMessageRoute(preview, archivedId: "image-archive-1", messageId: "image-message-1")
    }

    func testRegularMessageIdOnlyPushResolvesWithoutGroupAuthorFilter() throws {
        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com' id='regular-message-id'>
              <body>Hello</body>
            </message>
            """
        )
        let request = try XCTUnwrap(PushNotificationMessageOpenRequestFactory.make(
            route: preview.route,
            fallbackConversationType: .regular
        ))
        let target = localCandidate(
            primary: "regular-primary",
            messageId: "regular-message-id",
            authorId: nil
        )

        XCTAssertNil(request.anchor.archivedId)
        XCTAssertNil(request.anchor.authorId)
        XCTAssertEqual(
            resolve(request: request, candidates: [target]),
            .matched(target, source: .authorMessageID)
        )
    }

    func testGroupMessageIdOnlyPushResolvesWithParticipantIdAuthorFilter() throws {
        let preview = try parse(
            """
            <message type='groupchat' from='stage@conference.example.com/member-a'
                     to='romeo@example.com' id='group-message-id'>
              <body>Hello group</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user xmlns='https://xabber.com/protocol/groups' id='member-a'>
                  <jid>mercutio@example.com</jid>
                  <nickname>Mercutio</nickname>
                </user>
              </x>
            </message>
            """
        )
        let request = try XCTUnwrap(PushNotificationMessageOpenRequestFactory.make(
            route: preview.route,
            fallbackConversationType: .regular
        ))
        let target = localCandidate(
            primary: "group-primary",
            messageId: "group-message-id",
            authorId: "member-a"
        )
        let sameMessageIdFromAnotherAuthor = localCandidate(
            primary: "other-group-primary",
            messageId: "group-message-id",
            authorId: "member-b"
        )

        XCTAssertNil(request.anchor.archivedId)
        XCTAssertEqual(request.anchor.authorId, "member-a")
        XCTAssertEqual(
            resolve(
                request: request,
                candidates: [sameMessageIdFromAnotherAuthor, target]
            ),
            .matched(target, source: .authorMessageID)
        )
    }

    func testGroupSenderIdentityAndAvatarMetadataSurviveRouteRoundTrip() throws {
        let preview = try parse(
            """
            <message type='groupchat' from='stage@conference.example.com/member-a' to='romeo@example.com'>
              <body>Hello group</body>
              <x xmlns='https://xabber.com/protocol/groups'>
                <user xmlns='https://xabber.com/protocol/groups' id='member-a'>
                  <jid>mercutio@example.com</jid>
                  <nickname>Mercutio</nickname>
                  <avatar><info id='avatar-1' url='https://cdn.example.com/mercutio.jpg'/></avatar>
                </user>
              </x>
            </message>
            """
        )
        let decoded = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: preview.route.userInfo())
        )

        XCTAssertEqual(decoded.userInfo()["sender_user_id"] as? String, "member-a")
        XCTAssertEqual(decoded.userInfo()["sender_avatar_url"] as? String, "https://cdn.example.com/mercutio.jpg")
        XCTAssertEqual(decoded.senderJid, "mercutio@example.com")
        XCTAssertEqual(decoded.senderNickname, "Mercutio")
    }

    func testMediatedIncognitoInviteKeepsOpaqueInviterIdentityWithoutExposingJid() throws {
        let preview = try parse(
            """
            <message from='stage@conference.example.com' to='romeo@example.com' id='invite-1'>
              <invite xmlns='https://xabber.com/protocol/groups' jid='stage@conference.example.com'>
                <user id='member-juliet'>
                  <nickname>Juliet</nickname>
                  <avatar><info url='https://cdn.example.com/juliet.jpg'/></avatar>
                </user>
              </invite>
              <group xmlns='https://xabber.com/protocol/groups' privacy='incognito'>
                <info><name>Secret Stage</name></info>
              </group>
            </message>
            """
        )
        let decoded = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: preview.route.userInfo())
        )

        XCTAssertEqual(decoded.kind, .groupInvite)
        XCTAssertEqual(decoded.groupchat, "stage@conference.example.com")
        XCTAssertEqual(decoded.inviterNickname, "Juliet")
        XCTAssertNil(decoded.inviterJid)
        XCTAssertEqual(decoded.senderUserId, "member-juliet")
        XCTAssertEqual(decoded.senderAvatarURL, "https://cdn.example.com/juliet.jpg")
        XCTAssertEqual(
            decoded.senderAvatarIdentity,
            PushNotificationAvatarIdentity(
                owner: owner,
                groupchat: "stage@conference.example.com",
                participantId: "member-juliet"
            )
        )
    }

    func testSubscriptionTapSelectsIncomingContactRequestsInsteadOfOpeningChat() {
        let previousCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            AppRootCoordinator.active = previousCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        AppRootCoordinator.active = nil
        let spy = RootSelectionSpy()
        NotifyManager.shared.leftMenuDelegate = spy

        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRoute(
            .subscriptionRequest(
                owner: owner,
                contactJid: "benvolio@example.com",
                nickname: "Benvolio"
            ),
            atStart: false
        ))

        XCTAssertEqual(spy.selections.count, 1)
        XCTAssertEqual(spy.selections.first?.screen, "contacts")
        XCTAssertEqual(spy.selections.first?.category, "show_all_contacts")
        XCTAssertEqual(spy.openChatCount, 0)
    }

    func testGroupInviteTapSelectsIncomingInvitationsInsteadOfOpeningChat() {
        let previousCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            AppRootCoordinator.active = previousCoordinator
            NotifyManager.shared.leftMenuDelegate = previousDelegate
        }
        AppRootCoordinator.active = nil
        let spy = RootSelectionSpy()
        NotifyManager.shared.leftMenuDelegate = spy

        XCTAssertTrue(NotifyManager.shared.onTouchNotificationRoute(
            .groupInvite(
                owner: owner,
                groupchat: "stage@conference.example.com",
                inviteKind: "group",
                inviterJid: "juliet@example.com",
                inviterNickname: "Juliet"
            ),
            atStart: false
        ))

        XCTAssertEqual(spy.selections.count, 1)
        XCTAssertEqual(spy.selections.first?.screen, "groups")
        XCTAssertEqual(spy.selections.first?.category, "show_all_invites")
        XCTAssertEqual(spy.openChatCount, 0)
    }

    func testCompactLeftMenuKeepsIncomingRequestCategoriesAfterRootReset() throws {
        let menu = LeftMenuViewController()
        menu.previousSelectedKey = nil

        menu.didSelectRootScreenBy(
            key: "contacts",
            category: "show_all_contacts"
        )
        menu.didSelectRootScreenBy(
            key: "groups",
            category: "show_all_invites"
        )

        XCTAssertEqual(try XCTUnwrap(menu.contactsVc).category, "subscribtions")
        XCTAssertEqual(try XCTUnwrap(menu.groupsVc).category, "invitations")
    }

    @MainActor
    func testSplitRequestRouteRetainsPendingDestinationWhenRealMenuCannotPresent() {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            NotifyManager.shared.leftMenuDelegate = previousDelegate
            AppRootCoordinator.active = previousCoordinator
        }

        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)
        let detachedMenu = LeftMenuViewController()
        NotifyManager.shared.leftMenuDelegate = detachedMenu
        let previousSelectedKey = detachedMenu.previousSelectedKey

        XCTAssertFalse(coordinator.routeNotificationRequestList(
            .groupInvitations(owner: owner)
        ))
        XCTAssertEqual(detachedMenu.previousSelectedKey, previousSelectedKey)

        let acceptingMenu = RootSelectionSpy()
        NotifyManager.shared.leftMenuDelegate = acceptingMenu
        coordinator.sceneDidBecomeActive()

        XCTAssertEqual(acceptingMenu.selections.count, 1)
        XCTAssertEqual(acceptingMenu.selections.first?.screen, "groups")
        XCTAssertEqual(acceptingMenu.selections.first?.category, "show_all_invites")
    }

    @MainActor
    func testIncomingRequestListRouteSurvivesPresentedModalAndRetries() async {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousCoordinator = AppRootCoordinator.active
        let previousDelegate = NotifyManager.shared.leftMenuDelegate
        defer {
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
            NotifyManager.shared.leftMenuDelegate = previousDelegate
            AppRootCoordinator.active = previousCoordinator
        }

        CommonConfigManager.shared.config.interface_type =
            CommonConfigManager.InterfaceType.split.rawValue
        let coordinator = AppRootCoordinator(window: UIWindow(), appDelegate: nil)
        let spy = RootSelectionSpy()
        NotifyManager.shared.leftMenuDelegate = spy
        coordinator.currentPresentedVc = UIViewController()

        XCTAssertFalse(coordinator.routeNotificationRequestList(
            .contactRequests(owner: owner)
        ))
        XCTAssertTrue(spy.selections.isEmpty)

        coordinator.currentPresentedVc = nil
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(spy.selections.count, 1)
        XCTAssertEqual(spy.selections.first?.screen, "contacts")
        XCTAssertEqual(spy.selections.first?.category, "show_all_contacts")
    }

    func testAvatarSnapshotRoundTripIsOwnerAndParticipantScoped() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let regular = PushNotificationAvatarIdentity(
            owner: owner,
            contactJid: "Juliet@Example.com/mobile"
        )
        let otherOwner = PushNotificationAvatarIdentity(
            owner: "other@example.com",
            contactJid: "juliet@example.com"
        )
        let groupMember = PushNotificationAvatarIdentity(
            owner: owner,
            groupchat: "stage@conference.example.com",
            participantId: "member-a"
        )
        let imageData = try XCTUnwrap(makeImage(color: .systemPurple).pngData())

        try store.store(imageData: imageData, for: regular)

        XCTAssertEqual(store.imageData(for: regular), imageData)
        XCTAssertNil(store.imageData(for: otherOwner))
        XCTAssertNil(store.imageData(for: groupMember))
        XCTAssertFalse(store.fileURL(for: regular).path.contains("juliet@example.com"))
    }

    func testAvatarSnapshotRejectsCorruptDataAndInitialsAreUnicodeAware() throws {
        let store = PushNotificationAvatarStore(rootURL: temporaryDirectory)
        let identity = PushNotificationAvatarIdentity(
            owner: owner,
            contactJid: "juliet@example.com"
        )

        XCTAssertThrowsError(try store.store(imageData: Data("not-an-image".utf8), for: identity))
        XCTAssertNil(store.imageData(for: identity))
        XCTAssertEqual(
            PushNotificationInitialsRenderer.initials(
                displayName: "Mary Jane Watson",
                jid: "juliet@example.com"
            ),
            "MW"
        )
        XCTAssertEqual(
            PushNotificationInitialsRenderer.initials(
                displayName: "😀",
                jid: "juliet@example.com"
            ),
            "😀"
        )
        XCTAssertFalse(PushNotificationInitialsRenderer.imageData(
            displayName: "Juliet Capulet",
            jid: "juliet@example.com"
        ).isEmpty)
    }

    func testNoBodyFallbackFormatsIndonesianSingularCount() throws {
        let bundle = try makeLocalizationBundle(
            language: "id",
            strings: ["plurals.new_chat_messages.item_0": "%1$d pesan baru"]
        )

        XCTAssertEqual(
            PushNotificationLocalization.newMessage(
                bundle: bundle,
                locale: Locale(identifier: "id_ID")
            ),
            "1 pesan baru"
        )

        let preview = try parse(
            """
            <message from='juliet@example.com/mobile' to='romeo@example.com' id='empty-message-id'/>
            """
        )
        XCTAssertEqual(preview.body, PushNotificationLocalization.newMessage())
    }

    func testCommunicationNotificationDoesNotUseLegacyAddressBookIdentifiers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("xabber-push-extension/NotificationService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains(".contactID"))
        XCTAssertFalse(source.contains("CNContactStore"))
        XCTAssertFalse(source.contains("CNSaveRequest"))
    }

    private func parse(_ xml: String) throws -> PushNotificationPreview {
        try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: xml,
                owner: owner
            )
        )
    }

    private func assertExactMessageRoute(
        _ preview: PushNotificationPreview,
        archivedId: String,
        messageId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let request = PushNotificationMessageOpenRequestFactory.make(
            route: preview.route,
            fallbackConversationType: .regular
        )
        XCTAssertEqual(request?.anchor.archivedId, archivedId, file: file, line: line)
        XCTAssertEqual(request?.anchor.messageId, messageId, file: file, line: line)
        XCTAssertEqual(request?.source, .pushNotification, file: file, line: line)
        XCTAssertEqual(request?.highlight, true, file: file, line: line)
        XCTAssertEqual(request?.markReadOnVisible, true, file: file, line: line)
    }

    private func localCandidate(
        primary: String,
        messageId: String,
        authorId: String?
    ) -> LastChatsSearchLocalCandidate {
        LastChatsSearchLocalCandidate(
            primary: primary,
            archivedId: nil,
            messageId: messageId,
            authorId: authorId,
            sourceDate: nil,
            bodyFingerprint: nil
        )
    }

    private func resolve(
        request: ChatOpenMessageRequest,
        candidates: [LastChatsSearchLocalCandidate]
    ) -> LastChatsSearchLocalResolution {
        LastChatsSearchLocalResolver.resolve(
            provenance: LastChatsSearchResultProvenance(
                targetKind: .message,
                conversation: LastChatsSearchConversation(
                    owner: request.owner,
                    jid: request.chatJid,
                    conversationTypeRawValue: request.conversationType.rawValue
                ),
                messagePrimary: request.anchor.messagePrimary,
                archivedId: request.anchor.archivedId,
                messageId: request.anchor.messageId,
                authorId: request.anchor.authorId,
                sourceDate: request.anchor.sourceDate,
                bodyFingerprint: request.anchor.bodyFingerprint,
                provider: .localMessages,
                queryGeneration: 1
            ),
            candidates: candidates
        )
    }

    private func makeLocalizationBundle(
        language: String,
        strings: [String: String]
    ) throws -> Bundle {
        let localizationDirectory = temporaryDirectory
            .appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localizationDirectory,
            withIntermediateDirectories: true
        )
        let stringsData = try PropertyListSerialization.data(
            fromPropertyList: strings,
            format: .xml,
            options: 0
        )
        try stringsData.write(
            to: localizationDirectory.appendingPathComponent("Localizable.strings")
        )
        return try XCTUnwrap(Bundle(path: localizationDirectory.path))
    }

    private func makeImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}
