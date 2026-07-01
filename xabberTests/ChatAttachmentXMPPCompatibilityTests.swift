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

        XCTAssertEqual(item.legacyBody, "\(remoteURL)\n")
        XCTAssertEqual(item.references.first?.begin, 0)
        XCTAssertGreaterThan(item.references.first?.end ?? 0, remoteURL.count)
        XCTAssertEqual(uriElement.stringValue, remoteURL)
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
        XCTAssertNil(parsed.metadata?["nickname"])
        XCTAssertEqual(parsed.url, "xmpp:alice@example.com")
    }

    func testContactSharingParserSkipsMissingJIDAndWrongNamespacePayloads() throws {
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
            "contact_jid": contactJid
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
