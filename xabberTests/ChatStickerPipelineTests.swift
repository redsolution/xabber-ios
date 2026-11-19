import XCTest
import XMPPFramework
@testable import xabber

@MainActor
final class ChatStickerPipelineTests: XCTestCase {
    func testWebScheduledStickerKeepsEmojiAndRenderingIdentity() throws {
        let message = try XMPPMessage(xmlString: webScheduledStickerXML)
        let item = MessageStorageItem()
        item.configureIncomingMessage(
            message,
            owner: "receiver@example.test",
            opponent: "sender@example.test",
            outgoing: false,
            isRead: false,
            date: Date()
        )

        let reference = try XCTUnwrap(item.references.first)
        XCTAssertEqual(item.body, "🥳")
        XCTAssertEqual(item.displayAs, .sticker)
        XCTAssertEqual(reference.kind, .sticker)
        XCTAssertEqual(reference.metadata?[ChatStickerWireCodec.packMetadataKey] as? String, "https://files.example.test/party/pack.xml")
        XCTAssertEqual(reference.fileSharingURI, "https://files.example.test/party/party.webp")
        XCTAssertNil(reference.pendingMediaAttachment)
        XCTAssertEqual(ChatStickerWireCodec.inlineThumbnail(in: message), thumbnailData)
        let attachment = try XCTUnwrap(ChatViewController.stickerAttachment(from: [ChatMessageReferenceSnapshot(reference)]))
        XCTAssertEqual(attachment.size, CGSize(width: 512, height: 256))
    }

    func testIncomingStickerLoadsFromReferenceWithoutManifestOrInlineImage() throws {
        let wire = webScheduledStickerXML
            .replacingOccurrences(of: " pack='https://files.example.test/party/pack.xml'", with: "")
            .replacingOccurrences(of: "data:image/png;base64,\(thumbnailData.base64EncodedString())", with: "")
        let message = try XMPPMessage(xmlString: wire)
        let owner = "receiver@example.test"
        let reference = try XCTUnwrap(parseReferences(
            message, primary: "message", jid: "sender@example.test", owner: owner
        ).first)
        XCTAssertEqual(reference.kind, .sticker)
        XCTAssertNil(reference.metadata?[ChatStickerWireCodec.packMetadataKey])
        let attachment = try XCTUnwrap(ChatViewController.stickerAttachment(from: [ChatMessageReferenceSnapshot(reference)]))
        XCTAssertNil(attachment.inlineThumbnail)
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving

        cell.bindSticker(attachment, messagePrimary: "message", displaySize: CGSize(width: 192, height: 96),
                         scale: 2, traitStyle: .light, owner: owner)

        let request = try XCTUnwrap(serving.requests.first)
        XCTAssertTrue(request.isSticker)
        XCTAssertEqual(request.url.absoluteString, "https://files.example.test/party/party.webp")
        XCTAssertEqual(request.owner, owner)
        try XCTUnwrap(serving.subscriptions.first).emit(.success(delivery(color: .green, size: 64)))
        XCTAssertNotNil(cell.imageView.image)
    }

    func testStickerPayloadRoundTripsThroughOneDecorationForRegularAndEncryptedPreparation() throws {
        let descriptor = ChatStickerDescriptor(
            name: "Party",
            packURL: try XCTUnwrap(URL(string: "https://files.example.test/party/pack.xml")),
            imageURL: try XCTUnwrap(URL(string: "https://files.example.test/party/party.webp")),
            emoji: "👩‍🎨",
            width: 512,
            height: 256,
            inlineThumbnail: thumbnailData
        )
        for type in [ClientSynchronizationManager.ConversationType.regular, .omemo] {
            let prepared = try XCTUnwrap(ChatStickerWireCodec.makeMessage(
                descriptor,
                owner: "sender@example.test",
                conversation: "receiver@example.test",
                conversationType: type
            ))
            let wire = try XMPPMessage(xmlString: prepared.xmlString)
            XCTAssertEqual(wire.body, descriptor.emoji)
            XCTAssertEqual(wire.to?.bare, "receiver@example.test")
            XCTAssertEqual(ChatStickerWireCodec.inlineThumbnail(in: wire), thumbnailData)
            let references = parseReferences(wire, primary: "1", jid: "receiver@example.test", owner: "sender@example.test")
            XCTAssertEqual(references.map(\.kind), [.sticker])
            XCTAssertEqual(references.first?.end, descriptor.emoji.utf16.count)
            XCTAssertTrue(wire.xmlString.contains("type=\"decoration\"") || wire.xmlString.contains("type='decoration'"))
        }
    }

    func testStickerRecentProjectionIncludesInlineMiniatureAndEmojiFallback() throws {
        let message = try XMPPMessage(xmlString: webScheduledStickerXML)
        let preview = try XCTUnwrap(LastChatListSyncPreviewParser.projection(
            owner: "receiver@example.test",
            conversationPrimary: "chat",
            lastMessageID: "message",
            messageElement: message
        ))

        XCTAssertTrue(preview.isAttachment)
        XCTAssertEqual(preview.text, "🥳")
        XCTAssertEqual(preview.stickerThumbnail, thumbnailData)
    }

    func testStickerWithoutUsableInlineImageFallsBackToEmoji() throws {
        let message = try XMPPMessage(xmlString: webScheduledStickerXML.replacingOccurrences(
            of: thumbnailData.base64EncodedString(), with: "invalid-thumbnail"
        ))
        let preview = try XCTUnwrap(LastChatListSyncPreviewParser.projection(
            owner: "receiver@example.test",
            conversationPrimary: "chat",
            lastMessageID: "message",
            messageElement: message
        ))

        XCTAssertTrue(preview.isAttachment)
        XCTAssertEqual(preview.text, "🥳")
        XCTAssertNil(preview.stickerThumbnail)
    }

    func testStickerRejectsForeignNamespaceAndNonHTTPImageSource() throws {
        for wire in [
            webScheduledStickerXML.replacingOccurrences(of: "https://xabber.com/protocol/stickers", with: "urn:example:unrecognized"),
            webScheduledStickerXML.replacingOccurrences(of: "https://files.example.test/party/party.webp", with: "file:///private/party.webp"),
            webScheduledStickerXML.replacingOccurrences(
                of: "<name>party.webp</name>",
                with: "<name>party.webp</name><encrypted xmlns='urn:xmpp:esfs:0'/>"
            )
        ] {
            let message = try XMPPMessage(xmlString: wire)
            XCTAssertFalse(ChatStickerWireCodec.containsSticker(in: message))
            XCTAssertNil(ChatStickerWireCodec.inlineThumbnail(in: message))
            XCTAssertFalse(parseReferences(message, primary: "a", jid: "b", owner: "c").contains { $0.kind == .sticker })
        }
    }

    func testStickerShowsEmbeddedMiniatureWhileFullImageIsLoading() throws {
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = RecordingStickerThumbnailServing()
        assertStickerSurfaceIsTransparent(cell)
        let attachment = ImageAttachment(
            primary: "embedded", url: URL(string: "https://files.example.test/party/party.webp"),
            size: CGSize(width: 192, height: 192), inlineThumbnail: thumbnailData
        )

        cell.bindSticker(
            attachment, messagePrimary: "message", displaySize: CGSize(width: 192, height: 192),
            scale: 2, traitStyle: .light
        )

        XCTAssertNotNil(cell.imageView.image)
        assertStickerSurfaceIsTransparent(cell)
        cell.prepareForReuse()
        XCTAssertNil(cell.imageView.image)
        assertStickerSurfaceIsTransparent(cell)
    }

    func testEmbeddedMiniatureRemainsVisibleWithoutConsentButtonWhenFullImageFails() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        let attachment = ImageAttachment(
            primary: "embedded", url: URL(string: "https://outside.example.org/sticker.png"),
            size: CGSize(width: 192, height: 192), inlineThumbnail: thumbnailData
        )
        cell.bindSticker(
            attachment, messagePrimary: "message", displaySize: CGSize(width: 192, height: 192),
            scale: 2, traitStyle: .light, owner: "owner@example.com"
        )
        let miniature = try XCTUnwrap(cell.imageView.image)

        try XCTUnwrap(serving.subscriptions.first).emit(.failure(.loadFailed))

        XCTAssertTrue(cell.imageView.image === miniature)
        XCTAssertFalse(cell.imageView.subviews.contains {
            $0.accessibilityIdentifier == "chat.media.photo.show-external" && !$0.isHidden
        })
        assertStickerSurfaceIsTransparent(cell)
    }

    private var thumbnailData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD7sAAAAASUVORK5CYII=")!
    }

    private var webScheduledStickerXML: String {
        """
        <message xmlns='jabber:client' from='sender@example.test' to='receiver@example.test' type='chat' id='sticker'>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='0'>
            <sticker xmlns='https://xabber.com/protocol/stickers' name='Party' pack='https://files.example.test/party/pack.xml'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file>
                  <name>party.webp</name><media-type>image/webp</media-type><width>512</width><height>256</height>
                  <thumbnail xmlns='urn:xmpp:thumbs:1' uri='data:image/png;base64,\(thumbnailData.base64EncodedString())'/>
                </file>
                <sources><uri>https://files.example.test/party/party.webp</uri></sources>
              </file-sharing>
            </sticker>
          </reference>
          <body>🥳</body>
          <deferred xmlns='https://xabber.com/protocol/schedule' id='schedule' deliver-at='2033-05-18T03:33:20Z'/>
        </message>
        """
    }

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
        XCTAssertEqual(layout.imagesInlineViewSize, renderedSize)
        XCTAssertEqual(layout.messageContainerSize, renderedSize)
        XCTAssertGreaterThan(layout.timeMarkerSize.height, 0)
        XCTAssertEqual(layout.timeMarkerIndicator, .none)
        XCTAssertEqual(layout.cellSize.height, layout.messageContainerSize.height + layout.messageContainerMargin.vertical)
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

    func testTinyStickerTimeMarkerFitsAboveWarningWithoutResizingImage() {
        var message = datasource(sticker: ImageAttachment(primary: "small", size: CGSize(width: 6, height: 12)))
        message.messageWarningText = "Warning"
        message.timeMarkerText = NSAttributedString(
            string: "12:00:00",
            attributes: [.font: UIFont.systemFont(ofSize: 24)]
        )
        let controller = ChatViewController()
        defer { _ = controller }
        controller.owner = message.owner
        controller.jid = message.jid
        let collection = MessagesCollectionView()
        collection.messagesDataSource = controller
        let indexPath = IndexPath(item: 0, section: 0)
        let layout = ChatMessageLayoutCalculator.measure(message, stickerLayoutContext)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        layout.apply(to: attributes)
        let cell = StickerMessageCell(frame: CGRect(origin: .zero, size: layout.cellSize))

        cell.configure(with: message, at: indexPath, and: collection)
        cell.apply(attributes)

        XCTAssertEqual(layout.imagesInlineViewSize, CGSize(width: 6, height: 12))
        XCTAssertEqual(cell.imageView.frame.size, layout.imagesInlineViewSize)
        XCTAssertGreaterThan(layout.timeMarkerSize.width, layout.imagesInlineViewSize.width)
        XCTAssertGreaterThan(layout.messageContainerSize.width, layout.timeMarkerSize.width)
        XCTAssertGreaterThan(layout.warningInlineViewSize.height, 0)
        XCTAssertGreaterThanOrEqual(cell.warningLabel.frame.minY, cell.imageView.frame.maxY)
        XCTAssertLessThan(cell.timeMarker.frame.maxY, cell.warningLabel.frame.minY)
        XCTAssertEqual(cell.warningLabel.frame.maxY, cell.messageContainerView.bounds.maxY)
        XCTAssertEqual(layout.cellSize.height, layout.messageContainerSize.height + layout.messageContainerMargin.vertical)
        XCTAssertTrue(cell.messageContainerView.bounds.contains(cell.timeMarker.frame))
        XCTAssertTrue(cell.bounds.contains(cell.messageContainerView.frame))
        XCTAssertEqual(cell.timeMarker.textLabel.attributedText?.string, "12:00:00")
        XCTAssertNil(cell.timeMarker.indicatorView.image(for: .normal))
        XCTAssertFalse(cell.timeMarker.isHidden)
        XCTAssertTrue(layout.timeMarkerWithBackplate)
        XCTAssertEqual(cell.timeMarker.backgroundColor, UIColor.black.withAlphaComponent(0.25))
        let photoRadius = CommonConfigManager.shared.messageStyleConfig.messageBubbles.noTail.image.timestamp
            .getRadiusFor(index: attributes.cornerRadius).leftBottom
        XCTAssertEqual(cell.timeMarker.layer.cornerRadius, photoRadius)
        assertStickerSurfaceIsTransparent(cell)
    }

    func testOutgoingStickerTimeAndDeliveryIndicatorOverlayBottomRightAndUpdate() throws {
        var message = datasource(sticker: ImageAttachment(primary: "sticker", size: CGSize(width: 120, height: 120)))
        message.outgoing = true
        message.isOutgoing = true
        message.indicator = .sending
        let controller = ChatViewController()
        defer { _ = controller }
        controller.owner = message.owner
        controller.jid = message.jid
        let collection = MessagesCollectionView()
        collection.messagesDataSource = controller
        let indexPath = IndexPath(item: 0, section: 0)
        let layout = ChatMessageLayoutCalculator.measure(message, stickerLayoutContext)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        layout.apply(to: attributes)
        let cell = StickerMessageCell(frame: CGRect(origin: .zero, size: layout.cellSize))

        cell.configure(with: message, at: indexPath, and: collection)
        cell.apply(attributes)
        let sendingImage = try XCTUnwrap(cell.timeMarker.indicatorView.image(for: .normal))
        XCTAssertEqual(layout.timeMarkerIndicator, .sending)
        XCTAssertEqual(layout.messageContainerSize, layout.imagesInlineViewSize)
        XCTAssertEqual(cell.timeMarker.superview, cell.messageContainerView)
        XCTAssertTrue(cell.imageView.frame.contains(cell.timeMarker.frame))
        let rightInset = cell.imageView.frame.maxX - cell.timeMarker.frame.maxX
        let bottomInset = cell.imageView.frame.maxY - cell.timeMarker.frame.maxY
        XCTAssertGreaterThan(rightInset, 0)
        XCTAssertLessThanOrEqual(rightInset, 8)
        XCTAssertGreaterThan(bottomInset, 0)
        XCTAssertLessThanOrEqual(bottomInset, 8)

        message.indicator = .read
        message.timeMarkerText = NSAttributedString(string: "12:01")
        cell.reconfigureContent(with: message, at: indexPath, and: collection, changeMask: [.chrome])

        let readImage = try XCTUnwrap(cell.timeMarker.indicatorView.image(for: .normal))
        XCTAssertFalse(readImage.isEqual(sendingImage))
        XCTAssertEqual(cell.timeMarker.textLabel.attributedText?.string, "12:01")
        XCTAssertEqual(cell.timeMarker.backgroundColor, UIColor.black.withAlphaComponent(0.25))
        assertStickerSurfaceIsTransparent(cell)
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
        assertStickerSurfaceIsTransparent(cell)

        firstSubscription.emit(.success(delivery(color: .red, size: 384)))

        XCTAssertEqual(cell.representedStickerPrimary, "b")
        XCTAssertNil(cell.imageView.image)

        serving.subscriptions[1].emit(.success(delivery(color: .green, size: 384)))
        XCTAssertNotNil(cell.imageView.image)
        assertStickerSurfaceIsTransparent(cell)
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
        assertStickerSurfaceIsTransparent(cell)
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
        assertStickerSurfaceIsTransparent(cell)

        cell.resumeOnscreenWork()
        cell.resumeOnscreenWork()

        XCTAssertEqual(serving.requests.count, 2)
        XCTAssertEqual(serving.requests.last?.displaySize, .init(width: 192, height: 96))
        XCTAssertEqual(serving.activeSubscriptionCount, 1)
    }

    func testFailedRemoteStickerDoesNotOfferImageConsent() throws {
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        cell.bindSticker(
            ImageAttachment(primary: "external", url: URL(string: "https://outside.example.org/sticker.png"), size: CGSize(width: 192, height: 192)),
            messagePrimary: "message",
            displaySize: CGSize(width: 192, height: 192),
            scale: 2,
            traitStyle: .light,
            owner: "owner@example.com"
        )
        let request = try XCTUnwrap(serving.subscriptions.first)
        request.emit(.failure(.loadFailed))
        XCTAssertNil(cell.imageView.image)
        XCTAssertFalse(cell.imageView.subviews.contains {
            $0.accessibilityIdentifier == "chat.media.photo.show-external" && !$0.isHidden
        })

        cell.prepareForReuse()

        XCTAssertFalse(cell.imageView.subviews.contains { !$0.isHidden })
        assertStickerSurfaceIsTransparent(cell)
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
        XCTAssertTrue(request.isSticker)
        let serving = RecordingStickerThumbnailServing()
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        cell.thumbnailPipeline = serving
        cell.bindSticker(ImageAttachment(primary: "sticker", url: url, size: CGSize(width: 8_192, height: 4_096)),
                         messagePrimary: item.messagePrimary, displaySize: request.displaySize.cgSize,
                         scale: 3, traitStyle: .light, owner: item.owner)
        XCTAssertEqual(serving.requests.first, request)
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

    private func assertStickerSurfaceIsTransparent(
        _ cell: StickerMessageCell, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(cell.messageContainerView.bubble.isHidden, file: file, line: line)
        XCTAssertEqual(cell.imageView.backgroundColor, .clear, file: file, line: line)
    }

    private func sticker(primary: String, path: String, size: CGSize) -> ImageAttachment {
        ImageAttachment(
            primary: primary,
            url: URL(string: "https://files.example.com/\(path)"),
            size: size
        )
    }

    private var stickerLayoutContext: ChatMessageLayoutContext {
        ChatMessageLayoutContext(
            width: 390,
            contentSizeCategory: UIContentSizeCategory.large.rawValue,
            localeIdentifier: "en_US",
            interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
            messageStyle: "bubble",
            cornerRadius: "16",
            avatarMode: "bottom"
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
        case .image, .videoPreview, .avatar, .locationSnapshot:
            return false
        }
    }
}
