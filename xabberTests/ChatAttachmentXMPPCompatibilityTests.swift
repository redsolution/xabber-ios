import XCTest
import XMPPFramework
@testable import xabber

final class ChatAttachmentXMPPCompatibilityTests: XCTestCase {
    private let owner = "romeo@example.com"
    private let jid = "juliet@example.com"

    func testVideoReferenceRoundTripsPreviewMetadata() throws {
        let reference = mediaReference(
            mediaType: "video/quicktime",
            name: "balcony.mov",
            metadata: [
                "width": 1920,
                "height": 1080,
                "size": 4096,
                "orientation": "landscapeRight",
                "video_duration": "1:02",
                "thumbnail": "video-preview-key"
            ]
        )

        let parsed = try roundTrip(reference, body: "Trip caption")

        XCTAssertEqual(parsed.mimeType, "video")
        XCTAssertEqual(parsed.metadata?["media-type"] as? String, "video/quicktime")
        XCTAssertEqual(parsed.metadata?["name"] as? String, "balcony.mov")
        XCTAssertEqual(parsed.metadata?["width"] as? Int, 1920)
        XCTAssertEqual(parsed.metadata?["height"] as? Int, 1080)
        XCTAssertEqual(parsed.metadata?["size"] as? Int, 4096)
        XCTAssertEqual(parsed.metadata?["orientation"] as? String, "landscapeRight")
        XCTAssertEqual(parsed.metadata?["video_duration"] as? String, "1:02")
        XCTAssertEqual(parsed.metadata?["uri"] as? String, "https://example.com/balcony.mov")
    }

    func testImageAnimatedAudioAndGenericFileReferencesRoundTrip() throws {
        let image = try roundTrip(mediaReference(mediaType: "image/jpeg", name: "photo.jpg"))
        XCTAssertEqual(image.mimeType, "image")
        XCTAssertEqual(image.metadata?["media-type"] as? String, "image/jpeg")
        XCTAssertEqual(image.metadata?["name"] as? String, "photo.jpg")

        let animatedImage = try roundTrip(mediaReference(mediaType: "image/gif", name: "dance.gif"))
        XCTAssertEqual(animatedImage.mimeType, "image")
        XCTAssertEqual(animatedImage.metadata?["media-type"] as? String, "image/gif")

        let audio = try roundTrip(mediaReference(
            mediaType: "audio/mpeg",
            name: "song.mp3",
            metadata: ["duration": 42]
        ))
        XCTAssertEqual(audio.mimeType, "audio")
        XCTAssertEqual(audio.duration, 42)
        XCTAssertEqual(audio.metadata?["media-type"] as? String, "audio/mpeg")

        let file = try roundTrip(mediaReference(mediaType: "application/pdf", name: "report.pdf"))
        XCTAssertEqual(file.mimeType, "pdf")
        XCTAssertEqual(file.metadata?["media-type"] as? String, "application/pdf")
        XCTAssertEqual(file.metadata?["name"] as? String, "report.pdf")
    }

    func testEncryptedMediaReferenceRoundTripsEncryptionMetadata() throws {
        let reference = mediaReference(
            mediaType: "image/jpeg",
            name: "secret.jpg",
            metadata: [
                "encryption-key": "key-material",
                "iv": "iv-material"
            ]
        )

        let parsed = try roundTrip(reference)

        XCTAssertEqual(parsed.metadata?["encryption-key"] as? String, "key-material")
        XCTAssertEqual(parsed.metadata?["iv"] as? String, "iv-material")
        XCTAssertEqual(parsed.metadata?["media-type"] as? String, "image/jpeg")
    }

    func testCaptionBodyDoesNotCorruptMediaReferenceOffsets() throws {
        let reference = mediaReference(mediaType: "image/jpeg", name: "captioned.jpg")
        reference.begin = 0
        reference.end = 0

        let message = try makeMessage(body: "Batch caption", references: [reference])
        let parsed = try XCTUnwrap(parseReferences(message, primary: "caption-primary", jid: jid, owner: owner).first)

        XCTAssertEqual(message.body, "Batch caption")
        XCTAssertEqual(parsed.begin, 0)
        XCTAssertEqual(parsed.end, 0)
        XCTAssertEqual(parsed.metadata?["uri"] as? String, "https://example.com/captioned.jpg")
    }

    func testPushPreviewKeepsCaptionedMediaBodyAndItemsStable() throws {
        let archiveXML = """
        <message from='juliet@example.com/mobile' to='romeo@example.com'>
          <body>Trip caption</body>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='0'>
            <file-sharing xmlns='https://xabber.com/protocol/files'>
              <file>
                <media-type>image/jpeg</media-type>
                <name>captioned.jpg</name>
                <size>3072</size>
              </file>
              <sources>
                <uri>https://example.com/captioned.jpg</uri>
              </sources>
            </file-sharing>
          </reference>
        </message>
        """

        let preview = try XCTUnwrap(PushNotificationArchiveParser.parseArchivedMessage(xmlString: archiveXML, owner: owner))

        XCTAssertEqual(preview.body, "Trip caption")
        XCTAssertEqual(preview.mediaItems.count, 1)
        XCTAssertEqual(preview.mediaItems.first?.kind, .image)
        XCTAssertEqual(preview.mediaItems.first?.filename, "captioned.jpg")
    }

    private func roundTrip(_ reference: MessageReferenceStorageItem, body: String = "") throws -> MessageReferenceStorageItem {
        let message = try makeMessage(body: body, references: [reference])
        return try XCTUnwrap(parseReferences(message, primary: UUID().uuidString, jid: jid, owner: owner).first)
    }

    private func makeMessage(body: String, references: [MessageReferenceStorageItem]) throws -> XMPPMessage {
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = jid
        item.body = body
        item.legacyBody = body
        item.conversationType = .regular
        item.references.append(objectsIn: references)

        let referencesXML = item.createReferences()
            .map { $0.xmlString }
            .joined(separator: "\n")
        let bodyXML = body.isEmpty ? "" : "<body>\(body)</body>"
        let xml = """
        <message from='\(jid)/mobile' to='\(owner)'>
          \(bodyXML)
          \(referencesXML)
        </message>
        """
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func mediaReference(
        mediaType: String,
        name: String,
        metadata extraMetadata: [String: Any] = [:]
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = MimeIcon(mediaType).value.rawValue
        reference.owner = owner
        reference.jid = jid
        reference.conversationType = .regular
        reference.begin = 0
        reference.end = 0
        var metadata: [String: Any] = [
            "uri": "https://example.com/\(name)",
            "media-type": mediaType,
            "name": name,
            "filename": name,
            "size": 1024
        ]
        extraMetadata.forEach { metadata[$0.key] = $0.value }
        reference.metadata = metadata
        return reference
    }
}
