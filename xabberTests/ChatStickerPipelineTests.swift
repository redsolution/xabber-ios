import XCTest
@testable import xabber

@MainActor
final class ChatStickerPipelineTests: XCTestCase {
    func testLargeStickerUsesBoundedImmutableLayoutAndDownsampleRequest() throws {
        let attachment = ImageAttachment(
            primary: "sticker",
            url: URL(string: "https://files.example.com/large-sticker.png"),
            size: CGSize(width: 8_192, height: 4_096)
        )
        let message = datasource(sticker: attachment)
        let context = ChatMessageLayoutContext(
            width: 390,
            contentSizeCategory: UIContentSizeCategory.large.rawValue,
            localeIdentifier: "en_US",
            interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
            messageStyle: "bubble",
            cornerRadius: "16",
            avatarMode: "bottom"
        )

        let layout = ChatMessageLayoutCalculator.measure(message, context)
        let renderedSize = ChatStickerLayoutPolicy.renderedSize(
            sourceSize: attachment.size,
            availableWidth: 314
        )
        let request = ChatThumbnailRequest(
            url: try XCTUnwrap(attachment.url),
            displaySize: ChatCollectionPrefetchSize(
                width: Double(renderedSize.width),
                height: Double(renderedSize.height)
            ),
            scale: 3,
            traitStyle: .light
        )

        XCTAssertEqual(renderedSize, CGSize(width: 192, height: 96))
        XCTAssertEqual(layout.messageContainerSize, renderedSize)
        XCTAssertEqual(layout.cellSize.height, renderedSize.height + layout.messageContainerMargin.vertical)
        XCTAssertEqual(request.pixelSize, ChatCollectionPrefetchSize(width: 576, height: 288))
        XCTAssertTrue(request.accepts(pixelSize: .init(width: 576, height: 288)))
        XCTAssertFalse(request.accepts(pixelSize: .init(width: 8_192, height: 4_096)))
        let identicalKey = ChatMessageLayoutKey(
            message: datasource(sticker: attachment),
            context: context
        )
        let changedKey = ChatMessageLayoutKey(
            message: datasource(sticker: ImageAttachment(
                primary: "sticker",
                url: attachment.url,
                size: CGSize(width: 4_096, height: 4_096)
            )),
            context: context
        )
        XCTAssertEqual(ChatMessageLayoutKey(message: message, context: context), identicalKey)
        XCTAssertNotEqual(identicalKey.revision, changedKey.revision)
    }

    func testStickerBindingCancelsOldRequestAndRejectsDelayedReuseCompletion() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        let first = sticker(primary: "a", path: "a.png", size: CGSize(width: 256, height: 256))
        let second = sticker(primary: "b", path: "b.png", size: CGSize(width: 256, height: 256))

        cell.bindSticker(
            first,
            messagePrimary: "message-a",
            displaySize: CGSize(width: 192, height: 192),
            scale: 2,
            traitStyle: .light
        )
        let firstSubscription = try XCTUnwrap(serving.subscriptions.first)
        cell.bindSticker(
            second,
            messagePrimary: "message-b",
            displaySize: CGSize(width: 192, height: 192),
            scale: 2,
            traitStyle: .light
        )

        XCTAssertEqual(firstSubscription.cancelCount, 1)
        XCTAssertEqual(serving.requests.count, 2)
        XCTAssertEqual(cell.representedStickerPrimary, "b")
        XCTAssertNil(cell.imageView.image)
        XCTAssertEqual(cell.imageView.backgroundColor, ChatStickerPlaceholder.color)

        firstSubscription.emit(.success(delivery(color: .red, size: 384)))

        XCTAssertEqual(cell.representedStickerPrimary, "b")
        XCTAssertNil(cell.imageView.image)

        serving.subscriptions[1].emit(.success(delivery(color: .green, size: 384)))
        XCTAssertNotNil(cell.imageView.image)
    }

    func testStickerIdentityChangeCancelsOldRequestBeforeNewGeometryExists() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        cell.bindSticker(
            sticker(primary: "a", path: "a.png", size: CGSize(width: 256, height: 256)),
            messagePrimary: "message-a",
            displaySize: CGSize(width: 192, height: 192),
            scale: 2,
            traitStyle: .light
        )
        let oldSubscription = try XCTUnwrap(serving.subscriptions.first)

        cell.bindSticker(
            sticker(primary: "b", path: "b.png", size: CGSize(width: 256, height: 256)),
            messagePrimary: "message-b",
            displaySize: .zero,
            scale: 2,
            traitStyle: .light
        )
        oldSubscription.emit(.success(delivery(color: .red, size: 384)))

        XCTAssertEqual(oldSubscription.cancelCount, 1)
        XCTAssertEqual(cell.representedStickerPrimary, "b")
        XCTAssertNil(cell.imageView.image)
        XCTAssertEqual(cell.imageView.backgroundColor, ChatStickerPlaceholder.color)
        XCTAssertEqual(serving.requests.count, 1)
    }

    func testStickerRetryFailureReuseKeepsOneSubviewAndOneActiveRequest() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        let attachment = sticker(primary: "sticker", path: "sticker.png", size: CGSize(width: 512, height: 512))
        let initialSubviewCount = cell.messageContainerView.subviews.count

        for attempt in 0..<20 {
            cell.bindSticker(
                attachment,
                messagePrimary: "message",
                displaySize: CGSize(width: 192, height: 192),
                scale: 2,
                traitStyle: .dark
            )
            let subscription = try XCTUnwrap(serving.subscriptions.last)
            subscription.emit(.failure(.loadFailed))
            XCTAssertEqual(cell.messageContainerView.subviews.count, initialSubviewCount)
            XCTAssertLessThanOrEqual(serving.activeSubscriptionCount, 1, "attempt \(attempt)")
        }

        XCTAssertEqual(serving.requests.count, 20)
        XCTAssertEqual(cell.messageContainerView.subviews.count, initialSubviewCount)
    }

    func testStickerDisappearanceCancelsAndAppearanceResumesOneBoundedRequest() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        let attachment = sticker(
            primary: "sticker",
            path: "sticker.png",
            size: CGSize(width: 8_192, height: 4_096)
        )
        cell.bindSticker(
            attachment,
            messagePrimary: "message",
            displaySize: CGSize(width: 192, height: 96),
            scale: 3,
            traitStyle: .light
        )
        let firstSubscription = try XCTUnwrap(serving.subscriptions.first)

        cell.cancelOffscreenWork()

        XCTAssertEqual(firstSubscription.cancelCount, 1)
        XCTAssertEqual(serving.activeSubscriptionCount, 0)
        XCTAssertNil(cell.imageView.image)
        XCTAssertEqual(cell.imageView.backgroundColor, ChatStickerPlaceholder.color)

        cell.resumeOnscreenWork()
        cell.resumeOnscreenWork()

        XCTAssertEqual(serving.requests.count, 2)
        XCTAssertEqual(serving.requests.last?.displaySize, .init(width: 192, height: 96))
        XCTAssertEqual(serving.activeSubscriptionCount, 1)
    }

    func testStickerPrefetchUsesSameBoundedRequestAsVisibleBindingAndNoDocumentResource() throws {
        let url = try XCTUnwrap(URL(string: "https://files.example.com/sticker.png"))
        let item = ChatCollectionPrefetchItem(
            messagePrimary: "message",
            owner: "owner@example.com",
            jid: "alexey@example.com",
            avatarURL: nil,
            sticker: ChatCollectionPrefetchImageReference(
                primary: "sticker",
                url: url,
                size: ChatCollectionPrefetchSize(width: 8_192, height: 4_096)
            ),
            images: [],
            videos: [],
            locations: [],
            contacts: []
        )
        let context = ChatCollectionPrefetchContext.empty(
            conversationKey: .init(
                owner: "owner@example.com",
                jid: "alexey@example.com",
                conversationType: "regular"
            ),
            mediaContainerSize: .init(width: 314, height: 314),
            screenScale: 3,
            traitStyle: .light
        )

        let resources = ChatCollectionPrefetchPlanner.resources(
            for: item,
            indexPath: IndexPath(item: 0, section: 0),
            context: context
        )
        let request = try XCTUnwrap(resources.compactMap { resource -> ChatThumbnailRequest? in
            guard case .image(let identity, let request) = resource,
                  identity.kind == .sticker else {
                return nil
            }
            return request
        }.first)

        XCTAssertEqual(request.displaySize, .init(width: 192, height: 96))
        XCTAssertEqual(request.pixelSize, .init(width: 576, height: 288))
        XCTAssertEqual(resources.filter(\.isFullDocumentResource).count, 0)
    }

    func testStickerReferenceMappingRestoresStickerKindWithStableIdentity() throws {
        let reference = MessageReferenceStorageItem()
        reference.primary = "sticker-reference"
        reference.owner = "owner@example.com"
        reference.jid = "alexey@example.com"
        reference.kind_ = MessageReferenceStorageItem.Kind.media.rawValue
        reference.mimeType = "image/png"
        reference.url = "https://files.example.com/sticker.png"
        reference.metadata = [
            "width": 512,
            "height": 256,
            "name": "Memoji"
        ]

        let attachment = try XCTUnwrap(
            ChatViewController.stickerAttachment(
                from: [ChatMessageReferenceSnapshot(reference)]
            )
        )

        XCTAssertEqual(attachment.primary, "sticker-reference")
        XCTAssertEqual(attachment.url?.absoluteString, "https://files.example.com/sticker.png")
        XCTAssertEqual(attachment.size, CGSize(width: 512, height: 256))
    }

    private func sticker(primary: String, path: String, size: CGSize) -> ImageAttachment {
        ImageAttachment(
            primary: primary,
            url: URL(string: "https://files.example.com/\(path)"),
            size: size
        )
    }

    private func datasource(sticker: ImageAttachment) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "message",
            jid: "alexey@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "alexey@example.com", displayName: "Alexey"),
            messageId: "message-id",
            sentDate: Date(timeIntervalSince1970: 100),
            editDate: nil,
            kind: .sticker(sticker),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: false,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "archive",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            locations: [],
            contacts: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }

    private func delivery(color: UIColor, size: Int) -> ChatThumbnailDelivery {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return ChatThumbnailDelivery(
            image: image,
            pixelSize: .init(width: Double(size), height: Double(size)),
            source: .loader
        )
    }
}

private final class RecordingStickerThumbnailServing: ChatThumbnailServing {
    private(set) var requests: [ChatThumbnailRequest] = []
    private(set) var subscriptions: [RecordingStickerThumbnailSubscription] = []

    var activeSubscriptionCount: Int {
        subscriptions.filter { $0.cancelCount == 0 && !$0.didComplete }.count
    }

    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription {
        let subscription = RecordingStickerThumbnailSubscription(completion: completion)
        requests.append(request)
        subscriptions.append(subscription)
        return subscription
    }
}

private final class RecordingStickerThumbnailSubscription: ChatThumbnailSubscription {
    private var completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    private(set) var cancelCount = 0
    private(set) var didComplete = false

    init(completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?) {
        self.completion = completion
    }

    func emit(_ result: Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) {
        guard !didComplete else { return }
        didComplete = true
        completion?(result)
    }

    func cancel() {
        guard completion != nil else { return }
        cancelCount += 1
        completion = nil
    }
}

private extension ChatCollectionPrefetchResource {
    var isFullDocumentResource: Bool {
        switch self {
        case .image, .videoPreview, .avatar, .locationSnapshot, .pageWarmup:
            return false
        }
    }
}
