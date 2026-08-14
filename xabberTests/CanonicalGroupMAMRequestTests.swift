import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

private final class CanonicalGroupMAMCapturingStream: XMPPStream {
    private(set) var sentElements: [DDXMLElement] = []

    override func send(_ element: DDXMLElement) {
        sentElements.append(element)
    }
}

final class CanonicalGroupMAMRequestTests: XCTestCase {
    private let owner = "owner@example.com"
    private var previousRealmConfiguration: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "CanonicalGroupMAMRequestTests-\(name)-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testCanonicalGroupHistoryTargetsBareGroupJIDDirectly() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = CanonicalGroupMAMCapturingStream()
        let groupJID = try XCTUnwrap(XMPPJID(string: "Stage@Example.COM/Group"))

        let queryID = manager.requestCanonicalGroupHistory(
            stream,
            groupJID: groupJID,
            queryId: "canonical-group-history"
        )

        let iq = XMPPIQ(from: try XCTUnwrap(stream.sentElements.first))
        XCTAssertEqual(queryID, "canonical-group-history")
        XCTAssertEqual(iq.to?.bare, "stage@example.com")
        XCTAssertNil(iq.to?.resource)
        XCTAssertEqual(iq.type, "set")
    }

    func testCanonicalGroupHistoryOmitsAccountArchiveFilters() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        manager.isExtendedArchiveAvailable = true
        let stream = CanonicalGroupMAMCapturingStream()

        manager.requestCanonicalGroupHistory(
            stream,
            groupJID: try XCTUnwrap(XMPPJID(string: "stage@example.com")),
            queryId: "canonical-group-history-filters"
        )

        let iq = XMPPIQ(from: try XCTUnwrap(stream.sentElements.first))
        XCTAssertEqual(dataFormFieldValues(in: iq, named: "with"), [])
        XCTAssertEqual(dataFormFieldValues(in: iq, named: "conversation-type"), [])
    }

    func testCanonicalGroupHistoryUsesNewestAuthoritativeBootstrapPage() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = CanonicalGroupMAMCapturingStream()

        manager.requestCanonicalGroupHistory(
            stream,
            groupJID: try XCTUnwrap(XMPPJID(string: "stage@example.com")),
            queryId: "canonical-group-history-bootstrap",
            pageSize: 25
        )

        let iq = XMPPIQ(from: try XCTUnwrap(stream.sentElements.first))
        let query = try XCTUnwrap(iq.element(forName: "query"))
        let rsm = try XCTUnwrap(query.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm"))
        XCTAssertEqual(rsm.element(forName: "max")?.stringValue, "25")
        XCTAssertNotNil(rsm.element(forName: "before"))
        XCTAssertEqual(dataFormFieldValues(in: iq, named: "rsm-counter"), ["1"])

        let task = try XCTUnwrap(
            manager.callbacksQueue.first(where: { $0.elementId == "canonical-group-history-bootstrap" })?.task
        )
        XCTAssertEqual(task.conversationType, .group)
        XCTAssertEqual(task.purpose, .bootstrap)
    }

    private func dataFormFieldValues(in iq: XMPPIQ, named name: String) -> [String] {
        guard let field = iq
            .element(forName: "query")?
            .element(forName: "x")?
            .elements(forName: "field")
            .first(where: { $0.attributeStringValue(forName: "var") == name }) else {
            return []
        }

        return field
            .elements(forName: "value")
            .compactMap(\.stringValue)
    }
}
