import XCTest
@testable import xabber

final class ChatAttachmentDraftModelTests: XCTestCase {
    func testAssetDraftIdentityUsesLocalIdentifier() {
        let first = AttachmentAssetDraft(assetLocalIdentifier: "asset-1")
        let same = AttachmentAssetDraft(assetLocalIdentifier: "asset-1")
        let different = AttachmentAssetDraft(assetLocalIdentifier: "asset-2")

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, different)
        XCTAssertEqual(first.id, "asset:asset-1")
    }

    func testFileDraftIdentityUsesStandardizedFileURL() throws {
        let firstURL = try XCTUnwrap(URL(string: "file:///tmp/folder/../photo.jpg"))
        let sameURL = try XCTUnwrap(URL(string: "file:///tmp/photo.jpg"))

        let first = AttachmentFileDraft(url: firstURL)
        let same = AttachmentFileDraft(url: sameURL)

        XCTAssertEqual(first, same)
        XCTAssertEqual(first.id, "file:file:///tmp/photo.jpg")
    }

    func testReferenceBuilderPreservesDraftOrder() throws {
        let drafts = [
            preparedDraft(id: "second", filename: "second.jpg", mediaType: "image/jpeg"),
            preparedDraft(id: "first", filename: "first.pdf", mediaKind: .file, mediaType: "application/pdf")
        ]

        let references = try ChatAttachmentReferenceBuilder().makeReferences(
            from: drafts,
            context: Self.context
        )

        XCTAssertEqual(references.compactMap(\.filename), ["second.jpg", "first.pdf"])
    }

    func testReferenceBuilderRejectsUnpreparedDrafts() {
        let states: [AttachmentPreparationState] = [
            .pending,
            .preparing,
            .unavailable(.assetUnavailable)
        ]

        for state in states {
            let draft = AttachmentDraft(
                id: "draft-\(state)",
                source: .gallery,
                mediaKind: .image,
                thumbnailState: .none,
                filename: "image.jpg",
                byteSize: 1,
                duration: nil,
                dimensions: nil,
                preparationState: state
            )

            XCTAssertThrowsError(
                try ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context)
            )
        }
    }

    func testImageReferencePreservesLegacyMediaContract() throws {
        let localURL = try XCTUnwrap(URL(string: "file:///tmp/prepared/image.jpg"))
        let referenceURL = try XCTUnwrap(URL(string: "file:///photos/original/image.jpg"))
        let draft = preparedDraft(
            id: "image",
            filename: "image.jpg",
            mediaKind: .image,
            mediaType: "image/jpeg",
            localFileURL: localURL,
            referenceURL: referenceURL,
            dimensions: CGSize(width: 640, height: 480)
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .media)
        XCTAssertEqual(reference.owner, Self.context.owner)
        XCTAssertEqual(reference.jid, Self.context.jid)
        XCTAssertEqual(reference.conversationType, Self.context.conversationType)
        XCTAssertEqual(reference.localFileUrl, localURL)
        XCTAssertEqual(reference.mimeType, "image")
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "image/jpeg")
        XCTAssertEqual(reference.metadata?["filename"] as? String, "image.jpg")
        XCTAssertEqual(reference.metadata?["size"] as? Int, 2048)
        XCTAssertEqual(reference.metadata?["uri"] as? String, referenceURL.absoluteString)
        XCTAssertEqual(reference.metadata?["width"] as? Int, 640)
        XCTAssertEqual(reference.metadata?["height"] as? Int, 480)
    }

    func testVideoReferencePreservesPreviewAndDurationMetadata() throws {
        let previewURL = try XCTUnwrap(URL(string: "file:///tmp/video-preview.png"))
        let draft = preparedDraft(
            id: "video",
            filename: "clip.mov",
            mediaKind: .video,
            mediaType: "video/quicktime",
            dimensions: CGSize(width: 1920, height: 1080),
            videoPreviewKey: "preview-key",
            videoOrientation: "landscapeRight",
            videoDurationLabel: "0:12",
            videoPreviewLocalURL: previewURL
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .media)
        XCTAssertEqual(reference.mimeType, "video")
        XCTAssertEqual(reference.videoPreviewKey, "preview-key")
        XCTAssertEqual(reference.videoOrientation, "landscapeRight")
        XCTAssertEqual(reference.video_duration, "0:12")
        XCTAssertEqual(reference.metadata?["preview_local_url"] as? String, previewURL.absoluteString)
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "video/quicktime")
        XCTAssertEqual(reference.metadata?["width"] as? Int, 1920)
        XCTAssertEqual(reference.metadata?["height"] as? Int, 1080)
    }

    func testAnimatedImageReferencePreservesImageMimeAndDimensions() throws {
        let draft = preparedDraft(
            id: "gif",
            filename: "anim.gif",
            mediaKind: .animatedImage,
            mediaType: "image/gif",
            dimensions: CGSize(width: 320, height: 240)
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .media)
        XCTAssertEqual(reference.mimeType, "image")
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "image/gif")
        XCTAssertEqual(reference.metadata?["width"] as? Int, 320)
        XCTAssertEqual(reference.metadata?["height"] as? Int, 240)
    }

    func testAudioFileReferenceRemainsMediaAndPreservesDuration() throws {
        let draft = preparedDraft(
            id: "audio",
            filename: "song.mp3",
            mediaKind: .audio,
            mediaType: "audio/mpeg",
            duration: 42
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .media)
        XCTAssertEqual(reference.mimeType, "audio")
        XCTAssertEqual(reference.duration, 42)
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "audio/mpeg")
    }

    func testGenericFileReferencePreservesFileMetadata() throws {
        let draft = preparedDraft(
            id: "file",
            filename: "document.pdf",
            mediaKind: .file,
            mediaType: "application/pdf"
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .media)
        XCTAssertEqual(reference.mimeType, "pdf")
        XCTAssertEqual(reference.metadata?["filename"] as? String, "document.pdf")
        XCTAssertEqual(reference.metadata?["size"] as? Int, 2048)
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "application/pdf")
        XCTAssertEqual(reference.metadata?["uri"] as? String, "file:///tmp/document.pdf")
    }

    func testPreparedLocationDraftDoesNotRequireUpload() {
        let location = preparedLocation()
        let draft = locationDraft(location: location)

        XCTAssertEqual(draft.preparedLocation, location)
        XCTAssertFalse(draft.requiresUpload)
    }

    func testPreparedContactDraftDoesNotRequireUploadAndIsSendable() {
        let contact = preparedContact()
        let draft = contactDraft(contact: contact)

        XCTAssertEqual(draft.preparedContact, contact)
        XCTAssertTrue(draft.isPreparedForSend)
        XCTAssertFalse(draft.requiresUpload)
    }

    func testReferenceBuilderEmitsUploadedGeolocReferenceForPreparedLocation() throws {
        let location = preparedLocation()
        let draft = locationDraft(location: location)

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .geoloc)
        XCTAssertEqual(reference.owner, Self.context.owner)
        XCTAssertEqual(reference.jid, Self.context.jid)
        XCTAssertEqual(reference.conversationType, Self.context.conversationType)
        XCTAssertEqual(reference.mimeType, "location")
        XCTAssertEqual(reference.url, "geo:51.5007,-0.1246")
        XCTAssertTrue(reference.isUploaded)
        XCTAssertNil(reference.localFileUrl)
        XCTAssertNil(reference.downloadUrl)
        XCTAssertEqual(reference.metadata?["lat"] as? String, "51.5007")
        XCTAssertEqual(reference.metadata?["lon"] as? String, "-0.1246")
        XCTAssertEqual(reference.metadata?["accuracy"] as? String, "12.5")
        XCTAssertEqual(reference.metadata?["text"] as? String, "Westminster")
        XCTAssertEqual(reference.metadata?["timestamp"] as? String, "2026-06-30T06:00:00Z")
        XCTAssertEqual(reference.metadata?["uri"] as? String, "geo:51.5007,-0.1246")
        XCTAssertEqual(reference.metadata?["local-snapshot-url"] as? String, "file:///tmp/location-snapshot.png")
    }

    func testReferenceBuilderEmitsUploadedContactReferenceForPreparedContact() throws {
        let contact = preparedContact()
        let draft = contactDraft(contact: contact)

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .contact)
        XCTAssertEqual(reference.owner, Self.context.owner)
        XCTAssertEqual(reference.jid, Self.context.jid)
        XCTAssertEqual(reference.conversationType, Self.context.conversationType)
        XCTAssertEqual(reference.mimeType, "contact")
        XCTAssertEqual(reference.url, "xmpp:alice@example.com")
        XCTAssertTrue(reference.isUploaded)
        XCTAssertNil(reference.localFileUrl)
        XCTAssertNil(reference.downloadUrl)
        XCTAssertEqual(reference.metadata?["contact_jid"] as? String, "alice@example.com")
        XCTAssertEqual(reference.metadata?["nickname"] as? String, "Alice")
        XCTAssertEqual(reference.metadata?["given"] as? String, "Alice")
        XCTAssertEqual(reference.metadata?["family"] as? String, "Capulet")
        XCTAssertEqual(reference.metadata?["display_title"] as? String, "Alice Capulet")
        XCTAssertEqual(reference.metadata?["avatar_url"] as? String, "https://example.com/avatars/alice.png")
        XCTAssertEqual(reference.metadata?["avatar_id"] as? String, "avatar-hash")
    }

    func testReferenceBuilderAcceptsPreparedLocationWithoutSnapshot() throws {
        let location = preparedLocation(localSnapshotURL: nil)
        let draft = locationDraft(location: location)

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.kind, .geoloc)
        XCTAssertEqual(reference.url, location.geoURI)
        XCTAssertNil(reference.metadata?["local-snapshot-url"])
    }

    func testGeolocOutgoingBodyUsesGeoURIFallback() throws {
        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(
            from: [locationDraft(location: preparedLocation())],
            context: Self.context
        ).first)

        let outgoingBody = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            captionState: ChatAttachmentCaptionState(),
            conversationType: Self.context.conversationType,
            references: [reference]
        )

        XCTAssertEqual(outgoingBody.body, "geo:51.5007,-0.1246")
        XCTAssertEqual(outgoingBody.legacyBody, "geo:51.5007,-0.1246")
    }

    func testContactOutgoingBodyUsesContactFallbackAndReferenceOffsets() throws {
        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(
            from: [contactDraft(contact: preparedContact())],
            context: Self.context
        ).first)

        let outgoingBody = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            captionState: ChatAttachmentCaptionState(),
            conversationType: Self.context.conversationType,
            references: [reference]
        )

        XCTAssertEqual(outgoingBody.body, "Alice Capulet (alice@example.com)")
        XCTAssertEqual(outgoingBody.legacyBody, "Alice Capulet (alice@example.com)")
        XCTAssertEqual(reference.begin, 0)
        XCTAssertEqual(reference.end, outgoingBody.body.xmlEscaping(reverse: false).count)
    }

    func testContactOutgoingBodyWithCaptionPlacesFallbackAfterCaption() throws {
        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(
            from: [contactDraft(contact: preparedContact())],
            context: Self.context
        ).first)

        let outgoingBody = ChatAttachmentCaptionOutgoingBodyPolicy.makeOutgoingBody(
            captionState: ChatAttachmentCaptionState(rawText: "Meet this contact"),
            conversationType: Self.context.conversationType,
            references: [reference]
        )

        XCTAssertEqual(outgoingBody.body, "Meet this contact\nAlice Capulet (alice@example.com)")
        XCTAssertEqual(outgoingBody.legacyBody, outgoingBody.body)
        XCTAssertEqual(reference.begin, "Meet this contact".xmlEscaping(reverse: false).count)
        XCTAssertEqual(reference.end, outgoingBody.body.xmlEscaping(reverse: false).count)
    }

    func testEditedImageBuildsFromPreparedOutputFile() throws {
        let localURL = try XCTUnwrap(URL(string: "file:///tmp/edited/output.jpg"))
        let draft = preparedDraft(
            id: "edited",
            filename: "output.jpg",
            mediaKind: .image,
            mediaType: "image/jpeg",
            localFileURL: localURL,
            referenceURL: localURL
        )

        let reference = try XCTUnwrap(ChatAttachmentReferenceBuilder().makeReferences(from: [draft], context: Self.context).first)

        XCTAssertEqual(reference.localFileUrl, localURL)
        XCTAssertEqual(reference.metadata?["uri"] as? String, localURL.absoluteString)
        XCTAssertEqual(reference.metadata?["filename"] as? String, "output.jpg")
    }

    private static let context = ChatAttachmentFlowContext(
        owner: "alice@example.com",
        jid: "bob@example.com",
        conversationType: .regular,
        forwardedMessageIds: []
    )

    private func preparedDraft(
        id: String,
        filename: String,
        mediaKind: AttachmentMediaKind = .image,
        mediaType: String,
        localFileURL: URL? = nil,
        referenceURL: URL? = nil,
        byteSize: Int = 2048,
        duration: Int? = nil,
        dimensions: CGSize? = nil,
        videoPreviewKey: String? = nil,
        videoOrientation: String? = nil,
        videoDurationLabel: String? = nil,
        videoPreviewLocalURL: URL? = nil
    ) -> AttachmentDraft {
        let fallbackLocalURL = URL(fileURLWithPath: "/tmp/\(filename)")
        let preparedFile = AttachmentPreparedFile(
            localFileURL: localFileURL ?? fallbackLocalURL,
            referenceURL: referenceURL ?? fallbackLocalURL,
            filename: filename,
            byteSize: byteSize,
            mediaType: mediaType,
            dimensions: dimensions,
            duration: duration,
            videoPreviewKey: videoPreviewKey,
            videoOrientation: videoOrientation,
            videoDurationLabel: videoDurationLabel,
            videoPreviewLocalURL: videoPreviewLocalURL,
            temporaryData: nil
        )

        return AttachmentDraft(
            id: id,
            source: .gallery,
            mediaKind: mediaKind,
            thumbnailState: .none,
            filename: filename,
            byteSize: byteSize,
            duration: duration,
            dimensions: dimensions,
            preparationState: .prepared(preparedFile)
        )
    }

    private func preparedLocation(
        localSnapshotURL: URL? = URL(fileURLWithPath: "/tmp/location-snapshot.png")
    ) -> AttachmentPreparedLocation {
        AttachmentPreparedLocation(
            coordinate: AttachmentLocationCoordinate(latitude: 51.5007, longitude: -0.1246),
            displayAddress: "Westminster",
            accuracy: 12.5,
            geoURI: "geo:51.5007,-0.1246",
            createdAt: Date(timeIntervalSince1970: 1_782_799_200),
            localSnapshotURL: localSnapshotURL
        )
    }

    private func preparedContact() -> AttachmentPreparedContact {
        AttachmentPreparedContact(
            jid: "alice@example.com",
            nickname: "Alice",
            given: "Alice",
            family: "Capulet",
            displayTitle: "Alice Capulet",
            avatarURL: "https://example.com/avatars/alice.png",
            avatarMetadata: [
                "avatar_id": "avatar-hash",
                "avatar_type": "image/png",
                "avatar_bytes": "6459"
            ]
        )
    }

    private func locationDraft(location: AttachmentPreparedLocation) -> AttachmentDraft {
        AttachmentDraft(
            id: "location:\(location.geoURI)",
            source: .geolocation,
            mediaKind: .location,
            thumbnailState: .none,
            filename: "Location",
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .preparedLocation(location)
        )
    }

    private func contactDraft(contact: AttachmentPreparedContact) -> AttachmentDraft {
        AttachmentDraft(
            id: "contact:\(contact.jid)",
            source: .contact,
            mediaKind: .contact,
            thumbnailState: .none,
            filename: contact.displayTitle,
            byteSize: 0,
            duration: nil,
            dimensions: nil,
            preparationState: .preparedContact(contact)
        )
    }
}
