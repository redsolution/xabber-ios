import XCTest
import XMPPFramework
import UIKit
@testable import xabber

final class ChatAttachmentXMPPCompatibilityTests: XCTestCase {
    private let owner = "romeo@example.com"
    private let jid = "juliet@example.com"

    func testFilePresentationPrefersSemanticReferenceNameOverTransportFilename() throws {
        let sourceURL = "https://gallery.example/files/opaque-token/server-generated-name.bin"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references'
                       type='mutable'
                       begin='0'
                       end='\(sourceURL.xmlEscaping(reverse: false).unicodeScalars.count)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file>
                  <media-type>application/pdf</media-type>
                  <name>Quarterly Report.pdf</name>
                  <size>4096</size>
                </file>
                <sources>
                  <uri>\(sourceURL)</uri>
                </sources>
              </file-sharing>
            </reference>
            """,
            body: sourceURL
        )
        let reference = try XCTUnwrap(
            parseReferences(
                message,
                primary: "semantic-file-name-message",
                jid: jid,
                owner: owner
            ).first
        )
        var metadata = try XCTUnwrap(reference.metadata)
        metadata["filename"] = "server-generated-name.bin"
        reference.metadata = metadata

        let mapped = ChatViewController.mapReferenceAttachments([reference])
        let file = try XCTUnwrap(mapped.files.first)

        XCTAssertEqual(file.name, "Quarterly Report.pdf")
        XCTAssertEqual(file.presentation.displayName, "Quarterly Report.pdf")
    }

    func testIncomingImageRetainsAndUsesRemoteWireThumbnailForInlinePresentation() throws {
        let sourceURL = "https://gallery.example/files/opaque-token/full-size.png"
        let thumbnailURL = "https://gallery.example/files/opaque-token/thumb_full-size.png"
        let fallbackLength = sourceURL.xmlEscaping(reverse: false).unicodeScalars.count
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references'
                       type='mutable'
                       begin='0'
                       end='\(fallbackLength)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file>
                  <media-type>image/png</media-type>
                  <thumbnail xmlns='urn:xmpp:thumbs:1'
                             width='320'
                             height='260'
                             media-type='image/png'
                             uri='\(thumbnailURL)'/>
                  <name>Screenshot.png</name>
                  <size>373348</size>
                  <height>731</height>
                  <width>900</width>
                </file>
                <sources>
                  <uri>\(sourceURL)</uri>
                </sources>
              </file-sharing>
            </reference>
            """,
            body: sourceURL
        )
        let parsed = try XCTUnwrap(
            parseReferences(
                message,
                primary: "remote-thumbnail-message",
                jid: jid,
                owner: owner
            ).first
        )

        XCTAssertEqual(parsed.metadata?["thumbnail-uri"] as? String, thumbnailURL)
        XCTAssertEqual(parsed.downloadUrl?.absoluteString, sourceURL)
        let image = try XCTUnwrap(
            ChatViewController.mapReferenceAttachments([parsed]).images.first
        )
        XCTAssertEqual(image.url?.absoluteString, sourceURL)
        XCTAssertEqual(
            image.previewUrl?.absoluteString,
            thumbnailURL,
            "The bounded wire thumbnail must remain distinct from the full source used for opening and download."
        )
    }

    func testAlreadyPercentEncodedMediaSourceAndThumbnailRemainCanonical() throws {
        let sourceURL = "https://gallery.example/files/Trip%20Photos/photo%2Bfinal.png?token=a%2Fb"
        let thumbnailURL = "https://gallery.example/files/Trip%20Photos/thumb%2Bfinal.png?token=c%2Fd"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references'
                       type='mutable'
                       begin='0'
                       end='\(sourceURL.unicodeScalars.count)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file>
                  <media-type>image/png</media-type>
                  <thumbnail xmlns='urn:xmpp:thumbs:1'
                             width='320'
                             height='260'
                             media-type='image/png'
                             uri='\(thumbnailURL)'/>
                  <name>photo final.png</name>
                </file>
                <sources>
                  <uri>\(sourceURL)</uri>
                </sources>
              </file-sharing>
            </reference>
            """,
            body: sourceURL
        )
        let reference = try XCTUnwrap(
            parseReferences(
                message,
                primary: "percent-encoded-media-message",
                jid: jid,
                owner: owner
            ).first
        )

        XCTAssertEqual(reference.downloadUrl?.absoluteString, sourceURL)
        let image = try XCTUnwrap(
            ChatViewController.mapReferenceAttachments([reference]).images.first
        )
        XCTAssertEqual(image.url?.absoluteString, sourceURL)
        XCTAssertEqual(image.previewUrl?.absoluteString, thumbnailURL)
    }

    func testPersistedDataImageThumbnailBecomesBoundedTimelinePreview() throws {
        let sourceURL = "https://gallery.example/files/data-thumbnail.png"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let thumbnailData = try XCTUnwrap(image.pngData())
        let thumbnailURI = "data:image/png;base64,\(thumbnailData.base64EncodedString())"
        let messagePrimary = "data-thumbnail-message-\(UUID().uuidString)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references'
                       type='mutable'
                       begin='0'
                       end='\(sourceURL.unicodeScalars.count)'>
              <file-sharing xmlns='https://xabber.com/protocol/files'>
                <file>
                  <media-type>image/png</media-type>
                  <thumbnail xmlns='urn:xmpp:thumbs:1'
                             width='2'
                             height='2'
                             media-type='image/png'
                             uri='\(thumbnailURI)'/>
                  <name>data-thumbnail.png</name>
                </file>
                <sources>
                  <uri>\(sourceURL)</uri>
                </sources>
              </file-sharing>
            </reference>
            """,
            body: sourceURL
        )
        let reference = try XCTUnwrap(
            parseReferences(
                message,
                primary: messagePrimary,
                jid: jid,
                owner: owner
            ).first
        )
        let attachment = try XCTUnwrap(reference.pendingMediaAttachment)
        reference.messageId = messagePrimary
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(reference, update: .modified)
            realm.add(attachment, update: .modified)
        }
        defer {
            try? realm.write {
                realm.delete(reference)
                realm.delete(attachment)
            }
        }
        reference.pendingMediaAttachment = nil

        let mapped = ChatViewController.mapReferenceAttachments([reference])

        XCTAssertEqual(mapped.images.first?.previewUrl?.absoluteString, thumbnailURI)
        XCTAssertEqual(mapped.images.first?.url?.absoluteString, sourceURL)
    }

    func testEmptySemanticFileNameFallsBackToTransportFilename() throws {
        let reference = mediaReference(
            mediaType: "application/octet-stream",
            name: "   "
        )
        var metadata = try XCTUnwrap(reference.metadata)
        metadata["filename"] = "transport-report.bin"
        reference.metadata = metadata

        let file = try XCTUnwrap(
            ChatViewController.mapReferenceAttachments([reference]).files.first
        )

        XCTAssertEqual(file.name, "transport-report.bin")
    }

    func testEmptySemanticAndTransportFileNamesUseGenericFallback() throws {
        let reference = mediaReference(
            mediaType: "application/octet-stream",
            name: "\n  "
        )
        var metadata = try XCTUnwrap(reference.metadata)
        metadata["filename"] = "\t"
        reference.metadata = metadata

        let file = try XCTUnwrap(
            ChatViewController.mapReferenceAttachments([reference]).files.first
        )

        XCTAssertEqual(file.name, "file")
    }

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

    func testUploadedRemoteMediaReferenceBuildsNonEmptyFallbackBodyForDelivery() throws {
        let remoteURL = "https://gallery.example/files/xabber-logs-20260610-104307-anomaly-warn.zip"
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = "file"
        reference.url = remoteURL
        reference.isUploaded = true
        reference.metadata = [
            "media-type": "application/zip",
            "name": "xabber-logs-20260610-104307-anomaly-warn.zip",
            "size": 136951,
            "hash": "remote-hash"
        ]
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.references.append(reference)

        item.createLegacyBody()
        let referenceElement = try XCTUnwrap(item.createReferences().first)
        let uriElement = try XCTUnwrap(referenceElement
            .element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files")?
            .element(forName: "sources")?
            .element(forName: "uri"))

        XCTAssertEqual(item.legacyBody, remoteURL)
        XCTAssertEqual(item.references.first?.begin, 0)
        XCTAssertEqual(item.references.first?.end, remoteURL.xmlEscaping(reverse: false).unicodeScalars.count)
        XCTAssertEqual(uriElement.stringValue, remoteURL)
    }

    func testMediaFallbackRangesSeparateCaptionAndMultipleAttachments() throws {
        let caption = "Look & 👨🏿‍🚀"
        let first = mediaReference(mediaType: "image/jpeg", name: "first.jpg")
        let second = mediaReference(mediaType: "application/pdf", name: "second.pdf")
        let firstURI = try XCTUnwrap(first.fileSharingURI)
        let secondURI = try XCTUnwrap(second.fileSharingURI)
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.legacyBody = caption
        item.references.append(objectsIn: [first, second])

        item.createLegacyBody()
        let referenceElements = item.createReferences()
        let firstBegin = "\(caption)\n".xmlEscaping(reverse: false).unicodeScalars.count
        let firstEnd = firstBegin + firstURI.xmlEscaping(reverse: false).unicodeScalars.count
        let secondBegin = firstEnd + 1
        let secondEnd = secondBegin + secondURI.xmlEscaping(reverse: false).unicodeScalars.count

        XCTAssertEqual(item.legacyBody, "\(caption)\n\(firstURI)\n\(secondURI)")
        XCTAssertEqual(first.begin, firstBegin)
        XCTAssertEqual(first.end, firstEnd)
        XCTAssertEqual(second.begin, secondBegin)
        XCTAssertEqual(second.end, secondEnd)
        XCTAssertEqual(referenceElements[0].attributeIntegerValue(forName: "begin"), firstBegin)
        XCTAssertEqual(referenceElements[0].attributeIntegerValue(forName: "end"), firstEnd)
        XCTAssertEqual(referenceElements[1].attributeIntegerValue(forName: "begin"), secondBegin)
        XCTAssertEqual(referenceElements[1].attributeIntegerValue(forName: "end"), secondEnd)
    }

    func testVoiceFallbackRangeCoversItsCompletePlainTextFallback() {
        let uri = "https://example.com/voice.ogg"
        let reference = MessageReferenceStorageItem()
        reference.kind = .voice
        reference.mimeType = "audio"
        reference.url = uri
        reference.metadata = ["duration": 12.0, "uri": uri]
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.references.append(reference)

        item.createLegacyBody()

        XCTAssertEqual(reference.begin, 0)
        XCTAssertEqual(reference.end, item.legacyBody.xmlEscaping(reverse: false).unicodeScalars.count)
        XCTAssertFalse(item.legacyBody.hasSuffix("\n"))
        XCTAssertTrue(item.legacyBody.hasSuffix(uri))
    }

    func testValidIncomingMediaReferenceHidesOnlyItsFallbackBody() throws {
        let fallback = "https://example.com/photo.jpg"
        let message = try makeMessage(
            referenceXML: mediaReferenceXML(begin: "0", end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count)"),
            body: fallback
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.references.count, 1)
        XCTAssertEqual(item.references.first?.kind, .media)
    }

    func testMalformedIncomingMediaReferenceKeepsFallbackBodyVisible() throws {
        let fallback = "https://example.com/photo.jpg"
        let invalidReferences = [
            mediaReferenceXML(begin: "0", end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count + 1)"),
            mediaReferenceXML(begin: nil, end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count)"),
            mediaReferenceXML(begin: "not-a-number", end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count)"),
            mediaReferenceXML(begin: "-1", end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count)"),
            mediaReferenceXML(begin: "8", end: "3")
        ]

        for referenceXML in invalidReferences {
            let message = try makeMessage(referenceXML: referenceXML, body: fallback)
            let item = MessageStorageItem()

            item.configureIncomingMessage(
                message,
                owner: owner,
                opponent: jid,
                outgoing: false,
                isRead: false,
                date: Date(timeIntervalSince1970: 10)
            )

            XCTAssertTrue(item.references.isEmpty)
            XCTAssertEqual(item.body, fallback)
        }
    }

    func testMalformedIncomingVoiceReferenceKeepsFallbackBodyVisible() throws {
        let fallback = "Voice message\nhttps://example.com/voice.ogg"
        let message = try makeMessage(
            referenceXML: voiceReferenceXML(
                begin: "0",
                end: "\(fallback.xmlEscaping(reverse: false).unicodeScalars.count + 1)"
            ),
            body: fallback
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(item.references.isEmpty)
        XCTAssertEqual(item.body, fallback)
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

    func testGeolocReferenceRoundTripsXEPGEO() throws {
        let body = "geo:51.5007,-0.1246"
        let reference = geolocReference(
            latitude: "51.5007",
            longitude: "-0.1246",
            body: body,
            metadata: [
                "accuracy": "12",
                "text": "Westminster",
                "timestamp": "2026-06-30T06:00:00Z",
                "local-snapshot-url": "file:///tmp/location-snapshot.png"
            ]
        )

        let message = try makeMessage(body: body, references: [reference])
        let referenceElement = try XCTUnwrap(message.elements(forName: "reference").first)
        let geolocElement = try XCTUnwrap(referenceElement.element(
            forName: "geoloc",
            xmlns: "http://jabber.org/protocol/geoloc"
        ))
        XCTAssertEqual(referenceElement.attributeStringValue(forName: "type"), "mutable")
        XCTAssertEqual(geolocElement.element(forName: "lat")?.stringValue, "51.5007")
        XCTAssertEqual(geolocElement.element(forName: "lon")?.stringValue, "-0.1246")
        XCTAssertNil(geolocElement.element(forName: "local-snapshot-url"))

        let parsed = try XCTUnwrap(parseReferences(
            message,
            primary: "geoloc-primary",
            jid: jid,
            owner: owner
        ).first)

        XCTAssertEqual(parsed.kind, .geoloc)
        XCTAssertEqual(parsed.url, body)
        XCTAssertEqual(parsed.mimeType, "location")
        XCTAssertTrue(parsed.isUploaded)
        XCTAssertNil(parsed.localFileUrl)
        XCTAssertEqual(parsed.metadata?["lat"] as? String, "51.5007")
        XCTAssertEqual(parsed.metadata?["lon"] as? String, "-0.1246")
        XCTAssertEqual(parsed.metadata?["accuracy"] as? String, "12")
        XCTAssertEqual(parsed.metadata?["text"] as? String, "Westminster")
        XCTAssertEqual(parsed.metadata?["timestamp"] as? String, "2026-06-30T06:00:00Z")
        XCTAssertEqual(parsed.metadata?["uri"] as? String, body)
    }

    func testContactSharingReferenceRoundTripsPayloadAndAvatarMetadata() throws {
        let body = "Alice Capulet (alice@example.com)"
        let reference = contactReference(
            body: body,
            contactJid: "alice@example.com",
            nickname: "Alice",
            given: "Alice",
            family: "Capulet",
            avatarMetadata: [
                "avatar_id": "74c4ecf80b09aa4f7c58f5563db80f8251289898",
                "avatar_type": "image/png",
                "avatar_bytes": "6459",
                "avatar_url": "https://example.com/avatars/alice.png",
                "avatar_width": "96",
                "avatar_height": "96"
            ]
        )

        let message = try makeMessage(body: body, references: [reference])
        let referenceElement = try XCTUnwrap(message.elements(forName: "reference").first)
        let contactElement = try XCTUnwrap(referenceElement.element(
            forName: "contact",
            xmlns: "https://xabber.com/protocol/contact-sharing"
        ))
        let nameElement = try XCTUnwrap(contactElement.element(forName: "name"))
        let avatarInfo = try XCTUnwrap(contactElement.element(forName: "avatar")?.element(
            forName: "info",
            xmlns: "urn:xmpp:avatar:metadata"
        ))

        XCTAssertEqual(referenceElement.attributeStringValue(forName: "type"), "mutable")
        XCTAssertEqual(contactElement.attributeStringValue(forName: "jid"), "alice@example.com")
        XCTAssertEqual(contactElement.attributeStringValue(forName: "entity"), MessageContactEntityKind.contact.rawValue)
        XCTAssertEqual(contactElement.element(forName: "nickname")?.stringValue, "Alice")
        XCTAssertEqual(nameElement.element(forName: "given")?.stringValue, "Alice")
        XCTAssertEqual(nameElement.element(forName: "family")?.stringValue, "Capulet")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "id"), "74c4ecf80b09aa4f7c58f5563db80f8251289898")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "type"), "image/png")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "bytes"), "6459")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "url"), "https://example.com/avatars/alice.png")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "width"), "96")
        XCTAssertEqual(avatarInfo.attributeStringValue(forName: "height"), "96")

        let parsed = try XCTUnwrap(parseReferences(
            message,
            primary: "contact-primary",
            jid: jid,
            owner: owner
        ).first)

        XCTAssertEqual(parsed.kind, .contact)
        XCTAssertEqual(parsed.url, "xmpp:alice@example.com")
        XCTAssertEqual(parsed.mimeType, "contact")
        XCTAssertTrue(parsed.isUploaded)
        XCTAssertNil(parsed.localFileUrl)
        XCTAssertEqual(parsed.metadata?["contact_jid"] as? String, "alice@example.com")
        XCTAssertEqual(parsed.metadata?["entity"] as? String, MessageContactEntityKind.contact.rawValue)
        XCTAssertEqual(parsed.metadata?["nickname"] as? String, "Alice")
        XCTAssertEqual(parsed.metadata?["given"] as? String, "Alice")
        XCTAssertEqual(parsed.metadata?["family"] as? String, "Capulet")
        XCTAssertEqual(parsed.metadata?["avatar_id"] as? String, "74c4ecf80b09aa4f7c58f5563db80f8251289898")
        XCTAssertEqual(parsed.metadata?["avatar_type"] as? String, "image/png")
        XCTAssertEqual(parsed.metadata?["avatar_bytes"] as? String, "6459")
        XCTAssertEqual(parsed.metadata?["avatar_url"] as? String, "https://example.com/avatars/alice.png")
        XCTAssertEqual(parsed.metadata?["avatar_width"] as? String, "96")
        XCTAssertEqual(parsed.metadata?["avatar_height"] as? String, "96")
    }

    func testIncomingContactSharingMessageRendersCardWithoutFallbackBody() throws {
        let body = "Ally (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Ally</nickname>
                <name>
                  <given>Alice</given>
                  <family>Capulet</family>
                </name>
                <avatar>
                  <info xmlns='urn:xmpp:avatar:metadata'
                        id='hash-1'
                        url='https://example.com/avatars/alice.png'/>
                </avatar>
              </contact>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.legacyBody, body)
        XCTAssertEqual(item.bodyForAttachmentRendering, "")
        XCTAssertEqual(item.displayedBody(), "Ally")
        let reference = try XCTUnwrap(item.references.first)
        XCTAssertEqual(reference.kind, .contact)
        let mapped = ChatViewController.mapReferenceAttachments(item.references.toArray())
        XCTAssertEqual(mapped.contacts.first?.title, "Ally")
        XCTAssertEqual(mapped.contacts.first?.jid, "alice@example.com")
        XCTAssertEqual(mapped.contacts.first?.avatarURL, "https://example.com/avatars/alice.png")
    }

    func testMalformedContactSharingMessageKeepsFallbackBodyVisible() throws {
        let body = "Ally (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'>
                <nickname>Ally</nickname>
              </contact>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(item.references.isEmpty)
        XCTAssertEqual(item.body, body)
        XCTAssertEqual(item.bodyForAttachmentRendering, body)
        XCTAssertEqual(item.displayedBody(), body)
        XCTAssertTrue(ChatViewController.mapReferenceAttachments(item.references.toArray()).contacts.isEmpty)
    }

    func testOutgoingContactSharingFallbackIsHiddenFromAttachmentRendering() {
        let body = "Alice Capulet (alice@example.com)"
        let reference = contactReference(
            body: body,
            contactJid: "alice@example.com",
            nickname: "Alice",
            given: "Alice",
            family: "Capulet"
        )
        let item = MessageStorageItem()

        item.configureOutgoingMessage(
            body,
            legacy: body,
            messageId: "outgoing-contact",
            owner: owner,
            opponent: jid,
            references: [reference],
            inlineForwards: []
        )

        XCTAssertEqual(item.body, body)
        XCTAssertEqual(item.bodyForAttachmentRendering, "")
        XCTAssertEqual(item.displayedBody(), body)
        XCTAssertEqual(ChatViewController.mapReferenceAttachments(item.references.toArray()).contacts.first?.title, "Alice")
    }

    func testForwardedInlineContactSharingMessageHidesFallbackBody() throws {
        let body = "Ally (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Ally</nickname>
              </contact>
            </reference>
            """,
            body: body
        )
        let inline = MessageForwardsInlineStorageItem()

        inline.configureInline(
            message,
            parentId: "parent-message",
            owner: owner,
            jid: jid,
            opponent: jid,
            outgoing: false,
            date: Date(timeIntervalSince1970: 20),
            forwardJid: jid
        )

        XCTAssertEqual(inline.body, "")
        XCTAssertEqual(inline.references.first?.kind, .contact)
        let mapped = ChatViewController.mapReferenceAttachments(inline.references.toArray())
        XCTAssertEqual(mapped.contacts.first?.title, "Ally")
    }

    func testInlineForwardParsesWhenXEP0297DelayIsOmitted() throws {
        let fallback = "Forwarded fallback"
        let originalStamp = "2026-08-26T08:15:30Z"
        let message = try makeMessage(
            referenceXML: inlineForwardReferenceXML(
                fallback: fallback,
                forwardedChildren: """
                <message xmlns='jabber:client'
                         from='juliet@example.com/mobile'
                         to='romeo@example.com'
                         id='forward-without-delay'>
                  <time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>
                  <body>Original body</body>
                </message>
                """
            ),
            body: fallback
        )

        let forwards = parseInlineMessages(
            message,
            parentId: "outer-message",
            jid: jid,
            owner: owner
        )

        XCTAssertEqual(forwards.count, 1)
        XCTAssertEqual(forwards.first?.messageId, "forward-without-delay")
        XCTAssertEqual(forwards.first?.body, "Original body")
        XCTAssertEqual(forwards.first?.originalDate, originalStamp.xmppDate)
    }

    func testInlineForwardWithoutAnyTimestampKeepsOriginalDateUnknown() throws {
        let fallback = "Forwarded fallback"
        let message = try makeMessage(
            referenceXML: inlineForwardReferenceXML(
                fallback: fallback,
                forwardedChildren: """
                <message xmlns='jabber:client'
                         from='juliet@example.com/mobile'
                         to='romeo@example.com'
                         id='forward-without-timestamp'>
                  <body>Original body</body>
                </message>
                """
            ),
            body: fallback
        )

        let forward = try XCTUnwrap(parseInlineMessages(
            message,
            parentId: "outer-message",
            jid: jid,
            owner: owner
        ).first)

        XCTAssertNil(forward.originalDate)
    }

    func testInlineForwardRequiresUnambiguousXEP0297EnvelopeAndKeepsFallbackVisible() throws {
        let fallback = "Malformed forward fallback"
        let malformedPayloads = [
            "<delay xmlns='urn:xmpp:delay' stamp='2026-08-26T08:15:30Z'/>",
            """
            <message xmlns='jabber:client' from='juliet@example.com' to='romeo@example.com' id='first'>
              <body>First</body>
            </message>
            <message xmlns='jabber:client' from='mercutio@example.com' to='romeo@example.com' id='second'>
              <body>Second</body>
            </message>
            """,
            """
            <delay xmlns='urn:xmpp:delay' stamp='2026-08-26T08:15:30Z'/>
            <delay xmlns='urn:xmpp:delay' stamp='2026-08-26T08:15:31Z'/>
            <message xmlns='jabber:client' from='juliet@example.com' to='romeo@example.com' id='duplicate-delay'>
              <body>Duplicate delay</body>
            </message>
            """
        ]

        for payload in malformedPayloads {
            let message = try makeMessage(
                referenceXML: inlineForwardReferenceXML(
                    fallback: fallback,
                    forwardedChildren: payload
                ),
                body: fallback
            )
            let item = configuredIncomingMessage(message)

            XCTAssertTrue(item.inlineForwards.isEmpty)
            XCTAssertFalse(item.references.contains(where: { $0.kind == .forward }))
            XCTAssertEqual(item.body, fallback)
        }
    }

    func testInlineForwardRequiresCompleteOriginalAddressingAndKeepsFallbackVisible() throws {
        let fallback = "Incomplete forward fallback"
        let malformedMessages = [
            """
            <message xmlns='jabber:client' to='romeo@example.com' id='missing-from'>
              <body>Missing from</body>
            </message>
            """,
            """
            <message xmlns='jabber:client' from='juliet@example.com' id='missing-to'>
              <body>Missing to</body>
            </message>
            """
        ]

        for malformedMessage in malformedMessages {
            let message = try makeMessage(
                referenceXML: inlineForwardReferenceXML(
                    fallback: fallback,
                    forwardedChildren: malformedMessage
                ),
                body: fallback
            )
            let item = configuredIncomingMessage(message)

            XCTAssertTrue(item.inlineForwards.isEmpty)
            XCTAssertFalse(item.references.contains(where: { $0.kind == .forward }))
            XCTAssertEqual(item.body, fallback)
        }
    }

    func testInlineForwardWithMalformedDelayKeepsFallbackVisible() throws {
        let fallback = "Invalid delay fallback"
        let message = try makeMessage(
            referenceXML: inlineForwardReferenceXML(
                fallback: fallback,
                forwardedChildren: """
                <delay xmlns='urn:xmpp:delay' stamp='not-a-date'/>
                <message xmlns='jabber:client'
                         from='juliet@example.com'
                         to='romeo@example.com'
                         id='invalid-delay-forward'>
                  <body>Original body</body>
                </message>
                """
            ),
            body: fallback
        )

        let item = configuredIncomingMessage(message)

        XCTAssertTrue(item.inlineForwards.isEmpty)
        XCTAssertFalse(item.references.contains(where: { $0.kind == .forward }))
        XCTAssertEqual(item.body, fallback)
    }

    func testInlineForwardWithoutRequiredWireRangeKeepsFallbackVisible() throws {
        let fallback = "Missing range fallback"
        let message = try makeMessage(
            referenceXML: inlineForwardReferenceXML(
                fallback: fallback,
                includeRange: false,
                forwardedChildren: """
                <message xmlns='jabber:client'
                         from='juliet@example.com'
                         to='romeo@example.com'
                         id='missing-range-forward'>
                  <body>Original body</body>
                </message>
                """
            ),
            body: fallback
        )

        let item = configuredIncomingMessage(message)

        XCTAssertTrue(item.inlineForwards.isEmpty)
        XCTAssertFalse(item.references.contains(where: { $0.kind == .forward }))
        XCTAssertEqual(item.body, fallback)
    }

    func testInlineForwardParsingBoundsMaliciousNestedDepth() throws {
        let message = try makeNestedInlineForwardMessage(levels: 24)

        let forwards = parseInlineMessages(
            message,
            parentId: "deep-forward-root",
            jid: jid,
            owner: owner
        )

        let deepestForward = deepestInlineForward(in: forwards)
        XCTAssertEqual(inlineForwardDepth(forwards), inlineForwardMaximumDepth)
        XCTAssertEqual(deepestForward?.body, "Forward level 8")
        XCTAssertFalse(deepestForward?.references.contains(where: { $0.kind == .forward }) == true)
    }

    func testArchivedContactSharingMessageUsesSameParsingAndPreviewBehavior() throws {
        let body = "Ally (alice@example.com)"
        let message = try makeArchivedMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Ally</nickname>
              </contact>
            </reference>
            """,
            body: body,
            archiveId: "archive-contact-1"
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: true,
            date: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(item.archivedId, "archive-contact-1")
        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.displayedBody(), "Ally")
        XCTAssertEqual(ChatViewController.mapReferenceAttachments(item.references.toArray()).contacts.first?.jid, "alice@example.com")
    }

    func testEncryptedIncomingContactSharingUsesSameParsedReferenceBehavior() throws {
        let body = "Ally (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Ally</nickname>
              </contact>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 40),
            isEncrypted: true
        )

        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.displayedBody(), "Ally")
        XCTAssertEqual(item.references.first?.kind, .contact)
        XCTAssertEqual(ChatViewController.mapReferenceAttachments(item.references.toArray()).contacts.first?.jid, "alice@example.com")
    }

    func testContactSharingMinimalReferenceParsesWithJIDOnly() throws {
        let body = "alice@example.com"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'/>
            </reference>
            """,
            body: body
        )

        let parsed = try XCTUnwrap(parseReferences(
            message,
            primary: "contact-minimal-primary",
            jid: jid,
            owner: owner
        ).first)

        XCTAssertEqual(parsed.kind, .contact)
        XCTAssertEqual(parsed.metadata?["contact_jid"] as? String, "alice@example.com")
        XCTAssertNil(parsed.metadata?["entity"])
        XCTAssertNil(parsed.metadata?["nickname"])
        XCTAssertEqual(parsed.url, "xmpp:alice@example.com")
    }

    func testContactSharingReferenceRoundTripsGroupAndIncognitoEntities() throws {
        let cases: [(MessageContactEntityKind, String, String)] = [
            (.groupchat, "Public Room", "public-room@conference.example.com"),
            (.incognito, "Incognito Room", "secret-room@conference.example.com")
        ]

        for (entity, nickname, contactJid) in cases {
            let body = "\(nickname) (\(contactJid))"
            let reference = contactReference(
                body: body,
                contactJid: contactJid,
                entity: entity,
                nickname: nickname
            )

            let message = try makeMessage(body: body, references: [reference])
            let referenceElement = try XCTUnwrap(message.elements(forName: "reference").first)
            let contactElement = try XCTUnwrap(referenceElement.element(
                forName: "contact",
                xmlns: "https://xabber.com/protocol/contact-sharing"
            ))

            XCTAssertEqual(contactElement.attributeStringValue(forName: "jid"), contactJid)
            XCTAssertEqual(contactElement.attributeStringValue(forName: "entity"), entity.rawValue)

            let parsed = try XCTUnwrap(parseReferences(
                message,
                primary: "contact-\(entity.rawValue)-primary",
                jid: jid,
                owner: owner
            ).first)

            XCTAssertEqual(parsed.kind, .contact)
            XCTAssertEqual(parsed.metadata?["contact_jid"] as? String, contactJid)
            XCTAssertEqual(parsed.metadata?["entity"] as? String, entity.rawValue)
            XCTAssertEqual(parsed.metadata?["nickname"] as? String, nickname)
            XCTAssertEqual(parsed.url, "xmpp:\(contactJid)")
        }
    }

    func testContactSharingParserSkipsMissingJIDWrongNamespaceInvalidEntityAndFullJIDPayloads() throws {
        let body = "Alice (alice@example.com)"
        let cases = [
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'>
                <nickname>Alice</nickname>
              </contact>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='urn:example:wrong'
                       jid='alice@example.com'>
                <nickname>Alice</nickname>
              </contact>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'
                       entity='channel'>
                <nickname>Alice</nickname>
              </contact>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com/mobile'
                       entity='contact'>
                <nickname>Alice</nickname>
              </contact>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <vCard xmlns='vcard-temp'>
                <FN>Alice Capulet</FN>
                <EMAIL><USERID>alice@example.com</USERID></EMAIL>
              </vCard>
            </reference>
            """
        ]

        for referenceXML in cases {
            let message = try makeMessage(referenceXML: referenceXML, body: body)
            XCTAssertTrue(parseReferences(
                message,
                primary: UUID().uuidString,
                jid: jid,
                owner: owner
            ).isEmpty)
        }
    }

    func testContactSharingMalformedAvatarMetadataDoesNotInvalidateContactCard() throws {
        let body = "Alice (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Alice</nickname>
                <avatar>
                  <info xmlns='urn:xmpp:avatar:metadata'
                        bytes='not-a-number'
                        width='wide'
                        height='tall'/>
                </avatar>
              </contact>
            </reference>
            """,
            body: body
        )

        let parsed = try XCTUnwrap(parseReferences(
            message,
            primary: "contact-malformed-avatar-primary",
            jid: jid,
            owner: owner
        ).first)

        XCTAssertEqual(parsed.kind, .contact)
        XCTAssertEqual(parsed.metadata?["contact_jid"] as? String, "alice@example.com")
        XCTAssertNil(parsed.metadata?["entity"])
        XCTAssertEqual(parsed.metadata?["nickname"] as? String, "Alice")
    }

    func testContactSharingConfigureIncomingMessageHidesFallbackBody() throws {
        let body = "Alice Capulet (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'
                       jid='alice@example.com'>
                <nickname>Alice</nickname>
                <name>
                  <given>Alice</given>
                  <family>Capulet</family>
                </name>
              </contact>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.legacyBody, body)
        XCTAssertEqual(item.references.first?.kind, .contact)
    }

    func testInvalidContactSharingConfigureIncomingMessageKeepsFallbackBody() throws {
        let body = "Alice (alice@example.com)"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <contact xmlns='https://xabber.com/protocol/contact-sharing'>
                <nickname>Alice</nickname>
              </contact>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(item.references.isEmpty)
        XCTAssertEqual(item.body, body)
    }

    func testGeolocParserSkipsMalformedMultipleAndWrongNamespacePayloads() throws {
        let cases = [
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
              <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                <lat>91</lat>
                <lon>2</lon>
              </geoloc>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
              <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                <lat>1</lat>
                <lon>2</lon>
              </geoloc>
              <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                <lat>3</lat>
                <lon>4</lon>
              </geoloc>
            </reference>
            """,
            """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='8'>
              <geoloc xmlns='urn:example:wrong'>
                <lat>1</lat>
                <lon>2</lon>
              </geoloc>
            </reference>
            """
        ]

        for referenceXML in cases {
            let message = try makeMessage(referenceXML: referenceXML, body: "geo:1,2")
            XCTAssertTrue(parseReferences(
                message,
                primary: UUID().uuidString,
                jid: jid,
                owner: owner
            ).isEmpty)
        }
    }

    func testGeolocReferenceDoesNotCreateMediaAttachmentStorage() throws {
        let realm = try WRealm.safe()
        let mediaAttachmentCount = realm.objects(MessageMediaAttachmentStorageItem.self).count
        let body = "geo:51.5007,-0.1246"
        let message = try makeMessage(body: body, references: [
            geolocReference(latitude: "51.5007", longitude: "-0.1246", body: body)
        ])

        let parsed = parseReferences(message, primary: "geoloc-media-primary", jid: jid, owner: owner)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(realm.objects(MessageMediaAttachmentStorageItem.self).count, mediaAttachmentCount)
    }

    func testWebCompatibleGeolocConfiguresIncomingMessageAndRendersLocationAttachment() throws {
        let body = "geo:56.838011,60.597465"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                <lat>56.838011</lat>
                <lon>60.597465</lon>
                <text>Yekaterinburg</text>
                <timestamp>2026-06-30T07:00:00Z</timestamp>
              </geoloc>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "")
        XCTAssertEqual(item.legacyBody, body)
        XCTAssertEqual(item.displayedBody(), "Location".localizeString(id: "chat_message_location", arguments: []))
        let reference = try XCTUnwrap(item.references.first)
        XCTAssertEqual(reference.kind, .geoloc)
        XCTAssertEqual(reference.metadata?["lat"] as? String, "56.838011")
        XCTAssertEqual(reference.metadata?["lon"] as? String, "60.597465")
        let mapped = ChatViewController.mapReferenceAttachments(item.references.toArray())
        XCTAssertEqual(mapped.locations.first?.geoURI, body)
    }

    func testMalformedGeolocFallsBackToBodyText() throws {
        let body = "geo:999,60.597465"
        let message = try makeMessage(
            referenceXML: """
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(body.count)'>
              <geoloc xmlns='http://jabber.org/protocol/geoloc'>
                <lat>999</lat>
                <lon>60.597465</lon>
              </geoloc>
            </reference>
            """,
            body: body
        )
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(item.references.isEmpty)
        XCTAssertEqual(item.body, body)
        XCTAssertEqual(item.displayedBody(), body)
        XCTAssertTrue(ChatViewController.mapReferenceAttachments(item.references.toArray()).locations.isEmpty)
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

    private func makeMessage(referenceXML: String, body: String) throws -> XMPPMessage {
        let xml = """
        <message from='\(jid)/mobile' to='\(owner)'>
          <body>\(body)</body>
          \(referenceXML)
        </message>
        """
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func inlineForwardReferenceXML(
        fallback: String,
        includeRange: Bool = true,
        forwardedChildren: String
    ) -> String {
        let range = includeRange
            ? " begin='0' end='\(fallback.xmlEscaping(reverse: false).unicodeScalars.count)'"
            : ""
        return """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable'\(range)>
          <forwarded xmlns='urn:xmpp:forward:0'>
            \(forwardedChildren)
          </forwarded>
        </reference>
        """
    }

    private func configuredIncomingMessage(_ message: XMPPMessage) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.configureIncomingMessage(
            message,
            owner: owner,
            opponent: jid,
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )
        return item
    }

    private func makeNestedInlineForwardMessage(levels: Int) throws -> XMPPMessage {
        var childXML = """
        <message xmlns='jabber:client'
                 from='juliet@example.com/mobile'
                 to='romeo@example.com'
                 id='deep-forward-leaf'>
          <body>Leaf body</body>
        </message>
        """

        for level in (0..<levels).reversed() {
            let fallback = "Forward level \(level)"
            childXML = """
            <message xmlns='jabber:client'
                     from='juliet@example.com/mobile'
                     to='romeo@example.com'
                     id='deep-forward-\(level)'>
              <body>\(fallback)</body>
              \(inlineForwardReferenceXML(
                  fallback: fallback,
                  forwardedChildren: childXML
              ))
            </message>
            """
        }

        let document = try DDXMLDocument(xmlString: childXML, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func inlineForwardDepth(
        _ forwards: [MessageForwardsInlineStorageItem]
    ) -> Int {
        var depth = 0
        var current = forwards.first
        while let forward = current {
            depth += 1
            current = forward.subforwards.first
        }
        return depth
    }

    private func deepestInlineForward(
        in forwards: [MessageForwardsInlineStorageItem]
    ) -> MessageForwardsInlineStorageItem? {
        var current = forwards.first
        while let child = current?.subforwards.first {
            current = child
        }
        return current
    }

    private func mediaReferenceXML(begin: String?, end: String?) -> String {
        let beginAttribute = begin.map { " begin='\($0)'" } ?? ""
        let endAttribute = end.map { " end='\($0)'" } ?? ""
        return """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable'\(beginAttribute)\(endAttribute)>
          <file-sharing xmlns='https://xabber.com/protocol/files'>
            <file>
              <media-type>image/jpeg</media-type>
              <name>photo.jpg</name>
              <size>1024</size>
            </file>
            <sources>
              <uri>https://example.com/photo.jpg</uri>
            </sources>
          </file-sharing>
        </reference>
        """
    }

    private func voiceReferenceXML(begin: String?, end: String?) -> String {
        let beginAttribute = begin.map { " begin='\($0)'" } ?? ""
        let endAttribute = end.map { " end='\($0)'" } ?? ""
        return """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable'\(beginAttribute)\(endAttribute)>
          <voice-message xmlns='https://xabber.com/protocol/voice-messages'>
            <file-sharing xmlns='https://xabber.com/protocol/files'>
              <file>
                <media-type>audio/ogg</media-type>
                <name>voice.ogg</name>
                <duration>12</duration>
                <size>1024</size>
              </file>
              <sources>
                <uri>https://example.com/voice.ogg</uri>
              </sources>
            </file-sharing>
          </voice-message>
        </reference>
        """
    }

    private func makeArchivedMessage(referenceXML: String, body: String, archiveId: String) throws -> XMPPMessage {
        let xml = """
        <message from='\(jid)/mobile' to='\(owner)'>
          <body>\(body)</body>
          <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='\(archiveId)'/>
          <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(archiveId)'/>
          \(referenceXML)
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

    private func geolocReference(
        latitude: String,
        longitude: String,
        body: String,
        metadata extraMetadata: [String: Any] = [:]
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .geoloc
        reference.mimeType = "location"
        reference.owner = owner
        reference.jid = jid
        reference.conversationType = .regular
        reference.begin = 0
        reference.end = body.count
        reference.url = body
        reference.isUploaded = true
        var metadata: [String: Any] = [
            "lat": latitude,
            "lon": longitude,
            "uri": body
        ]
        extraMetadata.forEach { metadata[$0.key] = $0.value }
        reference.metadata = metadata
        return reference
    }

    private func contactReference(
        body: String,
        contactJid: String,
        entity: MessageContactEntityKind = .contact,
        nickname: String? = nil,
        given: String? = nil,
        family: String? = nil,
        avatarMetadata: [String: String] = [:]
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.mimeType = "contact"
        reference.owner = owner
        reference.jid = jid
        reference.conversationType = .regular
        reference.begin = 0
        reference.end = body.count
        reference.url = "xmpp:\(contactJid)"
        reference.isUploaded = true
        var metadata: [String: Any] = [
            "contact_jid": contactJid,
            "entity": entity.rawValue
        ]
        if let nickname {
            metadata["nickname"] = nickname
        }
        if let given {
            metadata["given"] = given
        }
        if let family {
            metadata["family"] = family
        }
        avatarMetadata.forEach { metadata[$0.key] = $0.value }
        reference.metadata = metadata
        return reference
    }
}
