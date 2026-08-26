import XCTest
@testable import xabber

final class ChatDatasourceBoundsTests: XCTestCase {
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    func testDatasourceItemAcceptsOnlySingleItemInValidSection() {
        let controller = makeController()
        controller.datasource = [makeDatasource(primary: "first")]

        XCTAssertEqual(controller.datasourceItem(at: IndexPath(item: 0, section: 0))?.primary, "first")
        XCTAssertNil(controller.datasourceItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertNil(controller.datasourceItem(at: IndexPath(item: 2, section: 0)))
        XCTAssertNil(controller.datasourceItem(at: IndexPath(item: -1, section: 0)))
    }

    func testMessageForInvalidIndexPathsReturnsStaleFallback() {
        let controller = makeController()
        controller.datasource = [makeDatasource(primary: "first")]

        assertStaleFallback(controller.messageForItem(
            at: IndexPath(item: 1, section: 0),
            in: controller.messagesCollectionView
        ))
        assertStaleFallback(controller.messageForItem(
            at: IndexPath(item: 0, section: 1),
            in: controller.messagesCollectionView
        ))

        controller.datasource = []
        assertStaleFallback(controller.messageForItem(
            at: IndexPath(item: 0, section: 0),
            in: controller.messagesCollectionView
        ))
    }

    func testNumberOfItemsOnlyExposesExistingSingleItemSections() {
        let controller = makeController()
        controller.datasource = [
            makeDatasource(primary: "first"),
            makeDatasource(primary: "second")
        ]

        XCTAssertEqual(controller.numberOfItems(inSection: 0, in: controller.messagesCollectionView), 1)
        XCTAssertEqual(controller.numberOfItems(inSection: 1, in: controller.messagesCollectionView), 1)
        XCTAssertEqual(controller.numberOfItems(inSection: 2, in: controller.messagesCollectionView), 0)
        XCTAssertEqual(controller.numberOfItems(inSection: -1, in: controller.messagesCollectionView), 0)
    }

    func testReadBoundaryIgnoresStaleItemIndexInValidSection() {
        let controller = makeController()
        controller.datasource = [makeDatasource(primary: "incoming")]

        XCTAssertFalse(controller.advanceReadBoundaryFromVisibleMessages(
            indexPaths: [IndexPath(item: 1, section: 0)]
        ))
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
    }

    func testWillDisplayIgnoresStaleIndexPathAfterDatasetShrink() {
        let controller = makeController()
        controller.datasource = [makeDatasource(primary: "incoming")]
        controller.messagesCollectionView.messagesDataSource = controller

        controller.collectionView(
            controller.messagesCollectionView,
            willDisplay: UICollectionViewCell(),
            forItemAt: IndexPath(item: 1, section: 0)
        )

        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
    }

    private func assertStaleFallback(
        _ message: MessageType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let item = message as? ChatViewController.Datasource else {
            XCTFail("Expected datasource fallback item", file: file, line: line)
            return
        }
        XCTAssertEqual(item.primary, ChatViewController.staleDatasourceFallbackPrimary, file: file, line: line)
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        return controller
    }

    private func makeDatasource(primary: String) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: jid),
            messageId: primary,
            sentDate: Date(timeIntervalSince1970: 100),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Hello")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: true,
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
            isDownloaded: true,
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: primary,
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil
        )
    }
}
