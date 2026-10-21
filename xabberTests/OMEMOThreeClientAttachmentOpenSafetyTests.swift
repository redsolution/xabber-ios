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
