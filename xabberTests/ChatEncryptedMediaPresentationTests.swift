import XCTest
import UIKit
import CryptoSwift
@testable import xabber

final class ChatEncryptedMediaPresentationTests: XCTestCase {
    func testNormalThumbnailLoaderAuthenticatesEncryptedBytesBeforeImageDecode() throws {
        try assertEncryptedThumbnailLoads(damageAuthenticationTag: false)
    }

    func testNormalThumbnailLoaderRejectsTamperedDataWithoutRawURLFallback() throws {
        try assertEncryptedThumbnailLoads(damageAuthenticationTag: true)
    }

    func testImageVideoVoiceAndDocumentRetainAuthenticatedResourceIdentity() throws {
        let image = reference(id: "image", mime: "image/png")
        let video = reference(id: "video", mime: "video/mp4")
        let voice = reference(id: "voice", mime: "audio/ogg", kind: .voice)
        let document = reference(id: "document", mime: "text/plain")

        let mapped = ChatViewController.mapReferenceAttachments([image, video, voice, document])
        let descriptors = [
            try XCTUnwrap(mapped.images.first?.encryptedAttachment),
            try XCTUnwrap(mapped.videos.first?.encryptedAttachment),
            try XCTUnwrap(mapped.audio.first?.encryptedAttachment),
            try XCTUnwrap(mapped.files.first?.encryptedAttachment)
        ]

        XCTAssertEqual(descriptors.map(\.referenceIdentity), ["image", "video", "voice", "document"])
        XCTAssertTrue(descriptors.allSatisfy(\.requiresAuthentication))
        XCTAssertTrue(descriptors.allSatisfy { $0.owner == "receiver@example.com" })
    }

    func testIncompleteEncryptionMetadataCannotBecomeAPlainImage() throws {
        let image = reference(id: "partial-key", mime: "image/png")
        var metadata = try XCTUnwrap(image.metadata)
        metadata.removeValue(forKey: "iv")
        image.metadata = metadata

        let mapped = ChatViewController.mapReferenceAttachments([image])
        let descriptor = try XCTUnwrap(mapped.images.first?.encryptedAttachment)

        XCTAssertEqual(descriptor.state, .invalid)
        XCTAssertTrue(descriptor.requiresAuthentication)
    }

    func testThumbnailCacheSeparatesOwnerAndEncryptionContextFromPlainURL() throws {
        let url = try XCTUnwrap(URL(string: "https://gallery.example/files/shared.png"))
        let metadata = try XCTUnwrap(reference(id: "first", mime: "image/png").metadata)
        let first = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: url, owner: "first@example.com", referenceIdentity: "first")
        let second = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: url, owner: "second@example.com", referenceIdentity: "second")
        let plain = ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1)
        let firstRequest = ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1, encryptedAttachment: first)
        let secondRequest = ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1, encryptedAttachment: second)

        XCTAssertNotEqual(firstRequest, plain)
        XCTAssertNotEqual(firstRequest.cacheKey, plain.cacheKey)
        XCTAssertNotEqual(firstRequest.cacheKey, secondRequest.cacheKey)
        XCTAssertFalse(firstRequest.cacheKey.contains(metadata["encryption-key"] as! String))
    }

    func testInvalidDescriptorCannotReadAnAuthenticatedThumbnailCacheEntry() throws {
        let url = try XCTUnwrap(URL(string: "https://gallery.example/files/shared.png"))
        let metadata = try XCTUnwrap(reference(id: "valid", mime: "image/png").metadata)
        let valid = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: url, owner: "receiver@example.com", referenceIdentity: "valid")
        let invalid = ChatEncryptedAttachmentDescriptor(metadata: metadata, url: url, owner: "receiver@example.com", referenceIdentity: "")
        XCTAssertEqual(valid.state, .encrypted)
        XCTAssertEqual(invalid.state, .invalid)
        // Failed admission must not read an image cached for an accepted reference.
        let validRequest = ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1, encryptedAttachment: valid)
        let invalidRequest = ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1, encryptedAttachment: invalid)
        XCTAssertNotEqual(validRequest.cacheKey, invalidRequest.cacheKey)
    }

    func testEncryptedImageSignatureChangesWhenAuthenticationContextChanges() throws {
        let image = reference(id: "image", mime: "image/png")
        let first = try XCTUnwrap(ChatViewController.mapReferenceAttachments([image]).images.first)
        var metadata = try XCTUnwrap(image.metadata)
        metadata["encryption-key"] = Data(repeating: 4, count: 16).base64EncodedString()
        image.metadata = metadata
        let second = try XCTUnwrap(ChatViewController.mapReferenceAttachments([image]).images.first)

        XCTAssertNotEqual(ChatImageAttachmentSignature(first), ChatImageAttachmentSignature(second))
    }

    func testPrefetchRetainsTheEncryptedImageSourceDescriptor() throws {
        let image = reference(id: "image", mime: "image/png")
        let attachment = try XCTUnwrap(ChatViewController.mapReferenceAttachments([image]).images.first)
        let prefetch = ChatCollectionPrefetchImageReference(primary: attachment.primary, url: attachment.url, encryptedAttachment: attachment.encryptedAttachment)

        XCTAssertEqual(prefetch.encryptedAttachment, attachment.encryptedAttachment)
        XCTAssertTrue(prefetch.encryptedAttachment?.requiresAuthentication == true)
    }

    func testOrdinaryEncryptedAudioUploadRemainsAnOpenableFile() throws {
        let reference = MessageReferenceStorageItem()
        reference.primary = "encrypted-audio-reference"
        reference.owner = "receiver@example.com"
        reference.jid = "sender@example.com"
        reference.kind = .media
        reference.mimeType = "audio"
        reference.url = "https://gallery.example/files/audio.wav"
        reference.name = "audio.wav"
        reference.metadata = [
            "name": "audio.wav",
            "media-type": "audio/wav",
            "size": 16044,
            "encryption-key": Data(repeating: 1, count: 16).base64EncodedString(),
            "iv": Data(repeating: 2, count: 16).base64EncodedString(),
            "hash": String(repeating: "03", count: 32)
        ]

        let mapped = ChatViewController.mapReferenceAttachments([reference])

        XCTAssertTrue(mapped.audio.isEmpty, "An uploaded WAV is a file, not a recorded voice message")
        let file = try XCTUnwrap(mapped.files.first)
        XCTAssertEqual(file.primary, reference.primary)
        XCTAssertEqual(file.name, "audio.wav")
        XCTAssertEqual(file.url?.absoluteString, reference.url)
    }

    private func reference(id: String, mime: String, kind: MessageReferenceStorageItem.Kind = .media) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = id
        reference.owner = "receiver@example.com"
        reference.jid = "sender@example.com"
        reference.kind = kind
        reference.mimeType = mime
        reference.url = "https://gallery.example/files/\(id)"
        reference.metadata = [
            "media-type": mime, "size": 128,
            "encryption-key": Data(repeating: 1, count: 16).base64EncodedString(),
            "iv": Data(repeating: 2, count: 16).base64EncodedString(),
            "hash": String(repeating: "03", count: 32)
        ]
        return reference
    }

    private func assertEncryptedThumbnailLoads(damageAuthenticationTag: Bool) throws {
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }.pngData())
        let key = Data(repeating: 1, count: 16)
        let iv = Data(repeating: 2, count: 16)
        var ciphertext = try XCTUnwrap(png.encrypt(key: Array(key), iv: Array(iv)))
        if damageAuthenticationTag { ciphertext[ciphertext.count - 1] ^= 1 }
        let url = try XCTUnwrap(URL(string: "https://encrypted-presentation.example/\(UUID()).png"))
        EncryptedPresentationURLProtocol.register(ciphertext, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EncryptedPresentationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EncryptedPresentation-\(UUID())")
        defer {
            session.invalidateAndCancel()
            EncryptedPresentationURLProtocol.remove(url)
            try? FileManager.default.removeItem(at: directory)
        }
        let descriptor = ChatEncryptedAttachmentDescriptor(
            metadata: [
                "encryption-key": key.base64EncodedString(), "iv": iv.base64EncodedString(),
                "hash": ciphertext.sha256().toHexString(), "size": png.count, "media-type": "image/png"
            ],
            url: url, owner: "receiver@example.com", referenceIdentity: "image"
        )
        let receiver = ChatEncryptedAttachmentReceiver(session: session, cacheDirectory: directory)
        let loader = KingfisherChatThumbnailLoader(attachmentReceiver: receiver)
        let done = expectation(description: "Normal thumbnail path completes")
        let task = loader.load(ChatThumbnailRequest(url: url, displaySize: .init(width: 64, height: 64), scale: 1, encryptedAttachment: descriptor)) { result in
            defer { done.fulfill() }
            if damageAuthenticationTag {
                guard case .failure(.loadFailed) = result else { return XCTFail("Tampered bytes must not become an image") }
            } else {
                guard case .success(let image) = result else { return XCTFail("Verified PNG must reach the standard image decoder") }
                XCTAssertGreaterThan(image.pixelSize.width, 0)
                XCTAssertGreaterThan(image.pixelSize.height, 0)
            }
        }
        defer { task.cancel() }
        withExtendedLifetime(loader) {
            wait(for: [done], timeout: 4)
        }
        XCTAssertEqual(EncryptedPresentationURLProtocol.requests(for: url), 1)
    }
}

private final class EncryptedPresentationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var payloads: [URL: Data] = [:]
    private static var counts: [URL: Int] = [:]

    static func register(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        payloads[url] = data; counts[url] = 0
    }
    static func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        payloads.removeValue(forKey: url); counts.removeValue(forKey: url)
    }
    static func requests(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[url] ?? 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "encrypted-presentation.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let data = Self.payloads[url]
        Self.counts[url, default: 0] += 1
        Self.lock.unlock()
        guard let data, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
