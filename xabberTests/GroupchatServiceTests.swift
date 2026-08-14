import XCTest
import XMPPFramework
@testable import xabber

final class GroupchatServiceTests: XCTestCase {
    private let groupJID = "stage@example.com"

    func testCreateRegistersBeforeSendAndReturnsTypedSnapshot() async throws {
        let scheduler = ServiceManualTimeoutScheduler()
        var service: GroupchatService!
        var pendingCountInsideSend = 0
        service = GroupchatService(
            defaultTimeout: 10,
            timeoutScheduler: scheduler,
            requestIDProvider: { "create-1" }
        )
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ transport element")
            }
            pendingCountInsideSend = service.pendingRequestCount
            XCTAssertEqual(iq.type, "set")
            XCTAssertEqual(iq.to?.bare, "groups.example.com")
            XCTAssertEqual(iq.elementID, "create-1")
            XCTAssertEqual(iq.childElement?.name, "create")
            XCTAssertEqual(iq.childElement?.xmlns(), GroupProtocolNamespace.groups)

            let response = XMPPIQ(
                iqType: .result,
                elementID: iq.elementID,
                child: try? GroupProtocolCodec.encodeGroupSnapshot(
                    GroupSnapshot(
                        jid: self.groupJID,
                        privacy: .publicGroup,
                        info: GroupInfo(name: "Stage")
                    )
                )
            )
            self.assertReceive(response, by: service)
        }

        let snapshot = try await service.create(
            serviceJID: "Groups.Example.com/Service",
            snapshot: GroupSnapshot(
                privacy: .publicGroup,
                info: GroupInfo(name: "Stage")
            )
        )

        XCTAssertEqual(pendingCountInsideSend, 1)
        XCTAssertEqual(snapshot.jid, groupJID)
        XCTAssertEqual(snapshot.info?.name, "Stage")
        XCTAssertEqual(service.pendingRequestCount, 0)
        XCTAssertEqual(scheduler.pendingActionCount, 0)
    }

    func testCreateP2PUsesParentServiceAndPreservesTypedConflictPayload() async {
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { "p2p-1" })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ transport element")
            }
            XCTAssertEqual(iq.type, "set")
            XCTAssertEqual(iq.to?.bare, "groups.example.com")
            XCTAssertEqual(
                (iq.childElement as? DDXMLElement)?
                    .element(forName: "peer-to-peer")?
                    .attributeStringValue(forName: "parent"),
                "parent@groups.example.com"
            )

            do {
                let response = try self.iq("""
                <iq type='error' id='p2p-1'>
                  <group xmlns='https://xabber.com/protocol/groups'
                         jid='existing@groups.example.com'/>
                  <error type='cancel'>
                    <conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
                    <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Already exists</text>
                  </error>
                </iq>
                """)
                XCTAssertTrue(try service.receive(response))
            } catch {
                XCTFail("Could not route conflict response: \(error)")
            }
        }

        do {
            _ = try await service.createP2P(
                parentJID: "Parent@Groups.Example.com/Group",
                memberID: "member-7"
            )
            XCTFail("Expected typed IQ failure")
        } catch let GroupchatServiceError.iq(error) {
            XCTAssertEqual(error.type, "cancel")
            XCTAssertEqual(error.condition, "conflict")
            XCTAssertEqual(error.text, "Already exists")
            guard case let .snapshot(snapshot)? = error.payload else {
                return XCTFail("Expected existing group snapshot")
            }
            XCTAssertEqual(snapshot.jid, "existing@groups.example.com")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSuccessfulP2PCreateStartsOrdinaryJoinHandshake() async throws {
        let transport = ServiceRecordingTransport()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { "p2p-create" })
        service.prepare(transport.send)
        transport.onSend = { iq in
            let snapshot = try! GroupProtocolCodec.encodeGroupSnapshot(
                GroupSnapshot(jid: "direct@Groups.Example.com", parentJID: self.groupJID)
            )
            self.assertReceive(
                XMPPIQ(iqType: .result, elementID: iq.elementID, child: snapshot),
                by: service
            )
        }

        let snapshot = try await service.createP2P(
            parentJID: groupJID,
            memberID: "member-7"
        )

        XCTAssertEqual(snapshot.jid, "direct@groups.example.com")
        let elements = transport.elementSnapshot
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual((elements[0] as? XMPPIQ)?.childElement?.name, "create")
        XCTAssertEqual((elements[1] as? XMPPPresence)?.type, "subscribe")
        XCTAssertEqual(elements[1].to?.bare, "direct@groups.example.com")
    }

    func testRefreshGroupAndMembersUseCanonicalGETAndReturnTypedPayloads() async throws {
        var requestIDs = ["details-1", "members-1"].makeIterator()
        var sentNames: [String] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ,
                  let child = iq.childElement as? DDXMLElement else {
                return XCTFail("Expected IQ with command child")
            }
            sentNames.append(child.name ?? "")
            XCTAssertEqual(iq.type, "get")
            XCTAssertEqual(iq.to?.bare, self.groupJID)

            let payload: DDXMLElement
            switch child.name {
            case "query":
                payload = try! GroupProtocolCodec.encodeGroupSnapshot(
                    GroupSnapshot(jid: self.groupJID, info: GroupInfo(name: "Stage"))
                )
            case "members":
                XCTAssertNil(child.attribute(forName: "version"))
                payload = try! GroupProtocolCodec.encodeFullMembers([
                    GroupMember(id: "member-1", nickname: "Romeo"),
                    GroupMember(id: "member-2", nickname: "Juliet")
                ])
            default:
                return XCTFail("Unexpected command \(child.name ?? "nil")")
            }
            let response = XMPPIQ(iqType: .result, elementID: iq.elementID, child: payload)
            self.assertReceive(response, by: service)
        }

        let snapshot = try await service.refreshGroup(groupJID: groupJID)
        let members = try await service.refreshMembers(groupJID: groupJID)

        XCTAssertEqual(sentNames, ["query", "members"])
        XCTAssertEqual(snapshot.info?.name, "Stage")
        XCTAssertEqual(members.map(\.id), ["member-1", "member-2"])
    }

    func testMutationCommandsUseCanonicalSETShapesAndBareDestinations() async throws {
        var nextID = 0
        var sent: [XMPPIQ] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: {
            nextID += 1
            return "mutation-\(nextID)"
        })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            sent.append(iq)
            let response: XMPPIQ
            if iq.type == "get" {
                let payload: DDXMLElement
                switch iq.childElement?.name {
                case "query":
                    payload = try! GroupProtocolCodec.encodeGroupSnapshot(
                        GroupSnapshot(jid: self.groupJID, pinnedMessageIDs: [])
                    )
                case "invites":
                    payload = DDXMLElement(
                        name: "invites",
                        xmlns: GroupProtocolNamespace.groups
                    )
                case "block":
                    payload = DDXMLElement(
                        name: "block",
                        xmlns: GroupProtocolNamespace.groups
                    )
                case "members":
                    payload = try! GroupProtocolCodec.encodeFullMembers([])
                default:
                    return XCTFail("Unexpected refresh \(iq.childElement?.name ?? "nil")")
                }
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: payload
                )
            } else {
                response = XMPPIQ(iqType: .result, elementID: iq.elementID)
            }
            self.assertReceive(response, by: service)
        }

        try await service.delete(groupJID: "Stage@Example.com/Group")
        _ = try await service.pin(groupJID: groupJID, groupStanzaID: "stanza-1")
        _ = try await service.unpin(groupJID: groupJID, groupStanzaID: "stanza-1")
        _ = try await service.invite(
            groupJID: groupJID,
            targetJID: "Juliet@Example.com/Balcony",
            send: true,
            reason: "Join"
        )
        try await service.declineInvite(groupJID: groupJID)
        _ = try await service.block(
            groupJID: groupJID,
            targets: ["Juliet@Example.com/Balcony", "blocked.example.com"]
        )
        _ = try await service.kickMember(
            groupJID: groupJID,
            member: GroupMember(
                id: "member-7",
                jid: "Juliet@Example.com/Balcony",
                role: .member
            )
        )

        let mutations = sent.filter { $0.type == "set" }
        XCTAssertEqual(mutations.count, 7)
        XCTAssertEqual(mutations.map { $0.to?.bare }, [
            "example.com",
            groupJID,
            groupJID,
            groupJID,
            groupJID,
            groupJID,
            groupJID
        ])
        XCTAssertEqual(mutations.compactMap { $0.childElement?.name }, [
            "delete", "pinned-message", "pinned-message", "invite", "decline", "block", "kick"
        ])
        XCTAssertEqual(
            (mutations[2].childElement as? DDXMLElement)?
                .attributeStringValue(forName: "status"),
            "remove"
        )
        XCTAssertEqual(
            (mutations[3].childElement as? DDXMLElement)?
                .element(forName: "jid")?.stringValue,
            "juliet@example.com"
        )
    }

    func testSetPermissionsWaitsForSETResultThenRefreshesWithGET() async throws {
        let setSent = expectation(description: "permission SET sent")
        let getSent = expectation(description: "permission GET sent")
        var requestIDs = ["permission-set", "permission-get"].makeIterator()
        let transport = ServiceRecordingTransport()
        let service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare(transport.send)
        transport.onSend = { iq in
            if iq.type == "set" {
                setSent.fulfill()
            } else if iq.type == "get" {
                getSent.fulfill()
            }
        }
        let changes = GroupPermissionSet(
            scope: .direct,
            target: "member-7",
            permissions: [
                GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: false,
                    seconds: 60
                )
            ]
        )

        let task = Task {
            try await service.setPermissions(groupJID: groupJID, permissions: changes)
        }
        await fulfillment(of: [setSent], timeout: 1)
        XCTAssertEqual(transport.snapshot.count, 1)
        let setIQ = try XCTUnwrap(transport.snapshot.first)
        XCTAssertEqual(setIQ.type, "set")
        XCTAssertEqual(setIQ.childElement?.name, "permissions")
        XCTAssertEqual(
            (setIQ.childElement as? DDXMLElement)?
                .element(forName: "permission")?
                .attributeStringValue(forName: "seconds"),
            "60"
        )
        XCTAssertNil(
            (setIQ.childElement as? DDXMLElement)?
                .element(forName: "permission")?
                .attribute(forName: "expires")
        )

        XCTAssertTrue(try service.receive(
            XMPPIQ(iqType: .result, elementID: setIQ.elementID)
        ))
        await fulfillment(of: [getSent], timeout: 1)
        XCTAssertEqual(transport.snapshot.count, 2)
        let getIQ = transport.snapshot[1]
        XCTAssertEqual(getIQ.type, "get")
        XCTAssertEqual(getIQ.childElement?.name, "permissions")
        XCTAssertEqual(
            (getIQ.childElement as? DDXMLElement)?
                .attributeStringValue(forName: "target"),
            "member-7"
        )

        let refreshed = GroupPermissionSet(
            scope: .direct,
            target: "member-7",
            label: "member",
            permissions: [
                GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: false,
                    expires: 1_770_000_000
                )
            ]
        )
        let refreshedElement = try GroupProtocolCodec.encodePermissionSet(refreshed)
        XCTAssertTrue(try service.receive(
            XMPPIQ(iqType: .result, elementID: getIQ.elementID, child: refreshedElement)
        ))

        let result = try await task.value
        XCTAssertEqual(result, refreshed)
    }

    func testPermissionSETErrorDoesNotStartRefresh() async {
        let sent = expectation(description: "permission SET sent")
        let transport = ServiceRecordingTransport()
        let service = GroupchatService(requestIDProvider: { "permission-set" })
        service.prepare(transport.send)
        transport.onSend = { _ in sent.fulfill() }
        let task = Task {
            try await service.setPermissions(
                groupJID: self.groupJID,
                permissions: GroupPermissionSet(
                    scope: .newbies,
                    permissions: [
                        GroupPermission(name: "send-messages", status: false)
                    ]
                )
            )
        }
        await fulfillment(of: [sent], timeout: 1)

        do {
            let response = try iq("""
            <iq type='error' id='permission-set'>
              <error type='auth'>
                <not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
              </error>
            </iq>
            """)
            XCTAssertTrue(try service.receive(response))
            _ = try await task.value
            XCTFail("Expected permission SET failure")
        } catch let GroupchatServiceError.iq(error) {
            XCTAssertEqual(error.condition, "not-allowed")
            XCTAssertEqual(transport.snapshot.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPermissionResetHelpersSendCanonicalSETThenAuthoritativeGET() async throws {
        var requestIDs = [
            "defaults-reset-set", "defaults-reset-get",
            "personal-reset-set", "personal-reset-get",
            "newbies-reset-set", "newbies-reset-get"
        ].makeIterator()
        var sent: [XMPPIQ] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            sent.append(iq)
            if iq.type == "set" {
                self.assertReceive(
                    XMPPIQ(iqType: .result, elementID: iq.elementID),
                    by: service
                )
                return
            }

            let payload: DDXMLElement
            switch iq.childElement?.name {
            case "defaults":
                payload = try! GroupProtocolCodec.encodePermissionSet(
                    GroupPermissionResetMutationBuilder.defaults()
                )
            case "permissions":
                payload = try! GroupProtocolCodec.encodePermissionSet(
                    GroupPermissionResetMutationBuilder.personal(
                        targetMemberID: "member-7",
                        baseline: GroupPermissionResetMutationBuilder.adminBaseline
                    )
                )
            case "newbies":
                payload = try! GroupProtocolCodec.encodePermissionSet(
                    GroupPermissionResetMutationBuilder.newbies()
                )
            default:
                return XCTFail("Unexpected permission refresh")
            }
            self.assertReceive(
                XMPPIQ(iqType: .result, elementID: iq.elementID, child: payload),
                by: service
            )
        }

        let defaults = try await service.resetDefaultPermissions(groupJID: groupJID)
        let personal = try await service.resetPersonalPermissions(
            groupJID: groupJID,
            targetMemberID: "member-7",
            baseline: GroupPermissionResetMutationBuilder.adminBaseline
        )
        let newbies = try await service.resetNewbiesPermissions(groupJID: groupJID)

        XCTAssertEqual(defaults, GroupPermissionResetMutationBuilder.defaults())
        XCTAssertEqual(
            personal,
            GroupPermissionResetMutationBuilder.personal(
                targetMemberID: "member-7",
                baseline: GroupPermissionResetMutationBuilder.adminBaseline
            )
        )
        XCTAssertEqual(newbies, GroupPermissionResetMutationBuilder.newbies())
        XCTAssertEqual(sent.map { "\($0.type ?? ""): \($0.childElement?.name ?? "")" }, [
            "set: defaults", "get: defaults",
            "set: permissions", "get: permissions",
            "set: newbies", "get: newbies"
        ])
        XCTAssertTrue(sent.filter { $0.type == "set" }.allSatisfy {
            $0.childElement?.name != "delete"
        })
        XCTAssertEqual(
            (sent[4].childElement as? DDXMLElement)?
                .element(forName: "permissions")?.childCount,
            0
        )
    }

    func testDisconnectCancelsPendingExactlyOnceAndRemovesTransport() async {
        let sent = expectation(description: "request sent")
        let scheduler = ServiceManualTimeoutScheduler()
        let transport = ServiceRecordingTransport()
        let service = GroupchatService(
            defaultTimeout: 5,
            timeoutScheduler: scheduler,
            requestIDProvider: { "delete-1" }
        )
        service.prepare(transport.send)
        transport.onSend = { _ in sent.fulfill() }
        let task = Task { try await service.delete(groupJID: self.groupJID) }
        await fulfillment(of: [sent], timeout: 1)

        XCTAssertEqual(service.disconnect(), 1)
        XCTAssertEqual(service.disconnect(), 0)
        do {
            try await task.value
            XCTFail("Expected disconnect error")
        } catch let error as GroupRequestError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let late = XMPPIQ(iqType: .result, elementID: "delete-1")
        assertReceive(late, by: service, expected: false)
        scheduler.advance(by: 100)
        XCTAssertEqual(service.pendingRequestCount, 0)

        do {
            try await service.delete(groupJID: groupJID)
            XCTFail("Expected unprepared error")
        } catch let error as GroupchatServiceError {
            XCTAssertEqual(error, .notPrepared)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutAndLateResponseCompleteRequestOnlyOnce() async {
        let sent = expectation(description: "request sent")
        let scheduler = ServiceManualTimeoutScheduler()
        let service = GroupchatService(
            defaultTimeout: 5,
            timeoutScheduler: scheduler,
            requestIDProvider: { "members-timeout" }
        )
        service.prepare { _ in sent.fulfill() }
        let task = Task { try await service.refreshMembers(groupJID: self.groupJID) }
        await fulfillment(of: [sent], timeout: 1)

        scheduler.advance(by: 5)
        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as GroupRequestError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let payload = try! GroupProtocolCodec.encodeFullMembers([])
        assertReceive(
            XMPPIQ(iqType: .result, elementID: "members-timeout", child: payload),
            by: service,
            expected: false
        )
        XCTAssertEqual(service.pendingRequestCount, 0)
    }

    func testMalformedCorrelatedIQCompletesImmediatelyWithTypedDecodeError() async {
        let sent = expectation(description: "request sent")
        let scheduler = ServiceManualTimeoutScheduler()
        let transport = ServiceRecordingTransport()
        let service = GroupchatService(
            defaultTimeout: 30,
            timeoutScheduler: scheduler,
            requestIDProvider: { "malformed-details" }
        )
        service.prepare(transport.send)
        transport.onSend = { _ in sent.fulfill() }
        let task = Task {
            try await service.refreshGroup(groupJID: self.groupJID)
        }
        await fulfillment(of: [sent], timeout: 1)

        do {
            let malformed = try iq("""
            <iq type='result' id='malformed-details'>
              <group xmlns='https://xabber.com/protocol/groups'
                     jid='first@example.com'/>
              <group xmlns='https://xabber.com/protocol/groups'
                     jid='second@example.com'/>
            </iq>
            """)
            XCTAssertTrue(try service.receive(malformed))
            _ = try await task.value
            XCTFail("Expected typed response decoding failure")
        } catch let GroupchatServiceError.responseDecoding(error) {
            guard case let .router(.ambiguousEnvelope(reason)) = error else {
                return XCTFail("Expected ambiguous router envelope, got \(error)")
            }
            XCTAssertEqual(reason, "IQ contains multiple canonical group payloads")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.pendingRequestCount, 0)
        XCTAssertEqual(scheduler.pendingActionCount, 0)
    }

    func testTaskCancellationRemovesPendingRequestAndIgnoresLateResponse() async {
        let sent = expectation(description: "request sent")
        let scheduler = ServiceManualTimeoutScheduler()
        let transport = ServiceRecordingTransport()
        let service = GroupchatService(
            defaultTimeout: 30,
            timeoutScheduler: scheduler,
            requestIDProvider: { "cancelled-members" }
        )
        service.prepare(transport.send)
        transport.onSend = { _ in sent.fulfill() }
        let task = Task {
            try await service.refreshMembers(groupJID: self.groupJID)
        }
        await fulfillment(of: [sent], timeout: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected structured cancellation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(service.pendingRequestCount, 0)
        XCTAssertEqual(scheduler.pendingActionCount, 0)

        let members = try! GroupProtocolCodec.encodeFullMembers([])
        assertReceive(
            XMPPIQ(
                iqType: .result,
                elementID: "cancelled-members",
                child: members
            ),
            by: service,
            expected: false
        )
        scheduler.advance(by: 100)
        XCTAssertEqual(service.pendingRequestCount, 0)
    }

    func testReplacementTransportRequestSurvivesOldGenerationDisconnect() async throws {
        let oldSent = expectation(description: "old request sent")
        let newSent = expectation(description: "new request sent")
        var requestIDs = ["old-members", "new-members"].makeIterator()
        let scheduler = ServiceManualTimeoutScheduler()
        let oldTransport = ServiceRecordingTransport()
        let newTransport = ServiceRecordingTransport()
        let service = GroupchatService(
            defaultTimeout: 30,
            timeoutScheduler: scheduler,
            requestIDProvider: { requestIDs.next()! }
        )
        service.prepare(oldTransport.send)
        oldTransport.onSend = { _ in oldSent.fulfill() }
        let oldTask = Task {
            try await service.refreshMembers(groupJID: self.groupJID)
        }
        await fulfillment(of: [oldSent], timeout: 1)

        service.prepare(newTransport.send)
        newTransport.onSend = { _ in newSent.fulfill() }
        let newTask = Task {
            try await service.refreshMembers(groupJID: self.groupJID)
        }
        await fulfillment(of: [newSent], timeout: 1)

        do {
            _ = try await oldTask.value
            XCTFail("Expected old generation disconnect")
        } catch let error as GroupRequestError {
            XCTAssertEqual(error, .disconnected)
        }
        XCTAssertEqual(service.pendingRequestCount, 1)

        let newIQ = try XCTUnwrap(newTransport.snapshot.first)
        let members = try GroupProtocolCodec.encodeFullMembers([
            GroupMember(id: "member-new", nickname: "New")
        ])
        XCTAssertTrue(try service.receive(
            XMPPIQ(iqType: .result, elementID: newIQ.elementID, child: members)
        ))
        let newMembers = try await newTask.value
        XCTAssertEqual(newMembers.map(\.id), ["member-new"])
        XCTAssertEqual(service.pendingRequestCount, 0)
    }

    func testSendOnlyMembershipAndChatPresenceUseCanonicalBareGroupAddress() throws {
        let transport = ServiceRecordingTransport()
        let service = GroupchatService()
        service.prepare(transport.send)

        try service.sendJoin(groupJID: "Stage@Example.com/Group")
        try service.sendJoinApproval(groupJID: "Stage@Example.com/Group")
        try service.sendLeave(groupJID: "Stage@Example.com/Group")
        try service.sendPresenceReply(
            groupJID: "Stage@Example.com/Group",
            reply: .unsubscribed
        )
        try service.sendChatPresence(groupJID: "Stage@Example.com/Group", state: .active)
        try service.sendChatPresence(groupJID: "Stage@Example.com/Group", state: .inactive)
        try service.sendChatPresence(groupJID: "Stage@Example.com/Group", state: .gone)

        let elements = transport.elementSnapshot
        XCTAssertEqual(elements.count, 7)
        XCTAssertEqual((elements[0] as? XMPPPresence)?.type, "subscribe")
        XCTAssertEqual((elements[1] as? XMPPPresence)?.type, "subscribed")
        XCTAssertEqual((elements[2] as? XMPPPresence)?.type, "unsubscribe")
        XCTAssertEqual((elements[3] as? XMPPPresence)?.type, "unsubscribed")
        XCTAssertEqual(elements.map { $0.to?.bare }, Array(repeating: groupJID, count: 7))
        XCTAssertEqual((elements[4] as? XMPPMessage)?.type, "chat")
        XCTAssertNotNil(
            elements[4].element(
                forName: "active",
                xmlns: "http://jabber.org/protocol/chatstates"
            )
        )
        XCTAssertNotNil(
            elements[5].element(
                forName: "inactive",
                xmlns: "http://jabber.org/protocol/chatstates"
            )
        )
        XCTAssertNotNil(
            elements[6].element(
                forName: "gone",
                xmlns: "http://jabber.org/protocol/chatstates"
            )
        )
        XCTAssertNil(elements[3].element(forName: "x"))
    }

    func testUnexpectedIQPayloadIsRejectedWithoutStringlyTypedFallback() async {
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { "details-1" })
        service.prepare { element in
            let iq = element as! XMPPIQ
            let members = try! GroupProtocolCodec.encodeFullMembers([])
            self.assertReceive(
                XMPPIQ(iqType: .result, elementID: iq.elementID, child: members),
                by: service
            )
        }

        do {
            _ = try await service.refreshGroup(groupJID: groupJID)
            XCTFail("Expected payload mismatch")
        } catch let error as GroupchatServiceError {
            XCTAssertEqual(
                error,
                .unexpectedPayload(expected: .snapshot, actual: .members)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshInvitesAndBlocklistReturnTypedCanonicalLists() async throws {
        var requestIDs = ["invites-1", "block-1"].makeIterator()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            XCTAssertEqual(iq.type, "get")
            XCTAssertEqual(iq.to?.bare, self.groupJID)
            let payload: DDXMLElement
            if iq.childElement?.name == "invites" {
                payload = try! DDXMLElement(xmlString: """
                    <invites xmlns='https://xabber.com/protocol/groups'>
                      <jid>Juliet@Example.COM/Balcony</jid>
                    </invites>
                    """)
            } else {
                payload = try! DDXMLElement(xmlString: """
                    <block xmlns='https://xabber.com/protocol/groups'>
                      <jid>Tybalt@Example.COM/Sword</jid>
                      <jid>Spam.Example.COM</jid>
                    </block>
                    """)
            }
            self.assertReceive(
                XMPPIQ(iqType: .result, elementID: iq.elementID, child: payload),
                by: service
            )
        }

        let invites = try await service.refreshInvites(groupJID: groupJID)
        let blocklist = try await service.refreshBlocklist(groupJID: groupJID)
        XCTAssertEqual(invites, ["juliet@example.com"])
        XCTAssertEqual(blocklist, ["tybalt@example.com", "spam.example.com"])
    }

    func testInfoAndSettingsMutationWaitForResultBeforeAuthoritativeGET() async throws {
        var requestIDs = [
            "info-set", "info-get", "settings-set", "settings-get"
        ].makeIterator()
        var sent: [XMPPIQ] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            sent.append(iq)
            let child: DDXMLElement
            switch (iq.type, iq.childElement?.name) {
            case ("set", "info"):
                XCTAssertEqual(
                    (iq.childElement as? DDXMLElement)?
                        .element(forName: "name")?.stringValue,
                    "New stage"
                )
                child = try! GroupProtocolCodec.encodeInfo(
                    GroupInfo(name: "New stage")
                )
            case ("get", "info"):
                child = try! GroupProtocolCodec.encodeInfo(
                    GroupInfo(name: "New stage", description: "Authoritative")
                )
            case ("set", "settings"):
                child = try! GroupProtocolCodec.encodeSettings(
                    GroupSettings(membership: .privateGroup)
                )
            case ("get", "settings"):
                child = try! GroupProtocolCodec.encodeSettings(
                    GroupSettings(
                        membership: .privateGroup,
                        contacts: [],
                        domains: [],
                        index: GroupIndexVisibility.none,
                        state: .active
                    )
                )
            default:
                return XCTFail("Unexpected command")
            }
            self.assertReceive(
                XMPPIQ(iqType: .result, elementID: iq.elementID, child: child),
                by: service
            )
        }

        let info = try await service.updateInfo(
            groupJID: groupJID,
            info: GroupInfo(name: "New stage")
        )
        let settings = try await service.updateSettings(
            groupJID: groupJID,
            settings: GroupSettings(membership: .privateGroup)
        )

        XCTAssertEqual(info.description, "Authoritative")
        XCTAssertEqual(settings.contacts, [])
        XCTAssertEqual(sent.map { "\($0.type ?? ""):\($0.childElement?.name ?? "")" }, [
            "set:info", "get:info", "set:settings", "get:settings"
        ])
    }

    func testMemberOwnerRevokeAndUnblockMutationsRefreshOnlyAfterSETResult() async throws {
        var requestIDs = [
            "member-set", "member-get", "owner-set", "owner-get",
            "revoke-set", "revoke-get", "unblock-set", "unblock-get"
        ].makeIterator()
        var sent: [XMPPIQ] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            sent.append(iq)
            let response: XMPPIQ
            if iq.type == "set" {
                response = XMPPIQ(iqType: .result, elementID: iq.elementID)
            } else {
                let payload: DDXMLElement
                switch iq.childElement?.name {
                case "members":
                    payload = try! GroupProtocolCodec.encodeFullMembers([
                        GroupMember(id: "member-7", nickname: "Juliet")
                    ])
                case "invites":
                    payload = DDXMLElement(
                        name: "invites",
                        xmlns: GroupProtocolNamespace.groups
                    )
                case "block":
                    payload = DDXMLElement(
                        name: "block",
                        xmlns: GroupProtocolNamespace.groups
                    )
                default:
                    return XCTFail("Unexpected refresh")
                }
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: payload
                )
            }
            self.assertReceive(response, by: service)
        }

        let updatedMembers = try await service.updateMember(
            groupJID: groupJID,
            update: GroupMemberUpdate(memberID: "member-7", nickname: "Juliet")
        )
        let ownerMembers = try await service.setOwner(
            groupJID: groupJID,
            memberID: "member-7"
        )
        let invites = try await service.revokeInvite(
            groupJID: groupJID,
            targetJID: "Juliet@Example.com/Balcony"
        )
        let blocklist = try await service.unblock(
            groupJID: groupJID,
            target: "Blocked.Example.com"
        )
        XCTAssertEqual(updatedMembers.map(\.id), ["member-7"])
        XCTAssertEqual(ownerMembers.map(\.id), ["member-7"])
        XCTAssertEqual(invites, [])
        XCTAssertEqual(blocklist, [])

        XCTAssertEqual(sent.map { "\($0.type ?? ""):\($0.childElement?.name ?? "")" }, [
            "set:members", "get:members",
            "set:owner", "get:members",
            "set:revoke", "get:invites",
            "set:unblock", "get:block"
        ])
        XCTAssertEqual(
            (sent[0].childElement as? DDXMLElement)?
                .attributeStringValue(forName: "id"),
            "member-7"
        )
    }

    func testURLGroupAvatarMutationRejectsClearAndRefreshesAuthoritativeInfo() async throws {
        var requestIDs = ["avatar-set", "avatar-get"].makeIterator()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            let authoritative = GroupInfo(
                avatar: GroupAvatar(
                    id: "stored-id",
                    mediaType: "image/png",
                    bytes: 42,
                    url: "https://groups.example.com/stored.png"
                )
            )
            let responseInfo: GroupInfo
            if iq.type == "set" {
                let metadata = (iq.childElement as? DDXMLElement)?
                    .element(forName: "avatar")?
                    .element(forName: "info", xmlns: GroupProtocolNamespace.avatarMetadata)
                XCTAssertEqual(
                    metadata?.attributeStringValue(forName: "url"),
                    "https://media.example.com/upload.png"
                )
                responseInfo = GroupInfo(avatar: authoritative.avatar)
            } else {
                responseInfo = authoritative
            }
            self.assertReceive(
                XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: try! GroupProtocolCodec.encodeInfo(responseInfo)
                ),
                by: service
            )
        }

        let info = try await service.updateGroupAvatar(
            groupJID: groupJID,
            metadata: GroupAvatar(
                id: "upload-id",
                mediaType: "image/png",
                bytes: 42,
                url: "https://media.example.com/upload.png"
            )
        )
        XCTAssertEqual(info.avatar?.id, "stored-id")

        do {
            _ = try await service.updateGroupAvatar(
                groupJID: groupJID,
                metadata: GroupAvatar(
                    id: "upload-id",
                    mediaType: "image/png",
                    bytes: 42
                )
            )
            XCTFail("Expected URL-only avatar rejection")
        } catch let error as GroupCommandCodecError {
            XCTAssertEqual(error, .invalidAvatarURL(nil))
        }
    }

    func testURLMemberAvatarAcceptsTypedUserResultBeforeMembersRefresh() async throws {
        var requestIDs = ["member-avatar-set", "member-avatar-get"].makeIterator()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            let response: XMPPIQ
            if iq.type == "set" {
                let user = try! GroupProtocolCodec.encodeMemberUpdate(
                    GroupMemberUpdate(
                        memberID: "member-7",
                        avatar: GroupAvatar(
                            id: "stored-id",
                            mediaType: "image/png",
                            bytes: 42,
                            url: "https://groups.example.com/stored.png"
                        )
                    )
                ).element(forName: "user")!
                user.detach()
                user.setXmlns(GroupProtocolNamespace.groups)
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: user
                )
            } else {
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: try! GroupProtocolCodec.encodeFullMembers([
                        GroupMember(
                            id: "member-7",
                            nickname: "Juliet",
                            avatar: GroupAvatar(
                                id: "stored-id",
                                mediaType: "image/png",
                                bytes: 42,
                                url: "https://groups.example.com/stored.png"
                            )
                        )
                    ])
                )
            }
            self.assertReceive(response, by: service)
        }

        let members = try await service.updateMemberAvatar(
            groupJID: groupJID,
            memberID: "member-7",
            metadata: GroupAvatar(
                id: "upload-id",
                mediaType: "image/png",
                bytes: 42,
                url: "https://media.example.com/upload.png"
            )
        )
        XCTAssertEqual(members.first?.avatar?.id, "stored-id")
    }

    func testBlockMemberReportsTypedPartialFailureAfterBlockAndDemotion() async {
        var requestIDs = [
            "block-set", "demote-set", "demote-get", "kick-set",
            "block-refresh", "members-refresh"
        ].makeIterator()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ else {
                return XCTFail("Expected IQ")
            }
            let response: XMPPIQ
            switch iq.elementID {
            case "demote-get":
                let permissions = GroupPermissionSet(
                    scope: .direct,
                    target: "member-7",
                    label: "member",
                    permissions: [
                        GroupPermission(name: "create-admins", level: "admin", status: false)
                    ]
                )
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: try! GroupProtocolCodec.encodePermissionSet(permissions)
                )
            case "kick-set":
                response = try! self.iq("""
                <iq type='error' id='kick-set'>
                  <error type='cancel'>
                    <not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
                  </error>
                </iq>
                """)
            case "block-refresh":
                let block = DDXMLElement(
                    name: "block",
                    xmlns: GroupProtocolNamespace.groups
                )
                block.addChild(
                    DDXMLElement(name: "jid", stringValue: "juliet@example.com")
                )
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: block
                )
            case "members-refresh":
                response = XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: try! GroupProtocolCodec.encodeFullMembers([
                        GroupMember(id: "member-7", jid: "juliet@example.com")
                    ])
                )
            default:
                response = XMPPIQ(iqType: .result, elementID: iq.elementID)
            }
            self.assertReceive(response, by: service)
        }

        do {
            _ = try await service.blockMember(
                groupJID: groupJID,
                targetJID: "Juliet@Example.com/Balcony",
                demotionPermissions: GroupPermissionSet(
                    scope: .direct,
                    target: "member-7",
                    permissions: [
                        GroupPermission(name: "create-admins", level: "admin", status: false)
                    ]
                )
            )
            XCTFail("Expected partial kick failure")
        } catch let failure as GroupModerationPartialFailure {
            XCTAssertEqual(failure.failedStage, .kick)
            XCTAssertEqual(failure.completedStages, [.block, .demote])
            XCTAssertEqual(failure.blocklist, ["juliet@example.com"])
            XCTAssertEqual(failure.members?.map(\.id), ["member-7"])
            XCTAssertEqual(failure.refreshFailures, [])
            guard let serviceError = failure.underlying as? GroupchatServiceError,
                  case let .iq(iqError) = serviceError else {
                return XCTFail("Expected typed IQ cause")
            }
            XCTAssertEqual(iqError.condition, "not-allowed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKickMemberDemotesAdminBeforeKickAndReturnsAuthoritativeMembers() async throws {
        var requestIDs = [
            "baseline-get", "demote-set", "demote-refresh",
            "kick-set", "members-refresh"
        ].makeIterator()
        var sentIDs: [String] = []
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ,
                  let requestID = iq.elementID else {
                return XCTFail("Expected correlated IQ")
            }
            sentIDs.append(requestID)
            let response: XMPPIQ
            switch requestID {
            case "baseline-get":
                let baseline = GroupPermissionSet(
                    scope: .direct,
                    target: "member-7",
                    permissions: [
                        GroupPermission(
                            name: "create-admins",
                            level: "admin",
                            status: true
                        ),
                        GroupPermission(
                            name: "send-messages",
                            level: "member",
                            status: true
                        )
                    ]
                )
                response = XMPPIQ(
                    iqType: .result,
                    elementID: requestID,
                    child: try! GroupProtocolCodec.encodePermissionSet(baseline)
                )
            case "demote-set":
                XCTAssertEqual(iq.type, "set")
                XCTAssertEqual(iq.childElement?.name, "permissions")
                let permissions = try! GroupProtocolCodec.decodePermissionSet(
                    iq.childElement!
                )
                XCTAssertEqual(permissions.scope, .direct)
                XCTAssertEqual(permissions.target, "member-7")
                XCTAssertEqual(
                    permissions.permissions.first { $0.level == "admin" }?.status,
                    false
                )
                response = XMPPIQ(iqType: .result, elementID: requestID)
            case "demote-refresh":
                let demoted = GroupPermissionSet(
                    scope: .direct,
                    target: "member-7",
                    label: "member",
                    permissions: [
                        GroupPermission(
                            name: "create-admins",
                            level: "admin",
                            status: false
                        )
                    ]
                )
                response = XMPPIQ(
                    iqType: .result,
                    elementID: requestID,
                    child: try! GroupProtocolCodec.encodePermissionSet(demoted)
                )
            case "kick-set":
                XCTAssertEqual(iq.type, "set")
                XCTAssertEqual(iq.childElement?.name, "kick")
                response = XMPPIQ(iqType: .result, elementID: requestID)
            case "members-refresh":
                response = XMPPIQ(
                    iqType: .result,
                    elementID: requestID,
                    child: try! GroupProtocolCodec.encodeFullMembers([
                        GroupMember(id: "owner-1", role: .owner)
                    ])
                )
            default:
                return XCTFail("Unexpected request \(requestID)")
            }
            self.assertReceive(response, by: service)
        }

        let members = try await service.kickMember(
            groupJID: groupJID,
            member: GroupMember(
                id: "member-7",
                jid: "Juliet@Example.com/Balcony",
                role: .admin
            )
        )

        XCTAssertEqual(sentIDs, [
            "baseline-get", "demote-set", "demote-refresh",
            "kick-set", "members-refresh"
        ])
        XCTAssertEqual(members.map(\.id), ["owner-1"])
    }

    func testKickMemberReportsPartialFailureAndRefreshesMembersAfterAdminDemotion() async {
        var requestIDs = [
            "baseline-get", "demote-set", "demote-refresh",
            "kick-set", "members-refresh"
        ].makeIterator()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare { element in
            guard let iq = element as? XMPPIQ,
                  let requestID = iq.elementID else {
                return XCTFail("Expected correlated IQ")
            }
            let response: XMPPIQ
            switch requestID {
            case "baseline-get", "demote-refresh":
                let permissions = GroupPermissionSet(
                    scope: .direct,
                    target: "member-7",
                    permissions: [
                        GroupPermission(
                            name: "create-admins",
                            level: "admin",
                            status: requestID == "baseline-get"
                        )
                    ]
                )
                response = XMPPIQ(
                    iqType: .result,
                    elementID: requestID,
                    child: try! GroupProtocolCodec.encodePermissionSet(permissions)
                )
            case "demote-set":
                response = XMPPIQ(iqType: .result, elementID: requestID)
            case "kick-set":
                response = try! self.iq("""
                <iq type='error' id='kick-set'>
                  <error type='cancel'>
                    <not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
                  </error>
                </iq>
                """)
            case "members-refresh":
                response = XMPPIQ(
                    iqType: .result,
                    elementID: requestID,
                    child: try! GroupProtocolCodec.encodeFullMembers([
                        GroupMember(id: "member-7", role: .member)
                    ])
                )
            default:
                return XCTFail("Unexpected request \(requestID)")
            }
            self.assertReceive(response, by: service)
        }

        do {
            _ = try await service.kickMember(
                groupJID: groupJID,
                member: GroupMember(
                    id: "member-7",
                    jid: "juliet@example.com",
                    role: .admin
                )
            )
            XCTFail("Expected typed partial failure")
        } catch let failure as GroupModerationPartialFailure {
            XCTAssertEqual(failure.failedStage, .kick)
            XCTAssertEqual(failure.completedStages, [.demote])
            XCTAssertNil(failure.blocklist)
            XCTAssertEqual(failure.members?.map(\.role), [.member])
            XCTAssertEqual(failure.refreshFailures, [])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKickMemberRejectsAdminWithoutUsableDemotionBaselineBeforeKick() async {
        var requestIDs = ["baseline-get"].makeIterator()
        let transport = ServiceRecordingTransport()
        var service: GroupchatService!
        service = GroupchatService(requestIDProvider: { requestIDs.next()! })
        service.prepare(transport.send)
        transport.onSend = { iq in
            let baseline = GroupPermissionSet(
                scope: .direct,
                target: "member-7",
                permissions: [
                    GroupPermission(
                        name: "send-messages",
                        level: "member",
                        status: true
                    )
                ]
            )
            self.assertReceive(
                XMPPIQ(
                    iqType: .result,
                    elementID: iq.elementID,
                    child: try! GroupProtocolCodec.encodePermissionSet(baseline)
                ),
                by: service
            )
        }

        do {
            _ = try await service.kickMember(
                groupJID: groupJID,
                member: GroupMember(
                    id: "member-7",
                    jid: "juliet@example.com",
                    role: .admin
                )
            )
            XCTFail("Expected invalid demotion rejection")
        } catch let error as GroupchatServiceError {
            XCTAssertEqual(error, .invalidDemotionPermissions)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.elementSnapshot.count, 1)
        XCTAssertEqual((transport.elementSnapshot.first as? XMPPIQ)?.type, "get")
    }

    func testBlockMemberRejectsNonDirectOrStillAdminDemotionBeforeSending() async {
        let transport = ServiceRecordingTransport()
        let service = GroupchatService()
        service.prepare(transport.send)

        let invalidSets = [
            GroupPermissionSet(
                scope: .defaults,
                permissions: [
                    GroupPermission(name: "create-admins", level: "admin", status: false)
                ]
            ),
            GroupPermissionSet(
                scope: .direct,
                target: "member-7",
                permissions: [
                    GroupPermission(name: "create-admins", level: "admin", status: true)
                ]
            )
        ]

        for permissions in invalidSets {
            do {
                _ = try await service.blockMember(
                    groupJID: groupJID,
                    targetJID: "juliet@example.com",
                    demotionPermissions: permissions
                )
                XCTFail("Expected demotion validation error")
            } catch let error as GroupchatServiceError {
                XCTAssertEqual(error, .invalidDemotionPermissions)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            _ = try await service.blockMember(
                groupJID: groupJID,
                targetJID: ""
            )
            XCTFail("Expected target validation error")
        } catch is GroupCommandCodecError {
            // Expected local validation before the first mutation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.elementSnapshot.isEmpty)
    }
}

private extension GroupchatServiceTests {
    func assertReceive(
        _ iq: XMPPIQ,
        by service: GroupchatService,
        expected: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            XCTAssertEqual(
                try service.receive(iq),
                expected,
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Unexpected router error: \(error)",
                file: file,
                line: line
            )
        }
    }

    func iq(_ xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        return XMPPIQ(from: root)
    }
}

private final class ServiceRecordingTransport {
    private let lock = NSLock()
    private var elements: [XMPPElement] = []
    var onSend: ((XMPPIQ) -> Void)?

    var elementSnapshot: [XMPPElement] {
        lock.lock()
        defer { lock.unlock() }
        return elements
    }

    var snapshot: [XMPPIQ] {
        elementSnapshot.compactMap { $0 as? XMPPIQ }
    }

    func send(_ element: XMPPElement) {
        lock.lock()
        elements.append(element)
        lock.unlock()
        if let iq = element as? XMPPIQ {
            onSend?(iq)
        }
    }
}

private final class ServiceManualTimeoutScheduler: GroupRequestTimeoutScheduling {
    private struct ScheduledAction {
        let deadline: TimeInterval
        let token: Token
    }

    private final class Token: GroupRequestTimeoutCancellation {
        private let lock = NSLock()
        private let action: () -> Void
        private var cancelled = false
        private var completed = false

        init(action: @escaping () -> Void) {
            self.action = action
        }

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancelled && !completed
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func runIfPending() {
            lock.lock()
            guard !cancelled, !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            action()
        }
    }

    private var now: TimeInterval = 0
    private var scheduledActions: [ScheduledAction] = []

    var pendingActionCount: Int {
        scheduledActions.reduce(into: 0) { count, scheduledAction in
            if scheduledAction.token.isPending {
                count += 1
            }
        }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> GroupRequestTimeoutCancellation {
        let token = Token(action: action)
        scheduledActions.append(
            ScheduledAction(deadline: now + delay, token: token)
        )
        return token
    }

    func advance(by interval: TimeInterval) {
        now += interval
        scheduledActions
            .filter { $0.deadline <= now }
            .sorted { $0.deadline < $1.deadline }
            .forEach { $0.token.runIfPending() }
    }
}
