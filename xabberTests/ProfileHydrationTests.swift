import UIKit
import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class ProfileHydrationTests: XCTestCase {
    private final class Stream: XMPPStream {
        private let lock = NSLock()
        private var sent: [DDXMLElement] = []
        var onSend: ((DDXMLElement) -> Void)?
        override var isAuthenticated: Bool { true }
        override func send(_ element: DDXMLElement) {
            lock.lock()
            sent.append(element.copy() as! DDXMLElement)
            lock.unlock()
            onSend?(element)
        }
        var elements: [DDXMLElement] {
            lock.lock()
            defer { lock.unlock() }
            return sent
        }
    }

    private var originalRealm: Realm.Configuration!
    private var realm: Realm!
    private var account: Account!
    private var stream: Stream!
    private var owner: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ProfileHydration-\(UUID())")
        realm = try WRealm.safe()
        owner = "profile-\(UUID().uuidString.lowercased())@example.com"
        account = Account(jid: owner, queue: DispatchQueue(label: "ProfileHydrationTests.\(UUID())"))
        stream = Stream()
        stream.myJID = XMPPJID(string: owner)
        account.xmppStream = stream
        AccountManager.shared.users.append(account)
        try realm.write {
            let stored = AccountStorageItem()
            stored.jid = owner
            realm.add(stored)
        }
    }

    override func tearDownWithError() throws {
        account.vcards.clearSession()
        account.avatarManager.clearSession()
        account.xmppTaskScheduler.reset()
        account.queue.sync {}
        AccountManager.shared.users.removeAll { $0 === account }
        account = nil
        stream = nil
        realm = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        try super.tearDownWithError()
    }

    func testPreparedStreamQueuesOwnVCardUntilSendReadinessThenPersistsCorrelatedNoFromResult() throws {
        let sent = expectation(description: "own vCard sent after readiness")
        stream.onSend = { element in
            if element.element(forName: "vCard", xmlns: "vcard-temp") != nil { sent.fulfill() }
        }
        account.vcards.onStreamPrepared(stream)
        account.queue.sync {}
        XCTAssertTrue(stream.elements.isEmpty)

        account.sendReadiness.markStreamManagementEnabled()
        wait(for: [sent], timeout: 2)
        let request = try XCTUnwrap(stream.elements.first { $0.element(forName: "vCard", xmlns: "vcard-temp") != nil })
        XCTAssertNil(request.attributeStringValue(forName: "to"))
        XCTAssertTrue(account.vcards.read(withIQ: try iq("""
            <iq type='result' id='\(try XCTUnwrap(request.attributeStringValue(forName: "id")))'>
              <vCard xmlns='vcard-temp'><NICKNAME>Own profile</NICKNAME></vCard>
            </iq>
            """)))
        XCTAssertEqual(realm.object(ofType: vCardStorageItem.self, forPrimaryKey: owner)?.nickname, "Own profile")
    }

    func testPreparedStreamHydratesOwnAndActiveRosterAvatarsWithoutPresenceNotifications() throws {
        let peer = "peer@example.com"
        try addRoster(jid: peer)
        try addRoster(jid: owner)
        try addRoster(jid: "removed@example.com", removed: true)
        let sent = expectation(description: "own and peer metadata sent")
        sent.expectedFulfillmentCount = 2
        stream.onSend = { element in
            if element.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub") != nil { sent.fulfill() }
        }
        account.avatarManager.onStreamPrepared(stream)
        account.queue.sync {}
        XCTAssertTrue(stream.elements.isEmpty)

        account.sendReadiness.markStreamManagementEnabled()
        wait(for: [sent], timeout: 2)
        let requests = stream.elements
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.compactMap { $0.attributeStringValue(forName: "to") }), Set([owner!, peer]))
        XCTAssertTrue(requests.allSatisfy {
            $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == "urn:xmpp:avatar:metadata"
        })
    }

    func testOwnBinaryAvatarDataRunsBeforeQueuedRosterMetadataAfterBootstrap() throws {
        try addRoster(jid: "peer-a@example.com")
        try addRoster(jid: "peer-b@example.com")
        account.syncManager.isAvailable = true
        XCTAssertTrue(account.syncManager.sync(stream))
        XCTAssertTrue(account.syncManager.isInitialListSynchronizationTrafficGateActive())
        let blocked = expectation(description: "avatars wait for initial synchronization")
        blocked.isInverted = true
        let sent = expectation(description: "own metadata, own data and two peer metadata sent")
        sent.expectedFulfillmentCount = 4
        var bootstrapActive = true
        stream.onSend = { [unowned self] element in
            guard let items = element.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?.element(forName: "items") else { return }
            if bootstrapActive { blocked.fulfill() }
            sent.fulfill()
            if items.attributeStringValue(forName: "node") == "urn:xmpp:avatar:metadata",
               element.attributeStringValue(forName: "to") == owner {
                do {
                    let id = try XCTUnwrap(element.attributeStringValue(forName: "id"))
                    let response = try iq("""
                        <iq type='result' id='\(id)'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
                          <items node='urn:xmpp:avatar:metadata'><item id='own-binary-photo'><metadata xmlns='urn:xmpp:avatar:metadata'>
                            <info id='own-binary-photo' type='image/png'/>
                          </metadata></item></items>
                        </pubsub></iq>
                        """)
                    XCTAssertTrue(account.avatarManager.read(withIQ: response))
                } catch { XCTFail("Own metadata response could not be delivered: \(error)") }
            }
        }
        account.avatarManager.onStreamPrepared(stream)
        account.sendReadiness.markStreamManagementEnabled()
        wait(for: [blocked], timeout: 0.05)

        bootstrapActive = false
        account.syncManager.reset()
        wait(for: [sent], timeout: 2)

        let requests = stream.elements.filter { $0.element(forName: "pubsub") != nil }
        XCTAssertEqual(requests.prefix(2).compactMap { $0.attributeStringValue(forName: "to") }, [owner!, owner!])
        XCTAssertEqual(requests.prefix(2).compactMap { $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") }, ["urn:xmpp:avatar:metadata", "urn:xmpp:avatar:data"])
        XCTAssertEqual(requests.last?.attributeStringValue(forName: "to"), "peer-b@example.com")
    }

    func testCorrelatedOwnPEPMetadataResultMayOmitFrom() throws {
        account.avatarManager.requestPubSubItem(stream, node: .metadata, jid: owner, by: "")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        XCTAssertTrue(account.avatarManager.read(withIQ: try iq("""
            <iq type='result' id='\(id)'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
              <items node='urn:xmpp:avatar:metadata'><item id='own-photo'><metadata xmlns='urn:xmpp:avatar:metadata'>
                <info id='own-photo' url='https://example.com/avatar.png' type='image/png'/>
              </metadata></item></items>
            </pubsub></iq>
            """)))
        XCTAssertEqual(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.avatarMaxUrl, "https://example.com/avatar.png")
    }

    func testPEPResponseFromDifferentPublisherCannotReplaceRequestedOwnAvatar() throws {
        account.avatarManager.requestPubSubItem(stream, node: .metadata, jid: owner, by: "")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        try addRoster(jid: "other@example.com")
        XCTAssertFalse(account.avatarManager.read(withIQ: try iq("""
            <iq type='result' id='\(id)' from='other@example.com'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
              <items node='urn:xmpp:avatar:metadata'><item id='wrong-photo'><metadata xmlns='urn:xmpp:avatar:metadata'>
                <info url='https://example.com/wrong.png'/>
              </metadata></item></items>
            </pubsub></iq>
            """)))
        XCTAssertNil(realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: "other@example.com", owner: owner))?.avatarMaxUrl)
        XCTAssertTrue(account.avatarManager.read(withIQ: try metadataResult(id: id, photoID: "right-photo", url: "https://example.com/right.png")))
        XCTAssertEqual(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.avatarMaxUrl, "https://example.com/right.png")
    }

    func testLegacyVCardPhotoPersistsOwnAvatarWithoutFrom() throws {
        XCTAssertTrue(account.avatarManager.readFromVcard(try vcardPhoto(from: nil)))
        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        let key = try XCTUnwrap(stored.oldschoolAvatarKey)
        XCTAssertNotNil(DefaultAvatarManager.shared.cachedAvatarImage(url: key))
    }

    func testLegacyVCardPhotoHydratesContactFallback() throws {
        let peer = "peer@example.com"
        try addRoster(jid: peer)
        XCTAssertTrue(account.avatarManager.readFromVcard(try vcardPhoto(from: peer)))
        let stored = try XCTUnwrap(realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: peer, owner: owner)))
        let key = try XCTUnwrap(stored.oldschoolAvatarKey)
        XCTAssertNotNil(DefaultAvatarManager.shared.cachedAvatarImage(url: key))
    }

    func testLegacyVCardPhotoPreservesExistingPEPURLAndDataAvatar() throws {
        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        try realm.write {
            stored.avatarMaxUrl = "https://example.com/current.png"
            stored.oldschoolAvatarKey = "pep-current"
        }
        XCTAssertTrue(account.avatarManager.readFromVcard(try vcardPhoto(from: owner)))
        XCTAssertEqual(stored.avatarMaxUrl, "https://example.com/current.png")
        XCTAssertEqual(stored.oldschoolAvatarKey, "pep-current")
        try realm.write { stored.avatarMaxUrl = nil }
        XCTAssertTrue(account.avatarManager.readFromVcard(try vcardPhoto(from: owner)))
        XCTAssertEqual(stored.oldschoolAvatarKey, "pep-current")
    }

    func testCorrelatedOwnPEPDataWithoutFromReplacesPriorURL() throws {
        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        try realm.write {
            stored.avatarMaxUrl = "https://example.com/old.png"
            stored.oldschoolAvatarKey = "old-photo"
        }
        account.avatarManager.requestPubSubItem(stream, node: .data, jid: owner, by: "new-photo")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))

        XCTAssertTrue(account.avatarManager.read(withIQ: try pepData(id: id, photoID: "new-photo")))

        XCTAssertNil(stored.avatarMaxUrl)
        XCTAssertEqual(stored.oldschoolAvatarKey, ["new-photo", owner!].prp())
        XCTAssertNotNil(DefaultAvatarManager.shared.cachedAvatarImage(url: stored.oldschoolAvatarKey))
    }

    func testLatePEPDataCannotReplaceNewerMetadataURL() throws {
        account.avatarManager.requestPubSubItem(stream, node: .data, jid: owner, by: "old-photo")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        let metadata = try DDXMLDocument(xmlString: """
            <item id='new-photo'><metadata xmlns='urn:xmpp:avatar:metadata'>
              <info url='https://example.com/new.png'/>
            </metadata></item>
            """, options: 0)
        XCTAssertTrue(account.avatarManager.readFromPubSubMetadata(jid: owner, pubsub: try XCTUnwrap(metadata.rootElement())))

        XCTAssertTrue(account.avatarManager.read(withIQ: try pepData(id: id, photoID: "old-photo")))

        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(stored.avatarMaxUrl, "https://example.com/new.png")
        XCTAssertEqual(stored.oldschoolAvatarKey, "new-photo")
    }

    func testWrongPEPNodeKeepsRequestAvailableForItsMatchingResult() throws {
        account.avatarManager.requestPubSubItem(stream, node: .metadata, jid: owner, by: "")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        XCTAssertFalse(account.avatarManager.read(withIQ: try pepData(id: id, photoID: "wrong-node-photo")))
        XCTAssertTrue(account.avatarManager.read(withIQ: try metadataResult(id: id, photoID: "right-photo", url: "https://example.com/right.png")))
        XCTAssertEqual(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.avatarMaxUrl, "https://example.com/right.png")
    }

    func testMetadataRequestIgnoresUnrequestedDataNodeInSameResult() throws {
        account.avatarManager.requestPubSubItem(stream, node: .metadata, jid: owner, by: "")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        let result = try metadataResult(id: id, photoID: "requested-photo", url: "https://example.com/requested.png")
        let unexpected = try pepData(id: id, photoID: "unrequested-photo")
        let extraItems = try XCTUnwrap(unexpected.element(forName: "pubsub")?.element(forName: "items"))
        try XCTUnwrap(result.element(forName: "pubsub")).addChild(extraItems.copy() as! DDXMLElement)

        XCTAssertTrue(account.avatarManager.read(withIQ: result))

        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(stored.avatarMaxUrl, "https://example.com/requested.png")
        XCTAssertEqual(stored.oldschoolAvatarKey, "requested-photo")
    }

    func testLatePEPMetadataIQCannotReplaceNewerMetadataNotification() throws {
        account.avatarManager.requestPubSubItem(stream, node: .metadata, jid: owner, by: "")
        let id = try XCTUnwrap(stream.elements.first?.attributeStringValue(forName: "id"))
        let newer = try metadataResult(id: "notification", photoID: "new-photo", url: "https://example.com/new.png")
        let item = try XCTUnwrap(newer.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item"))
        XCTAssertTrue(account.avatarManager.readFromPubSubMetadata(jid: owner, pubsub: item))

        XCTAssertTrue(account.avatarManager.read(withIQ: try metadataResult(id: id, photoID: "old-photo", url: "https://example.com/old.png")))

        XCTAssertEqual(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.avatarMaxUrl, "https://example.com/new.png")
    }

    func testAvatarMetadataWithUncachedPersistedDataKeyRequestsDataAgain() throws {
        let photoID = "uncached-\(UUID())"
        let stored = try XCTUnwrap(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner))
        try realm.write { stored.oldschoolAvatarKey = [photoID, owner!].prp() }
        let metadata = try DDXMLDocument(xmlString: """
            <item id='\(photoID)'><metadata xmlns='urn:xmpp:avatar:metadata'><info id='\(photoID)' type='image/png'/></metadata></item>
            """, options: 0)
        let sent = expectation(description: "missing cached bytes refetched")
        stream.onSend = { _ in sent.fulfill() }
        account.sendReadiness.markStreamManagementEnabled()

        XCTAssertTrue(account.avatarManager.readFromPubSubMetadata(jid: owner, pubsub: try XCTUnwrap(metadata.rootElement())))
        wait(for: [sent], timeout: 2)

        XCTAssertEqual(stream.elements.first?.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node"), "urn:xmpp:avatar:data")
    }

    private func addRoster(jid: String, removed: Bool = false) throws {
        try realm.write {
            let stored = RosterStorageItem()
            stored.owner = owner
            stored.jid = jid
            stored.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
            stored.removed = removed
            realm.add(stored, update: .modified)
        }
    }

    private func vcardPhoto(from: String?) throws -> XMPPIQ {
        let data = try photoBase64()
        return try iq("""
            <iq type='result' id='vcard-photo'\(from.map { " from='\($0)'" } ?? "")>
              <vCard xmlns='vcard-temp'><PHOTO><TYPE>image/png</TYPE><BINVAL>\(data)</BINVAL></PHOTO></vCard>
            </iq>
            """)
    }

    private func pepData(id: String, photoID: String) throws -> XMPPIQ {
        try iq("""
            <iq type='result' id='\(id)'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
              <items node='urn:xmpp:avatar:data'><item id='\(photoID)'><data xmlns='urn:xmpp:avatar:data'>\(try photoBase64())</data></item></items>
            </pubsub></iq>
            """)
    }

    private func metadataResult(id: String, photoID: String, url: String) throws -> XMPPIQ {
        try iq("""
            <iq type='result' id='\(id)'><pubsub xmlns='http://jabber.org/protocol/pubsub'>
              <items node='urn:xmpp:avatar:metadata'><item id='\(photoID)'><metadata xmlns='urn:xmpp:avatar:metadata'>
                <info id='\(photoID)' url='\(url)'/>
              </metadata></item></items>
            </pubsub></iq>
            """)
    }

    private func photoBase64() throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.pngData()).base64EncodedString()
    }

    private func iq(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}
