import Foundation
import XCTest
import CocoaAsyncSocket
import XMPPFramework

final class ColdStreamManagementWireTests: XCTestCase {
    private static let namespace = "urn:xmpp:sm:3"
    private static let resumptionID = "resume-test-session"
    private static let originalJID = "account@example.test/server-bound-resource"
    private static let configuredJID = "account@example.test/new-process-default"

    private final class Wire: XMPPStream {
        var bindingFrames: [DDXMLElement] = []
        var streamFrames: [DDXMLElement] = []
        var advertisesSM = true
        var secureTransport = true
        override var supportsStreamManagement: Bool { advertisesSM }
        override var isSecure: Bool { secureTransport }
        override func sendBindElement(_ element: DDXMLElement) { bindingFrames.append(element) }
        override func send(_ element: DDXMLElement) { streamFrames.append(element) }
    }

    private final class LoopbackStream: XMPPStream {
        // The fixture uses a private loopback socket and synthetic credentials.
        // The security policy itself is covered by the insecure-connection case.
        private let lock = NSLock()
        private var reachedAuthentication = false

        override var isSecure: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedAuthentication
        }

        func permitFixtureAuthentication() {
            lock.lock()
            reachedAuthentication = true
            lock.unlock()
        }
    }

    private final class LoopbackPeer: NSObject, GCDAsyncSocketDelegate, XMPPStreamDelegate {
        enum Stage: Int {
            case opening, authenticate, reopening, binding

            var terminator: Data { Data((self == .authenticate ? "</auth>" : ">").utf8) }
        }

        let queue = DispatchQueue(label: "ColdStreamManagementWireTests.loopback")
        let authenticated: XCTestExpectation
        lazy var listener = GCDAsyncSocket(delegate: self, delegateQueue: queue)
        var accepted: GCDAsyncSocket?
        var firstBindingFrame: DDXMLElement?

        init(authenticated: XCTestExpectation) { self.authenticated = authenticated }

        func listen() throws -> UInt16 {
            try listener.accept(onInterface: "127.0.0.1", port: 0)
            return listener.localPort
        }

        func xmppStreamDidConnect(_ sender: XMPPStream) {
            (sender as? LoopbackStream)?.permitFixtureAuthentication()
            do { try sender.authenticate(withPassword: "loopback-fixture-password") }
            catch { XCTFail("The synthetic server should accept SASL PLAIN: \(error)") }
        }

        func xmppStreamDidAuthenticate(_ sender: XMPPStream) { authenticated.fulfill() }

        func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
            accepted = newSocket
            read(.opening, from: newSocket)
        }

        func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
            guard let stage = Stage(rawValue: tag), let xml = String(data: data, encoding: .utf8) else {
                return XCTFail("The client emitted an unreadable loopback frame")
            }
            let stream = "<stream:stream from='example.test' id='loopback' version='1.0' "
                + "xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
            let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
            if (stage == .opening || stage == .reopening) && xml.hasPrefix("<?xml") {
                read(stage, from: sock)
                return
            }
            switch stage {
            case .opening:
                send(stream + "<stream:features><mechanisms xmlns='\(sasl)'>"
                    + "<mechanism>PLAIN</mechanism></mechanisms></stream:features>", to: sock)
                read(.authenticate, from: sock)
            case .authenticate:
                XCTAssertTrue(xml.hasPrefix("<auth"))
                send("<success xmlns='\(sasl)'/>", to: sock)
                read(.reopening, from: sock)
            case .reopening:
                send(stream + "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>"
                    + "<sm xmlns='\(ColdStreamManagementWireTests.namespace)'/></stream:features>", to: sock)
                read(.binding, from: sock)
            case .binding:
                firstBindingFrame = try? DDXMLElement(xmlString: xml)
                guard firstBindingFrame?.localName == "resume" else {
                    return XCTFail("The first post-SASL frame should be <resume/>, before any resource bind")
                }
                send("<resumed xmlns='\(ColdStreamManagementWireTests.namespace)' "
                    + "h='27' previd='\(ColdStreamManagementWireTests.resumptionID)'/>", to: sock)
            }
        }

        private func send(_ xml: String, to socket: GCDAsyncSocket) {
            socket.write(Data(xml.utf8), withTimeout: 3, tag: 0)
        }

        private func read(_ stage: Stage, from socket: GCDAsyncSocket) {
            socket.readData(to: stage.terminator, withTimeout: 3, maxLength: 8192, tag: stage.rawValue)
        }

        func stop() {
            queue.async {
                self.accepted?.disconnect()
                self.listener.disconnect()
            }
        }
    }

    private final class Checkpoints: NSObject, XMPPStreamManagementDelegate {
        var values: [XMPPStreamManagementResumeCheckpoint] = []

        func xmppStreamManagement(_ sender: XMPPStreamManagement,
                                  didPrepare checkpoint: XMPPStreamManagementResumeCheckpoint) {
            values.append(checkpoint)
        }
    }

    private final class PendingInbound: NSObject, XMPPStreamManagementDelegate {
        let inspected: XCTestExpectation

        init(inspected: XCTestExpectation) { self.inspected = inspected }

        func xmppStreamManagement(_ sender: XMPPStreamManagement,
                                  getIsHandled isHandled: UnsafeMutablePointer<ObjCBool>?,
                                  stanzaId: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                  forReceivedElement element: XMPPElement) {
            isHandled?.pointee = false
            stanzaId?.pointee = "pending-commit" as NSString
            inspected.fulfill()
        }
    }

    private final class Harness {
        let queue = DispatchQueue(label: "ColdStreamManagementWireTests.module")
        let storage = XMPPStreamManagementMemoryStorage()
        let wire = Wire()
        let module: XMPPStreamManagement

        init(jid: String = ColdStreamManagementWireTests.configuredJID) {
            wire.myJID = XMPPJID(string: jid)
            module = XMPPStreamManagement(storage: storage, dispatchQueue: queue)
            XCTAssertTrue(module.activate(wire))
            module.autoResume = true
        }

        deinit { module.deactivate() }

        func startBinding() -> XMPPBindResult {
            var error: NSError?
            let result = module.start(&error)
            queue.sync {}
            return result
        }

        func receiveBindReply(_ element: DDXMLElement) -> XMPPBindResult {
            var error: NSError?
            let result = module.handleBind(element, withError: &error)
            queue.sync {}
            return result
        }

        func event(_ name: String, _ element: Any? = nil) {
            queue.sync { _ = module.perform(NSSelectorFromString(name), with: wire, with: element) }
        }

        func enable() throws {
            module.enable(withResumption: true, maxTimeout: 3600)
            queue.sync {}
            let enable = try XCTUnwrap(wire.streamFrames.last)
            XCTAssertEqual(enable.localName, "enable")
            event("xmppStream:didSendCustomElement:", enable)
            let enabled = DDXMLElement(name: "enabled", xmlns: ColdStreamManagementWireTests.namespace)
            enabled.addAttribute(withName: "resume", stringValue: "true")
            enabled.addAttribute(withName: "id", stringValue: ColdStreamManagementWireTests.resumptionID)
            enabled.addAttribute(withName: "max", stringValue: "3600")
            event("xmppStream:didReceiveCustomElement:", enabled)
        }

        func disconnect() {
            event("xmppStreamDidDisconnect:withError:")
        }

        func captureCheckpoints() -> Checkpoints {
            let checkpoints = Checkpoints()
            module.addDelegate(checkpoints, delegateQueue: queue)
            queue.sync {}
            return checkpoints
        }
    }

    private func smFrame(_ name: String, h: UInt32? = nil, previd: String? = nil) -> DDXMLElement {
        let element = DDXMLElement(name: name, xmlns: Self.namespace)
        if let h { element.addAttribute(withName: "h", stringValue: String(h)) }
        if let previd { element.addAttribute(withName: "previd", stringValue: previd) }
        return element
    }

    private func checkpoint(disconnect: Date = Date(), serverHandled: UInt32 = 27) -> XMPPStreamManagementResumeCheckpoint {
        XMPPStreamManagementResumeCheckpoint(resumptionID: Self.resumptionID, timeout: 3600,
            lastDisconnect: disconnect, lastHandledByClient: 13, lastHandledByServer: serverHandled,
            boundJID: Self.originalJID)
    }

    func testAutomaticResumeIsTheFirstFrameAfterSASLOnANewConnection() throws {
        executionTimeAllowance = 20
        let authenticated = expectation(description: "the real stream completes authentication by resuming")
        let peer = LoopbackPeer(authenticated: authenticated)
        let stream = LoopbackStream()
        stream.hostName = "127.0.0.1"
        stream.hostPort = try peer.listen()
        stream.myJID = XMPPJID(string: Self.configuredJID)
        let module = XMPPStreamManagement(storage: XMPPStreamManagementMemoryStorage())
        module.autoResume = true
        XCTAssertTrue(module.activate(stream))
        stream.addDelegate(peer, delegateQueue: peer.queue)
        defer {
            peer.stop()
            DispatchQueue.global(qos: .utility).async {
                stream.disconnect()
                module.deactivate()
            }
        }
        XCTAssertTrue(module.restoreResumeCheckpoint(checkpoint(), consume: { true }))

        DispatchQueue.global(qos: .userInitiated).async {
            do { try stream.connect(withTimeout: 3) }
            catch { XCTFail("Unable to connect to the loopback fixture: \(error)") }
        }
        guard XCTWaiter.wait(for: [authenticated], timeout: 6) == .completed else {
            return XCTFail("The loopback stream did not reach authenticated resumption")
        }

        let request = try XCTUnwrap(peer.queue.sync { peer.firstBindingFrame })
        XCTAssertEqual(request.attributeStringValue(forName: "previd"), Self.resumptionID)
        XCTAssertEqual(request.attributeStringValue(forName: "h"), "13")
        XCTAssertTrue(module.didResumeFromCheckpoint)
        XCTAssertEqual(stream.myJID?.full, Self.originalJID)
    }

    func testNewModuleResumesWithSavedCountersAndRestoresServerBoundResource() throws {
        let prior = Harness(jid: Self.originalJID)
        let recorded = prior.captureCheckpoints()
        try prior.enable()
        let inbound = XMPPMessage(messageType: .chat, to: nil, elementID: "handled-inbound")
        prior.event("xmppStream:didReceiveMessage:", inbound)
        prior.event("xmppStream:didReceivePresence:", XMPPPresence())
        prior.event("xmppStream:didReceiveCustomElement:", smFrame("r"))
        XCTAssertEqual(prior.wire.streamFrames.last?.attributeStringValue(forName: "h"), "2")
        let outbound = XMPPMessage(messageType: .chat, to: nil, elementID: "acknowledged-outbound")
        prior.event("xmppStream:didSendMessage:", outbound)
        prior.event("xmppStream:didReceiveCustomElement:", smFrame("a", h: 1))
        prior.disconnect()
        prior.queue.sync {}
        let saved = try XCTUnwrap(recorded.values.first)
        XCTAssertEqual(saved.lastHandledByClient, 2)
        XCTAssertEqual(saved.lastHandledByServer, 1)
        XCTAssertEqual(saved.boundJID, Self.originalJID)

        let reopened = Harness()
        var consumed = 0
        XCTAssertTrue(reopened.module.restoreResumeCheckpoint(saved, consume: {
            XCTAssertTrue(reopened.wire.bindingFrames.isEmpty)
            consumed += 1
            return true
        }))
        XCTAssertEqual(reopened.startBinding(), .continue)
        let request = try XCTUnwrap(reopened.wire.bindingFrames.first)
        XCTAssertEqual(request.localName, "resume")
        XCTAssertEqual(request.uri, Self.namespace)
        XCTAssertEqual(request.attributeStringValue(forName: "previd"), Self.resumptionID)
        XCTAssertEqual(request.attributeStringValue(forName: "h"), "2")
        XCTAssertEqual(consumed, 1)
        XCTAssertEqual(reopened.wire.myJID?.full, Self.configuredJID)

        XCTAssertEqual(reopened.receiveBindReply(smFrame("resumed", h: 1, previd: Self.resumptionID)), .success)
        XCTAssertTrue(reopened.module.didResumeFromCheckpoint)
        XCTAssertEqual(reopened.wire.myJID?.full, Self.originalJID)
    }

    func testUnacknowledgedOutboundStanzaPreventsCheckpoint() throws {
        let session = Harness(jid: Self.originalJID)
        let recorded = session.captureCheckpoints()
        try session.enable()
        session.event("xmppStream:didSendMessage:", XMPPMessage(messageType: .chat, to: nil, elementID: "pending"))

        session.disconnect()
        session.queue.sync {}

        XCTAssertTrue(recorded.values.isEmpty)
    }

    func testAcknowledgementBeyondTheSentCountPreventsCheckpoint() throws {
        let session = Harness(jid: Self.originalJID)
        let recorded = session.captureCheckpoints()
        try session.enable()
        session.event("xmppStream:didSendMessage:", XMPPMessage(messageType: .chat, to: nil, elementID: "pending"))
        session.event("xmppStream:didReceiveCustomElement:", smFrame("a", h: 2))

        session.disconnect()
        session.queue.sync {}

        XCTAssertTrue(recorded.values.isEmpty)
    }

    func testCheckpointDoesNotAdvertiseAnInboundStanzaAwaitingDurableHandling() throws {
        let session = Harness(jid: Self.originalJID)
        let recorded = session.captureCheckpoints()
        let inspected = expectation(description: "stream management asks whether the inbound stanza is durable")
        let pending = PendingInbound(inspected: inspected)
        session.module.addDelegate(pending, delegateQueue: session.queue)
        try session.enable()

        session.event("xmppStream:didReceiveMessage:", XMPPMessage(messageType: .chat, to: nil, elementID: "waiting"))
        wait(for: [inspected], timeout: 2)
        session.event("xmppStream:didReceiveCustomElement:", smFrame("r"))
        XCTAssertEqual(session.wire.streamFrames.last?.attributeStringValue(forName: "h"), "0")
        session.disconnect()
        session.queue.sync {}

        // A classification still in flight can prevent exporting a checkpoint.
        // If a checkpoint is eligible, the pending stanza must remain replayable.
        XCTAssertTrue(recorded.values.allSatisfy { $0.lastHandledByClient == 0 })
        withExtendedLifetime(pending) {}
    }

    func testCounterWrapAfterColdResumeStillProducesACoherentCheckpoint() throws {
        let session = Harness()
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(serverHandled: UInt32.max), consume: { true }))
        XCTAssertEqual(session.startBinding(), .continue)
        XCTAssertEqual(session.receiveBindReply(smFrame("resumed", h: UInt32.max, previd: Self.resumptionID)), .success)
        let recorded = session.captureCheckpoints()
        session.event("xmppStream:didSendMessage:", XMPPMessage(messageType: .chat, to: nil, elementID: "wrapped"))
        session.event("xmppStream:didReceiveCustomElement:", smFrame("a", h: 0))

        session.disconnect()
        session.queue.sync {}

        let saved = try XCTUnwrap(recorded.values.first)
        XCTAssertEqual(saved.lastHandledByServer, 0)
        XCTAssertEqual(saved.lastHandledByClient, 13)
    }

    func testTransientFailureBeforeBindingPreservesCheckpointAndBothCounters() {
        let session = Harness()
        var consumed = 0
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: {
            consumed += 1
            return true
        }))

        session.disconnect()

        XCTAssertEqual(consumed, 0)
        XCTAssertEqual(session.startBinding(), .continue)
        XCTAssertEqual(session.wire.bindingFrames.last?.attributeStringValue(forName: "h"), "13")
        XCTAssertEqual(consumed, 1)
        XCTAssertEqual(session.receiveBindReply(smFrame("resumed", h: 27, previd: Self.resumptionID)), .success)
    }

    func testRetryCanRestageCheckpointWithTheCurrentStoreClaim() {
        let session = Harness()
        let candidate = checkpoint()
        XCTAssertTrue(session.module.restoreResumeCheckpoint(candidate, consume: {
            XCTFail("The first attempt's claim no longer owns the durable record")
            return false
        }))
        session.disconnect()
        var consumed = 0
        XCTAssertTrue(session.module.restoreResumeCheckpoint(candidate, consume: {
            consumed += 1
            return true
        }))

        XCTAssertEqual(session.startBinding(), .continue)
        XCTAssertEqual(session.wire.bindingFrames.last?.attributeStringValue(forName: "h"), "13")
        XCTAssertEqual(consumed, 1)
    }

    func testRejectedColdResumeFallsBackAndLeavesTheConfiguredResource() {
        let session = Harness()
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: { true }))
        XCTAssertEqual(session.startBinding(), .continue)

        let failure = smFrame("failed", h: 27)
        failure.addChild(DDXMLElement(name: "item-not-found", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        XCTAssertEqual(session.receiveBindReply(failure), .failFallback)

        XCTAssertFalse(session.module.didResumeFromCheckpoint)
        XCTAssertEqual(session.wire.myJID?.full, Self.configuredJID)
        session.disconnect()
        XCTAssertEqual(session.startBinding(), .failFallback)
        XCTAssertEqual(session.wire.bindingFrames.count, 1)
    }

    func testColdResumeWithMismatchedServerCounterAbortsBinding() {
        let session = Harness()
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: { true }))
        XCTAssertEqual(session.startBinding(), .continue)

        XCTAssertEqual(session.receiveBindReply(smFrame("resumed", h: 28, previd: Self.resumptionID)), .failAbort)

        XCTAssertFalse(session.module.didResumeFromCheckpoint)
        XCTAssertEqual(session.wire.myJID?.full, Self.configuredJID)
    }

    func testExpiredCheckpointFallsBackWithoutSendingResume() {
        let session = Harness()
        let expired = checkpoint(disconnect: Date(timeIntervalSinceNow: -3601))
        XCTAssertFalse(session.module.restoreResumeCheckpoint(expired, consume: {
            XCTFail("An expired checkpoint must not enter the binding attempt")
            return true
        }))

        XCTAssertEqual(session.startBinding(), .failFallback)
        XCTAssertTrue(session.wire.bindingFrames.isEmpty)
    }

    func testServerWithoutStreamManagementConsumesCheckpointAndUsesNormalBinding() {
        let session = Harness()
        session.wire.advertisesSM = false
        var consumed = 0
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: {
            consumed += 1
            return true
        }))

        XCTAssertEqual(session.startBinding(), .failFallback)
        XCTAssertEqual(consumed, 1)
        XCTAssertTrue(session.wire.bindingFrames.isEmpty)
    }

    func testCheckpointRemovalFailureAbortsBeforeSendingResume() {
        let session = Harness()
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: { false }))

        XCTAssertEqual(session.startBinding(), .failAbort)
        XCTAssertTrue(session.wire.bindingFrames.isEmpty)
    }

    func testInsecureConnectionNeverSendsThePersistedResumeToken() {
        let session = Harness()
        session.wire.secureTransport = false
        XCTAssertTrue(session.module.restoreResumeCheckpoint(checkpoint(), consume: { true }))

        XCTAssertEqual(session.startBinding(), .failFallback)
        XCTAssertTrue(session.wire.bindingFrames.isEmpty)
    }

    func testFailedResumeDoesNotReuseTheRejectedSessionOnTheNextConnection() {
        let session = Harness()
        session.queue.sync {
            session.storage.setResumptionId(Self.resumptionID, timeout: 3600, lastDisconnect: Date(), for: session.wire)
            session.storage.setLastDisconnect(Date(), lastHandledByClient: 13, lastHandledByServer: 27,
                pendingOutgoingStanzas: nil, for: session.wire)
        }
        XCTAssertEqual(session.startBinding(), .continue)
        XCTAssertEqual(session.wire.bindingFrames.last?.attributeStringValue(forName: "h"), "13")

        let failure = smFrame("failed", h: 27)
        failure.addChild(DDXMLElement(name: "item-not-found", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        XCTAssertEqual(session.receiveBindReply(failure), .failFallback)
        session.disconnect()

        XCTAssertEqual(session.startBinding(), .failFallback)
        XCTAssertEqual(session.wire.bindingFrames.count, 1)
    }
}
