import XCTest
import UserNotifications
@testable import xabber

final class LocalNotificationRichContentTests: XCTestCase {
    private let owner = "romeo@example.com"
    private let sentAt = Date(timeIntervalSince1970: 1_723_337_600)

    override func tearDown() {
        RichNotificationLoaderURLProtocol.reset()
        super.tearDown()
    }

    func testNonRuntimeUnreadMessageIsRejectedForLocalNotificationSideEffect() {
        // Arrange
        let now = Date(timeIntervalSince1970: 1_723_337_600)
        let freshSentAt = now.addingTimeInterval(-1)

        // Act
        let isAdmitted = LocalNotificationAdmissionPolicy.allowsMessage(
            countsAsRuntimeUnread: false,
            sentAt: freshSentAt,
            now: now
        )

        // Assert
        XCTAssertFalse(isAdmitted)
    }

    func testFreshRuntimeUnreadMessageIsAllowedForLocalNotificationSideEffect() {
        // Arrange
        let now = Date(timeIntervalSince1970: 1_723_337_600)
        let freshSentAt = now.addingTimeInterval(-1)

        // Act
        let isAdmitted = LocalNotificationAdmissionPolicy.allowsMessage(
            countsAsRuntimeUnread: true,
            sentAt: freshSentAt,
            now: now
        )

        // Assert
        XCTAssertTrue(isAdmitted)
    }

    func testDelayedSubscribePresenceOlderThanFreshnessWindowIsRejected() {
        // Arrange
        let now = Date(timeIntervalSince1970: 1_723_337_600)
        let delayedDeliveryDate = now.addingTimeInterval(-11)

        // Act
        let isAdmitted = LocalNotificationAdmissionPolicy.allowsSubscribePresence(
            receivedAt: delayedDeliveryDate,
            now: now
        )

        // Assert
        XCTAssertFalse(isAdmitted)
    }

    func testFreshSubscribePresenceIsAllowed() {
        // Arrange
        let now = Date(timeIntervalSince1970: 1_723_337_600)
        let receivedAt = now.addingTimeInterval(-1)

        // Act
        let isAdmitted = LocalNotificationAdmissionPolicy.allowsSubscribePresence(
            receivedAt: receivedAt,
            now: now
        )

        // Assert
        XCTAssertTrue(isAdmitted)
    }

    func testLocalGroupPreviewKeepsExactAnchorAndRealParticipantIdentity() throws {
        let stanza = """
        <message from='garden@conference.example.com' to='romeo@example.com' type='chat' id='message-1'>
          <body>Hello</body>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='member-7'><jid>juliet@example.com</jid><nickname>Juliet</nickname></user>
          </x>
        </message>
        """

        let preview = LocalMessageNotificationPreviewFactory.make(
            originalStanzaXML: stanza,
            owner: owner,
            routeJid: "garden@conference.example.com",
            conversationType: "https://xabber.com/protocol/groups",
            archivedId: "archive-1",
            messageId: "message-1",
            sentAt: sentAt,
            fallbackBody: "Hello",
            senderJid: "juliet@example.com",
            senderNickname: "Juliet from app",
            senderUserId: "member-7"
        )

        XCTAssertEqual(preview.route.conversationType, "group")
        XCTAssertEqual(preview.route.groupchat, "garden@conference.example.com")
        XCTAssertEqual(preview.route.stanzaId, "archive-1")
        XCTAssertEqual(preview.route.messageId, "message-1")
        XCTAssertEqual(preview.route.timestamp, sentAt.timeIntervalSinceReferenceDate)
        XCTAssertEqual(preview.route.senderJid, "juliet@example.com")
        XCTAssertEqual(preview.route.senderNickname, "Juliet from app")
        XCTAssertEqual(preview.route.senderUserId, "member-7")
        XCTAssertEqual(preview.route.stanza, stanza)

        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: preview.route,
                fallbackConversationType: .regular
            )
        )
        XCTAssertEqual(request.conversationType, .group)
        XCTAssertEqual(request.anchor.archivedId, "archive-1")
        XCTAssertEqual(request.anchor.messageId, "message-1")
        XCTAssertEqual(request.anchor.authorId, "member-7")
        XCTAssertEqual(request.anchor.sourceDate, sentAt)
        XCTAssertTrue(request.highlight)
        XCTAssertTrue(request.markReadOnVisible)
    }

    func testLegacyLocalRouteFactoryNormalizesRawGroupConversationURI() {
        let route = LocalMessageNotificationRouteFactory.make(
            owner: owner,
            routeJid: "garden@conference.example.com",
            conversationType: "https://xabber.com/protocol/groups",
            stanzaId: "archive-legacy-group",
            senderJid: "juliet@example.com",
            senderNickname: "Juliet"
        )

        XCTAssertEqual(route.conversationType, "group")
        XCTAssertEqual(route.groupchat, "garden@conference.example.com")
    }

    func testPresentationUsesAuthoritativeAppNamesForDirectAndGroupMessages() {
        let direct = preview(
            route: .message(
                owner: owner,
                routeJid: "juliet@example.com",
                conversationType: "regular",
                stanzaId: "direct-archive",
                messageId: "direct-message",
                stanza: nil,
                senderJid: "juliet@example.com",
                senderNickname: nil,
                groupchat: nil
            ),
            body: "Balcony"
        )
        let directPlan = RichNotificationPresentationPolicy.plan(
            for: direct,
            overrides: RichNotificationNameOverrides(
                conversationName: "Juliet Capulet",
                senderName: nil,
                editMark: ""
            ),
            metadataName: { _, _ in "Stale mirror" }
        )

        XCTAssertEqual(directPlan.title, "Juliet Capulet")
        XCTAssertEqual(directPlan.subtitle, "")
        XCTAssertEqual(directPlan.body, "Balcony")
        XCTAssertEqual(directPlan.threadIdentifier, "xabber:romeo@example.com:juliet@example.com")
        XCTAssertEqual(directPlan.senderDisplayName, "Juliet Capulet")
        XCTAssertEqual(directPlan.senderHandle, "juliet@example.com")
        XCTAssertEqual(directPlan.categoryIdentifier, PushNotificationCategory.pushMessage)

        let groupRoute = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: "garden@conference.example.com",
            conversationType: "group",
            stanzaId: "group-archive",
            messageId: "group-message",
            stanza: nil,
            senderJid: "juliet@example.com",
            senderNickname: "Wire nickname",
            senderUserId: "member-7",
            groupchat: "garden@conference.example.com"
        )
        let groupPlan = RichNotificationPresentationPolicy.plan(
            for: preview(route: groupRoute, body: "Hello"),
            overrides: RichNotificationNameOverrides(
                conversationName: "Secret Garden",
                senderName: "Juliet from app",
                editMark: ""
            ),
            metadataName: { _, _ in nil }
        )

        XCTAssertEqual(groupPlan.title, "Secret Garden")
        XCTAssertEqual(groupPlan.subtitle, "Juliet from app")
        XCTAssertEqual(groupPlan.senderDisplayName, "Juliet from app")
        XCTAssertEqual(groupPlan.speakableGroupName, "Secret Garden")
        XCTAssertEqual(groupPlan.senderAvatarIdentity, groupRoute.senderAvatarIdentity)
        XCTAssertTrue(groupPlan.senderHandle.hasPrefix("xabber-group-participant:"))
    }

    func testRequestPresentationPlansOpenTheCorrectInbox() {
        let subscriptionRoute = PushNotificationRoutePayload.subscriptionRequest(
            owner: owner,
            contactJid: "mercutio@example.com",
            nickname: "Wire Mercutio"
        )
        let subscription = RichNotificationPresentationPolicy.plan(
            for: preview(route: subscriptionRoute, body: "ignored"),
            overrides: RichNotificationNameOverrides(
                conversationName: nil,
                senderName: "Mercutio from app",
                editMark: ""
            ),
            metadataName: { _, _ in nil }
        )
        XCTAssertEqual(subscription.title, "Mercutio from app")
        XCTAssertEqual(subscription.threadIdentifier, "xabber:romeo@example.com:contact-requests")
        XCTAssertEqual(subscription.categoryIdentifier, PushNotificationCategory.subscription)

        let inviteRoute = PushNotificationRoutePayload.groupInvite(
            owner: owner,
            groupchat: "garden@conference.example.com",
            inviteKind: "group",
            inviterJid: "juliet@example.com",
            inviterNickname: "Wire Juliet"
        )
        let invite = RichNotificationPresentationPolicy.plan(
            for: preview(route: inviteRoute, body: "ignored", groupName: "Wire Garden"),
            overrides: RichNotificationNameOverrides(
                conversationName: "Garden from app",
                senderName: "Juliet from app",
                editMark: ""
            ),
            metadataName: { _, _ in nil }
        )
        XCTAssertEqual(invite.title, "Garden from app")
        XCTAssertEqual(invite.subtitle, "Juliet from app")
        XCTAssertEqual(invite.threadIdentifier, "xabber:romeo@example.com:group-invitations")
        XCTAssertEqual(invite.categoryIdentifier, PushNotificationCategory.invite)
    }

    func testAttachmentPolicySupportsImagesStickersPlayableVideoAndVoice() {
        let items: [PushNotificationMediaItem] = [
            media(.image, name: "photo.jpg", type: "image/jpeg", url: "https://cdn.example.com/photo.jpg"),
            media(.sticker, name: "Memoji", type: "image/png", url: "https://cdn.example.com/sticker.png"),
            media(
                .video,
                name: "clip.mp4",
                type: "video/mp4",
                url: "https://cdn.example.com/clip.mp4",
                thumbnail: "https://cdn.example.com/clip.jpg"
            ),
            media(.voice, name: "voice.m4a", type: "audio/mp4", url: "https://cdn.example.com/voice.m4a"),
            media(.file, name: "document.pdf", type: "application/pdf", url: "https://cdn.example.com/document.pdf"),
            media(.forward, name: nil, type: nil, url: nil)
        ]

        let candidates = RichNotificationAttachmentPolicy.candidates(
            for: items,
            includePlayableMedia: true
        )

        XCTAssertEqual(candidates.map(\.kind), [.image, .image, .video, .audio])
        XCTAssertEqual(candidates[0].sourceURL, "https://cdn.example.com/photo.jpg")
        XCTAssertEqual(candidates[1].sourceURL, "https://cdn.example.com/sticker.png")
        XCTAssertEqual(candidates[2].sourceURL, "https://cdn.example.com/clip.mp4")
        XCTAssertEqual(candidates[2].fallbackImageURL, "https://cdn.example.com/clip.jpg")
        XCTAssertEqual(candidates[3].sourceURL, "https://cdn.example.com/voice.m4a")
    }

    func testForwardOnlyMessageGetsLocalizedFallbackAndExactMessageRoute() throws {
        let xml = """
        <message from='juliet@example.com' to='romeo@example.com' id='forward-message'>
          <body>forwarded</body>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='9'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message from='mercutio@example.com'><body>A plague</body></message>
            </forwarded>
          </reference>
          <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.com' id='forward-archive'/>
        </message>
        """

        let parsed = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(xmlString: xml, owner: owner)
        )

        XCTAssertEqual(parsed.mediaItems.map(\.kind), [.forward])
        XCTAssertEqual(
            parsed.body,
            PushNotificationLocalization.string(
                "chat_message_forwarded_message",
                fallback: "Forwarded message"
            )
        )
        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: parsed.route,
                fallbackConversationType: .regular
            )
        )
        XCTAssertEqual(request.anchor.archivedId, "forward-archive")
        XCTAssertEqual(request.anchor.messageId, "forward-message")
    }

    func testEveryMessageContentTypeKeepsTheSameExactTapRoute() throws {
        for kind in [
            PushNotificationMediaItem.Kind.image,
            .video,
            .sticker,
            .file,
            .voice,
            .forward
        ] {
            let route = PushNotificationRoutePayload.message(
                owner: owner,
                routeJid: "juliet@example.com",
                conversationType: "regular",
                stanzaId: "archive-\(String(describing: kind))",
                messageId: "message-\(String(describing: kind))",
                stanza: nil,
                senderJid: "juliet@example.com",
                senderNickname: "Juliet",
                groupchat: nil,
                timestamp: sentAt.timeIntervalSinceReferenceDate
            )
            let request = try XCTUnwrap(
                PushNotificationMessageOpenRequestFactory.make(
                    route: route,
                    fallbackConversationType: .regular
                )
            )
            XCTAssertEqual(request.anchor.archivedId, route.stanzaId)
            XCTAssertEqual(request.anchor.messageId, route.messageId)
            XCTAssertEqual(request.anchor.sourceDate, sentAt)
            XCTAssertTrue(request.highlight)
            XCTAssertTrue(request.markReadOnVisible)
        }
    }

    func testLocalRendererPreservesPresentationAttachmentsAndExactRoute() async throws {
        let route = PushNotificationRoutePayload.message(
            owner: owner,
            routeJid: "juliet@example.com",
            conversationType: "regular",
            stanzaId: "archive-rendered",
            messageId: "message-rendered",
            stanza: nil,
            senderJid: "juliet@example.com",
            senderNickname: "Juliet",
            groupchat: nil,
            timestamp: sentAt.timeIntervalSinceReferenceDate
        )
        let plan = RichNotificationPresentationPolicy.plan(
            for: preview(route: route, body: "Rendered body"),
            overrides: RichNotificationNameOverrides(
                conversationName: "Juliet from app",
                senderName: nil,
                editMark: ""
            ),
            metadataName: { _, _ in nil }
        )
        let renderer = LocalRichNotificationContentRenderer(
            avatarData: { _ in nil },
            donateInteractions: false
        )

        let content = await renderer.render(
            plan: plan,
            categoryIdentifier: PushNotificationCategory.message,
            sound: nil,
            attachments: []
        )

        XCTAssertEqual(content.title, "Juliet from app")
        XCTAssertEqual(content.body, "Rendered body")
        XCTAssertEqual(content.categoryIdentifier, PushNotificationCategory.message)
        XCTAssertEqual(content.threadIdentifier, plan.threadIdentifier)
        let decoded = try XCTUnwrap(PushNotificationRoutePayload(userInfo: content.userInfo))
        XCTAssertEqual(decoded, route)
        let request = try XCTUnwrap(
            PushNotificationMessageOpenRequestFactory.make(
                route: decoded,
                fallbackConversationType: .regular
            )
        )
        XCTAssertEqual(request.anchor.archivedId, "archive-rendered")
        XCTAssertEqual(request.anchor.messageId, "message-rendered")
        XCTAssertEqual(request.anchor.sourceDate, sentAt)
    }

    func testAttachmentLoaderCopiesLocalMediaWithoutMutatingItsSourceCache() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(
            "LocalNotificationRichContentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceDirectory = sandbox.appendingPathComponent("source", isDirectory: true)
        let stagingDirectory = sandbox.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: sandbox) }
        let sourceURL = sourceDirectory.appendingPathComponent("avatar.png")
        let imageData = PushNotificationInitialsRenderer.imageData(
            displayName: "Juliet",
            jid: "juliet@example.com"
        )
        try imageData.write(to: sourceURL, options: .atomic)
        let sourceKey = "local-cache://juliet-avatar"
        let loader = RichNotificationAttachmentLoader(
            rootDirectory: stagingDirectory,
            localFileURLsBySource: [sourceKey: sourceURL]
        )

        let attachments = await loader.attachments(
            for: [
                RichNotificationAttachmentCandidate(
                    kind: .image,
                    sourceURL: sourceKey,
                    filename: "avatar.png",
                    mediaType: "image/png"
                )
            ]
        )

        XCTAssertEqual(attachments.count, 1)
        XCTAssertNotEqual(attachments.first?.url, sourceURL)
        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), imageData)
    }

    func testConcurrentAttachmentSweepDoesNotDeleteAnotherActiveRequestDirectory() async throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "LocalNotificationConcurrentLoaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let firstRequestStarted = expectation(description: "first attachment request started")
        let firstURL = try XCTUnwrap(URL(string: "https://cdn.example.com/first.png"))
        let firstImage = PushNotificationInitialsRenderer.imageData(
            displayName: "Juliet",
            jid: "juliet@example.com"
        )
        let heldProtocol = LockedLoaderProtocolReference()
        RichNotificationLoaderURLProtocol.install { request, protocolInstance in
            guard request.url == firstURL else {
                protocolInstance.fail(URLError(.unsupportedURL))
                return
            }
            heldProtocol.store(protocolInstance)
            firstRequestStarted.fulfill()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RichNotificationLoaderURLProtocol.self]
        let loader = RichNotificationAttachmentLoader(
            configuration: configuration,
            rootDirectory: rootDirectory,
            limits: RichNotificationAttachmentLoader.Limits(
                staleDirectoryAge: 0
            )
        )
        let firstTask = Task {
            await loader.attachments(
                for: [
                    RichNotificationAttachmentCandidate(
                        kind: .image,
                        sourceURL: firstURL.absoluteString,
                        filename: "first.png",
                        mediaType: "image/png"
                    )
                ]
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 1)

        let inlineSource = "data:image/png;base64,\(firstImage.base64EncodedString())"
        let secondAttachments = await loader.attachments(
            for: [
                RichNotificationAttachmentCandidate(
                    kind: .image,
                    sourceURL: inlineSource,
                    filename: "second.png",
                    mediaType: "image/png"
                )
            ]
        )

        let firstProtocol = try XCTUnwrap(heldProtocol.load())
        firstProtocol.succeed(
            data: firstImage,
            mimeType: "image/png",
            contentLength: firstImage.count
        )
        let firstAttachments = await firstTask.value

        XCTAssertEqual(secondAttachments.count, 1)
        XCTAssertEqual(
            firstAttachments.count,
            1,
            "A concurrent sweep must hold a lease on every active request directory"
        )
    }

    func testOversizedContentLengthIsRejectedBeforeResponseBodyDownload() async throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "LocalNotificationOversizedLoaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let oversizedURL = try XCTUnwrap(URL(string: "https://cdn.example.com/oversized.mp4"))
        RichNotificationLoaderURLProtocol.install { request, protocolInstance in
            guard request.url == oversizedURL else {
                protocolInstance.fail(URLError(.unsupportedURL))
                return
            }
            protocolInstance.respond(
                mimeType: "video/mp4",
                contentLength: 256
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                protocolInstance.send(Data(repeating: 0x2A, count: 256))
                protocolInstance.finish()
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RichNotificationLoaderURLProtocol.self]
        let loader = RichNotificationAttachmentLoader(
            configuration: configuration,
            rootDirectory: rootDirectory,
            limits: RichNotificationAttachmentLoader.Limits(
                maximumVideoBytes: 64,
                maximumTotalBytes: 64,
                requestTimeout: 1,
                totalDeadline: 1
            )
        )

        let attachments = await loader.attachments(
            for: [
                RichNotificationAttachmentCandidate(
                    kind: .video,
                    sourceURL: oversizedURL.absoluteString,
                    filename: "oversized.mp4",
                    mediaType: "video/mp4"
                )
            ]
        )

        XCTAssertTrue(attachments.isEmpty)
        XCTAssertEqual(
            RichNotificationLoaderURLProtocol.deliveredBodyByteCount,
            0,
            "An oversized Content-Length must cancel the task before body bytes are downloaded"
        )
    }

    func testTotalDeadlineCancelsAnUnfinishedDownload() async throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "LocalNotificationDeadlineLoaderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let slowURL = try XCTUnwrap(URL(string: "https://cdn.example.com/slow.m4a"))
        RichNotificationLoaderURLProtocol.install { request, protocolInstance in
            guard request.url == slowURL else {
                protocolInstance.fail(URLError(.unsupportedURL))
                return
            }
            protocolInstance.respond(
                mimeType: "audio/mp4",
                contentLength: 32
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
                protocolInstance.finish()
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RichNotificationLoaderURLProtocol.self]
        let loader = RichNotificationAttachmentLoader(
            configuration: configuration,
            rootDirectory: rootDirectory,
            limits: RichNotificationAttachmentLoader.Limits(
                requestTimeout: 1,
                totalDeadline: 0.1
            )
        )
        let startedAt = Date()

        let attachments = await loader.attachments(
            for: [
                RichNotificationAttachmentCandidate(
                    kind: .audio,
                    sourceURL: slowURL.absoluteString,
                    filename: "slow.m4a",
                    mediaType: "audio/mp4"
                )
            ]
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertTrue(attachments.isEmpty)
        XCTAssertLessThan(
            elapsed,
            0.4,
            "The total attachment deadline must cancel an in-progress transfer"
        )
    }

    private func preview(
        route: PushNotificationRoutePayload,
        body: String,
        groupName: String? = nil,
        mediaItems: [PushNotificationMediaItem] = []
    ) -> PushNotificationPreview {
        PushNotificationPreview(
            route: route,
            body: body,
            groupName: groupName,
            mediaItems: mediaItems
        )
    }

    private func media(
        _ kind: PushNotificationMediaItem.Kind,
        name: String?,
        type: String?,
        url: String?,
        thumbnail: String? = nil
    ) -> PushNotificationMediaItem {
        PushNotificationMediaItem(
            kind: kind,
            filename: name,
            mediaType: type,
            size: nil,
            duration: nil,
            url: url,
            thumbnailURL: thumbnail
        )
    }
}

private final class LockedLoaderProtocolReference: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RichNotificationLoaderURLProtocol?

    func store(_ value: RichNotificationLoaderURLProtocol) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> RichNotificationLoaderURLProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RichNotificationLoaderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest, RichNotificationLoaderURLProtocol) -> Void

    private static let stateLock = NSLock()
    private static var handler: Handler?
    private static var bodyByteCount = 0

    private let lifecycleLock = NSLock()
    private var stopped = false
    private var responded = false

    static var deliveredBodyByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bodyByteCount
    }

    static func install(_ handler: @escaping Handler) {
        stateLock.lock()
        self.handler = handler
        bodyByteCount = 0
        stateLock.unlock()
    }

    static func reset() {
        stateLock.lock()
        handler = nil
        bodyByteCount = 0
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stateLock.lock()
        let handler = Self.handler
        Self.stateLock.unlock()
        guard let handler else {
            fail(URLError(.resourceUnavailable))
            return
        }
        handler(request, self)
    }

    override func stopLoading() {
        lifecycleLock.lock()
        stopped = true
        lifecycleLock.unlock()
    }

    func respond(mimeType: String, contentLength: Int) {
        guard beginResponseIfActive(),
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Content-Length": String(contentLength)
                ]
              ) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        guard isActive else { return }
        Self.stateLock.lock()
        Self.bodyByteCount += data.count
        Self.stateLock.unlock()
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard isActive else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: Error) {
        guard isActive else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    func succeed(data: Data, mimeType: String, contentLength: Int) {
        respond(mimeType: mimeType, contentLength: contentLength)
        send(data)
        finish()
    }

    private var isActive: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !stopped
    }

    private func beginResponseIfActive() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopped, !responded else { return false }
        responded = true
        return true
    }
}
