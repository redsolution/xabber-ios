import RealmSwift
import UIKit
import XCTest
@testable import xabber

@MainActor
final class MediaGalleryFilesListTests: XCTestCase {
    private var originalRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        originalRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "MediaGalleryFilesListTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = originalRealmConfiguration
        originalRealmConfiguration = nil
        super.tearDown()
    }

    func testRealmQueryShowsOnlyVisibleFileRowsNewestFirst() throws {
        let realm = try Realm()
        let olderFile = storedItem(kind: .file, primary: "older-file", date: 10)
        let newerFile = storedItem(kind: .file, primary: "newer-file", date: 20)
        let hiddenFile = storedItem(kind: .file, primary: "hidden-file", date: 30)
        hiddenFile.isLocallyHiddenByReport = true

        try realm.write {
            realm.add([
                olderFile,
                newerFile,
                hiddenFile,
                storedItem(kind: .image, primary: "image", date: 40),
                storedItem(kind: .video, primary: "video", date: 50),
                storedItem(kind: .voice, primary: "voice", date: 60)
            ])
        }

        let controller = makeController()
        controller.loadDatasource()

        XCTAssertEqual(controller.collectionObserver?.map(\.primary), ["newer-file", "older-file"])
        XCTAssertTrue(controller.collectionObserver?.allSatisfy { $0.kind == .file } == true)
    }

    func testListLayoutUsesStableFullWidthRows() {
        let policy = MediaGalleryFileListLayoutPolicy()

        let size = policy.itemSize(
            containerWidth: 390,
            contentInset: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        )

        XCTAssertEqual(policy.rowHeight, 64)
        XCTAssertEqual(size, CGSize(width: 366, height: 64))
    }

    func testRowStateUsesFilenameSizeMimeIconAndAccessibleOpenState() {
        let item = datasourceItem(
            filename: "quarterly-results-with-a-very-long-middle-name.pdf",
            url: URL(string: "https://gallery.example/quarterly-results.pdf"),
            mediaType: "application/pdf",
            byteSize: 2_048
        )

        let state = MediaGalleryFileRowStatePolicy.state(for: item)

        XCTAssertEqual(state.filename, item.filename)
        XCTAssertEqual(state.formattedSize, AccountQuotaStorageItem.beautify(size: 2_048))
        XCTAssertEqual(state.iconSystemName, "doc")
        XCTAssertTrue(state.canOpen)
        XCTAssertTrue(state.canShare)
        XCTAssertTrue(state.canJumpToMessage)
        XCTAssertEqual(state.accessibilityIdentifier, "mediaGallery.file.row.attachment-primary")
        XCTAssertEqual(state.accessibilityLabel, "\(item.filename), \(item.formattedByteSize)")
    }

    func testMimeIconPolicyMatchesAttachmentPickerMediaKinds() {
        XCTAssertEqual(rowState(mediaType: "image/png").iconSystemName, "photo")
        XCTAssertEqual(rowState(mediaType: "video/mp4").iconSystemName, "film")
        XCTAssertEqual(rowState(mediaType: "audio/mpeg").iconSystemName, "waveform")
        XCTAssertEqual(rowState(mediaType: "application/zip").iconSystemName, "doc")
        XCTAssertEqual(rowState(mediaType: nil).iconSystemName, "doc")
    }

    func testCellRepeatedConfigurationKeepsOneStableListHierarchy() throws {
        let cell = FilesGalleryForChatViewController.GalleryItemCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 64)
        )
        let firstState = MediaGalleryFileRowStatePolicy.state(
            for: datasourceItem(filename: "first.pdf", mediaType: "application/pdf")
        )
        let secondState = MediaGalleryFileRowStatePolicy.state(
            for: datasourceItem(filename: "second.zip", mediaType: "application/zip")
        )

        cell.configure(with: firstState)
        let firstSubviewCount = cell.contentView.subviews.count
        let firstConstraintCount = cell.contentView.constraints.count
        cell.configure(with: secondState)

        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(cell.rowState, secondState)
        XCTAssertEqual(content.text, "second.zip")
        XCTAssertEqual(content.secondaryText, secondState.formattedSize)
        XCTAssertEqual(content.textProperties.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cell.contentView.subviews.count, firstSubviewCount)
        XCTAssertEqual(cell.contentView.constraints.count, firstConstraintCount)
    }

    func testInvalidURLDisablesOpenAndShareButKeepsMessageJump() throws {
        let invalidURLItem = datasourceItem(url: nil)

        XCTAssertEqual(
            MediaGalleryFileActionPolicy.availableActions(for: invalidURLItem),
            [.goToMessage]
        )

        let missingAnchorItem = datasourceItem(
            url: URL(string: "https://gallery.example/document.pdf"),
            messagePrimary: "",
            archiveId: ""
        )
        XCTAssertEqual(
            MediaGalleryFileActionPolicy.availableActions(for: missingAnchorItem),
            [
                .open(try XCTUnwrap(missingAnchorItem.url)),
                .share(try XCTUnwrap(missingAnchorItem.url))
            ]
        )
    }

    func testPrimaryTapOpensAndExplicitShareAndJumpUseIndependentRoutes() throws {
        let fileRouter = FakeMediaGalleryFileActionRouter()
        let messageRouter = FakeFilesMessageNavigationRouter()
        let controller = makeController()
        controller.fileActionRouter = fileRouter
        controller.messageNavigationRouter = messageRouter
        let item = datasourceItem()
        let url = try XCTUnwrap(item.url)
        controller.datasource = [item]

        controller.collectionView(
            controller.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )
        controller.performFileAction(.share(url), for: item, sourceView: controller.view)
        controller.performFileAction(.goToMessage, for: item, sourceView: controller.view)

        XCTAssertEqual(fileRouter.openedURLs, [url])
        XCTAssertEqual(fileRouter.sharedURLs, [url])
        XCTAssertEqual(messageRouter.requests.count, 1)
        XCTAssertEqual(messageRouter.requests.first?.source, .mediaGallery)
    }

    func testContextMenuAndEmptyStateExposeFileActionsWithoutDuplicatingPrimaryTap() {
        let controller = makeController()
        let item = datasourceItem()

        controller.apply([])
        XCTAssertFalse(controller.emptyStateLabel.isHidden)

        controller.apply([item])
        XCTAssertTrue(controller.emptyStateLabel.isHidden)

        let actionIdentifiers = controller.contextMenuActions(for: item)
            .compactMap { ($0 as? UIAction)?.identifier.rawValue }
        XCTAssertEqual(
            Set(actionIdentifiers),
            Set([
                MediaGalleryFileMenuIdentifier.open.rawValue,
                MediaGalleryFileMenuIdentifier.share.rawValue,
                MediaGalleryFileMenuIdentifier.goToMessage.rawValue,
                MediaGalleryFileMenuIdentifier.report.rawValue
            ])
        )
    }

    private func makeController() -> FilesGalleryForChatViewController {
        let controller = FilesGalleryForChatViewController()
        controller.owner = Self.owner
        controller.jid = Self.jid
        controller.conversationType = .regular
        controller.loadViewIfNeeded()
        return controller
    }

    private func storedItem(
        kind: MessageMediaAttachmentStorageItem.Kind,
        primary: String,
        date: TimeInterval
    ) -> MessageMediaAttachmentStorageItem {
        let item = MessageMediaAttachmentStorageItem()
        item.primary = primary
        item.owner = Self.owner
        item.jid = Self.jid
        item.conversationType = .regular
        item.kind = kind
        item.messagePrimary = "message-\(primary)"
        item.archiveId = "archive-\(primary)"
        item.filename = "\(primary).bin"
        item.url_ = "https://gallery.example/files/\(primary)"
        item.date = Date(timeIntervalSince1970: date)
        return item
    }

    private func rowState(mediaType: String?) -> MediaGalleryFileRowState {
        MediaGalleryFileRowStatePolicy.state(
            for: datasourceItem(mediaType: mediaType)
        )
    }

    private func datasourceItem(
        filename: String = "document.pdf",
        url: URL? = URL(string: "https://gallery.example/document.pdf"),
        mediaType: String? = "application/pdf",
        byteSize: Int = 1_024,
        messagePrimary: String = "message-primary",
        archiveId: String = "archive-id"
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        BaseMediaGalleryForChatViewController.Datasource(
            kind: .file,
            primary: "attachment-primary",
            owner: Self.owner,
            jid: Self.jid,
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            filename: filename,
            url: url,
            messagePrimary: messagePrimary,
            archiveId: archiveId,
            isDownloaded: false,
            verySmallThumb: nil,
            thumb: nil,
            byteSize: byteSize,
            formattedByteSize: AccountQuotaStorageItem.beautify(size: byteSize),
            durationSeconds: nil,
            formattedDuration: nil,
            previewURL: nil,
            previewCacheIdentity: nil,
            mediaType: mediaType,
            decodedURL: nil,
            pcm: [],
            isSensitive: false,
            isSensitiveRevealed: false
        )
    }

    private static let owner = "owner@example.com"
    private static let jid = "contact@example.com"
}

@MainActor
private final class FakeMediaGalleryFileActionRouter: MediaGalleryFileActionRouting {
    private(set) var openedURLs: [URL] = []
    private(set) var sharedURLs: [URL] = []

    func open(_ url: URL, from presenter: UIViewController) {
        openedURLs.append(url)
    }

    func share(_ url: URL, from presenter: UIViewController, sourceView: UIView?) {
        sharedURLs.append(url)
    }
}

@MainActor
private final class FakeFilesMessageNavigationRouter: MediaGalleryMessageNavigationRouting {
    private(set) var requests: [ChatOpenMessageRequest] = []

    func route(
        _ request: ChatOpenMessageRequest,
        from presenter: UIViewController
    ) -> MediaGalleryMessageNavigationRouteResult {
        requests.append(request)
        return .navigationStack
    }
}
