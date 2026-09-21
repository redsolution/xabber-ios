import XCTest
import RealmSwift
import UIKit
@testable import xabber

@MainActor
final class AKESystemMessageLocalizationTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var previousLocalizationContext: LocalizationContext!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        previousLocalizationContext = LocalizationRuntime.shared.context
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "AKESystemMessageLocalizationTests-\(name)-\(UUID().uuidString)"
        )
        installLanguage(.english)
    }

    override func tearDown() {
        LocalizationRuntime.shared.replaceContext(previousLocalizationContext)
        previousLocalizationContext = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testEveryEventHasAClosedCanonicalLocalizationContract() {
        let expected: [(
            event: AuthenticatedKeyExchangeSystemEvent,
            key: String,
            fallback: String
        )] = [
            (
                .outgoingVerificationRequest,
                "authenticated_key_exchange__body__outgoing_verification_request",
                "Outgoing verification request"
            ),
            (
                .acceptedVerificationRequest,
                "authenticated_key_exchange__body__you_accepted_the_verification_request",
                "You accepted the verification request"
            ),
            (
                .incomingVerificationRequest,
                "authenticated_key_exchange__body__incoming_verification_request",
                "Incoming verification request"
            ),
            (
                .verificationRejected,
                "authenticated_key_exchange__body__verification_rejected",
                "Verification rejected"
            ),
            (
                .verificationTimedOut,
                "authenticated_key_exchange__body__verification_timed_out",
                "Verification timed out"
            ),
            (
                .verificationFailed,
                "authenticated_key_exchange__body__verification_failed",
                "Verification failed"
            ),
            (
                .verificationSucceeded,
                "authenticated_key_exchange__body__verification_succeeded",
                "Verification succeeded"
            )
        ]

        XCTAssertEqual(AuthenticatedKeyExchangeSystemEvent.allCases.count, expected.count)
        for contract in expected {
            XCTAssertEqual(contract.event.localizationKey, contract.key)
            XCTAssertEqual(contract.event.englishFallback, contract.fallback)
            XCTAssertEqual(contract.event.localizedText, contract.fallback)
        }
    }

    func testManagerPersistsSemanticEventWithoutRenderedBody() throws {
        let owner = "alice@example.org"
        let peer = "bob@example.org"
        let manager = AuthenticatedKeyExchangeManager(withOwner: owner)

        manager.makeSystemMessage(
            jid: peer,
            event: .incomingVerificationRequest
        )

        let realm = try WRealm.safe()
        let stored = try XCTUnwrap(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@", owner, peer)
                .first
        )
        XCTAssertEqual(stored.body, "")
        XCTAssertEqual(
            stored.systemMetadata?[MessageStorageItem.authenticatedKeyExchangeEventMetadataKey] as? String,
            AuthenticatedKeyExchangeSystemEvent.incomingVerificationRequest.rawValue
        )
        XCTAssertEqual(
            stored.authenticatedKeyExchangeSystemEvent,
            .incomingVerificationRequest
        )
    }

    func testPersistedEventRendersInCurrentLanguageAcrossChatSurfaces() throws {
        let owner = "alice@example.org"
        let peer = "bob@example.org"
        let manager = AuthenticatedKeyExchangeManager(withOwner: owner)
        manager.makeSystemMessage(jid: peer, event: .verificationSucceeded)

        let realm = try WRealm.safe()
        let stored = try XCTUnwrap(
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@", owner, peer)
                .first
        )
        XCTAssertEqual(stored.userVisibleBody, "Verification succeeded")
        XCTAssertEqual(stored.bodyForAttachmentRendering, "Verification succeeded")

        installLanguage(.russian)

        XCTAssertEqual(stored.body, "")
        XCTAssertEqual(stored.userVisibleBody, "Проверка выполнена успешно")
        XCTAssertEqual(stored.displayedBody(), "Проверка выполнена успешно")
        XCTAssertEqual(stored.copyableBodyText(), "Проверка выполнена успешно")

        let presentation = SavedMessageDisplayPolicy.presentation(
            for: stored,
            currentUserJid: owner,
            currentUserName: "Alice"
        )
        XCTAssertEqual(presentation.visibleBody, "Проверка выполнена успешно")

        let preview = LastChatMessagePreviewPolicy.preview(
            for: stored,
            blankMessageText: "Start messaging here"
        )
        XCTAssertEqual(preview.text, "Проверка выполнена успешно")
    }

    func testLegacyAndUnknownMetadataPreserveStoredBody() {
        let legacy = makeSystemMessage(body: "Verification succeeded")
        XCTAssertNil(legacy.authenticatedKeyExchangeSystemEvent)
        XCTAssertEqual(legacy.userVisibleBody, "Verification succeeded")

        installLanguage(.russian)
        XCTAssertEqual(legacy.userVisibleBody, "Verification succeeded")

        let alreadyLocalized = makeSystemMessage(body: "Проверка выполнена успешно")
        XCTAssertEqual(alreadyLocalized.userVisibleBody, "Проверка выполнена успешно")

        alreadyLocalized.systemMetadata = [
            MessageStorageItem.authenticatedKeyExchangeEventMetadataKey: "future_unknown_event"
        ]
        XCTAssertNil(alreadyLocalized.authenticatedKeyExchangeSystemEvent)
        XCTAssertEqual(alreadyLocalized.userVisibleBody, "Проверка выполнена успешно")
    }

    func testAKEEventMetadataIsIgnoredOutsideLocalOMEMOSystemMessages() {
        let message = makeSystemMessage(body: "Server-authored text")
        message.conversationType = .group
        message.systemMetadata = [
            MessageStorageItem.authenticatedKeyExchangeEventMetadataKey:
                AuthenticatedKeyExchangeSystemEvent.verificationSucceeded.rawValue
        ]

        installLanguage(.russian)

        XCTAssertNil(message.authenticatedKeyExchangeSystemEvent)
        XCTAssertEqual(message.userVisibleBody, "Server-authored text")
    }

    func testDisplayCacheContextChangesWithLocalizationRevision() {
        let traitCollection = UITraitCollection()
        let firstLocalizationContext = L10n.context
        let first = ChatDisplayModelCacheContext.current(
            searchText: nil,
            traitCollection: traitCollection,
            localizationContext: firstLocalizationContext
        )

        installLanguage(.russian)

        let secondLocalizationContext = L10n.context
        let second = ChatDisplayModelCacheContext.current(
            searchText: nil,
            traitCollection: traitCollection,
            localizationContext: secondLocalizationContext
        )

        XCTAssertEqual(first.localizationRevision, firstLocalizationContext.revision)
        XCTAssertEqual(second.localizationRevision, secondLocalizationContext.revision)
        XCTAssertEqual(second.localeIdentifier, secondLocalizationContext.locale.identifier)
        XCTAssertNotEqual(first, second)
    }

    private func makeSystemMessage(body: String) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.body = body
        message.displayAs = .system
        message.conversationType = .omemo
        message.outgoing = true
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
