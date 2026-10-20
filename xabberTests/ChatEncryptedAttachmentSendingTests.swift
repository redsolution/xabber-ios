import CryptoKit
import Foundation
import RealmSwift
import XCTest
@testable import xabber

final class ChatEncryptedAttachmentSendingTests: XCTestCase {
    private let plaintext = Data("public synthetic attachment fixture".utf8)
    private let key = Data(repeating: 3, count: 16)
    private let iv = Data(repeating: 4, count: 16)
    private var owner: String!
    private var file: URL!
    private var client: AttachmentUploadCapture!
    private var manager: XabberUploadManager!
    private var previousRealm: Realm.Configuration!
    private var previousDefault: Bool!
    private var previousClient: CloudStorageQuotaAPIClient!
    private var previousMonitor: (() -> AccountNetworkPathMonitoring?)!

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "AttachmentSending-\(UUID())")
        previousDefault = CommonConfigManager.shared.config.use_file_enryption_by_default
        CommonConfigManager.shared.config.use_file_enryption_by_default = false
        previousClient = XabberUploadManager.quotaAPIClient
        previousMonitor = XabberUploadManager.networkPathMonitorFactory
        client = AttachmentUploadCapture(); XabberUploadManager.quotaAPIClient = client
        XabberUploadManager.networkPathMonitorFactory = { nil }
        owner = "attachment-\(UUID().uuidString)@example.test"
        let configuration = AccountGalleryConfiguration(owner: owner)
        let base = URL(string: "https://gallery.example.test/api/")!
        configuration.storeBasicGalleryURL(base.absoluteString)
        configuration.storeToken("public-unit-test-token", galleryType: .basic, baseURL: base)
        manager = XabberUploadManager(withOwner: owner)
        file = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentSending-\(UUID()).bin")
        try plaintext.write(to: file)
    }

    override func tearDown() {
        manager = nil
        if let owner { AccountGalleryConfiguration(owner: owner).clearPersistedState() }
        XabberUploadManager.quotaAPIClient = previousClient
        XabberUploadManager.networkPathMonitorFactory = previousMonitor
        CommonConfigManager.shared.config.use_file_enryption_by_default = previousDefault
        Realm.Configuration.defaultConfiguration = previousRealm
        if let file { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }

    private func reference(type: ClientSynchronizationManager.ConversationType = .omemo,
                           kind: MessageReferenceStorageItem.Kind = .media,
                           protection: [String: Any] = [:]) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = UUID().uuidString; reference.owner = owner; reference.jid = "peer@example.test"
        reference.conversationType = type; reference.kind = kind; reference.mimeType = "file"
        reference.metadata = ["name": "fixture.bin", "filename": "fixture.bin", "media-type": "application/octet-stream", "size": plaintext.count]
            .merging(protection) { _, new in new }
        reference.localFileUrl = file
        return reference
    }
    private func persist(_ reference: MessageReferenceStorageItem) throws -> MessageStorageItem {
        let message = MessageStorageItem()
        message.owner = owner; message.opponent = reference.jid; message.messageId = UUID().uuidString
        message.conversationType = reference.conversationType; message.updatePrimary()
        reference.messageId = message.primary; message.references.append(reference)
        let realm = try WRealm.safe(); try realm.write { realm.add(message) }
        return message
    }
    private func upload(_ message: MessageStorageItem) {
        let finished = expectation(description: "Normal upload path returns")
        manager.getFileData(message: message.primary, successCallback: { finished.fulfill() }, failCallback: { finished.fulfill() })
        wait(for: [finished], timeout: 3)
    }
    private func configure(_ reference: MessageReferenceStorageItem) {
        let message = MessageStorageItem(); message.conversationType = reference.conversationType
        message.configureOutgoingMessage("", legacy: "", messageId: UUID().uuidString,
            owner: owner, opponent: reference.jid, references: [reference], inlineForwards: [])
    }
    func testOMEMONewMediaAndVoiceAlwaysGetEncryptionMaterialWhenDefaultIsDisabled() throws {
        for kind: MessageReferenceStorageItem.Kind in [.media, .voice] {
            let value = reference(kind: kind); configure(value)
            let encodedKey = try XCTUnwrap(value.metadata?["encryption-key"] as? String)
            let encodedIV = try XCTUnwrap(value.metadata?["iv"] as? String)
            XCTAssertEqual(Data(base64Encoded: encodedKey)?.count, 16)
            XCTAssertEqual(Data(base64Encoded: encodedIV)?.count, 16)
        }
    }
    func testOMEMOActualUploadAndSlotContainCiphertextWhenDefaultIsDisabled() throws {
        let value = reference(protection: ["encryption-key": key.base64EncodedString(), "iv": iv.base64EncodedString()])
        upload(try persist(value))
        let bytes = try XCTUnwrap(client.uploads.first)
        XCTAssertNotEqual(bytes, plaintext)
        XCTAssertEqual(bytes.count, plaintext.count + 16)
        XCTAssertEqual(try? Data.decrypt(bytes, key: Array(key), iv: Array(iv)), plaintext)
        XCTAssertEqual(client.slots.first?.size, bytes.count)
        XCTAssertEqual(client.slots.first?.hash, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func testOMEMOMissingKeysNeverReachUploadWhenDefaultIsDisabled() throws {
        upload(try persist(reference()))
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertTrue(client.slots.isEmpty)
    }
    func testOMEMOMalformedKeysNeverReachUploadWhenDefaultIsDisabled() throws {
        upload(try persist(reference(protection: ["encryption-key": "invalid", "iv": iv.base64EncodedString()])))
        XCTAssertTrue(client.uploads.isEmpty)
    }
    func testOMEMOInvalidIVLengthNeverReachesUploadWhenDefaultIsDisabled() throws {
        upload(try persist(reference(protection: ["encryption-key": key.base64EncodedString(), "iv": Data(repeating: 4, count: 15).base64EncodedString()])))
        XCTAssertTrue(client.uploads.isEmpty)
    }
    func testRegularAttachmentPreservesOriginalUploadBytesWhenDefaultIsDisabled() throws {
        let value = reference(type: .regular); configure(value)
        XCTAssertNil(value.metadata?["encryption-key"])
        upload(try persist(value))
        XCTAssertEqual(client.uploads, [plaintext])
    }
    func testAlreadyUploadedProtectedReferenceKeepsItsOriginalKeyAndIV() {
        let value = reference(protection: ["encryption-key": key.base64EncodedString(), "iv": iv.base64EncodedString()])
        value.isUploaded = true; configure(value)
        XCTAssertEqual(value.metadata?["encryption-key"] as? String, key.base64EncodedString())
        XCTAssertEqual(value.metadata?["iv"] as? String, iv.base64EncodedString())
    }
}

private final class AttachmentUploadCapture: CloudStorageQuotaAPIClient {
    var uploads: [Data] = []
    var slots: [CloudStorageUploadSlotRequest] = []
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, traceID: String, timeoutInterval: TimeInterval, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { slots.append(request); completion(.response(statusCode: 200, value: [:])) }
    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, fileMimeType: String, galleryMediaType: String, metadata: [String: String]?, context: String, traceID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { uploads.append(data); completion(.failure(statusCode: 418, error: nil)) }
    func deleteMedia(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteAvatar(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteGallery(baseURL: URL, token: String, jid: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getFiles(baseURL: URL, token: String, type: MimeIconTypes, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getAvatars(baseURL: URL, token: String, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteMediaForAll(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
}
