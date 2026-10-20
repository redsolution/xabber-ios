import XCTest
import XMPPFramework
@testable import xabber

final class TrustSharingProtocolProfileTests: XCTestCase {
    private let xmlns = "urn:xmpp:trustsharing:0"

    func testCurrentKnowledgeBaseCanonicalVectorMatchesWeb() throws {
        let explicit = try list("<trust-list xmlns='\(xmlns)' owner='user1@example.org' timestamp='1709270500'><trust timestamp='1709270490'>T1BRUlNUVQ==</trust></trust-list>")
        let implicit = try list("<trust-list xmlns='\(xmlns)' timestamp='1709270416'><distrust timestamp='1709270416'>SElKS0xNTg==</distrust><trust timestamp='1709270116'>QUJDREVGRw==</trust></trust-list>")

        XCTAssertEqual(TrustSharingSignature.canonicalString(for: [explicit, implicit]),
                       "trust-list||1709270416|trust|1709270116|QUJDREVGRw==|distrust|1709270416|SElKS0xNTg==|trust-list|user1@example.org|1709270500|trust|1709270490|T1BRUlNUVQ==")
    }

    func testCanonicalOwnerIsSignedAndOwnerChangesInvalidateSignatureInput() throws {
        let original = try list("<trust-list xmlns='\(xmlns)' owner='one@example.test' timestamp='100'><trust timestamp='90'>QQ==</trust></trust-list>")
        let changed = original.copy() as! DDXMLElement
        changed.addAttribute(withName: "owner", stringValue: "two@example.test")

        XCTAssertNotEqual(TrustSharingSignature.canonicalString(for: [original]),
                          TrustSharingSignature.canonicalString(for: [changed]))
    }

    func testEqualTimestampRecordsSortByTypeThenCanonicalBase64Ascending() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'><trust timestamp='90'>Qg==</trust><trust timestamp='90'>QQ==</trust><distrust timestamp='90'>Qw==</distrust></trust-list>")

        XCTAssertEqual(TrustSharingSignature.canonicalString(for: [items]),
                       "trust-list||100|distrust|90|Qw==|trust|90|QQ==|trust|90|Qg==")
    }

    func testEmptyListContributesSignedOwnerAndTimestamp() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")

        XCTAssertEqual(TrustSharingSignature.canonicalString(for: [items]), "trust-list||100")
    }

    func testOwnersUseNormalizedBareJIDsAndDuplicateCanonicalOwnersAreRejected() throws {
        let first = try list("<trust-list xmlns='\(xmlns)' owner='User@EXAMPLE.TEST' timestamp='100'/>")
        let duplicate = try list("<trust-list xmlns='\(xmlns)' owner='user@example.test' timestamp='200'/>")

        XCTAssertEqual(TrustSharingSignature.canonicalString(for: [first]), "trust-list|user@example.test|100")
        XCTAssertNil(TrustSharingSignature.canonicalString(for: [first, duplicate]))
    }

    func testResourceEmptyAndWhitespaceOwnersAreRejected() throws {
        for owner in ["", "user@example.test/resource", " user@example.test"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: owner)
            XCTAssertNil(TrustSharingSignature.canonicalString(for: [items]), owner)
        }
    }

    func testVerticalBarIsPermittedInLocalpartAndIncludedInTheCanonicalString() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' owner='A|B@EXAMPLE.TEST' timestamp='100'/>")
        XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), "a|b@example.test")
        XCTAssertEqual(TrustSharingSignature.canonicalString(for: [items]), "trust-list|a|b@example.test|100")
    }

    func testNoncanonicalBase64AndUnknownRecordTypesAreRejected() throws {
        for record in ["<trust timestamp='90'>Q Q==</trust>", "<trust timestamp='90'>QR==</trust>",
                       "<revoked timestamp='90'>QQ==</revoked>"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'>\(record)</trust-list>")
            XCTAssertNil(TrustSharingSignature.canonicalString(for: [items]), record)
        }
    }

    func testDuplicateAndConflictingDecodedKeysAreRejected() throws {
        for secondType in ["trust", "distrust"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'><trust timestamp='80'>QQ==</trust><\(secondType) timestamp='90'>QQ==</\(secondType)></trust-list>")
            XCTAssertNil(TrustSharingSignature.canonicalString(for: [items]))
        }
    }

    func testOnlyCurrentTrustListAndNodeAreRecognized() throws {
        let share = try list("<share xmlns='\(xmlns)' protocol='urn:xmpp:omemo:2' timestamp='100'><trusted-items timestamp='100'/><items timestamp='100'/></share>")

        XCTAssertTrue(TrustSharingSignature.trustedItems(from: share).isEmpty)
        XCTAssertEqual(TrustSharingSignature.node, xmlns)
    }

    func testASCIIAndDomainOnlyOwnersUseCanonicalBareJIDs() throws {
        for (raw, expected) in [("ALICE@EXAMPLE.TEST", "alice@example.test"), ("EXAMPLE.TEST", "example.test")] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: raw)
            XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), expected, raw)
        }
    }

    func testIDNDomainALabelAndULabelHaveTheSameCanonicalOwner() throws {
        for raw in ["juliet@xn--bcher-kva.example", "juliet@bücher.example", "juliet@BÜCHER.EXAMPLE"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: raw)
            XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), "juliet@bücher.example", raw)
        }
    }

    func testUnicodeNodeOwnerUsesNFC() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
        items.addAttribute(withName: "owner", stringValue: "cafe\u{0301}@example.test")
        XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), "café@example.test")
    }

    func testFullwidthNodeOwnerUsesWidthAndCaseMapping() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
        items.addAttribute(withName: "owner", stringValue: "ＡＬＩＣＥ@example.test")
        XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), "alice@example.test")
    }

    func testPrecisLowercaseOwnerPreservesSharpSInsteadOfLegacyNameprepFolding() throws {
        let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
        items.addAttribute(withName: "owner", stringValue: "Straße@example.test")
        XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), "straße@example.test")
    }

    func testEquivalentIDNFormsCannotCreateDuplicateCanonicalOwners() throws {
        let ascii = try list("<trust-list xmlns='\(xmlns)' owner='juliet@xn--bcher-kva.example' timestamp='100'/>")
        let unicode = try list("<trust-list xmlns='\(xmlns)' owner='juliet@bücher.example' timestamp='200'/>")
        XCTAssertNil(TrustSharingSignature.canonicalString(for: [ascii, unicode]))
    }

    func testIdentifierClassIsCheckedBeforeCaseMappingAndNFC() throws {
        for raw in ["K@example.test", "\u{1100}\u{1161}@example.test"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: raw)
            XCTAssertNil(TrustSharingSignature.canonicalOwner(for: items), raw)
        }
    }

    func testIDNDomainPermitsTheFourRFC5892PVALIDExceptions() throws {
        for domain in ["\u{06fd}.example", "\u{06fe}.example", "\u{0f0b}.example", "\u{3007}.example"] {
            for owner in [domain, "juliet@" + domain] {
                let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
                items.addAttribute(withName: "owner", stringValue: owner)
                XCTAssertEqual(TrustSharingSignature.canonicalOwner(for: items), owner, owner)
            }
        }
    }

    func testIDNDomainRejectsOldHangulJamoAndDisallowedExceptions() throws {
        let prohibited = ["\u{0640}", "\u{07fa}", "\u{302e}", "\u{302f}", "\u{3031}",
                          "\u{3032}", "\u{3033}", "\u{3034}", "\u{3035}", "\u{303b}"]
        let domains = ["\u{1100}.example", "\u{a960}.example", "\u{d7b0}.example"]
            + prohibited.flatMap { [$0 + ".example", "a" + $0 + ".example"] }
        for domain in domains {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: "juliet@" + domain)
            XCTAssertNil(TrustSharingSignature.canonicalOwner(for: items), domain)
        }
    }

    private func list(_ xml: String) throws -> DDXMLElement { try DDXMLElement(xmlString: xml) }
}
