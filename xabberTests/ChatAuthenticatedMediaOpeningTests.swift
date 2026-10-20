import XCTest
import UIKit
import RealmSwift
@testable import xabber

final class ChatAuthenticatedMediaOpeningTests: XCTestCase {
    private let owner = "receiver@example.test"
    private let peer = "sender@example.test"
    private let source = URL(string: "https://gallery.example.test/encrypted.png")!
    private var previousConfiguration: Realm.Configuration!
    private var localFile: URL!

    override func setUpWithError() throws {
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "MediaOpening-\(UUID())")
        localFile = FileManager.default.temporaryDirectory.appendingPathComponent("Verified-\(UUID()).txt")
        try Data("authenticated original".utf8).write(to: localFile)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: localFile)
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }
    private final class Task: ChatEncryptedAttachmentReceiveTask {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private struct Request {
        let descriptor: ChatEncryptedAttachmentDescriptor
        let completion: (Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) -> Void
        let task: Task
    }
    private final class Probe {
        var requests: [Request] = []
        var presented: [(ChatMediaOpeningKind, [URL], URL)] = []
    }
    private func controller() -> (ChatViewController, Probe) {
        let chat = ChatViewController(); chat.owner = owner; chat.jid = peer; chat.conversationType = .omemo
        let probe = Probe()
        chat.mediaAttachmentReceive = { descriptor, completion in
            let task = Task(); probe.requests.append(Request(descriptor: descriptor, completion: completion, task: task)); return task
        }
        chat.mediaPresentationForTesting = { probe.presented.append(($0, $1, $2)) }
        return (chat, probe)
    }
    private func reference(primary: String = "reference", owner: String? = nil, jid: String? = nil, type: ClientSynchronizationManager.ConversationType = .omemo, metadata: [String: Any]? = nil, url: URL? = nil) throws -> MessageReferenceStorageItem {
        let ref = MessageReferenceStorageItem(); ref.primary = primary; ref.owner = owner ?? self.owner; ref.jid = jid ?? peer
        ref.conversationType = type; ref.kind = .media; ref.mimeType = "image"; ref.messageId = "message"; ref.url = (url ?? source).absoluteString
        ref.metadata = metadata ?? ["encryption-key": Data(repeating: 1, count: 16).base64EncodedString(), "iv": Data(repeating: 2, count: 16).base64EncodedString(), "hash": String(repeating: "a", count: 64), "size": 22, "name": "private.png"]
        let realm = try WRealm.safe(); try realm.write { realm.add(ref) }; return ref
    }
    private func complete(_ request: Request, file: URL? = nil) {
        request.completion(.success(ChatAuthenticatedAttachmentFile(fileURL: file ?? localFile, byteCount: 22, plaintextSHA256: String(repeating: "b", count: 64), cacheIdentity: request.descriptor.cacheIdentity)))
    }
    func testNormalFileTapPresentsOnlyVerifiedLocalFile() throws {
        try reference(); let (chat, probe) = controller()
        chat.didTapOnFile(url: source)
        XCTAssertTrue(probe.presented.isEmpty, "Ciphertext must not reach an external opener")
        let request = try XCTUnwrap(probe.requests.first); XCTAssertEqual(request.descriptor.owner, owner)
        complete(request); XCTAssertEqual(probe.presented.first?.2, localFile)
    }
    func testNormalPhotoTapOpensDecodedLocalGalleryResource() throws {
        try reference(); let (chat, probe) = controller()
        chat.didTapOnPhoto(message: "message", urls: [source], url: source, referencePrimary: "reference", isSensitive: false)
        XCTAssertTrue(probe.presented.isEmpty)
        complete(try XCTUnwrap(probe.requests.first)); XCTAssertEqual(probe.presented.first?.1, [localFile]); XCTAssertEqual(probe.presented.first?.2, localFile)
    }
    func testNormalVideoTapUsesAuthenticatedLocalPlayerURL() throws {
        try reference(); let (chat, probe) = controller()
        chat.didTapOnVideo(message: "message", url: source, referencePrimary: "reference", isSensitive: false)
        XCTAssertTrue(probe.presented.isEmpty)
        complete(try XCTUnwrap(probe.requests.first)); XCTAssertEqual(probe.presented.first?.2, localFile)
    }
    func testAuthenticationFailureNeverFallsBackToRemoteCiphertext() throws {
        try reference(); let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        try XCTUnwrap(probe.requests.first).completion(.failure(.authenticationFailed)); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testInvalidMetadataCannotUseUnencryptedFileOpener() throws {
        try reference(metadata: ["iv": Data(repeating: 2, count: 16).base64EncodedString()]); let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        XCTAssertTrue(probe.presented.isEmpty)
        if let request = probe.requests.first { XCTAssertEqual(request.descriptor.state, .invalid); request.completion(.failure(.invalidMetadata)) }
        XCTAssertTrue(probe.presented.isEmpty)
    }
    func testPrimaryCannotBorrowAnotherOwnerOrConversationReference() throws {
        for change in 0..<3 {
            let primary = "foreign-\(change)"
            try reference(primary: primary, owner: change == 0 ? "other@example.test" : owner, jid: change == 1 ? "other-peer@example.test" : peer, type: change == 2 ? .regular : .omemo)
            let (chat, probe) = controller(); chat.didTapOnPhoto(message: "message", urls: [source], url: source, referencePrimary: primary, isSensitive: false)
            XCTAssertTrue(probe.requests.isEmpty); XCTAssertTrue(probe.presented.isEmpty)
        }
    }
    func testURLOnlyFileTapRejectsAmbiguousCurrentReferences() throws {
        try reference(primary: "first"); try reference(primary: "second", metadata: ["iv": "incomplete"])
        let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        XCTAssertTrue(probe.requests.isEmpty); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testCurrentContextChangeCancelsPendingOpenAndIgnoresLateCallback() throws {
        try reference(); let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        let request = try XCTUnwrap(probe.requests.first); chat.owner = "other@example.test"
        XCTAssertTrue(request.task.cancelled); complete(request); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testNewTapAndCancellationInvalidateEarlierCompletion() throws {
        try reference(); let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        let first = try XCTUnwrap(probe.requests.first); chat.didTapOnFile(url: source)
        XCTAssertTrue(first.task.cancelled); complete(first); XCTAssertTrue(probe.presented.isEmpty)
        let second = try XCTUnwrap(probe.requests.last); chat.cancelMediaOpening(); XCTAssertTrue(second.task.cancelled)
        complete(second); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testReferenceCryptographicBindingMustRemainCurrentAfterDownload() throws {
        let ref = try reference(); let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        let request = try XCTUnwrap(probe.requests.first), realm = try WRealm.safe()
        try realm.write { ref.metadata = ["iv": "incomplete"] }
        complete(request); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testPlaintextReferenceRetainsOrdinaryPresentationRoute() throws {
        try reference(metadata: ["name": "plain.png"]); let (chat, probe) = controller(); chat.didTapOnPhoto(message: "message", urls: [source], url: source, referencePrimary: "reference", isSensitive: false)
        XCTAssertTrue(probe.requests.isEmpty); XCTAssertEqual(probe.presented.first?.2, source)
    }
    func testFullGalleryLoadsLocalImageWithoutKingfisherURLCacheEntry() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("VerifiedImage-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: path) }; try XCTUnwrap(image.pngData()).write(to: path)
        let cell = PhotoGalleryCell(frame: CGRect(x: 0, y: 0, width: 200, height: 300)); cell.imageUrl = path; cell.configureForNewImageUrl(animated: false)
        let loaded = expectation(description: "Local image load completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { loaded.fulfill() }; wait(for: [loaded], timeout: 1)
        XCTAssertEqual(cell.imageView.image?.size, image.size)
    }
    func testMixedGalleryAuthenticatesEveryEncryptedNeighborPreservingOrderAndSelection() throws {
        try reference(); let plain = URL(string: "https://gallery.example.test/plain.png")!, second = URL(string: "https://gallery.example.test/second.png")!
        try reference(primary: "plain", metadata: ["name": "plain.png"], url: plain); try reference(primary: "second", url: second)
        let (chat, probe) = controller(); chat.didTapOnPhoto(message: "message", urls: [plain, source, second], url: source, referencePrimary: "reference", isSensitive: false)
        XCTAssertTrue(probe.presented.isEmpty); XCTAssertEqual(probe.requests.count, 2)
        let first = try XCTUnwrap(probe.requests.first), last = try XCTUnwrap(probe.requests.last)
        let secondFile = FileManager.default.temporaryDirectory.appendingPathComponent("VerifiedSecond-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: secondFile) }; try Data("second authenticated original".utf8).write(to: secondFile)
        complete(last, file: secondFile); XCTAssertTrue(probe.presented.isEmpty)
        complete(first); XCTAssertEqual(probe.presented.first?.1, [plain, localFile!, secondFile]); XCTAssertEqual(probe.presented.first?.2, localFile)
    }
    func testPlainSelectedPhotoDoesNotExposeAnEncryptedGalleryNeighbor() throws {
        try reference(); let plain = URL(string: "https://gallery.example.test/plain.png")!
        try reference(primary: "plain", metadata: ["name": "plain.png"], url: plain)
        let (chat, probe) = controller(); chat.didTapOnPhoto(message: "message", urls: [plain, source], url: plain, referencePrimary: "plain", isSensitive: false)
        XCTAssertTrue(probe.presented.isEmpty); complete(try XCTUnwrap(probe.requests.first))
        XCTAssertEqual(probe.presented.first?.1, [plain, localFile!]); XCTAssertEqual(probe.presented.first?.2, plain)
    }
    func testVoiceBuilderPreservesEncryptedMappedFallbackWhenReferenceIsAbsent() throws {
        let descriptor = ChatEncryptedAttachmentDescriptor(metadata: ["iv": "incomplete"], url: source, owner: owner, referenceIdentity: "missing")
        let audio = AudioAttachment(primary: "missing", url: source, size: 22, name: "voice", duration: 1, downloaded: false, pcm: [], encryptedAttachment: descriptor)
        let (chat, _) = controller(); let built = try XCTUnwrap(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(built.encryptedAttachment, descriptor)
    }
    func testMissingReferenceVoiceFallbackCannotBorrowAnotherAccountDescriptor() {
        let descriptor = ChatEncryptedAttachmentDescriptor(metadata: ["iv": "incomplete"], url: source,
            owner: "foreign@example.test", referenceIdentity: "missing")
        let audio = AudioAttachment(primary: "missing", url: source, size: 22, name: "voice", duration: 1,
            downloaded: false, pcm: [], encryptedAttachment: descriptor)
        let (chat, _) = controller()
        XCTAssertNil(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1)))
    }
    func testMissingReferenceVoiceFallbackCannotBorrowAnotherReferenceDescriptor() {
        let descriptor = ChatEncryptedAttachmentDescriptor(metadata: ["iv": "incomplete"], url: source,
            owner: owner, referenceIdentity: "other-reference")
        let audio = AudioAttachment(primary: "missing", url: source, size: 22, name: "voice", duration: 1,
            downloaded: false, pcm: [], encryptedAttachment: descriptor)
        let (chat, _) = controller()
        XCTAssertNil(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1)))
    }
    func testVoiceBuilderReplacesStaleMappedMetadataWithCurrentRealmBinding() throws {
        let ref = try reference(), descriptor = ChatEncryptedAttachmentDescriptor(metadata: ref.metadata, url: source, owner: owner, referenceIdentity: ref.primary)
        let audio = AudioAttachment(primary: ref.primary, url: source, size: 22, name: "voice", duration: 1, downloaded: false, pcm: [])
        let (chat, _) = controller(); let built = try XCTUnwrap(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(built.encryptedAttachment, descriptor)
        XCTAssertFalse(built.isLocallyAvailable)
        let realm = try WRealm.safe()
        try realm.write {
            ref.decodedUrl = localFile
            ref.isDownloaded = true
            var metadata = ref.metadata ?? [:]; metadata["authenticated-media-cache-identity"] = descriptor.cacheIdentity; ref.metadata = metadata
        }
        let cached = try XCTUnwrap(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(cached.authenticatedAttachmentCacheIdentity, descriptor.cacheIdentity)
        XCTAssertTrue(cached.isLocallyAvailable)
        try realm.write { ref.metadata = ["iv": "incomplete"] }
        XCTAssertEqual(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1))?.encryptedAttachment?.state, .invalid)
    }

    func testMissingGalleryNeighborRejectsTheWholeOpenWithoutCiphertextPresentation() throws {
        try reference(); let missing = URL(string: "https://gallery.example.test/missing.png")!
        let (chat, probe) = controller(); chat.didTapOnPhoto(message: "message", urls: [source, missing], url: source, referencePrimary: "reference", isSensitive: false)
        XCTAssertTrue(probe.requests.isEmpty); XCTAssertTrue(probe.presented.isEmpty)
    }

    private final class BackgroundWriteOutcome {
        private let lock = NSLock()
        private var error: Error?
        func save(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
        func rethrowIfFailed() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
    }
    private func replaceMetadataFromBackground(primary: String) throws {
        let configuration = try WRealm.safe().configuration, done = DispatchSemaphore(value: 0), outcome = BackgroundWriteOutcome()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            autoreleasepool {
                do {
                    let realm = try Realm(configuration: configuration)
                    guard let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary) else { return }
                    try realm.write { reference.metadata = ["iv": "incomplete"] }
                } catch { outcome.save(error) }
            }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        try outcome.rethrowIfFailed()
    }
    func testBackgroundMetadataCommitInvalidatesPendingOpenBeforeUIAutorefresh() throws {
        let ref = try reference(), realm = try WRealm.safe(); realm.autorefresh = false
        defer { realm.autorefresh = true }
        let (chat, probe) = controller(); chat.didTapOnFile(url: source)
        let request = try XCTUnwrap(probe.requests.first)
        try replaceMetadataFromBackground(primary: ref.primary)
        XCTAssertNotNil(ref.metadata?["encryption-key"], "Fixture must retain the old UI Realm version until admission refreshes it")
        complete(request); XCTAssertTrue(probe.presented.isEmpty)
    }
    func testVoiceBuilderRefreshesBackgroundMetadataBeforeUsingCachedUIRealm() throws {
        let ref = try reference(), realm = try WRealm.safe(); realm.autorefresh = false
        defer { realm.autorefresh = true }
        let audio = AudioAttachment(primary: ref.primary, url: source, size: 22, name: "voice", duration: 1, downloaded: false, pcm: [])
        let (chat, _) = controller(); try replaceMetadataFromBackground(primary: ref.primary)
        XCTAssertNotNil(ref.metadata?["encryption-key"])
        XCTAssertEqual(chat.voiceMessageDescriptor(audio: audio, containerPrimary: "message", sentDate: Date(timeIntervalSince1970: 1))?.encryptedAttachment?.state, .invalid)
    }
    func testUnattachedControllerCannotRetainOrPresentLocalDocumentPreview() {
        let (chat, _) = controller(); chat.mediaPresentationForTesting = nil
        chat.presentBoundMedia(kind: .file, urls: [localFile], url: localFile)
        XCTAssertNil(chat.documentPreviewURL)
    }

}
