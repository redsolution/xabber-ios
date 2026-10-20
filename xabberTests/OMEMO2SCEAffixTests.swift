import Foundation
import XCTest
import XMPPFramework
@testable import xabber

/// OM2-04 validates protected routing/time and measures the whole UTF-8 envelope.
/// These fixtures have an authentic payload MAC; malformed XML is not MAC damage.
final class OMEMO2SCEAffixTests: XCTestCase {
    private let namespace = "urn:xmpp:sce:1"
    private let alice = "alice@example.test"
    private let bob = "bob@example.test"
    private let historicTime = Date(timeIntervalSince1970: 1_074_988_500)

    func testHistoricalOriginalTimeDoesNotUseCurrentReceiptTime() throws {
        let original = OMEMOOriginalSendingTime(date: historicTime, source: .forwardedDelay)
        let opened = try open(affixes: bindingAffixes + timeAffix(historicTime), original: original)

        XCTAssertEqual(opened.timeValidation, .verified(original))
    }

    func testTimeSkewAtBothFiveMinuteBoundariesIsAccepted() throws {
        for offset in [-300.0, 300.0] {
            let original = OMEMOOriginalSendingTime(date: historicTime, source: .xabberDelivery)
            let opened = try open(affixes: timeAffix(historicTime.addingTimeInterval(offset)), original: original)

            XCTAssertEqual(opened.timeValidation, .verified(original), "offset \(offset)")
        }
    }

    func testTimeSkewBeyondEitherBoundaryIsRejected() throws {
        for offset in [-301.0, 301.0] {
            let original = OMEMOOriginalSendingTime(date: historicTime, source: .stanzaDelay)
            XCTAssertThrowsError(try open(affixes: timeAffix(historicTime.addingTimeInterval(offset)), original: original), "offset \(offset)")
        }
    }

    func testFractionalTimeSkewIsMeasuredWithoutRounding() throws {
        let original = OMEMOOriginalSendingTime(date: historicTime, source: .caller)
        let boundary = timeAffix(historicTime.addingTimeInterval(300), fractional: true)
        XCTAssertEqual(try open(affixes: boundary, original: original).timeValidation, .verified(original))
        let excessive = timeAffix(historicTime.addingTimeInterval(300.001), fractional: true)
        XCTAssertThrowsError(try open(affixes: excessive, original: original))
    }

    func testProtectedTimeWithNoOriginalTimeIsExplicitlyUnavailable() throws {
        let opened = try open(affixes: bindingAffixes + timeAffix(historicTime))

        XCTAssertEqual(opened.timeValidation, .unavailable)
    }

    func testMissingOptionalProtectedTimeIsExplicitlyAbsent() throws {
        let original = OMEMOOriginalSendingTime(date: historicTime, source: .caller)
        let opened = try open(affixes: bindingAffixes, original: original)

        XCTAssertEqual(opened.timeValidation, .absent)
    }

    func testTimeSourceIsPreservedInSuccessfulValidation() throws {
        for source in [OMEMOOriginalSendingTime.Source.xabberDelivery, .forwardedDelay, .stanzaDelay, .caller] {
            let original = OMEMOOriginalSendingTime(date: historicTime, source: source)
            XCTAssertEqual(try open(affixes: timeAffix(historicTime), original: original).timeValidation, .verified(original))
        }
    }

    func testMalformedTimeIsRejectedEvenWithoutTransportTimestamp() throws {
        for stamp in ["not-a-date", "2004-01-25", "", "2004-01-25T06:05:00",
                      "2004-02-30T06:05:00Z", "2004-01-25T25:05:00Z", "2004-01-25T06:05:00+99:99"] {
            XCTAssertThrowsError(try open(affixes: "<time stamp='\(stamp)'/>"), stamp)
        }
    }

    func testEquivalentExplicitTimezoneComparesWithTheSameOriginalInstant() throws {
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        let original = OMEMOOriginalSendingTime(date: date, source: .caller)
        let opened = try open(affixes: "<time stamp='2004-01-25T11:05:00+05:00'/>", original: original)

        XCTAssertEqual(opened.timeValidation, .verified(original))
    }

    func testDuplicateProtectedAffixesAreRejected() throws {
        for affix in ["<from jid='\(alice)'/>", "<to jid='\(bob)'/>", timeAffix(historicTime)] {
            XCTAssertThrowsError(try open(affixes: affix + affix), affix)
        }
    }

    func testAffixesRequireTheirUnqualifiedAttributes() throws {
        for affix in ["<from/>", "<to/>", "<time/>",
                      "<from xmlns:f='urn:foreign' f:jid='\(alice)'/>",
                      "<time xmlns:f='urn:foreign' f:stamp='2004-01-25T06:05:00Z'/>"] {
            XCTAssertThrowsError(try open(affixes: affix), affix)
        }
    }

    func testAffixesCannotCarryNestedElementsOrNonWhitespaceText() throws {
        for affix in ["<from jid='\(alice)'><to jid='\(bob)'/></from>",
                      "<to jid='\(bob)'>ambiguous</to>",
                      "<time stamp='2004-01-25T06:05:00Z'><time stamp='2004-01-25T06:05:00Z'/></time>",
                      "<time stamp='2004-01-25T06:05:00Z'>ambiguous</time>"] {
            XCTAssertThrowsError(try open(affixes: affix), affix)
        }
    }

    func testResourceQualifiedExpectedRoutesCompareWithProtectedBareJIDs() throws {
        let opened = try open(affixes: bindingAffixes, expectedFrom: alice + "/ios", expectedTo: bob + "/phone")

        XCTAssertEqual(opened.timeValidation, .absent)
    }

    func testProtectedJIDsMustBeCanonicalBareRoutes() throws {
        for affix in ["<from jid='\(alice)/device'/>", "<to jid='\(bob)/phone'/>",
                      "<from jid=' ALICE@example.test '/>", "<to jid='invalid jid'/>"] {
            XCTAssertThrowsError(try open(affixes: affix), affix)
        }
    }

    func testProtectedRoutingMismatchCannotBecomeVerified() throws {
        XCTAssertThrowsError(try open(affixes: bindingAffixes, expectedFrom: "mallory@example.test"))
        XCTAssertThrowsError(try open(affixes: bindingAffixes, expectedTo: "mallory@example.test"))
    }

    func testPrefixedAffixesHaveTheSameExpandedQNameMeaning() throws {
        let original = OMEMOOriginalSendingTime(date: historicTime, source: .caller)
        let affixes = "<s:from xmlns:s='\(namespace)' jid='\(alice)'/><s:to xmlns:s='\(namespace)' jid='\(bob)'/>" + timeAffix(historicTime, prefix: "s:")
        let opened = try open(affixes: affixes, original: original)

        XCTAssertEqual(opened.timeValidation, .verified(original))
    }

    func testForeignNameAffixesCannotAssertProtectedBindings() throws {
        let foreign = "<from xmlns='urn:foreign' jid='mallory@example.test'/><to xmlns='urn:foreign' jid='mallory@example.test'/><time xmlns='urn:foreign' stamp='not-a-date'/>"
        let opened = try open(affixes: bindingAffixes + foreign)

        XCTAssertEqual(opened.timeValidation, .absent)
    }

    func testGroupRecipientRequiresExactlyOneQualifiedMatchingTo() throws {
        let room = "room@conference.example.test"
        XCTAssertThrowsError(try open(affixes: "<to xmlns='urn:foreign' jid='\(room)'/>", expectedTo: room, requireTo: true))
        XCTAssertThrowsError(try open(affixes: "<to jid='\(bob)'/>", expectedTo: room, requireTo: true))
        let opened = try open(affixes: "<to jid='\(room)'/>", expectedTo: room, requireTo: true)
        XCTAssertEqual(opened.timeValidation, .absent)
    }

    func testLongIncomingPaddingIsAcceptedWithoutAnOutgoingLengthCap() throws {
        let xml = envelope(affixes: bindingAffixes, padding: String(repeating: "x", count: 4_096))
        let sealed = try Omemo2PayloadCodec.seal(xml)
        let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(sealed.ciphertext, keyAndMAC: sealed.keyAndMAC, expectedFrom: alice, expectedTo: bob))

        XCTAssertEqual(qualified(opened.envelope, "rpad").first?.stringValue?.count, 4_096)
    }

    func testPaddingMeasuresCompleteSerializedEnvelopeWithZeroExtra() throws {
        let xml = try DDXMLElement(xmlString: envelope(affixes: bindingAffixes, padding: ""))
        try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 0, randomBytes: deterministicRandom)

        XCTAssertEqual(try XCTUnwrap(xml.compactXMLString).utf8.count, Omemo2PayloadCodec.minimumEnvelopeByteCount)
        XCTAssertEqual(qualified(xml, "rpad").count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(qualified(xml, "rpad").first?.stringValue).count, 0)
    }

    func testPaddingAddsEntireAllowedTwoHundredByteExtra() throws {
        let xml = try DDXMLElement(xmlString: envelope(affixes: bindingAffixes, padding: ""))
        try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 200, randomBytes: deterministicRandom)

        XCTAssertEqual(try XCTUnwrap(xml.compactXMLString).utf8.count, Omemo2PayloadCodec.minimumEnvelopeByteCount + 200)
    }

    func testPaddingCountsUTF8BytesForMultibyteBody() throws {
        let xml = try DDXMLElement(xmlString: envelope(affixes: bindingAffixes, padding: "", body: String(repeating: "🌐ж", count: 20)))
        try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 0, randomBytes: deterministicRandom)

        XCTAssertEqual(try XCTUnwrap(xml.compactXMLString).utf8.count, 512)
        XCTAssertLessThan(try XCTUnwrap(xml.compactXMLString).count, try XCTUnwrap(xml.compactXMLString).utf8.count)
    }

    func testLargeContentDoesNotNeedMinimumPaddingOrLoseContent() throws {
        let text = String(repeating: "plain & <text> 🌐", count: 100)
        let body = DDXMLElement(name: "body", xmlns: "jabber:client")
        body.stringValue = text
        let xml = try DDXMLElement(xmlString: "<envelope xmlns='\(namespace)'><content>\(body.xmlString)</content><rpad/></envelope>")
        let before = try XCTUnwrap(xml.compactXMLString).utf8.count
        try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 0, randomBytes: deterministicRandom)

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(xml.compactXMLString).utf8.count, before)
        XCTAssertEqual(qualified(xml, "content").first?.element(forName: "body", xmlns: "jabber:client")?.stringValue, text)
        XCTAssertEqual(qualified(xml, "rpad").first?.stringValue ?? "", "")
    }

    func testPaddingRandomBytesAreXMLSafeASCII() throws {
        let xml = try DDXMLElement(xmlString: envelope(affixes: "", padding: ""))
        try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 200, randomBytes: { count in Data((0..<count).map { UInt8($0 % 256) }) })
        let padding = try XCTUnwrap(qualified(xml, "rpad").first?.stringValue)

        XCTAssertTrue(padding.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e && ![0x26, 0x3c, 0x3e, 0x22, 0x27].contains($0) })
        XCTAssertEqual(padding.count, padding.utf8.count)
        XCTAssertNoThrow(try DDXMLDocument(xmlString: XCTUnwrap(xml.compactXMLString), options: 0))
    }

    func testPaddingRejectsRandomFailureAndWrongByteCount() throws {
        let xml = try DDXMLElement(xmlString: envelope(affixes: "", padding: ""))
        XCTAssertThrowsError(try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 1, randomBytes: { _ in throw OmemoManagerError.encryptionFailed }))
        XCTAssertThrowsError(try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: 1, randomBytes: { _ in Data() }))
    }

    func testPaddingRejectsExtraOutsideTheSpecifiedRange() throws {
        for extra in [-1, 201] {
            let xml = try DDXMLElement(xmlString: envelope(affixes: "", padding: ""))
            XCTAssertThrowsError(try Omemo2PayloadCodec.applyPadding(to: xml, extraLength: extra, randomBytes: deterministicRandom))
        }
    }

    func testBuilderUsesActualEncryptionTimeAndProducesMinimumEnvelope() throws {
        let manager = OmemoManager(withOwner: alice)
        let before = Date()
        let serialized = try XCTUnwrap(manager.prepareStanzaContent(message: "hello", date: historicTime, jid: bob,
                                      additionalContent: [], ignoreTimeSignature: true))
        let after = Date()
        let xml = try DDXMLElement(xmlString: serialized)
        let stamp = try XCTUnwrap(qualified(xml, "time").first?.attributeStringValue(forName: "stamp"))
        let date = try XCTUnwrap(timestamp(stamp))

        XCTAssertGreaterThanOrEqual(date.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(date.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
        XCTAssertGreaterThanOrEqual(serialized.utf8.count, 512)
        XCTAssertLessThanOrEqual(serialized.utf8.count, 712)
        XCTAssertEqual(qualified(xml, "from").first?.attributeStringValue(forName: "jid"), alice)
        XCTAssertEqual(qualified(xml, "to").first?.attributeStringValue(forName: "jid"), bob)
    }

    func testPresentRoutingAffixRequiresAvailableExpectedRoute() throws {
        let packet = try Omemo2PayloadCodec.seal(envelope(affixes: bindingAffixes))
        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                expectedFrom: nil, expectedTo: bob))
        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                expectedFrom: alice, expectedTo: nil))
        XCTAssertThrowsError(try Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                expectedFrom: "not a jid", expectedTo: bob))
    }

    func testMissingOptionalRoutesRemainAllowedWithoutExpectedBindings() throws {
        let packet = try Omemo2PayloadCodec.seal(envelope(affixes: ""))
        let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                  expectedFrom: nil, expectedTo: nil))
        XCTAssertEqual(opened.timeValidation, .absent)
    }

    func testFinalOutgoingWriterRefreshesStaleProtectedTimeAndPadding() throws {
        let before = Date()
        let prepared = try Omemo2PayloadCodec.prepareOutgoingXML(envelope(affixes: bindingAffixes + timeAffix(historicTime)))
        let after = Date()
        let xml = try DDXMLElement(xmlString: prepared)
        let stamp = try XCTUnwrap(qualified(xml, "time").first?.attributeStringValue(forName: "stamp"))
        let date = try XCTUnwrap(timestamp(stamp))

        XCTAssertEqual(qualified(xml, "time").count, 1)
        XCTAssertGreaterThanOrEqual(date.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(date.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
        XCTAssertGreaterThanOrEqual(prepared.utf8.count, 512)
    }

    func testFinalOutgoingWriterAddsMissingTimeWithoutChangingProtectedContent() throws {
        let prepared = try Omemo2PayloadCodec.prepareOutgoingXML(envelope(affixes: bindingAffixes))
        let xml = try DDXMLElement(xmlString: prepared)

        XCTAssertEqual(qualified(xml, "time").count, 1)
        XCTAssertEqual(qualified(xml, "content").first?.element(forName: "body", xmlns: "jabber:client")?.stringValue, "hello")
        XCTAssertEqual(qualified(xml, "from").first?.attributeStringValue(forName: "jid"), alice)
        XCTAssertEqual(qualified(xml, "to").first?.attributeStringValue(forName: "jid"), bob)
    }

    func testOriginalSendingTimeDirectDeliveryRetainsItsSource() throws {
        let message = try incoming("<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>")
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: message), OMEMOOriginalSendingTime(date: date, source: .xabberDelivery))
    }

    func testFederatedDeliverySelectsAccountTimeRegardlessOfElementOrder() throws {
        let sender = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2026-10-19T09:51:22.314988Z'/>"
        let recipient = "<time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2026-10-19T09:51:22.351830Z'/>"
        for metadata in [sender + recipient, recipient + sender] {
            let message = try incoming(metadata)
            for (owner, stamp) in [(alice, "2026-10-19T09:51:22.314988Z"), (bob, "2026-10-19T09:51:22.351830Z")] {
                XCTAssertEqual(try OmemoManager.originalSendingTime(for: message, owner: owner),
                               OMEMOOriginalSendingTime(date: try Omemo2PayloadCodec.timestamp(stamp), source: .xabberDelivery))
            }
        }
    }

    func testFederatedDeliveryRejectsDuplicateAccountAuthority() throws {
        let own = "<time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2004-01-25T06:05:00Z'/>"
        let peer = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:01Z'/>"
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(own + peer + own), owner: bob))
    }

    func testFederatedDeliveryCannotSelectAuthorityWithoutAccountContext() throws {
        let metadata = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:00Z'/><time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2004-01-25T06:05:01Z'/>"
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(metadata)))
    }

    func testFederatedDeliveryDoesNotTreatQualifiedOrResourceByAsAccountAuthority() throws {
        let peer = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:00Z'/>"
        for attribute in ["xmlns:p='urn:foreign' p:by='\(bob)'", "by='\(bob)/phone'"] {
            let metadata = "<time xmlns='https://xabber.com/protocol/delivery' \(attribute) stamp='2004-01-25T06:05:00Z'/>"
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(peer + metadata), owner: bob))
        }
    }

    func testFederatedAccountTimeStillRequiresMatchingArchiveDelay() throws {
        let metadata = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:00Z'/><time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2004-01-25T06:05:01Z'/>"
        for (stamp, accepted) in [("2004-01-25T06:05:01Z", true), ("2004-01-25T06:05:00Z", false)] {
            let message = try transport("mam", inner: metadata, delay: "<delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>")
            if accepted {
                XCTAssertEqual(try OmemoManager.originalSendingTime(for: message, owner: bob)?.date,
                               try Omemo2PayloadCodec.timestamp(stamp))
            } else {
                XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: message, owner: bob))
            }
        }
    }

    func testFederatedDeliveryRejectsMalformedOrAmbiguousAuthorities() throws {
        let own = "<time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2004-01-25T06:05:00Z'/>"
        for other in [
            "<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>",
            "<time xmlns='https://xabber.com/protocol/delivery' by='' stamp='2004-01-25T06:05:00Z'/>",
            "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='bad'/>",
            "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:00Z'><nested/></time>"
        ] {
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(own + other), owner: bob), other)
        }
        let peer = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2004-01-25T06:05:00Z'/>"
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(own + peer + peer), owner: bob))
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(own + peer), owner: "other@example.test"))
    }

    func testDirectQueueDelayDoesNotConflictWithAccountArchiveTime() throws {
        let metadata = "<time xmlns='https://xabber.com/protocol/delivery' by='\(alice)' stamp='2026-10-19T09:58:52.729233Z'/><time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2026-10-19T09:58:52.766391Z'/><delay xmlns='urn:xmpp:delay' from='example.test' stamp='2026-10-19T09:58:52.806892Z'>Resent</delay>"
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: incoming(metadata), owner: bob),
                       OMEMOOriginalSendingTime(date: try Omemo2PayloadCodec.timestamp("2026-10-19T09:58:52.766391Z"), source: .xabberDelivery))
    }

    func testDirectQueueDelayDoesNotOverrideForwardedArchiveTime() throws {
        let message = try transport("mam", inner: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:01Z'/>",
                                    delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: message, owner: bob),
                       OMEMOOriginalSendingTime(date: try Omemo2PayloadCodec.timestamp("2004-01-25T06:05:00Z"), source: .forwardedDelay))
    }

    func testLowerPriorityDirectDelayStillRequiresValidSingletonMetadata() throws {
        let delivery = "<time xmlns='https://xabber.com/protocol/delivery' by='\(bob)' stamp='2004-01-25T06:05:00Z'/>"
        let valid = "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:01Z'/>"
        for delay in [valid + valid, "<delay xmlns='urn:xmpp:delay' stamp='bad'/>",
                      "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:01Z'><nested/></delay>"] {
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(delivery + delay), owner: bob), delay)
        }
    }

    func testOriginalSendingTimeDirectStanzaDelayRetainsItsSource() throws {
        let message = try incoming("<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: message), OMEMOOriginalSendingTime(date: date, source: .stanzaDelay))
    }

    func testOriginalSendingTimeMAMAndBothCarbonsUseNearestForwardedDelay() throws {
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        for kind in ["mam", "sent", "received"] {
            let message = try transport(kind, inner: "", delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
            XCTAssertEqual(try OmemoManager.originalSendingTime(for: message, owner: bob), OMEMOOriginalSendingTime(date: date, source: .forwardedDelay), kind)
        }
    }

    func testOriginalSendingTimeDeliveryPriorityPreservesMatchingDelay() throws {
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        let message = try transport("mam", inner: "<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>",
                                    delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: message, owner: bob), OMEMOOriginalSendingTime(date: date, source: .xabberDelivery))
    }

    func testOriginalSendingTimeForeignAndOutsideWrapperMetadataCannotReplaceLeafTime() throws {
        let message = try transport("mam", inner: "<time xmlns='urn:foreign' stamp='2004-01-25T06:05:00Z'/><delay xmlns='urn:foreign' stamp='2004-01-25T06:05:00Z'/>", delay: "")
        message.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>"))
        message.addChild(try DDXMLElement(xmlString: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>"))
        XCTAssertNil(try OmemoManager.originalSendingTime(for: message, owner: bob))
    }

    func testOriginalSendingTimeDuplicateKnownMetadataIsRejected() throws {
        for metadata in ["<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>",
                         "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>"] {
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(metadata + metadata)), metadata)
        }
        let delay = "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>"
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: transport("mam", inner: "", delay: delay + delay)))
    }

    func testOriginalSendingTimeMalformedKnownMetadataIsRejected() throws {
        for metadata in ["<time xmlns='https://xabber.com/protocol/delivery'/>",
                         "<time xmlns='https://xabber.com/protocol/delivery' stamp='not-a-date'/>",
                         "<delay xmlns='urn:xmpp:delay' stamp='not-a-date'/>",
                         "<delay xmlns='urn:xmpp:delay'/>"] {
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(metadata)), metadata)
        }
    }

    func testOriginalSendingTimeRequiresUnqualifiedStampAttribute() throws {
        for nameAndNamespace in [("time", "https://xabber.com/protocol/delivery"), ("delay", "urn:xmpp:delay")] {
            let metadata = "<\(nameAndNamespace.0) xmlns='\(nameAndNamespace.1)' xmlns:p='urn:foreign' p:stamp='2004-01-25T06:05:00Z'/>"
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(metadata)))
        }
    }

    func testOriginalSendingTimeKnownSourcesCannotCarryNestedElements() throws {
        for nameAndNamespace in [("time", "https://xabber.com/protocol/delivery"), ("delay", "urn:xmpp:delay")] {
            let metadata = "<\(nameAndNamespace.0) xmlns='\(nameAndNamespace.1)' stamp='2004-01-25T06:05:00Z'><injected xmlns='urn:foreign'/></\(nameAndNamespace.0)>"
            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming(metadata)))
        }
    }

    func testOriginalSendingTimeForwardedDelayKeepsMicrosecondPrecision() throws {
        let message = try transport("mam", inner: "", delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00.123456Z'/>")
        let original = try XCTUnwrap(OmemoManager.originalSendingTime(for: message, owner: bob))
        let expected = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z")).addingTimeInterval(0.123456)

        XCTAssertEqual(original.source, .forwardedDelay)
        XCTAssertEqual(original.date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testProtectedTimeKeepsMicrosecondsAtTheClockSkewBoundary() throws {
        let original = OMEMOOriginalSendingTime(date: historicTime.addingTimeInterval(0.123456), source: .forwardedDelay)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: historicTime.addingTimeInterval(300)).replacingOccurrences(of: "Z", with: "")

        XCTAssertEqual(try open(affixes: "<time stamp='\(base).123456Z'/>", original: original).timeValidation, .verified(original))
        XCTAssertThrowsError(try open(affixes: "<time stamp='\(base).123457Z'/>", original: original))
    }

    func testOriginalSendingTimeConflictingKnownSourcesAreRejected() throws {
        let message = try transport("mam", inner: "<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>",
                                    delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:10:01Z'/>")
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: message, owner: bob))
    }

    func testOriginalSendingTimeSourcesMustDescribeTheSameInstantNotMerelyTheSkewWindow() throws {
        let message = try transport("mam", inner: "<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>",
                                    delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:01Z'/>")
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: message, owner: bob))
    }

    func testOriginalSendingTimeMissingMetadataDoesNotUseCurrentClock() throws {
        XCTAssertNil(try OmemoManager.originalSendingTime(for: incoming("")))
    }

    func testOriginalSendingTimeExplicitCallerIsPreservedAndCannotHideConflict() throws {
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        let supplied = OMEMOOriginalSendingTime(date: date, source: .caller)
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: incoming(""), supplied: supplied), supplied)
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: incoming("<time xmlns='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:10:01Z'/>"), supplied: supplied))
    }

    func testOriginalSendingTimePrefixedQNameIsAccepted() throws {
        let message = try incoming("<d:time xmlns:d='https://xabber.com/protocol/delivery' stamp='2004-01-25T06:05:00Z'/>")
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        XCTAssertEqual(try OmemoManager.originalSendingTime(for: message), OMEMOOriginalSendingTime(date: date, source: .xabberDelivery))
    }

    func testOriginalSendingTimeAmbiguousWrapperDoesNotSelectOneMessage() throws {
        let inner = try incoming("<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>").xmlString
        let xml = "<message xmlns='jabber:client'><result xmlns='urn:xmpp:mam:2'><forwarded xmlns='urn:xmpp:forward:0'>\(inner)\(inner)</forwarded></result></message>"
        let message = XMPPMessage(from: try DDXMLElement(xmlString: xml))
        XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: message))
    }

    func testTrustSharingOriginalTimeRetainsRawXENForwardedDelay() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let message = try trustNotification(delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00.123456Z'/>")
        message.addChild(try DDXMLElement(xmlString: "<delay xmlns='urn:xmpp:delay' stamp='2026-10-02T10:00:00Z'/>"))
        let source = try XCTUnwrap(manager.originalSendingTime(for: message))
        let expected = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z")).addingTimeInterval(0.123456)

        XCTAssertEqual(source.source, .forwardedDelay)
        XCTAssertEqual(source.date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testTrustSharingOriginalTimeRejectsMalformedOrDuplicateRawXENDelay() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let delay = "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>"
        XCTAssertThrowsError(try manager.originalSendingTime(for: trustNotification(delay: delay + delay)))
        XCTAssertThrowsError(try manager.originalSendingTime(for: trustNotification(delay: "<delay xmlns='urn:xmpp:delay' stamp='not-a-date'/>")))
    }

    func testTrustSharingOriginalTimeDoesNotUseForeignRawXENDelay() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let message = try trustNotification(delay: "<delay xmlns='urn:foreign' stamp='2004-01-25T06:05:00Z'/>")
        XCTAssertNil(try manager.originalSendingTime(for: message))
    }

    func testTrustSharingOriginalTimeRetainsMAMAndCarbonWrappersBeforeUnwrapping() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        for kind in ["mam", "sent", "received"] {
            let message = try transport(kind, inner: "<encrypted xmlns='urn:xmpp:omemo:2'/>", delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
            XCTAssertEqual(try manager.originalSendingTime(for: message), OMEMOOriginalSendingTime(date: date, source: .forwardedDelay))
        }
    }

    func testTrustSharingOpaqueAdapterUsesOriginalXENTimeForAuthenticPayload() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        let packet = try Omemo2PayloadCodec.seal("<envelope xmlns='\(namespace)'><content><share xmlns='\(TrustSharingSignature.xmlns)'/></content><rpad/><from jid='\(alice)'/><to jid='\(bob)'/><time stamp='2004-01-25T06:05:00Z'/></envelope>")
        let message = try trustNotification(delay: "<delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>")
        var decryptCount = 0
        var validation: Omemo2PayloadCodec.SCETimeValidation?
        var publisher: String?

        let handled = manager.receiveListOfContactsDevices(message: message, encryption: .plaintext,
            decryptMessage: { leaf in
                decryptCount += 1
                XCTAssertEqual(leaf.from?.bare, self.alice)
                let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                                   expectedFrom: leaf.from?.bare, expectedTo: leaf.to?.bare,
                                   originalSendingTime: manager.originalSendingTime(for: message)))
                validation = opened.timeValidation
                return opened.envelope
            }, applyShare: { share, author in
                XCTAssertEqual(share.uri, TrustSharingSignature.xmlns)
                publisher = author
                return true
            })

        XCTAssertTrue(handled)
        XCTAssertEqual(decryptCount, 1)
        XCTAssertEqual(validation, .verified(OMEMOOriginalSendingTime(date: date, source: .forwardedDelay)))
        XCTAssertEqual(publisher, alice)
    }

    func testTrustSharingRawXENForeignFirstMessageCannotChangeDecryptLeafOrTime() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let genuine = try incoming("<encrypted xmlns='urn:xmpp:omemo:2'/>")
        let wire = "<message xmlns='jabber:client' from='server.example.test' to='\(bob)'><notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/><message xmlns='urn:foreign' from='mallory@example.test' to='\(bob)'><encrypted xmlns='urn:xmpp:omemo:2'/></message>\(genuine.xmlString)</forwarded></notification></message>"
        let message = XMPPMessage(from: try DDXMLElement(xmlString: wire))
        var decryptCount = 0
        var selectedSender: String?
        var selectedTime: OMEMOOriginalSendingTime?
        let decrypted = try DDXMLElement(xmlString: "<envelope xmlns='\(namespace)'><content><share xmlns='\(TrustSharingSignature.xmlns)'/></content><from jid='\(alice)'/></envelope>")

        let handled = manager.receiveListOfContactsDevices(message: message, encryption: .plaintext,
            decryptMessage: { leaf in
                decryptCount += 1
                selectedSender = leaf.from?.bare
                selectedTime = try manager.originalSendingTime(for: message)
                return decrypted
            }, applyShare: { _, _ in true })

        XCTAssertTrue(handled)
        XCTAssertEqual(decryptCount, 1)
        XCTAssertEqual(selectedSender, alice)
        let date = try XCTUnwrap(timestamp("2004-01-25T06:05:00Z"))
        XCTAssertEqual(selectedTime, OMEMOOriginalSendingTime(date: date, source: .forwardedDelay))
    }

    func testTrustSharingRawXENDuplicateQualifiedMessagesCannotReachDecrypt() throws {
        let manager = TrustSharingManager(withOwner: bob)
        let genuine = try incoming("<encrypted xmlns='urn:xmpp:omemo:2'/>")
        let message = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='server.example.test' to='\(bob)'><notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2004-01-25T06:05:00Z'/>\(genuine.xmlString)\(genuine.xmlString)</forwarded></notification></message>"))
        var decryptCount = 0
        var applyCount = 0

        _ = manager.receiveListOfContactsDevices(message: message, encryption: .plaintext,
            decryptMessage: { _ in decryptCount += 1; return nil },
            applyShare: { _, _ in applyCount += 1; return true })

        XCTAssertEqual(decryptCount, 0)
        XCTAssertEqual(applyCount, 0)
        XCTAssertThrowsError(try manager.originalSendingTime(for: message))
    }

    private func trustNotification(delay: String) throws -> XMPPMessage {
        let leaf = try incoming("<encrypted xmlns='urn:xmpp:omemo:2'/>")
        return XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='server.example.test' to='\(bob)'><notification xmlns='urn:xabber:xen:0'><forwarded xmlns='urn:xmpp:forward:0'>\(delay)\(leaf.xmlString)</forwarded></notification></message>"))
    }

    private func incoming(_ metadata: String) throws -> XMPPMessage {
        XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(alice)/ios' to='\(bob)' type='chat'>\(metadata)</message>"))
    }

    private func transport(_ kind: String, inner: String, delay: String) throws -> XMPPMessage {
        let leaf = try incoming(inner)
        let wrapper = kind == "mam" ? "result xmlns='urn:xmpp:mam:2' id='archive-id' queryid='query-id'" : "\(kind) xmlns='urn:xmpp:carbons:2'"
        let name = kind == "mam" ? "result" : kind
        return XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(bob)' to='\(bob)'><\(wrapper)><forwarded xmlns='urn:xmpp:forward:0'>\(delay)\(leaf.xmlString)</forwarded></\(name)></message>"))
    }

    private var bindingAffixes: String { "<from jid='\(alice)'/><to jid='\(bob)'/>" }

    private func envelope(affixes: String, padding: String = "pad", body: String = "hello") -> String {
        "<envelope xmlns='\(namespace)'><content><body xmlns='jabber:client'>\(body)</body></content><rpad>\(padding)</rpad>\(affixes)</envelope>"
    }

    private func open(affixes: String, original: OMEMOOriginalSendingTime? = nil,
                      expectedFrom: String? = nil, expectedTo: String? = nil, requireTo: Bool = false) throws -> Omemo2PayloadCodec.OpenedPayload {
        let packet = try Omemo2PayloadCodec.seal(envelope(affixes: affixes), randomBytes: deterministicRandom)
        let opened = try Omemo2PayloadCodec.openVerified(packet.ciphertext, keyAndMAC: packet.keyAndMAC,
                        expectedFrom: expectedFrom ?? alice, expectedTo: expectedTo ?? bob,
                        requireTo: requireTo, originalSendingTime: original)
        return try XCTUnwrap(opened)
    }

    private func qualified(_ xml: DDXMLElement, _ name: String) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: xml, named: name, xmlns: namespace)
    }

    private func deterministicRandom(_ count: Int) -> Data { Data(repeating: 42, count: count) }

    private func timeAffix(_ date: Date, fractional: Bool = false, prefix: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        let ns = prefix.isEmpty ? "" : " xmlns:s='\(namespace)'"
        return "<\(prefix)time\(ns) stamp='\(formatter.string(from: date))'/>"
    }

    private func timestamp(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: stamp) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }
}
