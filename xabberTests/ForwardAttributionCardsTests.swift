import XCTest
import XMPPFramework
@testable import xabber

final class ForwardAttributionCardsTests: XCTestCase {
    func testIndividualCardRoundTripUsesDataReferenceWithoutBodyRange() throws {
        let card = ForwardContactCard(
            jid: "juliet@example.com", name: "Juliet <Capulet>", nickname: "Juliet",
            kind: .individual, privacy: nil, avatarURI: "https://example.com/avatar%20one.png"
        )

        let reference = ForwardContactDataCodec.encode(card)

        XCTAssertEqual(reference.xmlns(), "https://xabber.com/protocol/references")
        XCTAssertEqual(reference.attributeStringValue(forName: "type"), "data")
        XCTAssertNil(reference.attribute(forName: "begin"))
        XCTAssertNil(reference.attribute(forName: "end"))
        XCTAssertEqual(ForwardContactDataCodec.decode(reference), card)
        XCTAssertFalse(reference.xmlString.contains("<Capulet>"))
    }

    func testGroupWriterUsesCanonicalKindAndSeparatePrivacy() throws {
        let card = ForwardContactCard(
            jid: "council@example.com", name: "Council", nickname: nil,
            kind: .group, privacy: .incognito, avatarURI: nil
        )

        let reference = ForwardContactDataCodec.encode(card)
        let vcard = try XCTUnwrap(reference.element(forName: "vcard", xmlns: ForwardContactDataCodec.vcardXMLNS))

        XCTAssertEqual(vcard.element(forName: "kind")?.element(forName: "text")?.stringValue, "group")
        XCTAssertEqual(vcard.element(forName: "x-groups-privacy")?.element(forName: "text")?.stringValue, "incognito")
        XCTAssertEqual(vcard.element(forName: "impp")?.element(forName: "uri")?.stringValue, "xmpp:council@example.com")
        XCTAssertEqual(ForwardContactDataCodec.decode(reference), card)
    }

    func testLegacyGroupAliasesAreReadOnlyAndUnknownPrivacyStaysUnknown() throws {
        let incognito = try XCTUnwrap(ForwardContactDataCodec.decode(reference(kind: "incognito")))
        let oldPublic = try XCTUnwrap(ForwardContactDataCodec.decode(reference(kind: "groupchat")))
        let unknown = try XCTUnwrap(ForwardContactDataCodec.decode(reference(kind: "group", extra: "<x-groups-privacy><text>unknown</text></x-groups-privacy>")))
        let unknownLegacy = try XCTUnwrap(ForwardContactDataCodec.decode(reference(kind: "incognito", extra: "<x-groups-privacy><text>unknown</text></x-groups-privacy>")))

        XCTAssertEqual(incognito.kind, .group)
        XCTAssertEqual(incognito.privacy, .incognito)
        XCTAssertEqual(oldPublic.kind, .group)
        XCTAssertNil(oldPublic.privacy)
        XCTAssertNil(unknown.privacy)
        XCTAssertNil(unknownLegacy.privacy)
        XCTAssertFalse(ForwardContactDataCodec.encode(incognito).xmlString.contains("<text>incognito</text></kind>"))
    }

    func testDataCardRejectsBodyRangesForeignNamespacesAndAmbiguousPayloads() throws {
        let valid = try reference()
        let ranged = valid.copy() as! DDXMLElement
        ranged.addAttribute(withName: "begin", stringValue: "0")
        let foreign = valid.copy() as! DDXMLElement
        foreign.setXmlns("urn:foreign:references")
        let multiple = valid.copy() as! DDXMLElement
        multiple.addChild(try XCTUnwrap(valid.element(forName: "vcard")?.copy() as? DDXMLElement))
        let mutable = valid.copy() as! DDXMLElement
        mutable.removeAttribute(forName: "type")
        mutable.addAttribute(withName: "type", stringValue: "mutable")

        for malformed in [ranged, foreign, multiple, mutable] {
            XCTAssertNil(ForwardContactDataCodec.decode(malformed))
        }
    }

    func testRequiredAddressIsBareXMPPURIAndRequiredNameIsNonempty() throws {
        for impp in ["https://example.com/juliet", "xmpp:juliet@example.com/phone", "xmpp:juliet@example.com?message", "xmpp:juliet@example.com#fragment", "xmpp:bad jid@example.com"] {
            XCTAssertNil(ForwardContactDataCodec.decode(try reference(impp: impp)), impp)
        }
        XCTAssertNil(ForwardContactDataCodec.decode(try reference(name: "   ")))
        XCTAssertNil(ForwardContactDataCodec.decode(try reference(extra: "<impp><uri>xmpp:other@example.com</uri></impp>")))
    }

    func testAvatarRejectsDataURIAndCredentialsWithoutDiscardingUsableIdentity() throws {
        for uri in ["data:image/png;base64,AAAA", "file:///tmp/avatar.png", "javascript:alert(1)", "https://user:secret@example.com/avatar.png"] {
            let card = try XCTUnwrap(ForwardContactDataCodec.decode(reference(extra: "<photo><uri>\(uri)</uri></photo>")))
            XCTAssertNil(card.avatarURI, uri)
            XCTAssertEqual(card.jid, "juliet@example.com")
        }
    }

    func testCardsAreScopedToDirectReferencesOfCurrentMessage() throws {
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='romeo@example.com' to='owner@example.com'>
          \(try reference().xmlString)
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='1'>
            <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='other@example.com' to='owner@example.com'>
              \(try reference(impp: "xmpp:other@example.com", name: "Other").xmlString)
            </message></forwarded>
          </reference>
        </message>
        """)

        XCTAssertEqual(ForwardContactDataCodec.cards(in: message).map(\.jid), ["juliet@example.com"])
    }

    func testIdenticalCardsDeduplicateWhileConflictingCardsFallBackForThatJID() throws {
        let message = XMPPMessage(type: "chat")
        message.addChild(try reference())
        message.addChild(try reference())
        message.addChild(try reference(impp: "xmpp:other@example.com", name: "Other"))
        XCTAssertEqual(ForwardContactDataCodec.cards(in: message).map(\.jid), ["juliet@example.com", "other@example.com"])

        message.addChild(try reference(name: "Impersonated Juliet"))

        XCTAssertEqual(ForwardContactDataCodec.cards(in: message).map(\.jid), ["other@example.com"])
    }

    func testMetadataRoundTripUsesExistingJSONStorageAndSeparateKind() throws {
        let card = try XCTUnwrap(ForwardContactDataCodec.decode(reference(kind: "incognito")))
        let storage = MessageReferenceStorageItem()
        storage.kind = .forwardContactData
        storage.metadata = ForwardContactDataCodec.metadata(for: card)

        XCTAssertEqual(storage.kind_.isEmpty, false)
        XCTAssertEqual(storage.kind, .forwardContactData)
        XCTAssertEqual(storage.xmlType, "data")
        XCTAssertEqual(ForwardContactDataCodec.card(from: storage), card)
        XCTAssertEqual(ForwardContactDataCodec.card(from: ForwardContactDataCodec.metadata(for: card)), card)
        XCTAssertFalse(storage.metadata_.isEmpty)
    }

    func testOutgoingProjectionEncodesDataCardWithoutFallbackRangeOrEmptyForwardMarker() throws {
        let card = try XCTUnwrap(ForwardContactDataCodec.decode(reference()))
        let data = MessageReferenceStorageItem()
        data.kind = .forwardContactData
        data.metadata = ForwardContactDataCodec.metadata(for: card)
        let forwardMarker = MessageReferenceStorageItem()
        forwardMarker.kind = .forward
        let message = MessageStorageItem()
        message.references.append(objectsIn: [data, forwardMarker])

        let encoded = message.createReferences()

        XCTAssertEqual(encoded.count, 1)
        XCTAssertEqual(ForwardContactDataCodec.decode(try XCTUnwrap(encoded.first)), card)
        XCTAssertNil(encoded.first?.attribute(forName: "begin"))
        XCTAssertNil(encoded.first?.attribute(forName: "end"))
    }

    func testMatchingCardUsesBareAddressAndRejectsConflictingStoredSnapshots() throws {
        func stored(_ card: ForwardContactCard) -> MessageReferenceStorageItem {
            let reference = MessageReferenceStorageItem()
            reference.kind = .forwardContactData
            reference.metadata = ForwardContactDataCodec.metadata(for: card)
            return reference
        }
        let card = try XCTUnwrap(ForwardContactDataCodec.decode(reference()))
        let duplicate = stored(card)
        let conflict = try XCTUnwrap(ForwardContactDataCodec.decode(reference(name: "Different")))

        XCTAssertEqual(ForwardContactDataCodec.matchingCard(for: "juliet@example.com/phone", references: [duplicate, stored(card)]), card)
        XCTAssertNil(ForwardContactDataCodec.matchingCard(for: "other@example.com", references: [duplicate]))
        XCTAssertNil(ForwardContactDataCodec.matchingCard(for: card.jid, references: [duplicate, stored(conflict)]))
        XCTAssertEqual(ForwardContactDataCodec.matchingCard(for: "juliet@example.com/phone", cards: [card]), card)
    }

    private func reference(
        kind: String = "individual", impp: String = "xmpp:juliet@example.com",
        name: String = "Juliet", extra: String = ""
    ) throws -> DDXMLElement {
        try DDXMLElement(xmlString: """
        <reference xmlns='https://xabber.com/protocol/references' type='data'>
          <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
            <fn><text>\(name)</text></fn><kind><text>\(kind)</text></kind>
            <impp><uri>\(impp)</uri></impp>\(extra)
          </vcard>
        </reference>
        """)
    }
}
