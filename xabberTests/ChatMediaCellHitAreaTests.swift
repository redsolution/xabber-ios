import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatMediaCellHitAreaTests: XCTestCase {
    private let width: CGFloat = 765.5
    private let indexPath = IndexPath(item: 0, section: 0)

    func testReusedImageCellKeepsImageAndCaptionHittableAfterFinalContentViewGrowth() throws {
        let controller = ChatViewController()
        controller.owner = "media-layout-owner@example.test"
        controller.jid = "media-layout-peer@example.test"
        let collection = MessagesCollectionView()
        collection.messagesDataSource = controller
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 57))
        let text = message(primary: "previous-text", image: false)
        cell.configure(with: text, at: indexPath, and: collection)
        cell.apply(attributes(for: text))
        cell.prepareForReuse()
        let media = message(primary: "exact-image", image: true)
        let mediaAttributes = attributes(for: media)
        cell.configure(with: media, at: indexPath, and: collection)

        // UIKit may apply the new media geometry before finalizing the reused
        // contentView's size. The child hierarchy must follow that final size.
        cell.contentView.frame.size.height = 57
        cell.apply(mediaAttributes)
        cell.frame.size = mediaAttributes.frame.size
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.imagesView.views.count, 1)
        let image = try XCTUnwrap(cell.imagesView.views.first)
        XCTAssertEqual(image.primary, "exact-image-reference")
        XCTAssertGreaterThan(cell.imagesView.frame.height, 400)
        assertBackgroundFillsContentView(cell)
        try assertHitReaches(cell.imagesView, in: cell)
        try assertHitReaches(cell.labelContainer, in: cell)
    }

    func testBackgroundUsesContentViewBoundsInsteadOfItsSuperviewFrame() {
        let cell = MessageContentCell(frame: CGRect(x: 0, y: 0, width: width, height: 455))
        cell.contentView.frame = CGRect(x: 8, y: 12, width: width - 16, height: 431)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = cell.frame
        attributes.messageContainerSize = CGSize(width: 432, height: 447)

        cell.apply(attributes)

        assertBackgroundFillsContentView(cell)
    }

    func testBackgroundFollowsFinalWidthAndShrinkWithoutReapplyingMessageGeometry() {
        let cell = MessageContentCell(frame: CGRect(x: 0, y: 0, width: 390, height: 455))
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = cell.frame
        attributes.messageContainerSize = CGSize(width: 432, height: 447)
        cell.apply(attributes)

        cell.frame.size = CGSize(width: width, height: 57)
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        assertBackgroundFillsContentView(cell)
    }

    func testOrdinaryLayoutPreservesReplySwipeHorizontalDisplacement() {
        let cell = MessageContentCell(frame: CGRect(x: 0, y: 0, width: width, height: 455))
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = cell.frame
        attributes.messageContainerSize = CGSize(width: 432, height: 447)
        cell.apply(attributes)
        cell.backgroundContentView.frame.origin.x = -35

        cell.setNeedsLayout()
        cell.layoutIfNeeded()

        XCTAssertEqual(cell.backgroundContentView.frame.minX, -35,
            "Reply-pan calls layoutIfNeeded while moving this container")
    }

    func testRealReplyPanUsesTheSameLocalOriginAsTheAppliedBackground() {
        let cell = MessageContentCell(frame: CGRect(x: 0, y: 0, width: width, height: 455))
        cell.contentView.frame = CGRect(x: 8, y: 12, width: width - 16, height: 431)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = cell.frame
        attributes.messageContainerSize = CGSize(width: 432, height: 447)
        cell.apply(attributes)
        let pan = ControlledReplyPan()
        cell.contentView.addGestureRecognizer(pan)
        cell.panGesture = pan

        pan.controlledState = .changed
        cell.panGestureObserver()
        XCTAssertEqual(cell.backgroundContentView.frame.minX, -35)
        XCTAssertEqual(cell.backgroundContentView.frame.minY, 0)
        pan.controlledState = .ended
        cell.panGestureObserver()
        XCTAssertEqual(cell.backgroundContentView.frame.minX, 0)
        XCTAssertEqual(cell.backgroundContentView.frame.minY, 0)
    }

    func testRealReplyPanKeepsConfiguredImageAndCaptionHittableAfterFinishing() throws {
        let controller = ChatViewController()
        controller.owner = "media-layout-owner@example.test"
        controller.jid = "media-layout-peer@example.test"
        let collection = MessagesCollectionView()
        collection.messagesDataSource = controller
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 455))
        let media = message(primary: "reply-image", image: true)
        let attributes = attributes(for: media)
        cell.configure(with: media, at: indexPath, and: collection)
        cell.apply(attributes)
        cell.frame.size = attributes.frame.size
        cell.contentView.frame = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        assertBackgroundFillsContentView(cell)
        try assertHitReaches(cell.imagesView, in: cell)
        try assertHitReaches(cell.labelContainer, in: cell)
        let pan = ControlledReplyPan()
        cell.contentView.addGestureRecognizer(pan)
        cell.panGesture = pan

        pan.controlledState = .changed
        cell.panGestureObserver()
        pan.controlledState = .ended
        cell.panGestureObserver()

        assertBackgroundFillsContentView(cell)
        try assertHitReaches(cell.imagesView, in: cell)
        try assertHitReaches(cell.labelContainer, in: cell)
    }

    private func assertHitReaches(_ target: UIView, in cell: TextMessageCell,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: cell)
        XCTAssertTrue(cell.bounds.contains(point), file: file, line: line)
        let hit = try XCTUnwrap(cell.hitTest(point, with: nil), file: file, line: line)
        XCTAssertTrue(hit === target || hit.isDescendant(of: target),
            "A rendered media/caption control must remain inside its ancestor hit area", file: file, line: line)
    }

    private func assertBackgroundFillsContentView(_ cell: MessageContentCell,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let actual = cell.backgroundContentView.frame
        let expected = cell.contentView.bounds
        // Autoresizing aligns frames to physical pixels (the iPad fixture has
        // half-point width while this hosted simulator uses a 3x display).
        let pixel = 1 / UIScreen.main.scale
        XCTAssertEqual(actual.minX, expected.minX, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: pixel, file: file, line: line)
    }

    private func attributes(for message: ChatViewController.Datasource) -> MessagesCollectionViewLayoutAttributes {
        let context = ChatMessageLayoutContext(width: width,
            contentSizeCategory: UIContentSizeCategory.large.rawValue, localeIdentifier: "en_US",
            interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
            messageStyle: "bubble", cornerRadius: "16", avatarMode: "bottom")
        let layout = ChatMessageLayoutCalculator.measure(message, context)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        layout.apply(to: attributes)
        attributes.frame = CGRect(origin: .zero, size: layout.cellSize)
        return attributes
    }

    private func message(primary: String, image: Bool) -> ChatViewController.Datasource {
        .init(primary: primary, jid: "media-layout-peer@example.test", owner: "media-layout-owner@example.test",
              outgoing: true, sender: Sender(id: "media-layout-owner@example.test", displayName: "Owner"),
              messageId: primary, sentDate: Date(timeIntervalSince1970: 100), editDate: nil,
              kind: .attributedText(NSAttributedString(string: image ? "QA3 exact image caption" : "Previous text",
                  attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])),
              withAuthor: false, withAvatar: false, error: false, errorType: "", canPinMessage: false,
              canEditMessage: false, canDeleteMessage: true, forwards: [], isOutgoing: true, isEdited: false,
              groupchatAuthorRole: "", groupchatAuthorId: "", groupchatAuthorNickname: "", groupchatAuthorBadge: "",
              isHasAttachedMessages: false, isDownloaded: true, state: .read, searchString: nil, errorMetadata: nil,
              burnDate: -1, afterburnInterval: -1, archivedId: "archive-" + primary, queryIds: nil, isRead: true,
              selectedSearchResultId: nil, isHadHistoryGap: false, tailed: false, isFakeMessage: false,
              images: image ? [.init(primary: "exact-image-reference", url: nil, size: .init(width: 64, height: 64))] : [],
              videos: [], locations: [], contacts: [], files: [], audios: [],
              timeMarkerText: NSAttributedString(string: "12:00"), indicator: .none, avatarUrl: nil, attributedAuthor: nil)
    }
}

private final class ControlledReplyPan: UIPanGestureRecognizer {
    var controlledState: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { controlledState }
        set { controlledState = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: -35, y: 0) }
}

