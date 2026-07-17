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

    func testZeroSizedVideoMetadataKeepsVideoAndBackplateTimeInsideContainer() {
        assertVideoAndBackplateTimeStayInsideContainer(size: .zero)
    }

    func testSmallVideoMetadataKeepsBackplateTimeInsideContainer() {
        assertVideoAndBackplateTimeStayInsideContainer(size: CGSize(width: 5, height: 5))
    }

    private func assertVideoAndBackplateTimeStayInsideContainer(
        size: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let message = makeVideoMessage(size: size)
        let layout = ChatMessageLayoutCalculator.measure(
            message,
            context: ChatMessageLayoutContext(
                width: 390,
                contentSizeCategory: "UICTContentSizeCategoryL",
                localeIdentifier: "en_US",
                interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
                messageStyle: "no_tail",
                cornerRadius: "16",
                avatarMode: "bottom"
            )
        )
        let attributes = MessagesCollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        layout.apply(to: attributes)
        let cell = makeCell()

        cell.layoutVideosView(with: attributes)
        cell.layoutTimeMarker(with: attributes)

        XCTAssertTrue(attributes.timeMarkerWithBackplate, file: file, line: line)
        XCTAssertEqual(
            ChatMessageFrameGeometryValidator.violations(
                frames: [
                    .init(name: "videos", frame: cell.videosView.frame),
                    .init(name: "time", frame: cell.timeMarker.frame)
                ],
                containerBounds: CGRect(origin: .zero, size: attributes.messageContainerSize)
            ),
            [],
            file: file,
            line: line
        )
        XCTAssertGreaterThan(cell.videosView.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(cell.videosView.frame.height, 0, file: file, line: line)
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

    private func makeVideoMessage(size: CGSize) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: "zero-sized-video",
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "romeo@example.com", displayName: "Romeo"),
            messageId: "zero-sized-video-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: .attributedText(NSAttributedString(
                string: "",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
            )),
            withAuthor: false,
            withAvatar: false,
            reservesAvatarSpace: false,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: true,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "zero-sized-video-archived",
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: false,
            images: [],
            videos: [VideoAttachment(
                primary: "video-reference",
                url: nil,
                size: size,
                duration: 0,
                downloaded: false
            )],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
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
