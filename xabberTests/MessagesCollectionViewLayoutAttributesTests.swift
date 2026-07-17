import XCTest
@testable import xabber

final class MessagesCollectionViewLayoutAttributesTests: XCTestCase {
    func testCopyPreservesAllGeometryAndHashIdentity() throws {
        let original = makeAttributes()
        let copy = try XCTUnwrap(original.copy() as? MessagesCollectionViewLayoutAttributes)

        XCTAssertTrue(original.isEqual(copy))
        XCTAssertEqual(original.hash, copy.hash)
        XCTAssertEqual(copy.forwardsInlineViewSize.count, 1)
    }

    func testForwardGeometryChangeInvalidatesEqualityAndHash() throws {
        let original = makeAttributes()
        let changed = try XCTUnwrap(original.copy() as? MessagesCollectionViewLayoutAttributes)
        changed.forwardsInlineViewSize = [makeForwardSize(height: 144)]

        XCTAssertFalse(original.isEqual(changed))
        XCTAssertNotEqual(original.hash, changed.hash)
    }

    func testCopyForwardGeometryIsIndependentFromOriginalMutation() throws {
        let original = makeAttributes()
        let copy = try XCTUnwrap(original.copy() as? MessagesCollectionViewLayoutAttributes)

        original.forwardsInlineViewSize = [makeForwardSize(height: 188)]

        XCTAssertEqual(copy.forwardsInlineViewSize.first?.messageContainer.height, 96)
        XCTAssertFalse(original.isEqual(copy))
    }

    private func makeAttributes() -> MessagesCollectionViewLayoutAttributes {
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 32, width: 390, height: 180)
        attributes.messagePrimary = "message"
        attributes.avatarSize = CGSize(width: 32, height: 32)
        attributes.side = .left
        attributes.messageContainerSize = CGSize(width: 260, height: 164)
        attributes.messageContainerMargin = UIEdgeInsets(top: 4, left: 5, bottom: 6, right: 7)
        attributes.messageContainerPadding = UIEdgeInsets(top: 2, left: 3, bottom: 4, right: 5)
        attributes.messageLabelInsets = UIEdgeInsets(top: 3, left: 7, bottom: 5, right: 11)
        attributes.forwardsContainerViewSize = CGSize(width: 224, height: 100)
        attributes.forwardsInlineViewSize = [makeForwardSize(height: 96)]
        attributes.textInlineViewSize = CGSize(width: 180, height: 42)
        attributes.warningInlineViewSize = CGSize(width: 180, height: 28)
        attributes.authorInlineSize = CGSize(width: 120, height: 18)
        attributes.tail = "smooth"
        attributes.cornerRadius = "12"
        attributes.tailWidth = 8
        attributes.timeMarkerSize = CGSize(width: 44, height: 16)
        attributes.timeMarkerIndicator = .read
        attributes.timeMarkerRadius = 7
        attributes.timeMarkerInsets = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
        attributes.inlineContainerSizeInsets = UIEdgeInsets(top: 4, left: 5, bottom: 6, right: 7)
        attributes.inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 3, bottom: 4, right: 5)
        return attributes
    }

    private func makeForwardSize(height: CGFloat) -> MessageAttachmentSizes {
        MessageAttachmentSizes(
            textLabelSize: CGSize(width: 160, height: 34),
            imagesContainerSize: .zero,
            videosContainerSize: .zero,
            locationsContainerSize: .zero,
            contactsContainerSize: .zero,
            filesContainerSize: .zero,
            audiosContainerSize: .zero,
            containerSize: CGSize(width: 200, height: height - 10),
            authorSize: CGSize(width: 100, height: 18),
            messageContainer: CGSize(width: 212, height: height),
            timeMarker: CGSize(width: 36, height: 14)
        )
    }
}
