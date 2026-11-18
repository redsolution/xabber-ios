import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatStickerPickerTests: XCTestCase {
    private let manifestURL = URL(string: "https://stickers.example.com/owls/pack.xml")!
    private let owner = "first@example.com"

    func testManifestPreservesEmojiMetadataAndEscapesFilenames() throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 2).utf8), url: manifestURL)
        let entry = try XCTUnwrap(pack.stickers.first)

        XCTAssertEqual(pack.manifestURL, manifestURL)
        XCTAssertEqual(pack.version, 2)
        XCTAssertEqual(pack.coverURL?.absoluteString, "https://stickers.example.com/owls/cover.webp")
        XCTAssertEqual(entry.imageURL.absoluteString, "https://stickers.example.com/owls/Daffodil%20%23%201.webp")
        XCTAssertEqual(entry.name, "Daffodil")
        XCTAssertEqual(entry.emojis, ["🦉", "💐"])
        XCTAssertEqual(entry.width, 512)
        XCTAssertEqual(entry.descriptor(preferredEmoji: "💐").emoji, "💐")
    }

    func testManifestRejectsExternalEntitiesAndUnsafeMediaURLs() {
        let externalEntity = """
        <!DOCTYPE sticker-pack [<!ENTITY content SYSTEM 'file:///private/stickers'>]>
        <sticker-pack name="Unsafe"><stickers><sticker name="&content;"/></stickers></sticker-pack>
        """
        let unsafeURL = xml(version: 1, fileURL: "file:///private/secrets.webp")

        XCTAssertThrowsError(try ChatStickerPackManifest.parse(Data(externalEntity.utf8), url: manifestURL))
        XCTAssertThrowsError(try ChatStickerPackManifest.parse(Data(unsafeURL.utf8), url: manifestURL))
        XCTAssertNil(ChatStickerPackManifest.manifestURL("https://user:pass@stickers.example.com/pack.xml"))
    }

    func testInstallPersistsPerOwnerAndRefreshCannotDowngrade() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        var version = 3
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in Data(self.xml(version: version).utf8) }

        try await catalogue.install(manifestURL, owner: owner)
        version = 2
        try await catalogue.install(manifestURL, owner: owner)

        let restored = ChatStickerCatalogue(defaults: defaults) { _, _ in throw ChatStickerPackManifest.Failure.invalidManifest }
        XCTAssertEqual(restored.installed(for: owner).map(\.version), [3])
        XCTAssertTrue(restored.installed(for: "second@example.com").isEmpty)
        try restored.remove(manifestURL, owner: owner)
        XCTAssertTrue(catalogue.installed(for: owner).isEmpty)
    }

    func testSuggestionsMatchALoneEmojiAndKeepAlternatives() throws {
        let pack = try ChatStickerPackManifest.parse(Data(xml(version: 1, secondSticker: true).utf8), url: manifestURL)

        XCTAssertEqual(ChatStickerSuggestion.matches(text: " 🦉 ", packs: [pack]).map(\.name), ["Daffodil", "Owl"])
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "Hello 🦉", packs: [pack]).isEmpty)
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "🦉🦉", packs: [pack]).isEmpty)
        XCTAssertTrue(ChatStickerSuggestion.matches(text: "x", packs: [pack]).isEmpty)
    }

    func testUninstallFencesAPendingInstallResponse() async throws {
        let key = "ChatStickerPickerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let started = expectation(description: "Manifest request started")
        var receipt: CheckedContinuation<Data, Error>?
        let catalogue = ChatStickerCatalogue(defaults: defaults) { _, _ in
            try await withCheckedThrowingContinuation {
                receipt = $0
                started.fulfill()
            }
        }
        let install = Task { try await catalogue.install(manifestURL, owner: owner) }
        await fulfillment(of: [started], timeout: 2)
        try catalogue.remove(manifestURL, owner: owner)
        try XCTUnwrap(receipt).resume(returning: Data(xml(version: 2).utf8))

        if case .success = await install.result {
            XCTFail("A late manifest response restored a removed pack")
        }
        XCTAssertTrue(catalogue.installed(for: owner).isEmpty)
    }

    func testComposerStickerActionHasSeparateDelegateRouteAndKeepsDraft() {
        let delegate = StickerComposerDelegate()
        let view = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        view.delegate = delegate
        view.stickerOwner = owner
        view.setComposerText("Unrelated draft")

        view.stickerButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.opened, 1)
        XCTAssertEqual(view.textField.text, "Unrelated draft")
        view.changeState(to: .selection)
        XCTAssertTrue(view.stickerButton.isHidden)
        view.stickerButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.opened, 1)

        view.changeState(to: .normal)
        view.showSelectionPanel()
        XCTAssertTrue(view.stickerButton.isHidden)
        view.hideSelectionPanel()
        XCTAssertFalse(view.stickerButton.isHidden)
    }

    private func xml(version: Int, fileURL: String = "", secondSticker: Bool = false) -> String {
        """
        <sticker-pack name="Owls" version="\(version)">
          <cover><file><name>cover.webp</name></file></cover>
          <stickers>
            <sticker name="Daffodil"><file id="01"><name>Daffodil # 1.webp</name><url>\(fileURL)</url><media-type>image/webp</media-type><width>512</width><height>400</height></file><emojis><emoji>🦉</emoji><emoji>💐</emoji></emojis></sticker>
            \(secondSticker ? "<sticker name='Owl'><file id='02'><name>owl.webp</name></file><emojis><emoji>🦉</emoji></emojis></sticker>" : "")
          </stickers>
        </sticker-pack>
        """
    }

    private final class StickerComposerDelegate: XabberInputBarDelegate {
        private(set) var opened = 0
        func stickerPickerButtonTouchUp() { opened += 1 }
        func sendButtonTouchUp(with text: String) {}
        func sendButtonLongPressMenuRequested(sourceView: UIView, payload: ComposerMessagePayload) {}
        func scheduledMessagesButtonTouchUp() {}
        func attachmentButtonTouchUp() {}
        func onAfterburnButtonTouchUp() {}
        func onHeightChanged(to height: CGFloat, bar barHeight: CGFloat) {}
        func onCheckDevices() {}
        func onCheckContactDevices() {}
        func onUpdateSignature() {}
        func onIdentityVerification() {}
        func onTextDidChange(to text: String?) {}
        func onAudioMessageStartRecord(sessionID: UUID) {}
        func onAudioMessageDidCancel(sessionID: UUID) {}
        func onAudioMessageDidFinish(sessionID: UUID, intent: VoiceRecordingFinishIntent) {}
        func onAudioMessagePreviewSend(sessionID: UUID) {}
        func onAudioMessagePreviewDelete(sessionID: UUID) {}
        func recordAndPlayPanelPlayButtonTouchUp(sessionID: UUID) {}
        func didStopPlayingAudio() {}
        func didSetAudioPositionBar(percentage: Float) -> TimeInterval { 0 }
    }
}
