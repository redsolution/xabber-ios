import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryMessageNavigationTests: XCTestCase {
    func testRequestBuilderPreservesRouteAndAnchorMetadata() throws {
        let sourceDate = Date(timeIntervalSince1970: 1_711_283_200)
        let item = galleryItem(
            owner: "juliet@example.com",
            jid: "room@example.com",
            conversationType: .group,
            messagePrimary: "message-primary",
            archiveId: "archive-id",
            sourceDate: sourceDate
        )

        let request = try XCTUnwrap(MediaGalleryMessageNavigationRequestBuilder.request(for: item))

        XCTAssertEqual(request.owner, "juliet@example.com")
        XCTAssertEqual(request.chatJid, "room@example.com")
        XCTAssertEqual(request.conversationType, .group)
        XCTAssertEqual(request.anchor.messagePrimary, "message-primary")
        XCTAssertEqual(request.anchor.archivedId, "archive-id")
        XCTAssertEqual(request.anchor.sourceDate, sourceDate)
        XCTAssertTrue(request.highlight)
        XCTAssertFalse(request.markReadOnVisible)
        XCTAssertEqual(request.source, .mediaGallery)
        XCTAssertEqual(request.targetResolution, .anchor)
    }

    func testRequestBuilderKeepsAvailableAnchorAndNormalizesBlankValues() throws {
        let archiveOnly = galleryItem(messagePrimary: "  ", archiveId: " archive-id ")
        let primaryOnly = galleryItem(messagePrimary: " message-primary ", archiveId: "  ")

        let archiveRequest = try XCTUnwrap(
            MediaGalleryMessageNavigationRequestBuilder.request(for: archiveOnly)
        )
        let primaryRequest = try XCTUnwrap(
            MediaGalleryMessageNavigationRequestBuilder.request(for: primaryOnly)
        )

        XCTAssertNil(archiveRequest.anchor.messagePrimary)
        XCTAssertEqual(archiveRequest.anchor.archivedId, "archive-id")
        XCTAssertEqual(primaryRequest.anchor.messagePrimary, "message-primary")
        XCTAssertNil(primaryRequest.anchor.archivedId)
    }

    func testMissingRouteOrAnchorFieldsDisableJump() {
        XCTAssertNil(MediaGalleryMessageNavigationRequestBuilder.request(
            for: galleryItem(owner: "", messagePrimary: "message", archiveId: "archive")
        ))
        XCTAssertNil(MediaGalleryMessageNavigationRequestBuilder.request(
            for: galleryItem(jid: "", messagePrimary: "message", archiveId: "archive")
        ))
        XCTAssertNil(MediaGalleryMessageNavigationRequestBuilder.request(
            for: galleryItem(messagePrimary: "", archiveId: "")
        ))
    }

    func testSameActiveChatRoutesLocally() throws {
        let item = galleryItem()
        let request = try XCTUnwrap(MediaGalleryMessageNavigationRequestBuilder.request(for: item))
        let activeChat = ChatViewController()
        activeChat.owner = request.owner
        activeChat.jid = request.chatJid
        activeChat.conversationType = request.conversationType
        var locallyHandledRequest: ChatOpenMessageRequest?
        var appRouteCallCount = 0
        let router = MediaGalleryMessageNavigationRouter(
            activeChatProvider: { _, _ in activeChat },
            activeChatHandler: { _, _, request in
                locallyHandledRequest = request
            },
            appRouteHandler: { _, _ in
                appRouteCallCount += 1
                return true
            }
        )

        let result = router.route(request, from: UIViewController())

        XCTAssertEqual(result, .activeChat)
        XCTAssertEqual(locallyHandledRequest, request)
        XCTAssertEqual(appRouteCallCount, 0)
    }

    func testInactiveChatBuildsChatMessageRouteForNavigationStack() throws {
        let item = galleryItem(conversationType: .group)
        let request = try XCTUnwrap(MediaGalleryMessageNavigationRequestBuilder.request(for: item))
        var routedRequest: ChatOpenMessageRequest?
        let router = MediaGalleryMessageNavigationRouter(
            activeChatProvider: { _, _ in nil },
            activeChatHandler: { _, _, _ in
                XCTFail("Inactive chat must not use the local handler")
            },
            appRouteHandler: { route, _ in
                guard case let .chatMessage(
                    owner,
                    jid,
                    conversationType,
                    openMessageRequest,
                    configure
                ) = route else {
                    return false
                }
                XCTAssertEqual(owner, request.owner)
                XCTAssertEqual(jid, request.chatJid)
                XCTAssertEqual(conversationType, request.conversationType)
                XCTAssertNil(configure)
                routedRequest = openMessageRequest
                return true
            }
        )

        let result = router.route(request, from: UIViewController())

        XCTAssertEqual(result, .navigationStack)
        XCTAssertEqual(routedRequest, request)
    }

    func testBaseGalleryExposesSharedJumpMethodAndSkipsInvalidItem() {
        let router = FakeMediaGalleryMessageNavigationRouter()
        let controller = BaseMediaGalleryForChatViewController()
        controller.messageNavigationRouter = router
        let valid = galleryItem()
        let invalid = galleryItem(messagePrimary: "", archiveId: "")

        XCTAssertTrue(controller.canOpenContainingMessage(for: valid))
        XCTAssertEqual(controller.openContainingMessage(for: valid), .navigationStack)
        XCTAssertEqual(router.requests.count, 1)
        XCTAssertEqual(router.requests.first?.source, .mediaGallery)

        XCTAssertFalse(controller.canOpenContainingMessage(for: invalid))
        XCTAssertEqual(controller.openContainingMessage(for: invalid), .unavailable)
        XCTAssertEqual(router.requests.count, 1)
    }

    func testMediaGalleryUsesTransientHighlightWithoutChangingSuppressedSources() {
        XCTAssertTrue(ChatOpenMessageRequestSource.mediaGallery.usesTransientHighlight)
        XCTAssertTrue(
            ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: .mediaGallery)
        )
        XCTAssertTrue(
            ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: .pushNotification)
        )
        XCTAssertTrue(
            ChatOpenMessageRequestHandlingPolicy.shouldHonorMessageAnchorRequest(source: .mentionNotification)
        )
    }

    private func galleryItem(
        owner: String = "owner@example.com",
        jid: String = "contact@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        messagePrimary: String = "message-primary",
        archiveId: String = "archive-id",
        sourceDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .file,
            primary: "attachment",
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            date: sourceDate,
            filename: "document.pdf",
            url: URL(string: "https://gallery.example/document.pdf"),
            messagePrimary: messagePrimary,
            archiveId: archiveId,
            isDownloaded: false,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: 1_024,
            formattedByteSize: "1 KB",
            durationSeconds: nil,
            formattedDuration: nil,
            previewURL: nil,
            previewCacheIdentity: nil,
            mediaType: "application/pdf",
            decodedURL: nil,
            pcm: [],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }
}

@MainActor
private final class FakeMediaGalleryMessageNavigationRouter: MediaGalleryMessageNavigationRouting {
    private(set) var requests: [ChatOpenMessageRequest] = []

    func route(
        _ request: ChatOpenMessageRequest,
        from presenter: UIViewController
    ) -> MediaGalleryMessageNavigationRouteResult {
        requests.append(request)
        return .navigationStack
    }
}
