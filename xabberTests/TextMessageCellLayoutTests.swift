import XCTest
@testable import xabber

@MainActor
final class TextMessageCellLayoutTests: XCTestCase {
    func testSingleLineLabelContainerUsesMeasuredTextHeight() {
        let cell = makeCell()
        let attributes = makeAttributes(textSize: CGSize(width: 180, height: 20))

        cell.layoutLabelView(with: attributes)

        XCTAssertEqual(cell.labelContainer.frame.height, 28)
        XCTAssertEqual(cell.messageLabel.frame, CGRect(x: 7, y: 3, width: 180, height: 20))
    }

    func testThirtyLineLabelContainerUsesMeasuredTextHeight() {
        let cell = makeCell()
        let attributes = makeAttributes(textSize: CGSize(width: 240, height: 600))

        cell.layoutLabelView(with: attributes)

        XCTAssertEqual(cell.labelContainer.frame.height, 608)
        XCTAssertEqual(cell.messageLabel.frame.height, 600)
    }

    func testWarningBeginsAfterTextForTextAndMediaMessage() {
        let cell = makeCell()
        let attributes = makeAttributes(textSize: CGSize(width: 210, height: 84))
        attributes.authorInlineSize = CGSize(width: 120, height: 18)
        attributes.imagesInlineViewSize = CGSize(width: 240, height: 180)
        attributes.warningInlineViewSize = CGSize(width: 210, height: 34)

        cell.layoutLabelView(with: attributes)
        cell.layoutWarningLabel(with: attributes)

        XCTAssertEqual(cell.labelContainer.frame.minY, 198)
        XCTAssertEqual(cell.labelContainer.frame.height, 92)
        XCTAssertEqual(cell.warningLabel.frame.minY, cell.labelContainer.frame.maxY)
        XCTAssertFalse(cell.labelContainer.frame.intersects(cell.warningLabel.frame))
    }

    func testRepeatedApplyWithSameAttributesDoesNotMoveFrames() {
        let cell = makeCell()
        let attributes = makeAttributes(textSize: CGSize(width: 180, height: 42))
        attributes.frame = CGRect(x: 0, y: 0, width: 390, height: 110)
        attributes.messageContainerSize = CGSize(width: 240, height: 96)
        attributes.timeMarkerSize = CGSize(width: 44, height: 16)

        cell.apply(attributes)
        let first = snapshot(cell)
        cell.apply(attributes)

        XCTAssertEqual(snapshot(cell), first)
    }

    func testGeometryValidatorAcceptsFiniteContainedFrames() {
        let violations = ChatMessageFrameGeometryValidator.violations(
            frames: [
                .init(name: "text", frame: CGRect(x: 8, y: 12, width: 160, height: 42)),
                .init(name: "time", frame: CGRect(x: 170, y: 72, width: 42, height: 16))
            ],
            containerBounds: CGRect(x: 0, y: 0, width: 220, height: 96)
        )

        XCTAssertTrue(violations.isEmpty)
    }

    func testGeometryValidatorReportsNegativeNonFiniteAndOversizedFrames() {
        let violations = ChatMessageFrameGeometryValidator.violations(
            frames: [
                .init(name: "negative", frame: CGRect(x: 0, y: 0, width: -1, height: 10)),
                .init(name: "nan", frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)),
                .init(name: "oversized", frame: CGRect(x: 0, y: 0, width: 221, height: 10))
            ],
            containerBounds: CGRect(x: 0, y: 0, width: 220, height: 96)
        )

        XCTAssertEqual(violations, [
            .negativeSize(name: "negative"),
            .nonFinite(name: "nan"),
            .outsideContainer(name: "oversized")
        ])
    }

    func testWidthChangeReappliesGeometryWithoutStaleOrInvalidFrames() {
        let cell = makeCell()
        let portrait = makeAttributes(textSize: CGSize(width: 210, height: 84))
        portrait.frame = CGRect(x: 0, y: 0, width: 390, height: 150)
        portrait.messageContainerSize = CGSize(width: 280, height: 136)
        portrait.timeMarkerSize = CGSize(width: 44, height: 16)
        cell.apply(portrait)
        let portraitLabelFrame = cell.labelContainer.frame

        let landscape = makeAttributes(textSize: CGSize(width: 340, height: 42))
        landscape.frame = CGRect(x: 0, y: 0, width: 844, height: 110)
        landscape.messageContainerSize = CGSize(width: 420, height: 96)
        landscape.timeMarkerSize = CGSize(width: 44, height: 16)
        cell.apply(landscape)

        XCTAssertNotEqual(cell.labelContainer.frame, portraitLabelFrame)
        XCTAssertEqual(cell.labelContainer.frame.size, CGSize(width: 358, height: 50))
        XCTAssertTrue([
            cell.labelContainer.frame,
            cell.messageLabel.frame,
            cell.timeMarker.frame
        ].allSatisfy { frame in
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.size.width.isFinite && frame.size.height.isFinite
        })
    }

    private func makeCell() -> TextMessageCell {
        TextMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
    }

    private func makeAttributes(textSize: CGSize) -> MessagesCollectionViewLayoutAttributes {
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.textInlineViewSize = textSize
        attributes.messageLabelInsets = UIEdgeInsets(top: 3, left: 7, bottom: 5, right: 11)
        attributes.messageContainerSize = CGSize(width: 280, height: 680)
        return attributes
    }

    private func snapshot(_ cell: TextMessageCell) -> [CGRect] {
        [
            cell.labelContainer.frame,
            cell.messageLabel.frame,
            cell.warningLabel.frame,
            cell.timeMarker.frame,
            cell.containerView.frame
        ]
    }
}
