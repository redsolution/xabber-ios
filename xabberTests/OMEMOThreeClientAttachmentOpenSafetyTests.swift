import CryptoKit
import UIKit
import XCTest
@testable import xabber

@MainActor
final class OMEMOThreeClientAttachmentOpenSafetyTests: XCTestCase {
    private typealias Policy = OMEMOThreeClientLiveUIAuthorization
    private let prefix = "XABBER_OMEMO_UI_"
    private let messageID = "36c43080-cca4-4605-a303-79910bbd7d54"
    private let body = "QA3-E08-open-image"
    private let reference = "reference-primary"

    private func environment() throws -> [String: String] {
        var env = [prefix + "ACCEPTANCE": "1", prefix + "ROLE": "iphone",
            prefix + "ACCOUNT": "igor.boldin@redsolution.com", prefix + "TOKEN": body,
            prefix + "BASELINE_SHA256": String(repeating: "a", count: 64),
            prefix + "ASSERT_MESSAGE": "1", prefix + "OPEN_ATTACHMENT": "1",
            prefix + "MESSAGE_ID": messageID, prefix + "MESSAGE_BODY": body]
        try bind(&env, attachments: [fixture(.image)])
        return env
    }
    private func fixture(_ kind: Policy.AttachmentKind) -> [String: Any] {
        let values: (String, Int, String)
        switch kind {
        case .image: values = ("QA3-image.png", 14205, "10e3ad9db045757011ccac1be7b224584a2d4a41433c010910423cebf9eb2529")
        case .file: values = ("QA3-document.txt", 2738, "37a4be8e8dd6c7fcb7af2a306909b658075b9a00fe1ab8c02be4b64a7d3877d0")
        case .audio: values = ("QA3-audio.wav", 16044, "c5b99ceef5c83a371360cad83a267daa6fb69cb96525672d353dddcd8fc33e9c")
        case .video: values = ("QA3-video.mp4", 1870, "0c4ecc8cee6f7bf03ee9ffeac5394e2e0860d3e496e5329f5f94bbbc5cbc063a")
        case .voice: values = ("QA3-voice.ogg", 1420, "c88e7fddcea31b4b04d98b969fb939f79205bf8019fc9726f969099c18c85b83")
        }
        return ["kind": kind.rawValue, "referencePrimary": reference, "filename": values.0,
                "byteCount": values.1, "sha256": values.2]
    }
    private func bind(_ env: inout [String: String], attachments: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: [["id": messageID, "body": body,
            "sender": "web", "attachments": attachments]], options: [.sortedKeys])
        env[prefix + "MESSAGE_MANIFEST_BASE64"] = data.base64EncodedString()
        env[prefix + "MESSAGE_MANIFEST_SHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func authorize(_ env: [String: String], operation: Policy.Operation = .openAttachment) throws -> Policy.Configuration? {
        try Policy.authorize(environment: env, isSimulator: false, idiom: .phone, operation: operation)
    }

    func testVisibleConversationContainerNeedNotBeAHitTargetWhenExactAttachmentLeafIsHittable() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertTrue(Policy.isVisibleContainer(.init(
            exists: true, isHittable: false, frame: viewport, viewport: viewport)))
        let image = Policy.ElementVisibilityWitness(exists: true, isHittable: true,
            frame: CGRect(x: 16, y: 413, width: 310, height: 310), viewport: viewport)
        XCTAssertTrue(Policy.isTappable(image))
    }

    func testAttachmentTapStillRequiresItsActualLeafToBeHittable() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let image = Policy.ElementVisibilityWitness(exists: true, isHittable: false,
            frame: CGRect(x: 16, y: 413, width: 310, height: 310), viewport: viewport)
        XCTAssertFalse(Policy.isTappable(image))
        XCTAssertFalse(Policy.isVisible(image), "Existing cell, body and viewer visibility keeps its hittability guard")
    }

    func testMissingEmptyAndOffscreenElementsCannotAuthorizeVisibilityOrTaps() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        let witnesses: [Policy.ElementVisibilityWitness] = [
            .init(exists: false, isHittable: true, frame: viewport, viewport: viewport),
            .init(exists: true, isHittable: true, frame: .zero, viewport: viewport),
            .init(exists: true, isHittable: true, frame: CGRect(x: 0, y: 845, width: 390, height: 50), viewport: viewport)
        ]
        for witness in witnesses {
            XCTAssertFalse(Policy.isVisible(witness))
            XCTAssertFalse(Policy.isVisibleContainer(witness))
            XCTAssertFalse(Policy.isTappable(witness))
        }
        XCTAssertFalse(Policy.isVisibleContainer(.init(
            exists: true, isHittable: true, frame: viewport, viewport: .zero)))
    }

    private func gallery(identifier: String = "authorized-gallery", rootHittable: Bool = true,
                         readyHittable: Bool = true, closeHittable: Bool = true,
                         readyCount: Int = 1, closeCount: Int = 1) -> Policy.PhotoGalleryWitness {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        func element(_ hittable: Bool) -> Policy.ElementVisibilityWitness {
            .init(exists: true, isHittable: hittable, frame: viewport, viewport: viewport)
        }
        return .init(identifier: identifier, root: element(rootHittable),
            readyCells: Array(repeating: element(readyHittable), count: readyCount),
            closeControls: Array(repeating: element(closeHittable), count: closeCount))
    }

    func testDecodedGalleryRootAndReadyStateNeedOnlyGeometryWhenExactCloseIsHittable() {
        XCTAssertTrue(Policy.hasExactlyOneReadyPhotoGallery(identifier: "authorized-gallery",
            witnesses: [gallery(rootHittable: false, readyHittable: false)]))
    }

    func testPhotoGalleryReadinessRejectsOtherReferencesAndAmbiguousRootsOrReadyCells() {
        for witnesses in [[], [gallery(identifier: "other-gallery")], [gallery(), gallery()],
                          [gallery(readyCount: 0)], [gallery(readyCount: 2)]] {
            XCTAssertFalse(Policy.hasExactlyOneReadyPhotoGallery(identifier: "authorized-gallery", witnesses: witnesses))
        }
        let value = gallery()
        let offscreen = Policy.ElementVisibilityWitness(exists: true, isHittable: true,
            frame: CGRect(x: 0, y: 900, width: 64, height: 64), viewport: value.root.viewport)
        XCTAssertFalse(Policy.hasExactlyOneReadyPhotoGallery(identifier: "authorized-gallery", witnesses: [
            .init(identifier: value.identifier, root: value.root, readyCells: [offscreen], closeControls: value.closeControls)
        ]))
    }

    func testPhotoGalleryReadinessRequiresOneActuallyHittableClose() {
        for value in [gallery(closeHittable: false), gallery(closeCount: 0), gallery(closeCount: 2)] {
            XCTAssertFalse(Policy.hasExactlyOneReadyPhotoGallery(identifier: "authorized-gallery", witnesses: [value]))
        }
    }

    func testImageDismissRequiresObservedGalleryCloseAndTheSameExactManifest() throws {
        for label in ["Close", "Закрыть"] {
            var env = try environment()
            env[prefix + "DISMISS_ATTACHMENT"] = "1"; env[prefix + "DISMISS_LABEL"] = label
            var config: Policy.Configuration?
            XCTAssertNoThrow(config = try authorize(env, operation: .dismissAttachment))
            XCTAssertEqual(config?.attachment?.kind, .image)
            for other in ["Done", "Готово", "Delete"] {
                env[prefix + "DISMISS_LABEL"] = other
                XCTAssertThrowsError(try authorize(env, operation: .dismissAttachment))
            }
        }
    }

    private func messageBody(_ text: String? = nil, exists: Bool = true, hittable: Bool = false,
                             offscreen: Bool = false) -> Policy.MessageBodyWitness {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
        return .init(text: text ?? body, visibility: .init(exists: exists, isHittable: hittable,
            frame: CGRect(x: 20, y: offscreen ? 900 : 725, width: 154, height: 21), viewport: viewport))
    }

    func testExactReadOnlyBodyCanBeVisibleWithoutBeingAHitTargetInsideHittableCell() {
        XCTAssertTrue(Policy.hasVisibleExactBody(body, cell: gallery().root, bodies: [messageBody()]))
    }

    func testReadOnlyBodyRejectsWrongDuplicateMissingOffscreenOrCoveredCellEvidence() {
        for bodies in [[], [messageBody("another body", hittable: true)],
                       [messageBody(hittable: true), messageBody(hittable: true)],
                       [messageBody(exists: false, hittable: true)], [messageBody(hittable: true, offscreen: true)]] {
            XCTAssertFalse(Policy.hasVisibleExactBody(body, cell: gallery().root, bodies: bodies))
        }
        XCTAssertFalse(Policy.hasVisibleExactBody(body, cell: gallery(rootHittable: false).root,
            bodies: [messageBody(hittable: true)]))
    }

    func testVisibleBodyCannotReplaceExactMessageIdentityOrGalleryReference() {
        let visible = Policy.hasVisibleExactBody(body, cell: gallery().root, bodies: [messageBody(hittable: true)])
        XCTAssertTrue(visible)
        XCTAssertFalse(Policy.hasExactlyOneVisibleMessage(id: messageID, body: body, witnesses: [
            .init(collectionIdentifier: Policy.conversationCollectionIdentifier,
                cellIdentifier: Policy.messageIdentifierPrefix("different-message") + Data("primary".utf8).base64EncodedString(),
                body: body, isVisible: visible)
        ]))
        XCTAssertFalse(Policy.hasExactlyOneReadyPhotoGallery(identifier: "authorized-gallery",
            witnesses: [gallery(identifier: "other-reference")]))
    }

    func testOpenRequiresSeparateExplicitOptInBeforeCreatingApplication() throws {
        var env = try environment(); env[prefix + "OPEN_ATTACHMENT"] = nil
        XCTAssertNil(try authorize(env))
    }
    func testOpenRequiresTheExactHashBoundMessageManifestAndBody() throws {
        for key in ["MESSAGE_ID", "MESSAGE_BODY", "MESSAGE_MANIFEST_BASE64", "MESSAGE_MANIFEST_SHA256", "ASSERT_MESSAGE"] {
            var env = try environment(); env[prefix + key] = nil
            XCTAssertThrowsError(try authorize(env), key)
        }
    }
    func testAllFiveFixedMediaKindsBindTheirExactReferenceAndBytes() throws {
        for kind in [Policy.AttachmentKind.image, .file, .audio, .video, .voice] {
            var env = try environment(); try bind(&env, attachments: [fixture(kind)])
            let config = try XCTUnwrap(authorize(env)); let attachment = try XCTUnwrap(config.attachment)
            XCTAssertEqual(attachment.kind, kind); XCTAssertEqual(attachment.referencePrimary, reference)
            XCTAssertEqual(attachment.filename, fixture(kind)["filename"] as? String)
            XCTAssertEqual(attachment.sha256, fixture(kind)["sha256"] as? String)
            XCTAssertEqual(attachment.byteCount, fixture(kind)["byteCount"] as? Int)
            XCTAssertEqual(config.messageID, messageID); XCTAssertEqual(config.messageBody, body)
        }
    }
    private func genericOGGFileFixture() -> [String: Any] {
        var media = fixture(.voice)
        media["kind"] = Policy.AttachmentKind.file.rawValue
        return media
    }

    func testExactOGGFileUsesNormalFileControlAndViewerWithoutVoiceRelabeling() throws {
        var env = try environment()
        try bind(&env, attachments: [genericOGGFileFixture()])

        let config = try XCTUnwrap(authorize(env))
        let attachment = try XCTUnwrap(config.attachment)
        let encodedReference = Data(reference.utf8).base64EncodedString()

        XCTAssertEqual(attachment.kind, .file)
        XCTAssertEqual(attachment.filename, "QA3-voice.ogg")
        XCTAssertEqual(attachment.byteCount, 1420)
        XCTAssertEqual(attachment.sha256, fixture(.voice)["sha256"] as? String)
        XCTAssertEqual(attachment.referencePrimary, reference)
        XCTAssertEqual(Policy.attachmentIdentifier(kind: attachment.kind, referencePrimary: reference),
                       "chat.attachment.file." + encodedReference)
        XCTAssertEqual(Policy.viewerIdentifier(for: attachment), "chat.media.file.viewer." + encodedReference)
        XCTAssertNotEqual(Policy.attachmentIdentifier(kind: attachment.kind, referencePrimary: reference),
                          Policy.attachmentIdentifier(kind: .voice, referencePrimary: reference))
    }

    func testExactOGGFileDismissRequiresObservedCanonicalButtonAndSameManifest() throws {
        for label in ["Close", "Done", "Закрыть", "Готово"] {
            var env = try environment()
            try bind(&env, attachments: [genericOGGFileFixture()])
            env[prefix + "DISMISS_ATTACHMENT"] = "1"
            env[prefix + "DISMISS_LABEL"] = label

            let config = try XCTUnwrap(authorize(env, operation: .dismissAttachment))

            XCTAssertEqual(config.attachment?.kind, .file)
            XCTAssertEqual(config.attachment?.filename, "QA3-voice.ogg")
            XCTAssertEqual(config.attachment?.referencePrimary, reference)
            XCTAssertEqual(config.dismissLabel, label)
            env[prefix + "DISMISS_ATTACHMENT"] = nil
            XCTAssertNil(try authorize(env, operation: .dismissAttachment))
        }
        for label in ["", "Delete", "Done ", "Other personal button"] {
            var env = try environment()
            try bind(&env, attachments: [genericOGGFileFixture()])
            env[prefix + "DISMISS_ATTACHMENT"] = "1"
            env[prefix + "DISMISS_LABEL"] = label
            XCTAssertThrowsError(try authorize(env, operation: .dismissAttachment))
        }
    }

    func testOGGFileAllowlistRejectsOtherNamesBytesHashesAndExtraMetadata() throws {
        let changes: [(String, Any)] = [
            ("filename", "personal.ogg"), ("filename", "QA3-voice.OGG"),
            ("byteCount", 0), ("byteCount", 1421),
            ("sha256", String(repeating: "0", count: 64)),
            ("url", "https://example.test/file"), ("mimeType", "audio/ogg")
        ]
        for (key, value) in changes {
            var media = genericOGGFileFixture()
            media[key] = value
            var env = try environment()
            try bind(&env, attachments: [media])

            XCTAssertThrowsError(try authorize(env), key)
        }
    }

    func testOGGBytesDoNotAuthorizeImageWAVOrVideoControls() throws {
        for kind in [Policy.AttachmentKind.image, .audio, .video] {
            var media = genericOGGFileFixture()
            media["kind"] = kind.rawValue
            var env = try environment()
            try bind(&env, attachments: [media])

            XCTAssertThrowsError(try authorize(env), kind.rawValue)
        }
    }

    func testPreparedNativeOGGVoiceRetainsItsVoiceControlAndNonmodalSemantics() throws {
        var env = try environment()
        try bind(&env, attachments: [fixture(.voice)])

        let config = try XCTUnwrap(authorize(env))
        let attachment = try XCTUnwrap(config.attachment)
        let encodedReference = Data(reference.utf8).base64EncodedString()

        XCTAssertEqual(attachment.kind, .voice)
        XCTAssertEqual(Policy.attachmentIdentifier(kind: attachment.kind, referencePrimary: reference),
                       "chat.attachment.voice." + encodedReference)
        XCTAssertEqual(Policy.viewerIdentifier(for: attachment), "")
        env[prefix + "DISMISS_ATTACHMENT"] = "1"
        env[prefix + "DISMISS_LABEL"] = "Done"
        XCTAssertThrowsError(try authorize(env, operation: .dismissAttachment))
    }

    func testOGGFileRetainsPhysicalOptInManifestMessageAndReferenceGuards() throws {
        var valid = try environment()
        try bind(&valid, attachments: [genericOGGFileFixture()])
        XCTAssertEqual(try XCTUnwrap(authorize(valid)).attachment?.kind, .file)

        var missingOptIn = valid
        missingOptIn[prefix + "ACCEPTANCE"] = nil
        XCTAssertNil(try authorize(missingOptIn))
        var missingOpenOptIn = valid
        missingOpenOptIn[prefix + "OPEN_ATTACHMENT"] = nil
        XCTAssertNil(try authorize(missingOpenOptIn))

        for (key, value) in [
            ("ACCOUNT", "another@example.test"), ("BASELINE_SHA256", ""),
            ("ASSERT_MESSAGE", "0"), ("MESSAGE_MANIFEST_SHA256", String(repeating: "0", count: 64)),
            ("MESSAGE_ID", "57ac412c-c316-4bf3-91b4-f2041b8060d2"),
            ("MESSAGE_BODY", body + " changed"), ("RESET", "1")
        ] {
            var env = valid
            env[prefix + key] = value
            XCTAssertThrowsError(try authorize(env), key)
        }
        XCTAssertThrowsError(try Policy.authorize(environment: valid, isSimulator: true,
                                                 idiom: .phone, operation: .openAttachment))
        XCTAssertThrowsError(try Policy.authorize(environment: valid, isSimulator: false,
                                                 idiom: .pad, operation: .openAttachment))
        for invalidReference in ["", String(repeating: "x", count: 2049), "ref\nother"] {
            var media = genericOGGFileFixture()
            media["referencePrimary"] = invalidReference
            var env = valid
            try bind(&env, attachments: [media])
            XCTAssertThrowsError(try authorize(env))
        }
        for entries in [[], [genericOGGFileFixture(), genericOGGFileFixture()]] {
            var env = valid
            try bind(&env, attachments: entries)
            XCTAssertThrowsError(try authorize(env))
        }
    }

    func testMissingOrMultipleAttachmentsCannotAuthorizeAnAmbiguousTap() throws {
        for entries in [[], [fixture(.image), fixture(.image)]] {
            var env = try environment(); try bind(&env, attachments: entries)
            XCTAssertThrowsError(try authorize(env))
        }
    }
    func testUnknownKindFixtureHashSizeOrExtraMetadataCannotExpandScope() throws {
        for (key, value) in [("kind", "unknown" as Any), ("filename", "personal.png"),
            ("sha256", String(repeating: "0", count: 64)), ("byteCount", 0), ("url", "https://example.test/file")] {
            var media = fixture(.image); media[key] = value
            var env = try environment(); try bind(&env, attachments: [media])
            XCTAssertThrowsError(try authorize(env), key)
        }
    }
    func testReferencePrimaryMustBeNonemptyBoundedAndFreeOfControlCharacters() throws {
        for value in ["", String(repeating: "x", count: 2049), "ref\nother", "ref\u{0000}other"] {
            var media = fixture(.image); media["referencePrimary"] = value
            var env = try environment(); try bind(&env, attachments: [media])
            XCTAssertThrowsError(try authorize(env))
        }
    }
    func testSystemDismissRequiresTheSameExactAttachmentAndObservedNormalLabel() throws {
        for kind in [Policy.AttachmentKind.file, .audio, .video] {
            var env = try environment(); try bind(&env, attachments: [fixture(kind)])
            env[prefix + "DISMISS_ATTACHMENT"] = "1"; env[prefix + "DISMISS_LABEL"] = "Done"
            let config = try XCTUnwrap(authorize(env, operation: .dismissAttachment))
            XCTAssertEqual(config.attachment?.kind, kind); XCTAssertEqual(config.dismissLabel, "Done")
            env[prefix + "DISMISS_ATTACHMENT"] = nil
            XCTAssertNil(try authorize(env, operation: .dismissAttachment))
        }
    }
    func testSystemDismissRejectsUnobservedNoncanonicalLabelAndNonmodalVoice() throws {
        for label in ["", "Delete", "Done ", "Other personal button"] {
            var env = try environment(); try bind(&env, attachments: [fixture(.file)])
            env[prefix + "DISMISS_ATTACHMENT"] = "1"; env[prefix + "DISMISS_LABEL"] = label
            XCTAssertThrowsError(try authorize(env, operation: .dismissAttachment))
        }
        var env = try environment(); try bind(&env, attachments: [fixture(.voice)])
        env[prefix + "DISMISS_ATTACHMENT"] = "1"; env[prefix + "DISMISS_LABEL"] = "Done"
        XCTAssertThrowsError(try authorize(env, operation: .dismissAttachment))
    }

    func testVoiceWitnessRequiresANewPlayingEntryForTheSameExactReference() {
        let base = Policy.attachmentIdentifier(kind: .voice, referencePrimary: reference)
        XCTAssertTrue(Policy.hasNewVoicePlayback(referencePrimary: reference, before: base + ".downloaded.p0", after: base + ".downloaded.p1"))
        XCTAssertTrue(Policy.hasNewVoicePlayback(referencePrimary: reference, before: base + ".paused.p4", after: base + ".playing.p5"))
        for after in [base + ".downloaded.p0", base + ".failed.p1", base + ".playing.p01", base + ".playing.p-1",
                      Policy.attachmentIdentifier(kind: .voice, referencePrimary: "other") + ".playing.p1"] {
            XCTAssertFalse(Policy.hasNewVoicePlayback(referencePrimary: reference, before: base + ".downloaded.p0", after: after))
        }
    }
    func testImageVideoAndFileTargetsFollowActualReferenceRebindWithoutVoiceOverChanges() {
        let request = InlineAttachmentRepresentedRequest(containerPrimary: "container", referencePrimary: reference, resourceIdentity: "resource")
        let image = InlineImagesGridView.InlineMessageImageView(frame: .zero, primary: reference, url: nil, sourceURL: nil, isSensitive: false, representedRequest: request)
        let video = InlineVideosGridView.InlineMessageVideoView(frame: .zero, primary: reference, url: nil, isSensitive: false, representedRequest: request)
        let file = InlineFilesGridView.FileView(frame: .zero)
        let imageElement = image.isAccessibilityElement; let imageTraits = image.accessibilityTraits
        file.primary = reference
        XCTAssertEqual(image.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .image, referencePrimary: reference))
        XCTAssertEqual(video.playButton.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .video, referencePrimary: reference))
        XCTAssertEqual(file.filenameLabel.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .file, referencePrimary: reference))
        image.primary = "second"; video.primary = "second"; file.primary = "second"
        XCTAssertEqual(image.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .image, referencePrimary: "second"))
        XCTAssertEqual(video.playButton.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .video, referencePrimary: "second"))
        XCTAssertEqual(file.filenameLabel.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .file, referencePrimary: "second"))
        XCTAssertEqual(image.isAccessibilityElement, imageElement); XCTAssertEqual(image.accessibilityTraits, imageTraits)
        file.prepareForReuse(); XCTAssertNil(file.filenameLabel.accessibilityIdentifier)
    }
    func testVoiceRenderCounterEntersPlayingOnceAndResetsForAnotherReferenceAndReuse() {
        let view = InlineAudiosGridView.AudioView(frame: .zero, url: nil)
        let element = view.iconButton.isAccessibilityElement; let traits = view.iconButton.accessibilityTraits
        view.configure(reference, filename: "Voice", size: "1KB", duration: 1, pcm: [], state: .downloaded)
        let base = Policy.attachmentIdentifier(kind: .voice, referencePrimary: reference)
        XCTAssertEqual(view.iconButton.accessibilityIdentifier, base + ".downloaded.p0")
        view.render(state: .playing(currentTime: 0, duration: 1))
        XCTAssertEqual(view.iconButton.accessibilityIdentifier, base + ".playing.p1")
        view.render(state: .playing(currentTime: 0.1, duration: 1))
        XCTAssertEqual(view.iconButton.accessibilityIdentifier, base + ".playing.p1")
        view.render(state: .downloaded); view.render(state: .playing(currentTime: 0, duration: 1))
        XCTAssertEqual(view.iconButton.accessibilityIdentifier, base + ".playing.p2")
        view.configure("second", filename: "Voice", size: "1KB", duration: 1, pcm: [], state: .playing(currentTime: 0, duration: 1))
        XCTAssertEqual(view.iconButton.accessibilityIdentifier, Policy.attachmentIdentifier(kind: .voice, referencePrimary: "second") + ".playing.p1")
        XCTAssertEqual(view.iconButton.isAccessibilityElement, element); XCTAssertEqual(view.iconButton.accessibilityTraits, traits)
        view.prepareForReuse(); XCTAssertNil(view.iconButton.accessibilityIdentifier)
    }
    func testPhotoGalleryReadyIdentifierRequiresDecodedImageAndReuseClearsIt() throws {
        let cell = PhotoGalleryCell(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        cell.configureForNewImageUrl()
        XCTAssertEqual(cell.accessibilityIdentifier, "chat.media.photo.loading")
        XCTAssertNil(cell.imageView.image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        try XCTUnwrap(image.pngData()).write(to: url)
        cell.imageUrl = url; cell.configureForNewImageUrl()
        expectation(for: NSPredicate { _, _ in cell.accessibilityIdentifier == "chat.media.photo.ready" }, evaluatedWith: cell)
        waitForExpectations(timeout: 3)
        XCTAssertNotNil(cell.imageView.image)
        cell.prepareForReuse(); XCTAssertNil(cell.accessibilityIdentifier); XCTAssertNil(cell.imageView.image)
    }
}
