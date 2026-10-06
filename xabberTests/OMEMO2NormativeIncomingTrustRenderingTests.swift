import UIKit
import XCTest
@testable import xabber

@MainActor
final class OMEMO2NormativeIncomingTrustRenderingTests: XCTestCase {
    private let indexPath = IndexPath(item: 0, section: 0)
    private var context: ChatMessageLayoutContext {
        .init(width: 390, contentSizeCategory: UIContentSizeCategory.large.rawValue,
            localeIdentifier: "en_US", interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
            messageStyle: "bubble", cornerRadius: "16", avatarMode: "bottom")
    }
    private var existingWarning: String {
        let item = MessageStorageItem()
        item.markOmemoUntrustedContactDevicesWarning()
        return item.messageWarningText!
    }

    func testStickerLayoutReservesVisibleWarningWithoutChangingImageSize() {
        let warning = existingWarning
        let plain = ChatMessageLayoutCalculator.measure(datasource(warning: nil), context)
        let warned = ChatMessageLayoutCalculator.measure(datasource(warning: warning), context)
        XCTAssertGreaterThan(warned.warningInlineViewSize.height, 0)
        XCTAssertGreaterThan(warned.warningInlineViewSize.width, 0)
        XCTAssertEqual(warned.imagesInlineViewSize, plain.messageContainerSize)
        XCTAssertEqual(warned.messageContainerSize.height,
            plain.messageContainerSize.height + warned.warningInlineViewSize.height)
        XCTAssertEqual(warned.cellSize.height,
            plain.cellSize.height + warned.warningInlineViewSize.height)
    }

    func testStickerRendererDisplaysExistingWarningBelowUnchangedStickerImage() throws {
        let (controller, collection, cell) = fixture()
        defer { _ = controller }
        let warning = existingWarning
        let message = datasource(warning: warning)
        let layout = ChatMessageLayoutCalculator.measure(message, context)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        layout.apply(to: attributes)
        cell.configure(with: message, at: indexPath, and: collection)
        cell.apply(attributes)

        let label = try warningLabel(in: cell)
        XCTAssertEqual(label.text, warning)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.numberOfLines, 0)
        XCTAssertGreaterThan(label.frame.height, 0)
        XCTAssertGreaterThanOrEqual(label.frame.minY, cell.imageView.frame.maxY)
        XCTAssertLessThanOrEqual(label.frame.maxY, cell.messageContainerView.bounds.height)
        XCTAssertEqual(cell.imageView.frame.size, CGSize(width: 128, height: 64))
    }

    func testStickerChromeReconfigurationAndReuseDoNotLeaveAStaleWarning() throws {
        let (controller, collection, cell) = fixture()
        defer { _ = controller }
        let plain = datasource(warning: nil)
        cell.configure(with: plain, at: indexPath, and: collection)
        let warned = datasource(warning: existingWarning)
        cell.reconfigureContent(with: warned, at: indexPath, and: collection, changeMask: [.chrome])
        let label = try warningLabel(in: cell)
        XCTAssertEqual(label.text, existingWarning)
        XCTAssertFalse(label.isHidden)

        cell.prepareForReuse()
        XCTAssertNil(label.text)
        XCTAssertTrue(label.isHidden)
        cell.configure(with: plain, at: indexPath, and: collection)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        ChatMessageLayoutCalculator.measure(plain, context).apply(to: attributes)
        cell.apply(attributes)
        XCTAssertNil(label.text)
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(cell.imageView.frame.size, CGSize(width: 128, height: 64))
    }

    func testSystemLayoutReservesWarningWithoutChangingTheSystemText() {
        let plain = ChatMessageLayoutCalculator.measure(systemDatasource(warning: nil), context)
        let warned = ChatMessageLayoutCalculator.measure(systemDatasource(warning: existingWarning), context)
        XCTAssertGreaterThan(warned.warningInlineViewSize.height, 0)
        XCTAssertEqual(warned.textInlineViewSize, plain.textInlineViewSize)
        XCTAssertEqual(warned.messageContainerSize.height,
            plain.messageContainerSize.height + warned.warningInlineViewSize.height)
        XCTAssertEqual(warned.cellSize.height, plain.cellSize.height + warned.warningInlineViewSize.height)
    }

    func testSystemRendererDisplaysExistingWarningBelowTheSystemText() throws {
        let (controller, collection, cell) = systemFixture()
        defer { _ = controller }
        let message = systemDatasource(warning: existingWarning)
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        ChatMessageLayoutCalculator.measure(message, context).apply(to: attributes)
        cell.configure(with: message, at: indexPath, and: collection)
        cell.apply(attributes)
        let label = try warningLabel(in: cell)
        XCTAssertEqual(cell.messageLabel.attributedText?.string, "Encrypted timer event")
        XCTAssertEqual(label.text, existingWarning)
        XCTAssertFalse(label.isHidden)
        XCTAssertGreaterThan(label.frame.height, 0)
        XCTAssertGreaterThanOrEqual(label.frame.minY, cell.messageLabel.frame.maxY)
        XCTAssertLessThanOrEqual(label.frame.maxY, cell.messageContainerView.bounds.height)
    }

    func testSystemWarningChromeAndReusePreserveOrdinaryDateRendering() throws {
        let (controller, collection, cell) = systemFixture()
        defer { _ = controller }
        cell.configure(with: systemDatasource(warning: nil), at: indexPath, and: collection)
        cell.reconfigureContent(with: systemDatasource(warning: existingWarning), at: indexPath,
            and: collection, changeMask: [.chrome])
        let label = try warningLabel(in: cell)
        XCTAssertEqual(label.text, existingWarning)
        XCTAssertFalse(label.isHidden)
        cell.prepareForReuse()
        XCTAssertNil(label.text)
        XCTAssertTrue(label.isHidden)
        var date = systemDatasource(warning: nil)
        date.kind = .date(NSAttributedString(string: "Today"))
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: indexPath)
        ChatMessageLayoutCalculator.measure(date, context).apply(to: attributes)
        cell.configure(with: date, at: indexPath, and: collection)
        cell.apply(attributes)
        XCTAssertEqual(cell.messageLabel.attributedText?.string, "Today")
        XCTAssertNil(label.text)
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(attributes.warningInlineViewSize, .zero)
    }

    private func fixture() -> (ChatViewController, MessagesCollectionView, StickerMessageCell) {
        let controller = ChatViewController()
        controller.owner = "n09-ui-owner@example.test"; controller.jid = "n09-ui-peer@example.test"
        let collection = MessagesCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 300),
            collectionViewLayout: MessagesCollectionViewFlowLayout())
        collection.messagesDataSource = controller
        let cell = StickerMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        return (controller, collection, cell)
    }
    private func systemFixture() -> (ChatViewController, MessagesCollectionView, SystemMessageCell) {
        let controller = ChatViewController()
        controller.owner = "n09-ui-owner@example.test"; controller.jid = "n09-ui-peer@example.test"
        let collection = MessagesCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 300),
            collectionViewLayout: MessagesCollectionViewFlowLayout())
        collection.messagesDataSource = controller
        return (controller, collection, SystemMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300)))
    }
    private func warningLabel(in cell: MessageContentCell) throws -> UILabel {
        try XCTUnwrap(cell.messageContainerView.subviews.first(where: {
            $0.accessibilityIdentifier == "message.warning"
        }) as? UILabel)
    }
    private func systemDatasource(warning: String?) -> ChatViewController.Datasource {
        var item = datasource(warning: warning)
        item.kind = .system(NSAttributedString(string: "Encrypted timer event",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)]))
        return item
    }
    private func datasource(warning: String?) -> ChatViewController.Datasource {
        var item = ChatViewController.Datasource(
            primary: "n09-sticker", jid: "n09-ui-peer@example.test", owner: "n09-ui-owner@example.test",
            outgoing: false, sender: Sender(id: "n09-ui-peer@example.test", displayName: "Peer"),
            messageId: "n09-sticker", sentDate: Date(timeIntervalSince1970: 100), editDate: nil,
            kind: .sticker(ImageAttachment(primary: "n09-sticker-reference", url: nil, size: .init(width: 128, height: 64))),
            withAuthor: false, withAvatar: false, error: false, errorType: "", canPinMessage: false,
            canEditMessage: false, canDeleteMessage: true, forwards: [], isOutgoing: false, isEdited: false,
            groupchatAuthorRole: "", groupchatAuthorId: "", groupchatAuthorNickname: "", groupchatAuthorBadge: "",
            isHasAttachedMessages: false, isDownloaded: false, state: .read, searchString: nil, errorMetadata: nil,
            burnDate: -1, afterburnInterval: -1, archivedId: "n09-archive", queryIds: nil, isRead: true,
            selectedSearchResultId: nil, isHadHistoryGap: false, tailed: false, isFakeMessage: false,
            images: [], videos: [], locations: [], contacts: [], files: [], audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"), indicator: .none, avatarUrl: nil, attributedAuthor: nil)
        item.messageWarningText = warning
        return item
    }
}
