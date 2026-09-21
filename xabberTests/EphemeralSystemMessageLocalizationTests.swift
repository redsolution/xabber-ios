import XCTest
import UIKit
@testable import xabber

@MainActor
final class EphemeralSystemMessageLocalizationTests: XCTestCase {
    private var previousLocalizationContext: LocalizationContext!

    override func setUp() {
        super.setUp()
        previousLocalizationContext = LocalizationRuntime.shared.context
        installLanguage(.english)
    }

    override func tearDown() {
        LocalizationRuntime.shared.replaceContext(previousLocalizationContext)
        previousLocalizationContext = nil
        super.tearDown()
    }

    func testSemanticTimerMessageUsesCanonicalEnglishWireFallbackAndCurrentLanguageAcrossSurfaces() throws {
        let event = try XCTUnwrap(EphemeralTimerSystemEvent(timerSeconds: 300))
        XCTAssertEqual(event.canonicalEnglishBody, "Self-destruct timer was set to 5 minutes")

        let message = makeSystemMessage(timerSeconds: 300, body: event.canonicalEnglishBody)
        XCTAssertEqual(message.body, "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(message.userVisibleBody, "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(message.bodyForAttachmentRendering, "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(message.displayedBody(), "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(message.copyableBodyText(), "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(
            SavedMessageDisplayPolicy.presentation(
                for: message,
                currentUserJid: "alice@example.org"
            ).visibleBody,
            "Self-destruct timer was set to 5 minutes"
        )
        XCTAssertEqual(
            LastChatMessagePreviewPolicy.preview(
                for: message,
                blankMessageText: "Start messaging here"
            ).text,
            "Self-destruct timer was set to 5 minutes"
        )

        installLanguage(.russian)

        XCTAssertEqual(message.body, "Self-destruct timer was set to 5 minutes")
        XCTAssertEqual(message.userVisibleBody, "Таймер самоуничтожения установлен на 5 минут")
        XCTAssertEqual(message.bodyForAttachmentRendering, "Таймер самоуничтожения установлен на 5 минут")
        XCTAssertEqual(message.displayedBody(), "Таймер самоуничтожения установлен на 5 минут")
        XCTAssertEqual(message.copyableBodyText(), "Таймер самоуничтожения установлен на 5 минут")
        XCTAssertEqual(
            SavedMessageDisplayPolicy.presentation(
                for: message,
                currentUserJid: "alice@example.org"
            ).visibleBody,
            "Таймер самоуничтожения установлен на 5 минут"
        )
        XCTAssertEqual(
            LastChatMessagePreviewPolicy.preview(
                for: message,
                blankMessageText: "Start messaging here"
            ).text,
            "Таймер самоуничтожения установлен на 5 минут"
        )
    }

    func testDisabledTimerMessageUsesLocalizedSemanticText() {
        let event = EphemeralTimerSystemEvent.disabled
        XCTAssertEqual(event.canonicalEnglishBody, "Self-destruct timer was disabled")

        let message = makeSystemMessage(timerSeconds: 0, body: event.canonicalEnglishBody)

        XCTAssertEqual(message.userVisibleBody, "Self-destruct timer was disabled")

        installLanguage(.simplifiedChinese)

        XCTAssertEqual(message.userVisibleBody, "自毁计时器已关闭")
    }

    func testRecognizedLegacyTimerMetadataOverridesStoredLanguageDependentBody() {
        let message = makeSystemMessage(
            timerSeconds: 5,
            body: "Self-destruct timer was set to 5 seconds"
        )

        installLanguage(.spanish)

        XCTAssertEqual(
            message.userVisibleBody,
            "El temporizador de autodestrucción se configuró en 5 segundos"
        )
        XCTAssertEqual(
            LastChatMessagePreviewPolicy.preview(
                for: message,
                blankMessageText: "Start messaging here"
            ).text,
            "El temporizador de autodestrucción se configuró en 5 segundos"
        )
    }

    func testMissingMalformedAndUnknownTimerMetadataPreserveStoredBody() {
        let missing = makeSystemMessage(timerSeconds: nil, body: "Legacy timer message")
        XCTAssertNil(missing.ephemeralTimerSystemEvent)
        XCTAssertEqual(missing.userVisibleBody, "Legacy timer message")

        let unknown = makeSystemMessage(timerSeconds: 20, body: "Future timer message")
        XCTAssertNil(unknown.ephemeralTimerSystemEvent)
        XCTAssertEqual(unknown.userVisibleBody, "Future timer message")

        let wrongReferenceKind = makeSystemMessage(
            timerSeconds: 60,
            body: "Server-authored text",
            referenceKind: .quote
        )
        XCTAssertNil(wrongReferenceKind.ephemeralTimerSystemEvent)
        XCTAssertEqual(wrongReferenceKind.userVisibleBody, "Server-authored text")
    }

    func testTimerUnitsUsePluralRulesForAllSupportedLanguages() throws {
        let scenarios: [(SupportedLanguage, Int, String)] = [
            (.english, 60, "Self-destruct timer was set to 1 minute"),
            (.russian, 300, "Таймер самоуничтожения установлен на 5 минут"),
            (.french, 900, "Le minuteur d’autodestruction a été réglé sur 15 minutes"),
            (.spanish, 10, "El temporizador de autodestrucción se configuró en 10 segundos"),
            (.arabic, 5, "تم ضبط مؤقت التدمير الذاتي على 5 ثوانٍ"),
            (.simplifiedChinese, 30, "自毁计时器已设置为 30 秒")
        ]

        for (language, timerSeconds, expected) in scenarios {
            installLanguage(language)
            let event = try XCTUnwrap(EphemeralTimerSystemEvent(timerSeconds: timerSeconds))
            XCTAssertEqual(event.localizedText, expected, language.rawValue)
        }
    }

    private func makeSystemMessage(
        timerSeconds: Int?,
        body: String,
        referenceKind: MessageReferenceStorageItem.Kind = .systemMessage
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.body = body
        message.legacyBody = body
        message.displayAs = .system

        let reference = MessageReferenceStorageItem()
        reference.kind = referenceKind
        if let timerSeconds {
            reference.metadata = [EphemeralTimerSystemEvent.metadataKey: timerSeconds]
        }
        message.references.append(reference)
        return message
    }

    private func installLanguage(_ language: SupportedLanguage) {
        LocalizationRuntime.shared.replaceContext(
            selection: .fixed(language),
            preferredLanguages: [language.rawValue],
            locale: previousLocalizationContext.locale,
            calendar: previousLocalizationContext.calendar,
            timeZone: previousLocalizationContext.timeZone
        )
    }
}
