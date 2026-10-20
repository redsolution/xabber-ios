import CryptoKit
import CryptoSwift
import Foundation
import RealmSwift
import XCTest
@testable import xabber

final class ChatEncryptedAttachmentReceiverTests: XCTestCase {
    private let key = "Gbvf/UkBrz7CkRPQ93npug=="
    private let iv = "cCID9v7YmkIxJ1Lvq1H3vA=="
    // Independent OpenSSL/Node vector shared with the web AES-128-GCM profile.
    private let plaintext = Data(hex: "496e646570656e64656e7420694f53206174746163686d656e7420706172697479006279746573ff")
    private let ciphertext = Data(hex: "02e5bae68135bc736dce14ed1f4b52b28b9fdf8a0f8892e48f1a969c7d036a6b05ba9a570cf24d228d7e00c96ff2fb7b12ad45035fb4f940")
    private var directory: URL!
    private var session: URLSession!
    private var receiver: ChatEncryptedAttachmentReceiver!
    private var tasks: [ChatEncryptedAttachmentReceiveTask] = []
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUpWithError() throws {
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "EncryptedAttachment-\(UUID())")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatEncryptedAttachment-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EncryptedAttachmentURLProtocol.self]
        session = URLSession(configuration: configuration)
        receiver = ChatEncryptedAttachmentReceiver(session: session, cacheDirectory: directory)
        EncryptedAttachmentURLProtocol.reset(data: ciphertext)
    }
    override func tearDown() {
        tasks.forEach { $0.cancel() }; tasks = []
        session.invalidateAndCancel(); receiver = nil
        try? FileManager.default.removeItem(at: directory)
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        super.tearDown()
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func metadata(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["encryption-key": key, "iv": iv, "hash": hash(ciphertext), "size": plaintext.count,
         "name": "private.txt", "media-type": "text/plain"].merging(changes) { _, new in new }
    }
    private func descriptor(_ changes: [String: Any] = [:], owner: String = "owner@example.test", path: String = "file") -> ChatEncryptedAttachmentDescriptor {
        ChatEncryptedAttachmentDescriptor(metadata: metadata(changes), url: URL(string: "https://encrypted.example.test/\(path)")!, owner: owner, referenceIdentity: "reference")
    }
    private func receive(_ descriptor: ChatEncryptedAttachmentDescriptor) -> Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>? {
        let done = expectation(description: "Authenticated attachment completed")
        var result: Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>?
        tasks.append(receiver.receive(descriptor) { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value; done.fulfill()
        })
        wait(for: [done], timeout: 3)
        return result
    }
    private func validFile(_ descriptor: ChatEncryptedAttachmentDescriptor) -> ChatAuthenticatedAttachmentFile? {
        guard case let .success(file)? = receive(descriptor) else {
            XCTFail("Expected the standard receiver to authenticate and return a local plaintext file")
            return nil
        }
        return file
    }
    func testIndependentAES128GCMVectorReturnsVerifiedOriginalBytesAndHash() throws {
        guard let file = validFile(descriptor()) else { return }
        XCTAssertTrue(file.fileURL.isFileURL)
        XCTAssertEqual(try Data(contentsOf: file.fileURL), plaintext)
        XCTAssertEqual(file.byteCount, plaintext.count)
        XCTAssertEqual(file.plaintextSHA256, hash(plaintext))
        XCTAssertEqual(file.fileURL.pathExtension, "txt")
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 1)
    }
    func testCiphertextHashIsVerifiedBeforeDecryption() {
        guard case let .failure(error)? = receive(descriptor(["hash": String(repeating: "0", count: 64)])) else { return XCTFail("Expected hash rejection") }
        XCTAssertEqual(error, .ciphertextHashMismatch)
    }
    func testModifiedCombinedTagNeverCreatesPlaintextCache() {
        var damaged = ciphertext; damaged[damaged.count - 1] ^= 1
        EncryptedAttachmentURLProtocol.reset(data: damaged)
        guard case let .failure(error)? = receive(descriptor(["hash": hash(damaged)])) else { return XCTFail("Expected authentication rejection") }
        XCTAssertEqual(error, .authenticationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testAuthenticatedPlaintextMustMatchDeclaredOriginalSize() {
        guard case let .failure(error)? = receive(descriptor(["size": plaintext.count + 1])) else { return XCTFail("Expected size rejection") }
        XCTAssertEqual(error, .plaintextSizeMismatch)
    }
    func testIncompleteAndMalformedMetadataNeverBecomesPlaintextOrFetches() {
        let invalid: [[String: Any]] = [["encryption-key": ""], ["iv": "AA=="], ["hash": ""], ["hash": "not-a-hash"], ["encryption-key": key.replacingOccurrences(of: "==", with: "")], ["size": -1]]
        for changes in invalid {
            let value = descriptor(changes)
            XCTAssertEqual(value.state, .invalid)
            XCTAssertTrue(value.requiresAuthentication)
            guard case .failure(.invalidMetadata)? = receive(value) else { return XCTFail("Expected fail closed metadata") }
        }
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 0)
    }
    func testEitherESFSFieldAloneIsInvalidRatherThanAnUnencryptedFallback() {
        for metadata in [["iv": iv], ["encryption-key": key]] {
            let value = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: URL(string: "https://encrypted.example.test/file")!, owner: "owner@example.test", referenceIdentity: "r")
            XCTAssertEqual(value.state, .invalid); XCTAssertTrue(value.requiresAuthentication)
        }
    }
    func testPlaintextDescriptorPreservesExistingURLIdentity() {
        let url = URL(string: "https://encrypted.example.test/plain")!
        let value = ChatEncryptedAttachmentDescriptor(metadata: ["name": "plain.txt"], url: url, owner: "owner@example.test", referenceIdentity: "r")
        XCTAssertEqual(value.state, .plaintext)
        XCTAssertFalse(value.requiresAuthentication)
        XCTAssertEqual(value.cacheIdentity, url.absoluteString)
    }
    func testOwnerAndCryptographicBindingCannotShareACacheIdentity() {
        let initial = descriptor().cacheIdentity
        for value in [descriptor(owner: "other@example.test"), descriptor(["encryption-key": Data(repeating: 3, count: 16).base64EncodedString()]), descriptor(["iv": Data(repeating: 4, count: 16).base64EncodedString()]), descriptor(["hash": String(repeating: "a", count: 64)])] {
            XCTAssertNotEqual(initial, value.cacheIdentity)
        }
        XCTAssertFalse(initial.contains(key)); XCTAssertFalse(initial.contains(iv))
    }
    func testUnrelatedReferenceIdentityCanShareSameAuthenticatedResource() {
        let value = ChatEncryptedAttachmentDescriptor(metadata: metadata(), url: descriptor().sourceURL, owner: "owner@example.test", referenceIdentity: "other-reference")
        XCTAssertEqual(value.cacheIdentity, descriptor().cacheIdentity)
    }
    func testCachedPlaintextIsReusedWithoutAnotherHTTPDownload() throws {
        guard let first = validFile(descriptor()), let second = validFile(descriptor()) else { return }
        XCTAssertEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(try Data(contentsOf: second.fileURL), plaintext)
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 1)
    }
    func testDamagedLocalCacheCannotBeReturnedAsAuthenticatedPlaintext() throws {
        guard let first = validFile(descriptor()) else { return }
        try Data("tampered".utf8).write(to: first.fileURL)
        guard let second = validFile(descriptor()) else { return }
        XCTAssertEqual(try Data(contentsOf: second.fileURL), plaintext)
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 2)
    }
    func testSimultaneousConsumersShareOneCiphertextFetch() {
        let done = expectation(description: "Both consumers"); done.expectedFulfillmentCount = 2
        for _ in 0..<2 { tasks.append(receiver.receive(descriptor()) { result in
            guard case .success = result else { XCTFail("Expected authenticated file"); done.fulfill(); return }
            done.fulfill()
        }) }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 1)
    }
    func testCancelledConsumerCannotReceiveLatePlaintext() {
        let cancelled = expectation(description: "Cancelled consumer must not publish"); cancelled.isInverted = true
        let task = receiver.receive(descriptor()) { _ in cancelled.fulfill() }
        task.cancel()
        wait(for: [cancelled], timeout: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testCancellingOneSubscriberDoesNotCancelOtherConsumer() {
        let cancelled = expectation(description: "Cancelled"); cancelled.isInverted = true
        let completed = expectation(description: "Remaining subscriber")
        let first = receiver.receive(descriptor()) { _ in cancelled.fulfill() }
        tasks.append(receiver.receive(descriptor()) { result in
            if case .failure = result { XCTFail("Shared transfer must remain available") }
            completed.fulfill()
        })
        first.cancel()
        wait(for: [cancelled, completed], timeout: 0.2)
    }
    func testCredentialsFragmentsAndNonHTTPEncryptedSourcesNeverFetch() {
        for raw in ["https://user:secret@encrypted.example.test/file", "https://encrypted.example.test/file#secret", "file:///tmp/cipher"] {
            let value = ChatEncryptedAttachmentDescriptor(metadata: metadata(), url: URL(string: raw), owner: "owner@example.test", referenceIdentity: "r")
            XCTAssertEqual(value.state, .invalid)
            guard case .failure(.invalidMetadata)? = receive(value) else { return XCTFail("Unsafe resource admitted") }
        }
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 0)
    }
    func testCiphertextIsNeverAcceptedForHTTPFailure() {
        EncryptedAttachmentURLProtocol.reset(data: ciphertext, status: 403)
        guard case let .failure(error)? = receive(descriptor()) else { return XCTFail("Expected HTTP rejection") }
        XCTAssertEqual(error, .downloadFailed)
    }
    func testOversizedStalledCiphertextIsRejectedBeforeTheResponseFinishes() {
        // Foundation coalesces tiny URLProtocol chunks until EOF. Exceed its
        // transport buffer while withholding EOF to exercise actual streaming.
        EncryptedAttachmentURLProtocol.reset(data: Data(repeating: 1, count: 128 * 1_024), finishes: false)
        receiver = ChatEncryptedAttachmentReceiver(session: session, cacheDirectory: directory, maximumCiphertextBytes: 64)
        let done = expectation(description: "Size limit rejects an unfinished oversized response")
        var result: Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>?
        tasks.append(receiver.receive(descriptor()) { value in result = value; done.fulfill() })
        wait(for: [done], timeout: 1)
        guard case .failure(.tooLarge)? = result else { return XCTFail("The size limit must terminate the transfer before buffering the complete body") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProtectedVoiceUsesSharedAuthenticatedFileBeforeAudioDecoding() throws {
        let decoded = expectation(description: "Decode receives authenticated local bytes")
        let done = expectation(description: "Voice receive completes")
        let downloader = URLSessionVoiceMessageDownloader(attachmentReceiver: receiver) { [plaintext] url, _ in
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(try Data(contentsOf: url), plaintext)
            decoded.fulfill()
            return VoiceMessageDownloadedFile(decodedURL: url, duration: 1, pcm: [])
        }
        let voice = VoiceMessageDescriptor(referencePrimary: "encrypted-voice", containerMessagePrimary: "message", remoteURL: nil, decodedURL: nil, duration: 1, downloaded: false, pcm: [], sentDate: Date(timeIntervalSince1970: 1), encryptedAttachment: descriptor())
        let task = downloader.download(voice, progress: { _ in }) { result in
            if case .failure = result { XCTFail("Protected voice must use its authenticated resource rather than raw URL fallback") }
            if case let .success(file) = result { XCTAssertEqual(file.authenticatedAttachmentCacheIdentity, self.descriptor().cacheIdentity) }
            done.fulfill()
        }
        withExtendedLifetime(downloader) { withExtendedLifetime(task) { wait(for: [done, decoded], timeout: 1) } }
    }
    func testProtectedVoiceWithMalformedMetadataCannotUseRawOrDecodedFallback() {
        let done = expectation(description: "Protected voice rejected")
        let downloader = URLSessionVoiceMessageDownloader(attachmentReceiver: receiver) { _, _ in
            XCTFail("Malformed protected voice cannot reach audio decoding")
            return VoiceMessageDownloadedFile(decodedURL: URL(fileURLWithPath: "/tmp/invalid"), duration: 0, pcm: [])
        }
        let voice = VoiceMessageDescriptor(referencePrimary: "invalid-voice", containerMessagePrimary: "message", remoteURL: nil, decodedURL: nil, duration: 1, downloaded: false, pcm: [], sentDate: Date(timeIntervalSince1970: 1), encryptedAttachment: descriptor(["iv": "invalid"]))
        let task = downloader.download(voice, progress: { _ in }) { result in
            guard case let .failure(error) = result else { done.fulfill(); return XCTFail("Expected fail closed voice") }
            XCTAssertEqual(error as? ChatEncryptedAttachmentReceiveError, .invalidMetadata)
            done.fulfill()
        }
        withExtendedLifetime(downloader) { withExtendedLifetime(task) { wait(for: [done], timeout: 1) } }
        XCTAssertEqual(EncryptedAttachmentURLProtocol.requestCount, 0)
    }
    func testLegacyDownloadedVoiceFlagCannotBypassItsProtectedResourceBinding() {
        let voice = VoiceMessageDescriptor(referencePrimary: "voice", containerMessagePrimary: "message", remoteURL: nil, decodedURL: URL(fileURLWithPath: "/tmp/old-decoded"), duration: 1, downloaded: true, pcm: [], sentDate: Date(timeIntervalSince1970: 1), encryptedAttachment: descriptor())
        XCTAssertFalse(voice.isLocallyAvailable)
    }
    func testProtectedVoiceCancellationCannotReachDecoderOrCompletion() {
        let noCompletion = expectation(description: "Cancelled voice has no callback")
        noCompletion.isInverted = true
        let downloader = URLSessionVoiceMessageDownloader(attachmentReceiver: receiver) { _, _ in
            XCTFail("Cancelled protected voice cannot decode")
            return VoiceMessageDownloadedFile(decodedURL: URL(fileURLWithPath: "/tmp/invalid"), duration: 0, pcm: [])
        }
        let voice = VoiceMessageDescriptor(referencePrimary: "voice", containerMessagePrimary: "message", remoteURL: nil, decodedURL: nil, duration: 1, downloaded: false, pcm: [], sentDate: Date(timeIntervalSince1970: 1), encryptedAttachment: descriptor())
        let task = downloader.download(voice, progress: { _ in }) { _ in noCompletion.fulfill() }
        task.cancel()
        withExtendedLifetime(downloader) { wait(for: [noCompletion], timeout: 0.1) }
        // Cancellation may race with the initial HTTP start. Its guarantee is
        // that neither audio decoding nor the consumer callback can run late.
    }
    func testVoiceGalleryRetainsEncryptedMetadataWithoutAReferenceRow() throws {
        let realm = try WRealm.safe()
        let item = MessageMediaAttachmentStorageItem()
        item.primary = "protected-gallery-voice"; item.owner = "owner@example.test"; item.jid = "peer@example.test"
        item.kind = .voice; item.isEncrypted = true; item.url_ = "https://encrypted.example.test/file"
        item.date = Date(timeIntervalSince1970: 1); item.metadata = metadata()
        try realm.write { realm.add(item) }
        let value = MediaGalleryVoiceDescriptorMapper.descriptor(for: MediaGalleryDatasourceMapper.map(item, revealedSensitiveMediaPrimaries: []))
        XCTAssertEqual(value.encryptedAttachment?.state, .encrypted)
        XCTAssertEqual(value.encryptedAttachment?.cacheIdentity, descriptor().cacheIdentity)
        XCTAssertFalse(value.isLocallyAvailable)
    }
    func testLastChatsVoiceDescriptorRetainsEncryptedReferenceMetadata() throws {
        let realm = try WRealm.safe()
        let reference = MessageReferenceStorageItem()
        reference.primary = "protected-last-chats-voice"; reference.owner = "owner@example.test"; reference.jid = "peer@example.test"
        reference.kind = .voice; reference.url = "https://encrypted.example.test/file"; reference.metadata = metadata()
        reference.sentDate = Date(timeIntervalSince1970: 1)
        try realm.write { realm.add(reference) }
        let value = try XCTUnwrap(LastChatsViewController().sharedVoiceDescriptor(referencePrimary: reference.primary))
        XCTAssertEqual(value.encryptedAttachment?.state, .encrypted)
        XCTAssertEqual(value.encryptedAttachment?.cacheIdentity, descriptor().cacheIdentity)
    }
    private final class BackgroundWriteResult {
        private let lock = NSLock()
        private var error: Error?
        func record(_ value: Error) { lock.lock(); error = value; lock.unlock() }
        func rethrowError() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
    }
    private func staleVoiceReference() throws -> (Realm, MessageReferenceStorageItem, String) {
        let realm = try WRealm.safe()
        let reference = MessageReferenceStorageItem()
        reference.primary = "stale-protected-voice"; reference.owner = "owner@example.test"; reference.jid = "peer@example.test"
        reference.kind = .voice; reference.url = "https://encrypted.example.test/file"; reference.metadata = metadata()
        reference.sentDate = Date(timeIntervalSince1970: 1)
        try realm.write { realm.add(reference) }
        realm.autorefresh = false
        let configuration = realm.configuration, primary = reference.primary
        let newIV = Data(repeating: 9, count: 16).base64EncodedString()
        let done = DispatchSemaphore(value: 0), result = BackgroundWriteResult()
        Thread {
            autoreleasepool {
                do {
                    let background = try Realm(configuration: configuration)
                    let current = try XCTUnwrap(background.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: primary))
                    try background.write { var changed = current.metadata ?? [:]; changed["iv"] = newIV; current.metadata = changed }
                } catch { result.record(error) }
            }
            done.signal()
        }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        try result.rethrowError()
        XCTAssertEqual(reference.metadata?["iv"] as? String, iv, "Precondition: the main read version remains stale")
        return (realm, reference, newIV)
    }
    func testLastChatsVoiceDescriptorRefreshesBackgroundMetadataBeforeLocalReuse() throws {
        let (realm, reference, newIV) = try staleVoiceReference()
        defer { realm.autorefresh = true }
        let value = try XCTUnwrap(LastChatsViewController().sharedVoiceDescriptor(referencePrimary: reference.primary))
        XCTAssertEqual(value.encryptedAttachment?.cacheIdentity, descriptor(["iv": newIV]).cacheIdentity)
    }
    func testVoiceGalleryDescriptorRefreshesBackgroundMetadataBeforeLocalReuse() throws {
        let (realm, reference, newIV) = try staleVoiceReference()
        defer { realm.autorefresh = true }
        let item = MessageMediaAttachmentStorageItem()
        item.primary = reference.primary; item.owner = reference.owner; item.jid = reference.jid
        item.kind = .voice; item.url_ = reference.url!; item.metadata = metadata(); item.date = reference.sentDate
        let value = MediaGalleryVoiceDescriptorMapper.descriptor(for: MediaGalleryDatasourceMapper.map(item, revealedSensitiveMediaPrimaries: []))
        XCTAssertEqual(value.encryptedAttachment?.cacheIdentity, descriptor(["iv": newIV]).cacheIdentity)
    }
}

private final class EncryptedAttachmentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var status = 200
    private static var count = 0
    private static var finishes = true
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(data: Data, status: Int = 200, finishes: Bool = true) { lock.lock(); body = data; self.status = status; self.finishes = finishes; count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "encrypted.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let body = Self.body; let status = Self.status; let finishes = Self.finishes; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if finishes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
