import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class MediaGalleryEncryptedAttachmentTests: XCTestCase {
    private let owner = "gallery-receiver@example.test"
    private let peer = "gallery-sender@example.test"
    private let source = URL(string: "https://gallery.example.test/private.png")!
    private var previous: Realm.Configuration!
    private var local: URL!
    override func setUpWithError() throws {
        previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ProtectedGallery-\(UUID())")
        local = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryVerified-\(UUID()).png")
        try Data("verified gallery original".utf8).write(to: local)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: local)
        Realm.Configuration.defaultConfiguration = previous
        super.tearDown()
    }
    private final class Task: ChatEncryptedAttachmentReceiveTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private struct Pending {
        let descriptor: ChatEncryptedAttachmentDescriptor
        let task: Task
        let completion: (Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) -> Void
    }
    private final class Probe {
        var pending: [Pending] = []
        var presented: [(ChatMediaOpeningKind, [URL], URL)] = []
    }
    private final class FileRouter: MediaGalleryFileActionRouting {
        var opened: [URL] = [], shared: [URL] = []
        func open(_ url: URL, from presenter: UIViewController) { opened.append(url) }
        func share(_ url: URL, from presenter: UIViewController, sourceView: UIView?) { shared.append(url) }
    }
    private func configure(_ controller: BaseMediaGalleryForChatViewController) -> Probe {
        controller.owner = owner; controller.jid = peer; controller.conversationType = .omemo
        let probe = Probe()
        controller.galleryAttachmentReceive = { descriptor, completion in
            let task = Task(); probe.pending.append(Pending(descriptor: descriptor, task: task, completion: completion)); return task
        }
        controller.mediaGalleryPresentationForTesting = { probe.presented.append(($0, $1, $2)) }
        return probe
    }
    private func stored(_ primary: String = "attachment", kind: MessageMediaAttachmentStorageItem.Kind = .image,
                        metadata: [String: Any]? = nil, url: URL? = nil, foreign: Bool = false) throws -> MessageMediaAttachmentStorageItem {
        let item = MessageMediaAttachmentStorageItem()
        item.primary = primary; item.owner = foreign ? "other@example.test" : owner; item.jid = peer
        item.conversationType = .omemo; item.kind = kind; item.messagePrimary = "message"; item.archiveId = "archive"
        item.url_ = (url ?? source).absoluteString; item.filename = "private.png"; item.isEncrypted = true
        item.metadata = metadata ?? ["encryption-key": Data(repeating: 1, count: 16).base64EncodedString(),
            "iv": Data(repeating: 2, count: 16).base64EncodedString(), "hash": String(repeating: "a", count: 64),
            "size": 25, "name": "private.png"]
        let realm = try WRealm.safe(); try realm.write { realm.add(item) }; return item
    }
    private func map(_ item: MessageMediaAttachmentStorageItem) -> BaseMediaGalleryForChatViewController.Datasource {
        MediaGalleryDatasourceMapper.map(item, revealedSensitiveMediaPrimaries: [])
    }
    private func complete(_ pending: Pending, file: URL? = nil) {
        pending.completion(.success(ChatAuthenticatedAttachmentFile(fileURL: file ?? local, byteCount: 25,
            plaintextSHA256: String(repeating: "b", count: 64), cacheIdentity: pending.descriptor.cacheIdentity)))
    }
    func testStoredEncryptedImageCarriesItsDescriptorThroughGalleryPlanner() throws {
        let item = map(try stored())
        let descriptor = try XCTUnwrap(item.encryptedAttachment)
        XCTAssertEqual(descriptor.state, .encrypted); XCTAssertEqual(descriptor.owner, owner)
        let request = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(for: item, displaySize: CGSize(width: 80, height: 60), scale: 2))
        XCTAssertEqual(request.encryptedAttachment, descriptor)
    }
    func testGalleryCacheIdentitySeparatesProtectionFromPlaintextAndOtherKeys() throws {
        let item = try stored(), first = map(item)
        let a = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(for: first, displaySize: CGSize(width: 80, height: 60), scale: 2))
        let realm = try WRealm.safe(); var metadata = item.metadata!
        metadata["encryption-key"] = Data(repeating: 9, count: 16).base64EncodedString()
        try realm.write { item.metadata = metadata }
        let b = try XCTUnwrap(MediaGalleryImageRequestPlanner.request(for: map(item), displaySize: a.displaySize, scale: a.scale))
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
        XCTAssertNotEqual(a.cacheKey, MediaGalleryImageRequest(url: source, displaySize: a.displaySize, scale: a.scale).cacheKey)
        XCTAssertFalse(BaseMediaGalleryForChatViewController.Datasource.compareContent(first, map(item)))
    }
    func testHistoricalEncryptedRowWithoutKeysRemainsInvalidRatherThanPlaintext() throws {
        let item = map(try stored(metadata: ["name": "private.png"]))
        XCTAssertEqual(item.encryptedAttachment?.state, .invalid)
    }
    func testNormalPhotoGalleryTapAuthenticatesEveryResourceInOriginalOrder() throws {
        let first = try stored(), second = try stored("second", url: URL(string: "https://gallery.example.test/second.png")!)
        let controller = PhotoGalleryForChatViewController(), probe = configure(controller)
        controller.datasource = [map(first), map(second)]
        controller.collectionView(controller.collectionView, didSelectItemAt: IndexPath(item: 1, section: 0))
        XCTAssertTrue(probe.presented.isEmpty); XCTAssertEqual(probe.pending.count, 2)
        guard probe.pending.count == 2 else { return }
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("GallerySecond-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: other) }; try Data("second".utf8).write(to: other)
        complete(probe.pending[1], file: other); XCTAssertTrue(probe.presented.isEmpty)
        complete(probe.pending[0]); XCTAssertEqual(probe.presented.first?.1, [local!, other]); XCTAssertEqual(probe.presented.first?.2, other)
    }
    func testNormalVideoGalleryTapUsesOnlyVerifiedLocalPlayerURL() throws {
        let item = map(try stored(kind: .video)), controller = VideoGalleryForChatViewController(), probe = configure(controller)
        controller.datasource = [item]; controller.collectionView(controller.collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertTrue(probe.presented.isEmpty)
        complete(try XCTUnwrap(probe.pending.first)); XCTAssertEqual(probe.presented.first?.2, local)
    }
    func testNormalFileOpenAndShareWaitForAuthentication() throws {
        let item = map(try stored(kind: .file)), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]
        controller.performFileAction(.open(source), for: item, sourceView: nil)
        XCTAssertTrue(router.opened.isEmpty); complete(try XCTUnwrap(probe.pending.first)); XCTAssertEqual(router.opened, [local!])
        controller.performFileAction(.share(source), for: item, sourceView: nil)
        XCTAssertTrue(router.shared.isEmpty); complete(try XCTUnwrap(probe.pending.last)); XCTAssertEqual(router.shared, [local!])
    }
    func testAuthenticationFailureCannotOpenOrShareCiphertext() throws {
        let item = map(try stored(kind: .file)), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]
        controller.performFileAction(.open(source), for: item, sourceView: nil)
        try XCTUnwrap(probe.pending.first).completion(.failure(.authenticationFailed))
        XCTAssertTrue(router.opened.isEmpty); XCTAssertTrue(router.shared.isEmpty)
    }
    func testForeignGalleryItemCannotBorrowCurrentAccountReceiver() throws {
        let item = map(try stored(kind: .file, foreign: true)), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]; controller.performFileAction(.open(source), for: item, sourceView: nil)
        XCTAssertTrue(probe.pending.isEmpty); XCTAssertTrue(router.opened.isEmpty)
    }
    func testChangedOwnerCancelsAndRejectsLateGalleryCompletion() throws {
        let item = map(try stored(kind: .file)), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]; controller.performFileAction(.open(source), for: item, sourceView: nil)
        let pending = try XCTUnwrap(probe.pending.first); controller.owner = "other@example.test"
        XCTAssertTrue(pending.task.cancelled); complete(pending); XCTAssertTrue(router.opened.isEmpty)
    }
    func testChangedStoredCryptographicMetadataRejectsPendingOpen() throws {
        let row = try stored(kind: .file), item = map(row), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]; controller.performFileAction(.open(source), for: item, sourceView: nil)
        let pending = try XCTUnwrap(probe.pending.first), realm = try WRealm.safe()
        try realm.write { row.metadata = ["iv": "incomplete"] }
        complete(pending); XCTAssertTrue(router.opened.isEmpty)
    }
    func testExplicitCancelPreventsLateGalleryPresentation() throws {
        let item = map(try stored(kind: .video)), controller = VideoGalleryForChatViewController(), probe = configure(controller)
        controller.datasource = [item]; controller.collectionView(controller.collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
        let pending = try XCTUnwrap(probe.pending.first); controller.cancelGalleryMediaOpening()
        XCTAssertTrue(pending.task.cancelled); complete(pending); XCTAssertTrue(probe.presented.isEmpty)
    }
    private final class Subscription: ChatThumbnailSubscription { var cancelled = false; func cancel() { cancelled = true } }
    private final class Pipeline: ChatThumbnailServing {
        var requests: [ChatThumbnailRequest] = []; let subscription = Subscription()
        func acquire(_ request: ChatThumbnailRequest, consumer: ChatThumbnailConsumer, completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?) -> ChatThumbnailSubscription {
            requests.append(request); return subscription
        }
    }
    func testProtectedGalleryThumbnailUsesSharedPipelineAndCancelsItsSubscription() {
        let pipeline = Pipeline(), loader = KingfisherMediaGalleryImageLoader(thumbnailPipeline: pipeline), image = UIImageView()
        // A local fixture avoids HTTP even when the old loader incorrectly ignores protection.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("missing-gallery-fixture.png")
        let invalid = ChatEncryptedAttachmentDescriptor(metadata: ["iv": "incomplete"], url: file, owner: owner, referenceIdentity: "attachment")
        let request = MediaGalleryImageRequest(url: file, displaySize: CGSize(width: 80, height: 60), scale: 2, encryptedAttachment: invalid)
        loader.load(request: request, into: image, placeholder: nil) { _ in }
        XCTAssertEqual(pipeline.requests.count, 1)
        XCTAssertEqual(pipeline.requests.first?.encryptedAttachment, invalid)
        loader.cancelLoad(in: image); XCTAssertTrue(pipeline.subscription.cancelled)
    }
    func testProtectedGalleryPrefetchUsesSharedPipelineAndCancelsIt() {
        let pipeline = Pipeline(), factory = KingfisherMediaGalleryImagePrefetchTaskFactory(thumbnailPipeline: pipeline)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("missing-gallery-prefetch-fixture.png")
        let invalid = ChatEncryptedAttachmentDescriptor(metadata: ["iv": "incomplete"], url: file, owner: owner, referenceIdentity: "attachment")
        let request = MediaGalleryImageRequest(url: file, displaySize: CGSize(width: 80, height: 60), scale: 2, encryptedAttachment: invalid)
        let task = factory.makeTask(for: request)
        task.start()
        XCTAssertEqual(pipeline.requests.first?.encryptedAttachment, invalid)
        task.stop(); XCTAssertTrue(pipeline.subscription.cancelled)
    }

    func testBackgroundCryptoCommitInvalidatesPendingGalleryOpenBeforeUIAutorefresh() throws {
        let row = try stored(kind: .file), item = map(row), controller = FilesGalleryForChatViewController(), probe = configure(controller), router = FileRouter()
        controller.fileActionRouter = router; controller.datasource = [item]
        let realm = try WRealm.safe(), previousAutorefresh = realm.autorefresh
        realm.autorefresh = false
        defer { realm.autorefresh = previousAutorefresh; realm.refresh() }
        controller.performFileAction(.open(source), for: item, sourceView: nil)
        let pending = try XCTUnwrap(probe.pending.first), configuration = realm.configuration
        let finished = DispatchSemaphore(value: 0), primary = row.primary
        DispatchQueue.global().async {
            defer { finished.signal() }
            autoreleasepool {
                do {
                    let background = try Realm(configuration: configuration)
                    guard let changed = background.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: primary) else { return }
                    try background.write { changed.metadata = ["iv": "incomplete"] }
                } catch { XCTFail("Synthetic background Realm write failed: \(error)") }
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(row.metadata?["iv"] as? String, Data(repeating: 2, count: 16).base64EncodedString(), "The UI Realm must still be stale before completion")
        complete(pending)
        XCTAssertTrue(router.opened.isEmpty)
    }

}
