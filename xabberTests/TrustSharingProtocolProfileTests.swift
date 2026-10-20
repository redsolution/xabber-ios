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

    func testResourceEmptyAndDelimiterOwnersAreRejected() throws {
        for owner in ["", "user@example.test/resource", "user|other@example.test", " user@example.test"] {
            let items = try list("<trust-list xmlns='\(xmlns)' timestamp='100'/>")
            items.addAttribute(withName: "owner", stringValue: owner)
            XCTAssertNil(TrustSharingSignature.canonicalString(for: [items]), owner)
        }
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

    private func list(_ xml: String) throws -> DDXMLElement { try DDXMLElement(xmlString: xml) }
}
