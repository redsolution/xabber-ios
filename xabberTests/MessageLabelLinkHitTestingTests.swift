import XCTest
@testable import xabber

@MainActor
final class MessageLabelLinkHitTestingTests: XCTestCase {
    func testAttributedLinkInvokesExactlyOneURLCallback() {
        let (label, delegate) = makeLinkedLabel(destination: "https://one.example")

        XCTAssertTrue(label.handleGesture(CGPoint(x: 4, y: 10)))
        XCTAssertEqual(delegate.urls, [URL(string: "https://one.example")!])
    }

    func testReplacingContentClearsOldInteractionRange() {
        let (label, delegate) = makeLinkedLabel(destination: "https://old.example")
        XCTAssertTrue(label.handleGesture(CGPoint(x: 4, y: 10)))

        label.attributedText = NSAttributedString(
            string: "Plain",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )

        XCTAssertFalse(label.handleGesture(CGPoint(x: 4, y: 10)))
        XCTAssertEqual(delegate.urls, [URL(string: "https://old.example")!])
    }

    func testTextMessageCellConvertsMessageContainerPointThroughNestedLabelHierarchy() {
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 160))
        let delegate = LinkDelegateSpy()
        cell.messageLabel.delegate = delegate
        cell.messageContainerView.frame = CGRect(x: 80, y: 10, width: 260, height: 120)
        cell.containerView.frame = CGRect(x: 24, y: 14, width: 220, height: 96)
        cell.labelContainer.frame = CGRect(x: 18, y: 38, width: 190, height: 42)
        cell.messageLabel.frame = CGRect(x: 12, y: 8, width: 170, height: 24)
        cell.messageLabel.attributedText = linkedText(destination: "xmpp:alex@example.com")
        let pointInMessageContainer = cell.messageLabel.convert(
            CGPoint(x: 4, y: 10),
            to: cell.messageContainerView
        )

        XCTAssertTrue(cell.cellContentView(canHandle: pointInMessageContainer))
        XCTAssertEqual(delegate.urls, [URL(string: "xmpp:alex@example.com")!])
    }

    func testTextCellReuseClearsLinkInteractionState() {
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 160))
        let delegate = LinkDelegateSpy()
        cell.messageLabel.delegate = delegate
        cell.messageLabel.frame = CGRect(x: 0, y: 0, width: 170, height: 24)
        cell.messageLabel.attributedText = linkedText(destination: "https://reuse.example")
        XCTAssertTrue(cell.messageLabel.handleGesture(CGPoint(x: 4, y: 10)))

        cell.prepareForReuse()

        XCTAssertFalse(cell.messageLabel.handleGesture(CGPoint(x: 4, y: 10)))
        XCTAssertEqual(delegate.urls.count, 1)
    }

    func testForwardedMessageConvertsPointThroughNestedLabelHierarchy() {
        let view = InlineMessageAttachmentView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        view.setupSubviews()
        let delegate = LinkDelegateSpy()
        view.messageLabel.delegate = delegate
        view.containerView.frame = CGRect(x: 18, y: 12, width: 210, height: 96)
        view.labelContainer.frame = CGRect(x: 14, y: 42, width: 180, height: 36)
        view.messageLabel.frame = CGRect(x: 10, y: 6, width: 160, height: 24)
        view.messageLabel.attributedText = linkedText(destination: "https://forward.example")
        let point = view.messageLabel.convert(CGPoint(x: 4, y: 10), to: view)

        XCTAssertTrue(view.handleTouch(at: point))
        XCTAssertEqual(delegate.urls, [URL(string: "https://forward.example")!])
    }

    func testHandledForwardedLinkDoesNotFallThroughToMainMessageLink() {
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 160))
        let delegate = LinkDelegateSpy()
        cell.messageLabel.delegate = delegate
        cell.messageContainerView.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        cell.containerView.frame = cell.messageContainerView.bounds
        cell.labelContainer.frame = CGRect(x: 0, y: 0, width: 180, height: 40)
        cell.messageLabel.frame = cell.labelContainer.bounds
        cell.messageLabel.attributedText = linkedText(destination: "https://main.example")

        cell.forwardsContainer.frame = CGRect(x: 0, y: 0, width: 180, height: 40)
        let forward = InlineMessageAttachmentView(frame: cell.forwardsContainer.bounds)
        forward.setupSubviews()
        forward.messageLabel.delegate = delegate
        forward.messageLabel.frame = forward.bounds
        forward.messageLabel.attributedText = linkedText(destination: "https://forward.example")
        cell.forwardsContainer.inlineViews = [forward]
        cell.forwardsContainer.addSubview(forward)

        XCTAssertTrue(cell.cellContentView(canHandle: CGPoint(x: 4, y: 10)))
        XCTAssertEqual(delegate.urls, [URL(string: "https://forward.example")!])
    }

    private func makeLinkedLabel(destination: String) -> (MessageLabel, LinkDelegateSpy) {
        let label = MessageLabel(frame: CGRect(x: 0, y: 0, width: 220, height: 40))
        let delegate = LinkDelegateSpy()
        label.delegate = delegate
        label.attributedText = linkedText(destination: destination)
        return (label, delegate)
    }

    private func linkedText(destination: String) -> NSAttributedString {
        NSAttributedString(
            string: "Open",
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .link: destination
            ]
        )
    }
}

private final class LinkDelegateSpy: MessageLabelDelegate {
    var urls: [URL] = []

    func didSelectURL(_ url: URL) {
        urls.append(url)
    }
}
