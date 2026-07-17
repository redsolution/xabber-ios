import XCTest
import MaterialComponents.MDCPalettes
@testable import xabber

@MainActor
final class InlineForwardLayoutOrderingTests: XCTestCase {
    func testConfigureThenApplyMatchesApplyThenConfigure() throws {
        let attributes = makeAttributes()
        let message = makeMessage()

        let configureFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 100))
        configureFirst.configure([message], palette: .blue, delegate: nil)
        configureFirst.layout(with: attributes)

        let applyFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 100))
        applyFirst.layout(with: attributes)
        applyFirst.configure([message], palette: .blue, delegate: nil)

        XCTAssertEqual(try snapshot(configureFirst), try snapshot(applyFirst))
        XCTAssertEqual(try XCTUnwrap(configureFirst.inlineViews.first).messagePrimary, message.primary)
    }

    func testRepeatedApplyDoesNotMoveForwardFrames() throws {
        let view = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 100))
        let attributes = makeAttributes()
        view.configure([makeMessage()], palette: .blue, delegate: nil)
        view.layout(with: attributes)
        let first = try snapshot(view)

        view.layout(with: attributes)

        XCTAssertEqual(try snapshot(view), first)
    }

    func testContentBeforeUpdatedApplyReflowsExistingAttachmentFrames() throws {
        let message = makeMessage(
            files: [FileAttachment(
                primary: "file-1",
                url: URL(fileURLWithPath: "/tmp/report.pdf"),
                size: 1_024,
                name: "report.pdf",
                downloaded: true
            )]
        )
        let oldAttributes = makeAttributes(fileSize: CGSize(width: 120, height: 44))
        let newAttributes = makeAttributes(fileSize: CGSize(width: 200, height: 44))

        let configureFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 100))
        configureFirst.layout(with: oldAttributes)
        configureFirst.configure([message], palette: .blue, delegate: nil)
        configureFirst.updateContent([message], palette: .blue, delegate: nil)
        configureFirst.layout(with: newAttributes)

        let applyFirst = InlineForwardsContainerView(frame: CGRect(x: 0, y: 0, width: 224, height: 100))
        applyFirst.layout(with: newAttributes)
        applyFirst.configure([message], palette: .blue, delegate: nil)

        XCTAssertEqual(try snapshot(configureFirst).fileFrame, try snapshot(applyFirst).fileFrame)
        XCTAssertEqual(try XCTUnwrap(snapshot(configureFirst).fileFrame).width, 200)
    }

    func testContentUpdateDoesNotSynchronouslyInvokeLayoutSubviews() {
        let view = LayoutCountingInlineMessageAttachmentView(frame: CGRect(x: 0, y: 0, width: 212, height: 96))
        view.setupSubviews()
        view.layoutInvocationCount = 0

        view.updateContent(makeMessage(), palette: .blue)

        XCTAssertEqual(view.layoutInvocationCount, 0)
    }

    private func snapshot(_ view: InlineForwardsContainerView) throws -> ForwardSnapshot {
        let item = try XCTUnwrap(view.inlineViews.first)
        return ForwardSnapshot(
            itemFrame: item.frame,
            containerFrame: item.containerView.frame,
            labelContainerFrame: item.labelContainer.frame,
            messageLabelFrame: item.messageLabel.frame,
            messagePrimary: item.messagePrimary,
            text: item.messageLabel.attributedText?.string,
            fileFrame: item.filesView.views.first?.frame
        )
    }

    private func makeAttributes(fileSize: CGSize = .zero) -> MessagesCollectionViewLayoutAttributes {
        let attributes = MessagesCollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.side = .left
        attributes.cornerRadius = "12"
        attributes.messageLabelInsets = UIEdgeInsets(top: 3, left: 7, bottom: 5, right: 11)
        attributes.inlineContainerSizeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 2)
        attributes.inlineContainerSizePadding = UIEdgeInsets(top: 2, left: 2, bottom: 0, right: 2)
        attributes.forwardsInlineViewSize = [MessageAttachmentSizes(
            textLabelSize: CGSize(width: 160, height: 34),
            imagesContainerSize: .zero,
            videosContainerSize: .zero,
            locationsContainerSize: .zero,
            contactsContainerSize: .zero,
            filesContainerSize: fileSize,
            audiosContainerSize: .zero,
            containerSize: CGSize(width: 200, height: 86),
            authorSize: CGSize(width: 100, height: 18),
            messageContainer: CGSize(width: 212, height: 96),
            timeMarker: CGSize(width: 36, height: 14)
        )]
        return attributes
    }

    private func makeMessage(files: [FileAttachment] = []) -> MessageAttachment {
        MessageAttachment(
            primary: "forward-1",
            author: "Alexey",
            jid: "alexey@example.com",
            outgoing: false,
            textMessage: NSAttributedString(string: "Forward body"),
            images: [],
            videos: [],
            files: files,
            audios: [],
            timeMarker: NSAttributedString(string: "12:30"),
            subforwards: []
        )
    }
}

private struct ForwardSnapshot: Equatable {
    let itemFrame: CGRect
    let containerFrame: CGRect
    let labelContainerFrame: CGRect
    let messageLabelFrame: CGRect
    let messagePrimary: String
    let text: String?
    let fileFrame: CGRect?
}

private final class LayoutCountingInlineMessageAttachmentView: InlineMessageAttachmentView {
    var layoutInvocationCount = 0

    override func layoutSubviews() {
        layoutInvocationCount += 1
        super.layoutSubviews()
    }
}
