import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Reproduces the startup interleaving from the 2026-10-28 phone log using
/// real account send entry points and real XEP-SYNC page commits.
final class InitialSyncTrafficOrderingTests: XCTestCase {
    private final class PolicyMemory: OMEMO2StatePersistence {
        private var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private final class SynchronizationFlag {
        private let lock = NSLock()
        private var value = true
        var isPending: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    private final class Calls {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class Wire: XMPPStream {
        private let lock = NSLock()
        private var recorded: [DDXMLElement] = []
        weak var account: Account?
        var holdsBroadcastPresence = false
        var onSyncRequest: (() -> Void)?
        private var heldBroadcasts: [XMPPPresence] = []
        var heldBroadcastCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return heldBroadcasts.count
        }

        override var isAuthenticated: Bool { true }
        override var isConnected: Bool { true }
        override var isDisconnected: Bool { false }

        override func send(_ element: DDXMLElement) {
            let admitted: DDXMLElement?
            if let iq = element as? XMPPIQ {
                admitted = account?.xmppStream(self, willSend: iq) ?? (account == nil ? iq : nil)
            } else if let presence = element as? XMPPPresence {
                admitted = account?.xmppStream(self, willSend: presence) ?? (account == nil ? presence : nil)
            } else if let message = element as? XMPPMessage {
                admitted = account?.xmppStream(self, willSend: message) ?? (account == nil ? message : nil)
            } else {
                admitted = element
            }
            guard let admitted else { return }
            lock.lock()
            if let presence = admitted as? XMPPPresence,
               presence.to == nil, presence.type != "unavailable", holdsBroadcastPresence {
                heldBroadcasts.append(presence)
                lock.unlock()
                return
            }
            recorded.append(admitted.copy() as! DDXMLElement)
            lock.unlock()
            if let stanza = admitted as? XMPPElement,
               ClientSynchronizationManager.isClientSyncPaginationIQ(stanza) {
                onSyncRequest?()
            }
            // XMPPFramework invokes didSend on its registered delegate queue.
            // A synchronous callback here would make the test thread wait on
            // the SM module queue while holding unrelated Realm fixture work.
            if let account {
                account.queue.async { [weak account, weak self] in
                    guard let account, let self else { return }
                    if let presence = admitted as? XMPPPresence {
                        account.xmppStream(self, didSend: presence)
                    } else if let iq = admitted as? XMPPIQ {
                        account.xmppStream(self, didSend: iq)
                    }
                }
            }
        }

        func releaseHeldBroadcasts() {
            lock.lock()
            let pending = heldBroadcasts
            heldBroadcasts.removeAll()
            holdsBroadcastPresence = false
            lock.unlock()
            pending.forEach(send)
        }

        var sent: [DDXMLElement] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var sentIDs: [String] { sent.compactMap { $0.attributeStringValue(forName: "id") } }
    }

    private var previousRealm: Realm.Configuration!
    private var owner = ""
    private var account: Account!
    private var wire: Wire!

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        owner = "startup-order-\(UUID().uuidString.lowercased())@example.test"
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: owner)
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept([])
        AccountManager.shared.connectingUsers.accept([])
        AccountManager.shared.authenticatedUsers.accept([])
        let realm = try WRealm.safe()
        let stored = AccountStorageItem()
        stored.jid = owner
        stored.username = "startup-order"
        stored.enabled = true
        try realm.write { realm.add(stored, update: .modified) }
        account = Account(jid: owner, queue: DispatchQueue(label: owner))
        account.sendReadiness.onReadinessChanged = nil
        account.sendReadiness.markStreamManagementEnabled()
        account.blocked.lastUpdate = Date()
        account.omemo.omemo2Storage = try XabberOMEMO2Storage(owner: owner, persistence: PolicyMemory())
        wire = Wire()
        wire.myJID = XMPPJID(string: owner + "/ordering-test")
        wire.account = account
        account.xmppStream = wire
        AccountManager.shared.users.append(account)
        account.syncManager.isAvailable = true
        account.syncManager.prepareForAuthenticatedStream(didResume: false)
    }

    override func tearDownWithError() throws {
        account.syncManager.waitForPendingSnapshotApplies()
        account.queue.sync {}
        account.syncManager.syncRequestObserver = nil
        account.cancelStartupTrafficOrdering()
        wire.onSyncRequest = nil
        wire.account = nil
        account.messages.updateSendingMessagesTimer?.invalidate()
        account.messages.updateSendingMessagesTimer = nil
        account.syncManager.reset()
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept([])
        AccountManager.shared.connectingUsers.accept([])
        AccountManager.shared.authenticatedUsers.accept([])
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        account = nil
        wire = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        previousRealm = nil
    }

    func testAvailablePresenceCannotPassThePrimarySendGateDuringStartupSync() {
        let presence = XMPPPresence()
        XCTAssertFalse(AccountPrimaryStreamBootstrapSendGate.allowsDuringBootstrap(
            presence,
            replayPolicy: .latestPresence(scope: "available:broadcast"),
            ownerBareJID: owner
        ))
    }

    func testBothPrimarySendEntryPointsDeferBackgroundFamiliesDuringStartupSync() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        for (family, child) in backgroundFamilies {
            let direct = try iq(id: "direct-\(family)", child: child)
            XCTAssertEqual(account.sendPrimaryStanza(direct), .queued(stanzaId: "direct-\(family)"), family)
            let delegated = try iq(id: "delegate-\(family)", child: child)
            XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(delegated, finalDelegate: true), family)
        }
        XCTAssertTrue(wire.sentIDs.allSatisfy { !$0.hasPrefix("direct-") && !$0.hasPrefix("delegate-") })
    }

    func testRosterReadyDoesNotSendOwnPresenceBeforeSyncCompletes() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        try resolveInitialRoster()
        account.queue.sync {}
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast),
                       "Roster readiness must not trigger the presence flood before the chat list is synchronized")
    }

    func testFirstPageKeepsBackgroundQueuedAndFinalPageSendsPresenceBeforeBackground() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let firstID = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        account.queue.sync {}
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "after-sync-avatar", child: avatarQuery)),
                       .queued(stanzaId: "after-sync-avatar"))
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: firstID, index: 0, count: 2, final: false)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.syncRequests.count == 2 }
        XCTAssertFalse(wire.sentIDs.contains("after-sync-avatar"))
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))

        let finalID = try XCTUnwrap(syncRequests.last?.elementID)
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: finalID, index: 1, count: 2, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.wire.sentIDs.contains("after-sync-avatar") }

        let sent = wire.sent
        let presenceIndex = try XCTUnwrap(sent.firstIndex(where: isAvailableBroadcast))
        let backgroundIndex = try XCTUnwrap(sent.firstIndex { $0.attributeStringValue(forName: "id") == "after-sync-avatar" })
        XCTAssertLessThan(presenceIndex, backgroundIndex)
        XCTAssertEqual(sent.filter(isAvailableBroadcast).count, 1)
    }

    func testCachedCompletedSnapshotDoesNotAllowFreshAuthenticationToSkipSyncOrdering() throws {
        SettingManager.shared.saveItem(for: owner, scope: .clientSynchronization,
                                      key: "last_completed_snapshot_stamp", value: "1700000000000000")
        account.syncManager.prepareForAuthenticatedStream(didResume: false)
        XCTAssertTrue(account.syncManager.sync(wire))
        XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(try iq(id: "cached-avatar", child: avatarQuery)))
        XCTAssertFalse(account.syncManager.claimInitialPresenceSend())
    }

    func testUnsupportedSyncDoesNotStrandPresenceOrBackgroundTraffic() throws {
        account.syncManager.checkAvailability(try element("<features/>"))
        XCTAssertFalse(account.syncManager.isAvailable)
        XCTAssertTrue(account.preparePrimaryStreamStanzaForSend(try iq(id: "unsupported-avatar", child: avatarQuery)))
        XCTAssertTrue(account.syncManager.claimInitialPresenceSend())
    }

    func testResetStreamCannotReleaseOldQueuedTrafficIntoReplacementAuthentication() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let oldSyncID = try XCTUnwrap(syncRequests.last?.elementID)
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "old-avatar", child: avatarQuery)),
                       .queued(stanzaId: "old-avatar"))
        account.resetStream()
        let replacement = Wire()
        replacement.account = account
        replacement.myJID = XMPPJID(string: owner + "/replacement")
        wire = replacement
        account.xmppStream = replacement
        account.sendReadiness.markStreamManagementEnabled()
        account.syncManager.prepareForAuthenticatedStream(didResume: false)
        XCTAssertTrue(account.syncManager.sync(replacement))
        let replacementSyncID = try XCTUnwrap(syncRequests.last?.elementID)

        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: oldSyncID, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(try iq(id: "new-avatar", child: avatarQuery)))
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: replacementSyncID, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        account.queue.sync {}
        XCTAssertFalse(replacement.sentIDs.contains("old-avatar"))
    }

    func testSyncContinuationAndRequiredProtocolTrafficRemainAdmissible() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let required = [
            "<iq type='get' id='roster'><query xmlns='jabber:iq:roster'/></iq>",
            "<iq type='get' id='self-disco' to='\(owner)'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
            "<iq type='get' id='root-disco' to='example.test'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
            "<iq type='get' id='sync-next'><query xmlns='https://xabber.com/protocol/synchronization'><set xmlns='http://jabber.org/protocol/rsm'><max>40</max><after>opaque-cursor</after></set></query></iq>",
            "<iq type='result' id='required-result'/>",
            "<iq type='error' id='required-error'/>"
        ]
        for xml in required {
            let stanza = XMPPIQ(from: try element(xml))
            XCTAssertTrue(account.preparePrimaryStreamStanzaForSend(stanza), stanza.elementID ?? xml)
        }
        let durable = XMPPMessage(messageType: .chat, to: XMPPJID(string: "peer@example.test"), elementID: "user-message")
        durable.addBody("Offline-composed message")
        XCTAssertTrue(account.preparePrimaryStreamStanzaForSend(durable,
                      replayPolicy: .durableRegularMessage(originId: "user-message")))
        XCTAssertTrue(account.preparePrimaryStreamStanzaForSend(XMPPPresence(type: .unavailable),
                      replayPolicy: .latestPresence(scope: "account-unavailable")))
    }

    func testAuthenticatedPreparationBlocksBackgroundBeforeFirstSyncRequest() throws {
        XCTAssertTrue(syncRequests.isEmpty)
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "prep-gap-avatar", child: avatarQuery)),
                       .queued(stanzaId: "prep-gap-avatar"))
        XCTAssertNil(account.xmppStream(wire, willSend: try iq(id: "prep-gap-device", child: backgroundFamilies[5].1)))
        XCTAssertFalse(account.syncManager.claimInitialPresenceSend())
        XCTAssertFalse(wire.sentIDs.contains("prep-gap-avatar"))
    }

    func testSyncErrorKeepsTrafficBlockedUntilExplicitRetryCompletes() throws {
        try rejectedReplyKeepsTrafficBlocked(malformed: false)
    }

    func testMalformedSyncResultKeepsTrafficBlockedUntilExplicitRetryCompletes() throws {
        try rejectedReplyKeepsTrafficBlocked(malformed: true)
    }

    func testFinalSyncBeforeRosterKeepsBackgroundQueuedUntilRosterAndActualPresence() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let id = try XCTUnwrap(syncRequests.last?.elementID)
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "waiting-roster-avatar", child: avatarQuery)),
                       .queued(stanzaId: "waiting-roster-avatar"))
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: id, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        account.queue.sync {}
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        XCTAssertFalse(wire.sentIDs.contains("waiting-roster-avatar"))
        XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(try iq(id: "still-waiting-roster", child: avatarQuery)))

        try resolveInitialRoster()
        try waitUntil { self.wire.sentIDs.contains("waiting-roster-avatar") }
        let sent = wire.sent
        XCTAssertLessThan(try XCTUnwrap(sent.firstIndex(where: isAvailableBroadcast)),
                          try XCTUnwrap(sent.firstIndex { $0.attributeStringValue(forName: "id") == "waiting-roster-avatar" }))
    }

    func testExplicitDurableMessagePassesPreflightAndFinalDelegateDuringStartupSync() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let message = XMPPMessage(messageType: .chat, to: XMPPJID(string: "peer@example.test"), elementID: "durable-user-message")
        message.addBody("Offline-composed message")
        XCTAssertTrue(OMEMO2OptOutPolicy.allowsOutgoing(message, owner: owner, storage: account.omemo.omemo2Storage),
                      "The fixture supplies valid protected policy state so this tests startup admission")
        XCTAssertEqual(account.sendPrimaryStanza(message, replayPolicy: .durableRegularMessage(originId: "durable-user-message")),
                       .sent(stanzaId: "durable-user-message"))
        XCTAssertEqual(wire.sentIDs.filter { $0 == "durable-user-message" }.count, 1,
                       "The XMPPFramework final willSend delegate must retain the durable-message exemption")
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
    }

    func testDeferredOperationDoesNotCreateItsRequestUntilSyncAndPresenceComplete() throws {
        let calls = Calls()
        XCTAssertTrue(account.deferWorkUntilStartupSynchronizationCompletes(key: "fixture-avatar") { user, _ in
            calls.record("operation")
            let iq = XMPPIQ(iqType: .get, elementID: "operation-created-avatar",
                            child: DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub"))
            _ = user.sendPrimaryStanza(iq)
        })
        XCTAssertTrue(calls.recorded.isEmpty)
        XCTAssertFalse(wire.sentIDs.contains("operation-created-avatar"))
        XCTAssertTrue(account.syncManager.sync(wire))
        let id = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        XCTAssertTrue(calls.recorded.isEmpty)
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: id, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.wire.sentIDs.contains("operation-created-avatar") }
        XCTAssertEqual(calls.recorded, ["operation"])
        let sent = wire.sent
        XCTAssertLessThan(try XCTUnwrap(sent.firstIndex(where: isAvailableBroadcast)),
                          try XCTUnwrap(sent.firstIndex { $0.attributeStringValue(forName: "id") == "operation-created-avatar" }))
    }

    func testResetCancelsDeferredOperationExactlyOnceAndNeverCreatesItsRequest() {
        let calls = Calls()
        XCTAssertTrue(account.deferWorkUntilStartupSynchronizationCompletes(
            key: "cancelled-operation", onCancel: { calls.record("cancel") },
            work: { _, _ in calls.record("work") }
        ))
        account.resetStream()
        account.cancelStartupTrafficOrdering()
        account.queue.sync {}
        XCTAssertEqual(calls.recorded, ["cancel"])
    }

    func testSMResumeAfterUnsentInitialPresenceKeepsBackgroundBlockedUntilActualPresence() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let id = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        wire.holdsBroadcastPresence = true
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: id, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.wire.heldBroadcastCount == 1 }
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        account.resetStream()

        let resumed = Wire()
        resumed.account = account
        resumed.holdsBroadcastPresence = true
        resumed.myJID = XMPPJID(string: owner + "/resumed")
        wire = resumed
        account.xmppStream = resumed
        account.sendReadiness.markStreamManagementResumeSucceeded()
        account.syncManager.prepareForAuthenticatedStream(didResume: true)
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "resumed-avatar", child: avatarQuery)),
                       .queued(stanzaId: "resumed-avatar"))
        account.syncManager.restoreAfterStreamManagementResume()
        try waitUntil { self.wire.heldBroadcastCount == 1 }
        XCTAssertFalse(wire.sentIDs.contains("resumed-avatar"))
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))

        // Successful SM resumption preserves the already-resolved roster;
        // only the unsent presence must be submitted again.
        resumed.releaseHeldBroadcasts()
        try waitUntil { self.wire.sentIDs.contains("resumed-avatar") }
        let sent = wire.sent
        XCTAssertEqual(sent.filter(isAvailableBroadcast).count, 1)
        XCTAssertLessThan(try XCTUnwrap(sent.firstIndex(where: isAvailableBroadcast)),
                          try XCTUnwrap(sent.firstIndex { $0.attributeStringValue(forName: "id") == "resumed-avatar" }))
    }

    func testTransientSyncErrorAutomaticallyRetriesWithoutReleasingPresenceOrBackground() throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let failedID = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "auto-retry-avatar", child: avatarQuery)),
                       .queued(stanzaId: "auto-retry-avatar"))
        let error = XMPPIQ(from: try element("""
        <iq type='error' id='\(failedID)'><error type='wait'>
          <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
        </error></iq>
        """))
        XCTAssertTrue(account.syncManager.read(withIQ: error))
        account.syncManager.waitForPendingSnapshotApplies()
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        XCTAssertFalse(wire.sentIDs.contains("auto-retry-avatar"))

        try waitUntil(timeout: 3) { self.syncRequests.count == 2 }
        let retryID = try XCTUnwrap(syncRequests.last?.elementID)
        XCTAssertNotEqual(retryID, failedID)
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        XCTAssertFalse(wire.sentIDs.contains("auto-retry-avatar"))
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: retryID, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.wire.sentIDs.contains("auto-retry-avatar") }
        let sent = wire.sent
        XCTAssertLessThan(try XCTUnwrap(sent.firstIndex(where: isAvailableBroadcast)),
                          try XCTUnwrap(sent.firstIndex { $0.attributeStringValue(forName: "id") == "auto-retry-avatar" }))
    }

    func testUnansweredSyncRetriesAndStreamResetInvalidatesItsTimeoutAndRetry() throws {
        account.syncManager.startupResponseTimeoutInterval = 0.05
        XCTAssertTrue(account.syncManager.sync(wire))
        let timedOutID = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "timeout-avatar", child: avatarQuery)),
                       .queued(stanzaId: "timeout-avatar"))
        try waitUntil(timeout: 3) { self.syncRequests.count == 2 }
        XCTAssertNotEqual(syncRequests.last?.elementID, timedOutID)
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        XCTAssertFalse(wire.sentIDs.contains("timeout-avatar"))

        account.resetStream()
        let replacement = Wire()
        replacement.account = account
        replacement.myJID = XMPPJID(string: owner + "/after-timeout-reset")
        wire = replacement
        account.xmppStream = replacement
        account.sendReadiness.markStreamManagementEnabled()
        account.syncManager.prepareForAuthenticatedStream(didResume: false)
        let staleRetry = expectation(description: "Old timeout or retry must not dispatch onto the replacement stream")
        staleRetry.isInverted = true
        replacement.onSyncRequest = { staleRetry.fulfill() }
        wait(for: [staleRetry], timeout: 2.3)
        replacement.onSyncRequest = nil
        XCTAssertTrue(syncRequests.isEmpty)
        XCTAssertFalse(wire.sentIDs.contains("timeout-avatar"))
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
    }

    func testStartupSchedulerDefersInteractiveMAMButAdmitsOtherInteractiveWork() {
        let synchronization = SynchronizationFlag()
        let calls = Calls()
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(),
            initialListSynchronizationInProgress: { synchronization.isPending }
        )
        let interactiveRan = expectation(description: "Interactive non-MAM work remains available during sync")
        let mamRan = expectation(description: "MAM starts only after startup sync has released the scheduler")
        scheduler.enqueue(priority: .interactive, resource: .mamArchive, deduplicationKey: "visible-archive") { finish in
            calls.record("mam")
            mamRan.fulfill()
            finish()
        }
        scheduler.enqueue(priority: .interactive, resource: .other("startup-test"), deduplicationKey: "user-action") { finish in
            calls.record("interactive")
            interactiveRan.fulfill()
            finish()
        }
        wait(for: [interactiveRan], timeout: 2)
        XCTAssertEqual(calls.recorded, ["interactive"],
                       "A visible archive request must not arm its timeout before initial sync completes")

        synchronization.isPending = false
        scheduler.initialListSynchronizationDidChange()
        wait(for: [mamRan], timeout: 2)
        scheduler.initialListSynchronizationDidChange()
        scheduler.initialListSynchronizationDidChange()
        let drained = expectation(description: "Repeated gate notifications have drained")
        scheduler.enqueue(priority: .interactive, resource: .other("startup-barrier"), deduplicationKey: "barrier") { finish in
            calls.record("barrier")
            drained.fulfill()
            finish()
        }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(calls.recorded, ["interactive", "mam", "barrier"])
    }

    private func rejectedReplyKeepsTrafficBlocked(malformed: Bool) throws {
        XCTAssertTrue(account.syncManager.sync(wire))
        let id = try XCTUnwrap(syncRequests.last?.elementID)
        try resolveInitialRoster()
        XCTAssertEqual(account.sendPrimaryStanza(try iq(id: "retry-avatar", child: avatarQuery)),
                       .queued(stanzaId: "retry-avatar"))
        let reply: XMPPIQ
        if malformed {
            reply = XMPPIQ(from: try element("<iq type='result' id='\(id)'><query xmlns='https://xabber.com/protocol/synchronization'/></iq>"))
        } else {
            reply = XMPPIQ(from: try element("<iq type='error' id='\(id)'><error type='wait'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"))
        }
        XCTAssertTrue(account.syncManager.read(withIQ: reply))
        account.syncManager.waitForPendingSnapshotApplies()
        account.queue.sync {}
        XCTAssertFalse(account.syncManager.claimInitialPresenceSend())
        XCTAssertFalse(wire.sent.contains(where: isAvailableBroadcast))
        XCTAssertFalse(wire.sentIDs.contains("retry-avatar"))
        XCTAssertFalse(account.preparePrimaryStreamStanzaForSend(try iq(id: "after-rejected-avatar", child: avatarQuery)))

        account.syncManager.reset()
        XCTAssertTrue(account.syncManager.sync(wire))
        let retryID = try XCTUnwrap(syncRequests.last?.elementID)
        XCTAssertNotEqual(retryID, id)
        XCTAssertTrue(account.syncManager.read(withIQ: try page(id: retryID, index: 0, count: 0, final: true)))
        account.syncManager.waitForPendingSnapshotApplies()
        try waitUntil { self.wire.sentIDs.contains("retry-avatar") }
    }

    private func resolveInitialRoster() throws {
        account.roster.request(wire)
        let id = try XCTUnwrap(wire.sent.last { stanza in
            stanza.name == "iq" && stanza.element(forName: "query", xmlns: "jabber:iq:roster") != nil
        }?.attributeStringValue(forName: "id"))
        XCTAssertTrue(account.roster.read(withIQ: XMPPIQ(from: try element(
            "<iq type='result' id='\(id)'><query xmlns='jabber:iq:roster' ver='fixture'/></iq>"
        ))))
        XCTAssertTrue(account.roster.isInitialRosterReceived)
        account.queue.sync {}
    }

    private let avatarQuery = "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:avatar:metadata'/></pubsub>"
    private var backgroundFamilies: [(String, String)] {
        [
            ("omemo-bundle", "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:bundles'/></pubsub>"),
            ("omemo-devices", "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:omemo:2:devices'/></pubsub>"),
            ("avatar", avatarQuery),
            ("vcard", "<vCard xmlns='vcard-temp'/>"),
            ("mam", "<query xmlns='urn:xmpp:mam:2' queryid='background-mam'/>"),
            ("devices", "<query xmlns='https://xabber.com/protocol/devices#items'/>"),
            ("push", "<enable xmlns='https://xabber.com/protocol/push' node='fixture-push'/>"),
            ("rewrite", "<query xmlns='https://xabber.com/protocol/rewrite'/>"),
            ("trustsharing", "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:trustsharing:0'/></pubsub>")
        ]
    }
    private var syncRequests: [XMPPIQ] {
        wire.sent.compactMap { $0 as? XMPPIQ }.filter { ClientSynchronizationManager.isClientSyncPaginationIQ($0) }
    }
    private func isAvailableBroadcast(_ stanza: DDXMLElement) -> Bool {
        stanza.name == "presence" && stanza.attributeStringValue(forName: "to") == nil &&
            [nil, "", "available"].contains(stanza.attributeStringValue(forName: "type"))
    }
    private func iq(id: String, child: String) throws -> XMPPIQ {
        XMPPIQ(from: try element("<iq type='get' id='\(id)'>\(child)</iq>"))
    }
    private func element(_ xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return try XCTUnwrap(document.rootElement())
    }
    private func page(id: String, index: Int, count: Int, final: Bool) throws -> XMPPIQ {
        let conversation = count == 0 ? "" : """
        <conversation jid='chat-\(index)@example.test' type='https://xabber.com/protocol/chat' stamp='1793185595284531' status='active'>
          <metadata node='https://xabber.com/protocol/synchronization'><unread count='0'/></metadata>
        </conversation>
        """
        return XMPPIQ(from: try element("""
        <iq type='result' id='\(id)'><query xmlns='https://xabber.com/protocol/synchronization' stamp='1793185595284531'>
          \(conversation)
          <set xmlns='http://jabber.org/protocol/rsm'><first index='\(index)'>cursor-\(index)</first><last>cursor-\(index)</last><count>\(count)</count></set>
        </query></iq>
        """))
    }
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for account traffic transition", file: file, line: line)
    }
}
