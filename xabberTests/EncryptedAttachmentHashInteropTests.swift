import CryptoKit
import AVFoundation
import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

final class EncryptedAttachmentHashInteropTests: XCTestCase {
    private let plaintext = Data("Public encrypted file fixture\u{0}media and voice\u{ff}".utf8)
    private let key = Data(repeating: 3, count: 16)
    private let iv = Data(repeating: 4, count: 16)
    private let peer = "peer@example.test"
    private var owner: String!
    private var localFile: URL!
    private var cacheDirectory: URL!
    private var previousRealm: Realm.Configuration!
    private var previousClient: CloudStorageQuotaAPIClient!
    private var previousMonitor: (() -> AccountNetworkPathMonitoring?)!
    private var client: HashInteropUploadClient!
    private var manager: XabberUploadManager!
    private var subscriptions: [ChatEncryptedAttachmentReceiveTask] = []

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "HashInterop-\(UUID())")
        previousClient = XabberUploadManager.quotaAPIClient
        previousMonitor = XabberUploadManager.networkPathMonitorFactory
        client = HashInteropUploadClient()
        XabberUploadManager.quotaAPIClient = client
        XabberUploadManager.networkPathMonitorFactory = { nil }
        owner = "hash-interop-\(UUID().uuidString)@example.test"
        let base = URL(string: "https://gallery.example.test/api/")!
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(base.absoluteString)
        configuration.storeToken("public-test-token", galleryType: .basic, baseURL: base)
        manager = XabberUploadManager(withOwner: owner)
        localFile = FileManager.default.temporaryDirectory.appendingPathComponent("HashInterop-\(UUID()).bin")
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HashInteropCache-\(UUID())")
        try plaintext.write(to: localFile)
    }

    override func tearDown() {
        subscriptions.forEach { $0.cancel() }; subscriptions = []
        manager = nil
        if let owner { AccountGalleryConfiguration(owner: owner).clearPersistedState() }
        XabberUploadManager.quotaAPIClient = previousClient
        XabberUploadManager.networkPathMonitorFactory = previousMonitor
        Realm.Configuration.defaultConfiguration = previousRealm
        if let localFile { try? FileManager.default.removeItem(at: localFile) }
        if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
        super.tearDown()
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func ciphertext() throws -> Data { try XCTUnwrap(try plaintext.encrypt(key: Array(key), iv: Array(iv))) }
    private func reference(_ kind: MessageReferenceStorageItem.Kind = .media) -> MessageReferenceStorageItem {
        let value = MessageReferenceStorageItem()
        value.primary = UUID().uuidString; value.owner = owner; value.jid = peer
        value.conversationType = .omemo; value.kind = kind; value.mimeType = kind == .voice ? "audio" : "file"
        value.metadata = ["name": "fixture.bin", "filename": "fixture.bin", "media-type": "application/octet-stream",
                          "size": plaintext.count, "encryption-key": key.base64EncodedString(), "iv": iv.base64EncodedString()]
        value.localFileUrl = localFile
        return value
    }
    private func upload(_ kind: MessageReferenceStorageItem.Kind = .media) throws -> MessageStorageItem {
        let item = MessageStorageItem(), value = reference(kind)
        item.owner = owner; item.opponent = peer; item.messageId = UUID().uuidString
        item.conversationType = .omemo; item.updatePrimary()
        value.messageId = item.primary; item.references.append(value)
        return try performUpload(item)
    }
    private func performUpload(_ item: MessageStorageItem) throws -> MessageStorageItem {
        let realm = try WRealm.safe(); try realm.write { realm.add(item) }
        let completed = expectation(description: "Real production upload completes")
        var succeeded = false
        manager.getFileData(message: item.primary, successCallback: { succeeded = true; completed.fulfill() }, failCallback: { completed.fulfill() })
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(succeeded)
        realm.refresh()
        return item
    }
    private func recordedAudio() throws -> URL {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let url = cacheDirectory.appendingPathComponent("Recorded voice.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<48_000 { samples[index] = Float(sin(Double(index) * 440 * 2 * .pi / 48_000)) * 0.1 }
        do {
            let recording = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try recording.write(from: buffer)
        }
        return url
    }
    private func wire(_ item: MessageStorageItem) throws -> XMPPMessage {
        let refs = item.createReferences().map(\.xmlString).joined()
        return try message(refs)
    }
    private func message(_ refs: String) throws -> XMPPMessage {
        let doc = try DDXMLDocument(xmlString: """
        <message xmlns='jabber:client' from='\(peer)/test' to='\(owner!)'>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner!)' stamp='2026-10-21T08:00:00Z'/>
          \(refs)
        </message>
        """, options: 0)
        return XMPPMessage(from: try XCTUnwrap(doc.rootElement()))
    }
    private func parse(_ message: XMPPMessage) throws -> MessageReferenceStorageItem {
        try XCTUnwrap(parseReferences(message, primary: UUID().uuidString, jid: peer, owner: owner).first)
    }
    private func parsed(_ hashes: String, voice: Bool = false, encryption: String? = nil, sizeXML: String? = nil) throws -> MessageReferenceStorageItem {
        let protection = encryption ?? "<encrypted xmlns='urn:xmpp:esfs:0'><key>\(key.base64EncodedString())</key><iv>\(iv.base64EncodedString())</iv></encrypted>"
        let size = sizeXML ?? "<size>\(plaintext.count)</size>"
        let content = """
        <file-sharing xmlns='https://xabber.com/protocol/files'><sources><uri>https://gallery.example.test/cipher</uri></sources><file>
          <media-type>application/octet-stream</media-type><name>fixture.bin</name>\(size)
          \(hashes)\(protection)
        </file></file-sharing>
        """
        let inner = voice ? "<voice-message xmlns='https://xabber.com/protocol/voice-messages'>\(content)</voice-message>" : content
        return try parse(message("<reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>\(inner)</reference>"))
    }
    private func canonical(_ data: Data, surrounding: String = "") -> String {
        "<hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>\(surrounding)\(Data(SHA256.hash(data: data)).base64EncodedString())\(surrounding)</hash>"
    }
    private func descriptor(_ value: MessageReferenceStorageItem) -> ChatEncryptedAttachmentDescriptor {
        ChatEncryptedAttachmentDescriptor(metadata: value.metadata, url: value.downloadUrl, owner: owner, referenceIdentity: value.primary)
    }
    private func receive(_ value: MessageReferenceStorageItem, bytes: Data) -> Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>? {
        HashInteropURLProtocol.body = bytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HashInteropURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receiver = ChatEncryptedAttachmentReceiver(session: session, cacheDirectory: cacheDirectory)
        let completed = expectation(description: "Production authenticated receiver completes")
        var result: Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>?
        subscriptions.append(receiver.receive(descriptor(value)) { result = $0; completed.fulfill() })
        wait(for: [completed], timeout: 3)
        return result
    }
    private func assertChain(_ kind: MessageReferenceStorageItem.Kind) throws {
        let item = try upload(kind), sent = try XCTUnwrap(client.uploads.first)
        XCTAssertNotEqual(sent, plaintext)
        XCTAssertEqual(try Data.decrypt(sent, key: Array(key), iv: Array(iv)), plaintext)
        let message = try wire(item)
        let hashes = try message.nodes(forXPath: ".//*[local-name()='hash']")
        let hash = try XCTUnwrap(hashes.first as? DDXMLElement)
        XCTAssertEqual(hashes.count, 1)
        XCTAssertEqual(hash.xmlns(), "urn:xmpp:hashes:2")
        XCTAssertEqual(hash.attributeStringValue(forName: "algo"), "sha-256")
        XCTAssertEqual(hash.stringValue, Data(SHA256.hash(data: sent)).base64EncodedString())
        let received = try parse(message)
        XCTAssertEqual(received.metadata?["hash"] as? String, digest(sent))
        XCTAssertEqual(descriptor(received).state, .encrypted)
        guard case let .success(file)? = receive(received, bytes: sent) else { return XCTFail("Exact original bytes must pass the real receiver") }
        XCTAssertEqual(try Data(contentsOf: file.fileURL), plaintext)
        XCTAssertEqual(file.plaintextSHA256, digest(plaintext))
    }

    func testGallerySHA1CannotReplaceLocallyComputedCiphertextSHA256() throws {
        let item = try upload(), sent = try XCTUnwrap(client.uploads.first)
        XCTAssertEqual(item.references.first?.metadata?["hash"] as? String, digest(sent))
        // Preserve the existing slot request's cipher-versus-plaintext input.
        // This is not a claim about the server's normative gallery hash contract.
        XCTAssertEqual(client.slots.first?.hash, digest(sent))
        XCTAssertNotEqual(digest(sent), digest(plaintext))
        XCTAssertEqual(client.returnedGalleryHash.count, 40)
        XCTAssertEqual(item.references.first?.metadata?["gallery-hash"] as? String, client.returnedGalleryHash)
    }
    func testRealMediaUploadSerializesCanonicalHashAndReceiverReturnsExactOriginal() throws { try assertChain(.media) }
    func testRealVoiceUploadSerializesCiphertextHashAndReceiverReturnsExactOriginal() throws { try assertChain(.voice) }
    func testUploadedVoiceSerializesProtectedSizeAndHashAfterOriginalLocalFileIsGone() throws {
        let item = try upload(.voice), sent = try XCTUnwrap(client.uploads.first)
        try FileManager.default.removeItem(at: localFile)
        let received = try parse(wire(item))
        XCTAssertEqual(received.metadata?["size"] as? Int, plaintext.count)
        XCTAssertEqual(received.metadata?["hash"] as? String, digest(sent))
        XCTAssertEqual(descriptor(received).state, .encrypted)
    }
    func testCanonicalHashParsesToInternalHexForMediaAndVoice() throws {
        let sent = try ciphertext()
        for voice in [false, true] { XCTAssertEqual(try parsed(canonical(sent), voice: voice).metadata?["hash"] as? String, digest(sent)) }
    }
    func testCanonicalHashPermitsSurroundingXMLWhitespace() throws {
        let sent = try ciphertext()
        XCTAssertEqual(try parsed(canonical(sent, surrounding: " \n\t")).metadata?["hash"] as? String, digest(sent))
    }
    func testPrefixedCanonicalHashAndExplicitEmptyNamespaceLegacyAreReadable() throws {
        let sent = try ciphertext()
        for hash in ["<h:hash xmlns:h='urn:xmpp:hashes:2' algo='sha-256'>\(Data(SHA256.hash(data: sent)).base64EncodedString())</h:hash>", "<hash xmlns=''>\(digest(sent).uppercased())</hash>"] {
            XCTAssertEqual(try parsed(hash).metadata?["hash"] as? String, digest(sent))
        }
    }
    func testForeignHashCannotShadowSupportedCanonicalHash() throws {
        let sent = try ciphertext()
        let hashes = "<hash xmlns='urn:foreign'>forged</hash>" + canonical(sent)
        XCTAssertEqual(try parsed(hashes).metadata?["hash"] as? String, digest(sent))
    }
    func testUnsupportedAlgorithmAlongsideOneValidSHA256DoesNotShadowIt() throws {
        let sent = try ciphertext()
        let hashes = "<hash xmlns='urn:xmpp:hashes:2' algo='sha-512'>AA==</hash>" + canonical(sent)
        XCTAssertEqual(try parsed(hashes).metadata?["hash"] as? String, digest(sent))
    }
    func testExistingLegacy64HexRemainsReadableAndNormalizesCaseWithoutStorageMigration() throws {
        let sent = try ciphertext(), received = try parsed("<hash>\(digest(sent).uppercased())</hash>")
        XCTAssertEqual(received.metadata?["hash"] as? String, digest(sent))
        XCTAssertEqual(descriptor(received).state, .encrypted)
        guard case let .success(file)? = receive(received, bytes: sent) else { return XCTFail("Legacy valid digest must remain readable") }
        XCTAssertEqual(try Data(contentsOf: file.fileURL), plaintext)
    }
    func testLegacyHashWithExplicitAlgorithmCannotMasqueradeAsImplicitSHA256() throws {
        let sent = try ciphertext()
        for algorithm in ["", "sha-1", "sha-256"] {
            let value = try parsed("<hash algo='\(algorithm)'>\(digest(sent))</hash>")
            XCTAssertEqual(descriptor(value).state, .invalid)
            XCTAssertTrue(descriptor(value).requiresAuthentication)
        }
    }
    func testForeignNamespacedAlgorithmAttributeDoesNotShadowValidLegacyDigest() throws {
        let sent = try ciphertext()
        let value = try parsed("<hash xmlns:f='urn:foreign' f:algo='sha-1'>\(digest(sent))</hash>")
        XCTAssertEqual(value.metadata?["hash"] as? String, digest(sent))
        XCTAssertEqual(descriptor(value).state, .encrypted)
    }
    func testCanonicalAndLegacyHashesTogetherAreAmbiguous() throws {
        let sent = try ciphertext(), value = try parsed(canonical(sent) + "<hash>\(digest(sent))</hash>")
        XCTAssertEqual(descriptor(value).state, .invalid)
        XCTAssertTrue(descriptor(value).requiresAuthentication)
    }
    func testDuplicateLegacyHashesAreRejectedEvenWhenEqual() throws {
        let sent = try ciphertext(), legacy = "<hash>\(digest(sent))</hash>"
        XCTAssertEqual(descriptor(try parsed(legacy + legacy)).state, .invalid)
    }
    func testDuplicateSupportedCanonicalHashesAreRejectedEvenWhenEqual() throws {
        let sent = try ciphertext(), hash = canonical(sent)
        XCTAssertEqual(descriptor(try parsed(hash + hash)).state, .invalid)
    }
    func testAnyCanonicalHashNamespaceSuppressesLegacyFallback() throws {
        let sent = try ciphertext(), legacy = "<hash>\(digest(sent))</hash>"
        for canonical in ["<hash xmlns='urn:xmpp:hashes:2' algo='sha-512'>AA==</hash>", "<hash xmlns='urn:xmpp:hashes:2'>AA==</hash>", "<hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>not-base64</hash>"] {
            let value = try parsed(canonical + legacy)
            XCTAssertEqual(descriptor(value).state, .invalid)
            XCTAssertTrue(descriptor(value).requiresAuthentication)
        }
    }
    func testMalformedCanonicalBase64AndWrongLengthRemainProtectedInvalid() throws {
        let sent = try ciphertext(), encoded = Data(SHA256.hash(data: sent)).base64EncodedString()
        for value in [String(encoded.dropLast()), String(encoded.prefix(5)) + " \n" + String(encoded.dropFirst(5)), Data(repeating: 1, count: 31).base64EncodedString(), digest(sent)] {
            let received = try parsed("<hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>\(value)</hash>")
            XCTAssertEqual(descriptor(received).state, .invalid)
            XCTAssertTrue(descriptor(received).requiresAuthentication)
        }
    }
    func testServer40HexNeverBecomesSHA256OrPlaintext() throws {
        let value = try parsed("<hash>\(String(repeating: "a", count: 40))</hash>")
        XCTAssertEqual(descriptor(value).state, .invalid)
        XCTAssertTrue(descriptor(value).requiresAuthentication)
    }
    func testForeignOnlyHashDoesNotBecomeAdvertisedIntegrityMetadata() throws {
        let value = try parsed("<hash xmlns='urn:foreign'>\(String(repeating: "a", count: 64))</hash>")
        XCTAssertNil(value.metadata?["hash"])
        XCTAssertEqual(descriptor(value).state, .encrypted)
        XCTAssertTrue(descriptor(value).requiresAuthentication)
    }
    func testAbsentHashIsOptionalForParsedProtectedMediaAndVoiceWithExactAuthenticatedBytes() throws {
        let sent = try ciphertext()
        for voice in [false, true] {
            let value = try parsed("", voice: voice)
            XCTAssertNil(value.metadata?["hash"], "Absence must not be converted into a malformed advertised empty digest")
            XCTAssertEqual(descriptor(value).state, .encrypted)
            guard case let .success(file)? = receive(value, bytes: sent) else { XCTFail("GCM authenticates valid hashless bytes"); continue }
            XCTAssertEqual(try Data(contentsOf: file.fileURL), plaintext)
        }
    }
    func testHashlessCiphertextStillRequiresValidGCMTag() throws {
        var damaged = try ciphertext(); damaged[damaged.count - 1] ^= 1
        guard case .failure(.authenticationFailed)? = receive(try parsed(""), bytes: damaged) else { return XCTFail("Optional digest must never bypass GCM authentication") }
    }
    func testHashlessCiphertextStillRequiresExactOriginalSize() throws {
        let value = try parsed("")
        value.metadata?["size"] = plaintext.count + 1
        guard case .failure(.plaintextSizeMismatch)? = receive(value, bytes: try ciphertext()) else { return XCTFail("Optional digest must never bypass original size check") }
    }
    func testHashlessCacheIdentityIsStableAndDistinctFromProvidedOrMalformedHash() throws {
        let first = try parsed(""), second = try parsed("")
        XCTAssertEqual(descriptor(first).cacheIdentity, descriptor(second).cacheIdentity)
        XCTAssertNotEqual(descriptor(first).cacheIdentity, descriptor(try parsed(canonical(ciphertext()))).cacheIdentity)
        second.metadata?["hash"] = ""
        XCTAssertEqual(descriptor(second).state, .invalid)
        XCTAssertNotEqual(descriptor(first).cacheIdentity, descriptor(second).cacheIdentity)
    }
    func testParsedHashlessMediaAndVoiceReserializeWithoutInventingDigestOrReadingLocalFile() throws {
        for voice in [false, true] {
            let original = try parsed("", voice: voice)
            let item = MessageStorageItem()
            item.owner = owner; item.opponent = peer; item.conversationType = .omemo
            item.references.append(original)
            let reconstructed = try parse(wire(item))
            XCTAssertNil(reconstructed.metadata?["hash"])
            XCTAssertEqual(descriptor(reconstructed).state, .encrypted)
            XCTAssertEqual(descriptor(original).cacheIdentity, descriptor(reconstructed).cacheIdentity)
            guard case let .success(file)? = receive(reconstructed, bytes: try ciphertext()) else { XCTFail("Re-shared hashless content must remain authenticated"); continue }
            XCTAssertEqual(try Data(contentsOf: file.fileURL), plaintext)
        }
    }
    func testReserializingMalformedAdvertisedHashCannotEraseItsInvalidState() throws {
        for voice in [false, true] {
            let original = try parsed("<hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>invalid</hash>", voice: voice)
            let item = MessageStorageItem()
            item.owner = owner; item.opponent = peer; item.conversationType = .omemo; item.references.append(original)
            let reconstructed = try parse(wire(item))
            XCTAssertEqual(reconstructed.metadata?["hash"] as? String, "")
            XCTAssertEqual(descriptor(reconstructed).state, .invalid)
            XCTAssertTrue(descriptor(reconstructed).requiresAuthentication)
        }
    }
    func testRealVoiceBuilderRawFileURLIsEncodedAndUploadedWithActualOGGSizeAndCipherDigest() throws {
        let raw = try recordedAudio()
        XCTAssertTrue(raw.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        let preparedFixture = try AudioMessageReceiver.shared.encode(url: raw)
        XCTAssertEqual(String(data: try Data(contentsOf: preparedFixture).prefix(4), encoding: .ascii), "OggS",
            "The same raw file must be valid for the real encoder before testing upload URL handling")
        try FileManager.default.removeItem(at: preparedFixture)
        let value = VoiceMessageReferenceBuilder.make(owner: owner, jid: peer, conversationType: .omemo,
            rawUrl: raw, duration: 1, meteringLevels: [0.1, 0.2])
        XCTAssertNil(value.metadata?["size"], "Real recorder builder does not pre-populate the prepared OGG size")
        XCTAssertNil(value.localFileUrl)
        let item = MessageStorageItem(); item.conversationType = .omemo
        item.configureOutgoingMessage("", legacy: "", messageId: UUID().uuidString, owner: owner,
            opponent: peer, references: [value], inlineForwards: [])
        try performUpload(item)
        let encoded = try XCTUnwrap(value.localFileUrl)
        defer { try? FileManager.default.removeItem(at: encoded) }
        let ogg = try Data(contentsOf: encoded), cipher = try XCTUnwrap(client.uploads.first)
        XCTAssertEqual(String(data: ogg.prefix(4), encoding: .ascii), "OggS")
        XCTAssertEqual(value.metadata?["size"] as? Int, ogg.count)
        XCTAssertEqual(value.metadata?["hash"] as? String, digest(cipher))
        let received = try parse(wire(item))
        XCTAssertEqual(descriptor(received).state, .encrypted)
        guard case let .success(file)? = receive(received, bytes: cipher) else { return XCTFail("Normal recorded voice must authenticate exact encoded OGG bytes") }
        XCTAssertEqual(try Data(contentsOf: file.fileURL), ogg)
    }
    func testCanonicalDigestDoesNotAuthorizeTamperedCiphertextOrForgedGCMTag() throws {
        let original = try ciphertext(); var damaged = original; damaged[damaged.count - 1] ^= 1
        guard case .failure(.ciphertextHashMismatch)? = receive(try parsed(canonical(original)), bytes: damaged) else { return XCTFail("Changed cipher bytes must fail hash verification") }
        guard case .failure(.authenticationFailed)? = receive(try parsed(canonical(damaged)), bytes: damaged) else { return XCTFail("Even matching hash cannot replace GCM authentication") }
    }
    func testIncompleteOrMalformedExactESFSNeverFallsBackToPlaintextForMediaOrVoice() throws {
        let k = "<key>\(key.base64EncodedString())</key>", v = "<iv>\(iv.base64EncodedString())</iv>"
        for voice in [false, true] {
            for fields in [k, v, "", "<key/>" + v, "<key>not-base64</key>" + v, k + "<iv>AA==</iv>"] {
                let value = try parsed("", voice: voice, encryption: "<encrypted xmlns='urn:xmpp:esfs:0'>\(fields)</encrypted>")
                XCTAssertEqual(descriptor(value).state, .invalid)
                XCTAssertTrue(descriptor(value).requiresAuthentication)
                XCTAssertNotNil(value.metadata?["encryption-key"])
                XCTAssertNotNil(value.metadata?["iv"])
            }
        }
    }
    func testDuplicateExactESFSContainersOrFieldsRemainProtectedInvalid() throws {
        let k = "<key>\(key.base64EncodedString())</key>", v = "<iv>\(iv.base64EncodedString())</iv>"
        let valid = "<encrypted xmlns='urn:xmpp:esfs:0'>\(k)\(v)</encrypted>"
        for voice in [false, true] {
            for xml in [valid + valid, "<encrypted xmlns='urn:xmpp:esfs:0'>\(k)\(k)\(v)</encrypted>", "<encrypted xmlns='urn:xmpp:esfs:0'>\(k)\(v)\(v)</encrypted>"] {
                let value = try parsed("", voice: voice, encryption: xml)
                XCTAssertEqual(descriptor(value).state, .invalid)
                XCTAssertTrue(descriptor(value).requiresAuthentication)
            }
        }
    }
    func testForeignESFSElementsAndFieldsCannotShadowValidExactProtection() throws {
        let fields = "<key xmlns='urn:foreign'>forged</key><iv xmlns='urn:foreign'>forged</iv><key>\(key.base64EncodedString())</key><iv>\(iv.base64EncodedString())</iv>"
        let xml = "<encrypted xmlns='urn:foreign'><key>forged</key></encrypted><encrypted xmlns='urn:xmpp:esfs:0'>\(fields)</encrypted>"
        for voice in [false, true] {
            let value = try parsed("", voice: voice, encryption: xml)
            XCTAssertEqual(value.metadata?["encryption-key"] as? String, key.base64EncodedString())
            XCTAssertEqual(value.metadata?["iv"] as? String, iv.base64EncodedString())
            XCTAssertEqual(descriptor(value).state, .encrypted)
        }
    }
    func testPartialOrMalformedProtectedMetadataCannotSerializeAsPlaintext() throws {
        for kind: MessageReferenceStorageItem.Kind in [.media, .voice] {
            for missing in ["encryption-key", "iv"] {
                for malformed in [false, true] {
                    let value = reference(kind)
                    value.url = "https://gallery.example.test/cipher"
                    value.metadata?["uri"] = value.url
                    if malformed { value.metadata?[missing] = 7 } else { value.metadata?[missing] = nil }
                    XCTAssertEqual(descriptor(value).state, .invalid)
                    let item = MessageStorageItem()
                    item.owner = owner; item.opponent = peer; item.conversationType = .omemo; item.references.append(value)
                    let reconstructed = try parse(wire(item))
                    XCTAssertEqual(descriptor(reconstructed).state, .invalid)
                    XCTAssertTrue(descriptor(reconstructed).requiresAuthentication)
                }
            }
        }
    }
    func testMissingOrMalformedProtectedSizeCannotAuthenticateAnEmptyFile() throws {
        let emptyCipher = try XCTUnwrap(try Data().encrypt(key: Array(key), iv: Array(iv)))
        for voice in [false, true] {
            for size in ["", "<size/>", "<size>not-a-number</size>", "<size>0garbage</size>", "<size>0.5</size>", "<size>-1</size>", "<size>+0</size>", "<size>9007199254740992</size>", "<size><foreign xmlns='urn:foreign'/>0</size>"] {
                let value = try parsed("", voice: voice, sizeXML: size)
                XCTAssertEqual(descriptor(value).state, .invalid)
                XCTAssertTrue(descriptor(value).requiresAuthentication)
                guard case .failure(.invalidMetadata)? = receive(value, bytes: emptyCipher) else { XCTFail("Invalid required XML size must not become an authenticated zero-byte file"); continue }
            }
        }
    }
    func testDuplicateProtectedSizesRemainInvalidEvenWhenValuesAgree() throws {
        for voice in [false, true] {
            let value = try parsed("", voice: voice, sizeXML: "<size>0</size><size>0</size>")
            XCTAssertEqual(descriptor(value).state, .invalid)
            XCTAssertTrue(descriptor(value).requiresAuthentication)
        }
    }
    func testLiteralZeroSizeWithOptionalHashAuthenticatesEmptyMediaAndVoice() throws {
        let emptyCipher = try XCTUnwrap(try Data().encrypt(key: Array(key), iv: Array(iv)))
        for voice in [false, true] {
            for size in ["<size>0</size>", "<size> \n000\t </size>", "<size xmlns='urn:foreign'>forged</size><size>0</size>"] {
                let value = try parsed("", voice: voice, sizeXML: size)
                XCTAssertEqual(descriptor(value).state, .encrypted)
                guard case let .success(file)? = receive(value, bytes: emptyCipher) else { XCTFail("Literal zero is valid and must still verify GCM"); continue }
                XCTAssertEqual(file.byteCount, 0)
                XCTAssertEqual(try Data(contentsOf: file.fileURL), Data())
            }
        }
    }
}

private final class HashInteropURLProtocol: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "gallery.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HashInteropUploadClient: CloudStorageQuotaAPIClient {
    var uploads: [Data] = []
    var slots: [CloudStorageUploadSlotRequest] = []
    var returnedGalleryHash = ""
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, traceID: String, timeoutInterval: TimeInterval, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { slots.append(request); completion(.response(statusCode: 200, value: [:])) }
    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, fileMimeType: String, galleryMediaType: String, metadata: [String: String]?, context: String, traceID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        uploads.append(data)
        returnedGalleryHash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        completion(.response(statusCode: 200, value: ["file": "https://gallery.example.test/cipher", "name": filename, "hash": returnedGalleryHash, "quota": 1000000, "used": data.count, "id": 77]))
    }
    func deleteMedia(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteAvatar(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteGallery(baseURL: URL, token: String, jid: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getFiles(baseURL: URL, token: String, type: MimeIconTypes, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getAvatars(baseURL: URL, token: String, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
    func deleteMediaForAll(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) { completion(.failure(statusCode: 418, error: nil)) }
}
