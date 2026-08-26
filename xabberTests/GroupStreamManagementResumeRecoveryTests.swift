import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class GroupStreamManagementResumeRecoveryTests: XCTestCase {
    func testTransportBindingIgnoresDuplicatePrepareForSameStream() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var firstGenerationElements: [XMPPElement] = []
        var duplicateGenerationElements: [XMPPElement] = []

        XCTAssertTrue(binding.prepare(stream: stream) {
            firstGenerationElements.append($0)
        })
        XCTAssertFalse(binding.prepare(stream: stream) {
            duplicateGenerationElements.append($0)
        })

        try service.sendJoin(groupJID: "stage@groups.example.com")

        XCTAssertEqual(firstGenerationElements.count, 1)
        XCTAssertTrue(duplicateGenerationElements.isEmpty)
    }

    func testTransportBindingDisconnectAllowsSameStreamToInstallFreshGeneration() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var oldGenerationElements: [XMPPElement] = []
        var resumedGenerationElements: [XMPPElement] = []

        XCTAssertTrue(binding.prepare(stream: stream) {
            oldGenerationElements.append($0)
        })
        XCTAssertEqual(binding.disconnect(), 0)
        XCTAssertTrue(binding.prepare(stream: stream) {
            resumedGenerationElements.append($0)
        })

        try service.sendJoin(groupJID: "stage@groups.example.com")

        XCTAssertTrue(oldGenerationElements.isEmpty)
        XCTAssertEqual(resumedGenerationElements.count, 1)
    }

    func testTransportBindingNewStreamCancelsOldGeneration() async throws {
        let oldRequestSent = expectation(description: "old generation request sent")
        let service = GroupchatService(requestIDProvider: { "members-old" })
        let binding = CanonicalGroupTransportBinding(service: service)
        let oldStream = XMPPStream()
        let newStream = XMPPStream()
        let oldRecorder = ResumeTransportRecorder()
        let newRecorder = ResumeTransportRecorder()

        XCTAssertTrue(binding.prepare(stream: oldStream) { element in
            oldRecorder.append(element)
            oldRequestSent.fulfill()
        })
        let oldRequest = Task {
            try await service.refreshMembers(groupJID: "stage@groups.example.com")
        }
        await fulfillment(of: [oldRequestSent], timeout: 1)

        XCTAssertTrue(binding.prepare(stream: newStream, transport: newRecorder.append))

        do {
            _ = try await oldRequest.value
            XCTFail("Expected the old stream generation to be cancelled")
        } catch let error as GroupRequestError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(service.pendingRequestCount, 0)

        try service.sendJoin(groupJID: "stage@groups.example.com")
        XCTAssertEqual(oldRecorder.elements.count, 1)
        XCTAssertEqual(newRecorder.elements.count, 1)
    }

    func testResumeRecoveryOnlyRebindsTransport() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        binding.prepare(stream: stream) { _ in
            XCTFail("Disconnected transport must not be reused")
        }
        XCTAssertEqual(binding.disconnect(), 0)

        var sentElements: [XMPPElement] = []
        CanonicalGroupStreamResumeRecovery.recover(
            binding: binding,
            stream: stream,
            transport: { element in
                sentElements.append(element)
            }
        )

        XCTAssertTrue(sentElements.isEmpty)

        try service.sendJoin(groupJID: "stage@groups.example.com")

        XCTAssertEqual(sentElements.map { $0.to?.bare }, ["stage@groups.example.com"])
    }

    func testResumeRecoveryDoesNotEnumerateOrHydratePersistedGroups() throws {
        let service = GroupchatService()
        let binding = CanonicalGroupTransportBinding(service: service)
        let stream = XMPPStream()
        var sentElements: [XMPPElement] = []

        CanonicalGroupStreamResumeRecovery.recover(
            binding: binding,
            stream: stream,
            transport: { sentElements.append($0) }
        )

        XCTAssertTrue(sentElements.isEmpty)
        try service.sendJoin(groupJID: "stage@groups.example.com")
        XCTAssertEqual(sentElements.count, 1)
    }

    func testSuccessfulResumeBranchInvokesCanonicalRuntimeRecovery() throws {
        let source = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )
        let resumedBranch = try XCTUnwrap(
            source.range(of: "if didResume {")
        )
        let fullAuthenticationBranch = try XCTUnwrap(
            source.range(of: "} else {", range: resumedBranch.upperBound..<source.endIndex)
        )
        let body = String(source[resumedBranch.lowerBound..<fullAuthenticationBranch.lowerBound])

        let groupTransportRecovery = try XCTUnwrap(
            body.range(of: "recoverCanonicalGroupRuntimeAfterStreamManagementResume()")
        )
        let archiveReadiness = try XCTUnwrap(
            body.range(of: "sendReadiness.markStreamManagementResumeSucceeded()")
        )
        XCTAssertLessThan(
            groupTransportRecovery.lowerBound,
            archiveReadiness.lowerBound,
            "The group transport generation must be rebound before archive admission becomes ready"
        )

        let delegate = try productionSource(
            "models/account/delegates/AccountStreamDelegate.swift"
        )
        XCTAssertTrue(delegate.contains("disconnectCanonicalGroupTransport()"))
        XCTAssertFalse(delegate.contains("groupchatService.disconnect()"))

        let account = try productionSource("models/account/Account.swift")
        let resetStart = try XCTUnwrap(account.range(of: "func resetStream()"))
        let resetEnd = try XCTUnwrap(
            account.range(of: "func registerModules()", range: resetStart.upperBound..<account.endIndex)
        )
        let resetBody = String(account[resetStart.lowerBound..<resetEnd.lowerBound])
        XCTAssertTrue(resetBody.contains("disconnectCanonicalGroupTransport()"))
    }

    func testFullAuthenticationBranchInvokesCanonicalRuntimeRecoveryAfterTransportSetup() throws {
        let source = try productionSource(
            "models/account/extensions/AccountConnectBehaviorExtension.swift"
        )
        let fullAuthenticationStart = try XCTUnwrap(source.range(of: "} else {"))
        let completion = try XCTUnwrap(
            source.range(
                of: "self.connectionResilience.streamManagementResumeCompleted",
                range: fullAuthenticationStart.upperBound..<source.endIndex
            )
        )
        let body = String(
            source[fullAuthenticationStart.upperBound..<completion.lowerBound]
        )
        let configure = try XCTUnwrap(body.range(of: "self.configureExtensions()"))
        let recovery = try XCTUnwrap(
            body.range(of: "self.recoverCanonicalGroupRuntimeAfterFullAuthentication()")
        )

        XCTAssertLessThan(configure.lowerBound, recovery.lowerBound)

        let integration = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let methodStart = try XCTUnwrap(
            integration.range(of: "func recoverCanonicalGroupRuntimeAfterFullAuthentication()")
        )
        let methodEnd = try XCTUnwrap(
            integration.range(
                of: "func reconcileCanonicalGroupDeletionFromSynchronization(",
                range: methodStart.upperBound..<integration.endIndex
            )
        )
        let methodBody = String(integration[methodStart.lowerBound..<methodEnd.lowerBound])
        XCTAssertTrue(methodBody.contains("prepareCanonicalGroupTransport()"))
        XCTAssertFalse(methodBody.contains("activeGroups("))
        XCTAssertFalse(methodBody.contains("groupMembershipDidActivate("))
    }

    func testMembershipActivationOnlyUpdatesLocalProjectionWithoutMetadataFanOut() throws {
        let source = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "func groupMembershipDidActivate(")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "func groupMembershipDidDeactivate(",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let methodBody = String(
            source[methodStart.lowerBound..<methodEnd.lowerBound]
        )

        XCTAssertTrue(
            methodBody.contains("GroupConversationProjectionStore.activate(")
        )
        let forbiddenNetworkWork = [
            "Task {",
            "refreshGroup(",
            "refreshMembers(",
            "getPermissions(",
            "groupActivationSyncGate"
        ]
        XCTAssertEqual(
            forbiddenNetworkWork.filter(methodBody.contains),
            [],
            "A live membership activation may project local state, but metadata, members, and permissions are lazy"
        )
    }

    func testDeadActivationSyncGateAndLifecycleHooksAreDeleted() throws {
        let integration = try productionSource(
            "models/account/delegates/AccountGroupchatIntegration.swift"
        )
        let account = try productionSource("models/account/Account.swift")
        let streamDelegate = try productionSource(
            "models/account/delegates/AccountStreamDelegate.swift"
        )

        XCTAssertFalse(integration.contains("GroupActivationSyncGate"))
        XCTAssertFalse(integration.contains("invalidateCurrentActivations"))
        XCTAssertFalse(account.contains("groupActivationSyncGate"))
        XCTAssertFalse(streamDelegate.contains("groupActivationSyncGate"))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("xabber", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        return try Realm(configuration: configuration)
    }
}

private final class ResumeTransportRecorder {
    private let lock = NSLock()
    private var storage: [XMPPElement] = []

    var elements: [XMPPElement] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: XMPPElement) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}
