import XCTest
@testable import xabber

@MainActor
final class TextMessageCellReuseTests: XCTestCase {
    func testStaleAvatarCallbackDoesNotUpdateReusedCell() {
        let loader = FakeAvatarLoader()
        let cell = makeCell(loader: loader)
        let oldImage = image(color: .red)
        let currentImage = image(color: .blue)

        configure(
            cell,
            with: makeMessage(primary: "old-message", avatarUrl: "https://avatars.example.com/old.png")
        )
        configure(
            cell,
            with: makeMessage(primary: "current-message", avatarUrl: "https://avatars.example.com/current.png")
        )

        XCTAssertEqual(loader.requests.map(\.url), [
            "https://avatars.example.com/old.png",
            "https://avatars.example.com/current.png"
        ])

        loader.completeRequest(at: 0, image: oldImage)
        XCTAssertFalse(cell.avatarView.image === oldImage)

        loader.completeRequest(at: 1, image: currentImage)
        XCTAssertTrue(cell.avatarView.image === currentImage)
    }

    func testCurrentAvatarCallbackUpdatesCurrentCell() {
        let loader = FakeAvatarLoader()
        let cell = makeCell(loader: loader)
        let currentImage = image(color: .green)

        configure(
            cell,
            with: makeMessage(primary: "message", avatarUrl: "https://avatars.example.com/current.png")
        )
        loader.completeRequest(at: 0, image: currentImage)

        XCTAssertTrue(cell.avatarView.image === currentImage)
    }

    func testPrepareForReuseClearsRepresentedAvatarIdentity() {
        let loader = FakeAvatarLoader()
        let cell = makeCell(loader: loader)

        configure(
            cell,
            with: makeMessage(primary: "message", avatarUrl: "https://avatars.example.com/current.png")
        )
        XCTAssertNotNil(cell.representedAvatarIdentity)

        cell.prepareForReuse()

        XCTAssertNil(cell.representedAvatarIdentity)
    }

    func testAttachmentReconfigurationPreservesFileViewAfterReuseWhenIdentityMatches() throws {
        let loader = FakeAvatarLoader()
        let cell = makeCell(loader: loader)
        cell.filesView.frame = CGRect(x: 0, y: 0, width: 220, height: 44)
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/report.pdf"))

        configure(
            cell,
            with: makeMessage(
                primary: "message",
                files: [FileAttachment(primary: "file-1", url: fileURL, size: 1024, name: "report.pdf", downloaded: true)]
            )
        )
        let firstView = try XCTUnwrap(cell.filesView.views.first)

        cell.prepareForReuse()
        configure(
            cell,
            with: makeMessage(
                primary: "message",
                files: [FileAttachment(primary: "file-1", url: fileURL, size: 2048, name: "updated.pdf", downloaded: true)]
            )
        )

        let reusedView = try XCTUnwrap(cell.filesView.views.first)
        XCTAssertTrue(firstView === reusedView)
        XCTAssertEqual(reusedView.primary, "file-1")
        XCTAssertEqual(reusedView.filenameLabel.text, "updated.pdf")
        XCTAssertEqual(reusedView.sizeLabel.text, "2 KB")
    }

    func testPrepareForReuseClearsInlineMediaViews() throws {
        let loader = FakeAvatarLoader()
        let cell = makeCell(loader: loader)
        let imageURL = URL(fileURLWithPath: "/tmp/old-image.jpg")
        let videoURL = URL(fileURLWithPath: "/tmp/old-video.mov")
        let previewURL = URL(fileURLWithPath: "/tmp/old-video-preview.jpg")
        cell.imagesView.frame = CGRect(x: 0, y: 0, width: 220, height: 220)
        cell.videosView.frame = CGRect(x: 0, y: 0, width: 220, height: 220)

        configure(
            cell,
            with: makeMessage(
                primary: "message",
                images: [ImageAttachment(primary: "image-1", url: imageURL, size: CGSize(width: 1024, height: 768))],
                videos: [VideoAttachment(primary: "video-1", url: videoURL, size: CGSize(width: 1024, height: 768), previewUrl: previewURL, duration: 1, downloaded: true)]
            )
        )

        XCTAssertEqual(cell.imagesView.views.map(\.primary), ["image-1"])
        XCTAssertEqual(cell.videosView.views.map(\.primary), ["video-1"])

        cell.prepareForReuse()

        XCTAssertTrue(cell.imagesView.views.isEmpty)
        XCTAssertTrue(cell.videosView.views.isEmpty)
    }

    private func makeCell(loader: FakeAvatarLoader) -> TextMessageCell {
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        cell.avatarLoader = loader
        return cell
    }

    private func configure(_ cell: TextMessageCell, with message: ReuseTestMessage) {
        let messagesCollectionView = MessagesCollectionView()
        let dataSource = ReuseMessagesDataSource(message: message)
        messagesCollectionView.messagesDataSource = dataSource
        cell.configure(with: message, at: IndexPath(item: 0, section: 0), and: messagesCollectionView)
    }

    private func makeMessage(
        primary: String,
        avatarUrl: String? = nil,
        images: [ImageAttachment] = [],
        videos: [VideoAttachment] = [],
        files: [FileAttachment] = []
    ) -> ReuseTestMessage {
        ReuseTestMessage(
            primary: primary,
            jid: "room@example.com",
            owner: "owner@example.com",
            withAvatar: avatarUrl != nil,
            groupchatAuthorNickname: "Alexey",
            groupchatAuthorId: "alexey@example.com",
            imageAttachments: images,
            videoAttachments: videos,
            files: files,
            avatarUrl: avatarUrl
        )
    }

    private func image(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}

private final class FakeAvatarLoader: TextMessageCellAvatarLoading {
    struct Request {
        let url: String
        let userId: String
        let jid: String
        let owner: String
        let size: CGFloat
        let completion: (UIImage?) -> Void
    }

    private(set) var requests: [Request] = []

    func loadGroupAvatar(
        url: String,
        userId: String,
        jid: String,
        owner: String,
        size: CGFloat,
        completion: @escaping (UIImage?) -> Void
    ) {
        requests.append(Request(
            url: url,
            userId: userId,
            jid: jid,
            owner: owner,
            size: size,
            completion: completion
        ))
    }

    func completeRequest(at index: Int, image: UIImage?) {
        requests[index].completion(image)
    }
}

private final class ReuseMessagesDataSource: MessagesDataSource {
    let message: MessageType

    init(message: MessageType) {
        self.message = message
    }

    func currentSender() -> Sender {
        Sender(id: "owner@example.com", displayName: "Owner")
    }

    func isFromCurrentSender(message: MessageType) -> Bool {
        message.owner == currentSender().id
    }

    func messageBottomPadding(at indexPath: IndexPath) -> CGFloat { 0 }
    func showTopLabel(for message: MessageType) -> Bool { false }
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageType { message }
    func numberOfSections(in messagesCollectionView: MessagesCollectionView) -> Int { 1 }
    func numberOfItems(inSection section: Int, in messagesCollectionView: MessagesCollectionView) -> Int { 1 }
    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? { nil }
    func messageTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? { nil }
    func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? { nil }
    func showAvatar() -> Bool { true }
    func audioMessageDurationString(at indexPath: IndexPath, messageId: String?, index: Int?) -> String? { nil }
    func audioMessageCurrentGradientPercentage(at indexPath: IndexPath, messageId: String?, index: Int?) -> Float? { nil }
    func audioMessageDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval { 0 }
    func audioMessageCurrentDuration(at indexPath: IndexPath, messageId: String?, index: Int?) -> TimeInterval { 0 }
    func showDeliveryIndicator() -> Bool { false }
    func canPerformAction() -> Bool { true }
}

private struct ReuseTestMessage: MessageType {
    let primary: String
    let jid: String
    let owner: String
    var sender: Sender { Sender(id: jid, displayName: groupchatAuthorNickname) }
    var messageId: String { primary }
    var sentDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    var editDate: Date? { nil }
    var kind: MessageKind { .attributedText(NSAttributedString(string: "Body")) }
    var withAuthor: Bool { false }
    let withAvatar: Bool
    var error: Bool { false }
    var errorType: String { "" }
    var canPinMessage: Bool { true }
    var canEditMessage: Bool { true }
    var canDeleteMessage: Bool { true }
    var forwards: [MessageAttachment] { [] }
    var isOutgoing: Bool { false }
    var isEdited: Bool { false }
    let groupchatAuthorNickname: String
    var groupchatAuthorBadge: String { "" }
    let groupchatAuthorId: String
    var isHasAttachedMessages: Bool { false }
    var afterburnInterval: Double { 0 }
    var tailed: Bool { false }
    let imageAttachments: [ImageAttachment]
    let videoAttachments: [VideoAttachment]
    var images: [ImageAttachment] { imageAttachments }
    var videos: [VideoAttachment] { videoAttachments }
    var locations: [LocationAttachment] { [] }
    var contacts: [ContactAttachment] { [] }
    let files: [FileAttachment]
    var audios: [AudioAttachment] { [] }
    var messageWarningText: String? { nil }
    var timeMarkerText: NSAttributedString { NSAttributedString(string: "12:00") }
    var indicator: IndicatorType { .none }
    let avatarUrl: String?
    var attributedAuthor: NSAttributedString? { nil }
}
