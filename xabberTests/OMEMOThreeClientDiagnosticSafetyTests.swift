import CryptoKit
import Foundation
import XCTest
@testable import xabber

#if DEBUG
final class OMEMOThreeClientDiagnosticSafetyTests: XCTestCase {
    private var directory: URL!
    private var now: TimeInterval = 1_900_000_000
    private var pending: [() -> Void] = []
    private var timeouts: [() -> Void] = []
    private var actions: [OMEMOThreeClientDiagnosticExecution] = []
    private var completions: [(OMEMOThreeClientDiagnosticOutcome) -> Void] = []
    private var identity: OMEMOThreeClientDiagnosticSnapshot!
    private let token = "QA3-E06-SAFETY-T"
    private let fixtureBytes = Data("bounded synthetic QA3 fixture".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OMEMODiagnostic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        identity = snapshot()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        pending = []; timeouts = []; actions = []; completions = []
    }

    private func snapshot(
        bundle: String = "xabber.ios", pid: Int = 200,
        owner: String = "test.omemo.igor@dxs.xabber.com", sid: Int = 504224163,
        fingerprint: String = "0a0cd7daeded7269eaa6435a13000f694a23c9e63d7ef04055b46909cdbbfd19",
        authenticated: Bool = true, canFlush: Bool = true
    ) -> OMEMOThreeClientDiagnosticSnapshot {
        .init(bundleIdentifier: bundle, pid: pid, owner: owner, fullJID: owner + "/qa3-test",
              sid: sid, fingerprint: fingerprint, authenticated: authenticated, canFlush: canFlush)
    }

    private func command(_ additions: [String: Any] = [:]) -> [String: Any] {
        ["version": 1, "token": token, "operation": "route", "role": "T",
         "expires": now + 120, "expectedPID": 200].merging(additions) { _, new in new }
    }

    @discardableResult
    private func store(_ values: [String: Any], basename: String? = nil) throws -> String {
        let name = basename ?? token + ".json"
        try JSONSerialization.data(withJSONObject: values).write(to: directory.appendingPathComponent(name))
        return name
    }

    private func runner(in root: URL? = nil, readRealFixture: Bool = false) -> OMEMOThreeClientDiagnosticRunner {
        .init(directory: root ?? directory, now: { self.now }, snapshot: { _ in self.identity },
              schedule: { self.pending.append($0) }, timeout: { self.timeouts.append($0) },
              validateFixture: { _, source in
                  if readRealFixture { return try OMEMOThreeClientDiagnosticPolicy.read(source, limit: 2 * 1024 * 1024) }
                  return self.fixtureBytes
              }, execute: { request, completion in
                  self.actions.append(request); self.completions.append(completion); return nil
              })
    }

    private func drain() {
        let callbacks = pending; pending.removeAll(); callbacks.forEach { $0() }
    }

    private func result() throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(token + ".result.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testValidRouteRunsOnceOnlyAfterScheduledExecution() throws {
        let name = try store(command()); let sut = runner()
        XCTAssertEqual(sut.submit(name), "scheduled")
        XCTAssertTrue(actions.isEmpty)
        drain()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.command.role.owner, "test.omemo.igor@dxs.xabber.com")
        XCTAssertEqual(actions.first?.context.jid, "igor.boldin@redsolution.com")
        XCTAssertEqual(actions.first?.context.conversationType, .omemo)
        completions[0](.init(stage: .routeAccepted, success: true))
        XCTAssertEqual(try result()["stage"] as? String, "routeAccepted")
        XCTAssertEqual(try result()["deliveryProved"] as? Bool, false)
    }

    private func trustedDirectoryViaTemporaryRootAlias() throws -> URL {
        let actual = directory.appendingPathComponent("actual-temp", isDirectory: true)
        let alias = directory.appendingPathComponent("temp-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        return OMEMOThreeClientDiagnosticPolicy.directory(underTrustedTemporaryRoot: alias)
    }

    func testTrustedTemporaryRootAliasSchedulesCommandFromCanonicalDirectory() throws {
        let root = try trustedDirectoryViaTemporaryRootAlias()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: command()).write(to: root.appendingPathComponent(token + ".json"))
        XCTAssertEqual(runner(in: root).submit(token + ".json"), "scheduled")
        XCTAssertTrue(actions.isEmpty)
        drain()
        XCTAssertEqual(actions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(token + ".claim").path))
    }

    func testTrustedTemporaryRootDoesNotAuthorizeSymlinkedDiagnosticSubdirectory() throws {
        let root = try trustedDirectoryViaTemporaryRootAlias()
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        try JSONSerialization.data(withJSONObject: command()).write(to: outside.appendingPathComponent(token + ".json"))
        XCTAssertEqual(runner(in: root).submit(token + ".json"), "rejected")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(token + ".claim").path))
    }

    func testCanonicalTrustedRootStillRejectsSymlinkedCommand() throws {
        let root = try trustedDirectoryViaTemporaryRootAlias()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outside = directory.appendingPathComponent("outside.json")
        try JSONSerialization.data(withJSONObject: command()).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(token + ".json"), withDestinationURL: outside)
        XCTAssertEqual(runner(in: root).submit(token + ".json"), "rejected")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(token + ".claim").path))
    }

    func testCanonicalTrustedRootStillRejectsSymlinkedFixtureBeforeNormalAction() throws {
        let root = try trustedDirectoryViaTemporaryRootAlias()
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.png")
        try fixtureBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixtures.appendingPathComponent("QA3-image.png"), withDestinationURL: outside)
        try JSONSerialization.data(withJSONObject: command(["operation": "sendAttachment", "fixture": "QA3-image.png"]))
            .write(to: root.appendingPathComponent(token + ".json"))
        XCTAssertEqual(runner(in: root, readRealFixture: true).submit(token + ".json"), "scheduled")
        drain()
        XCTAssertTrue(actions.isEmpty)
        let output = try Data(contentsOf: root.appendingPathComponent(token + ".result.json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: output) as? [String: Any])?["stage"] as? String, "rejected")
    }

    func testTraversalAbsoluteBasenamesAndMismatchedTokensNeverSchedule() throws {
        let sut = runner()
        for name in ["../" + token + ".json", "/tmp/" + token + ".json", "personal.json", token + ".json/extra"] {
            XCTAssertEqual(sut.submit(name), "rejected")
        }
        let name = try store(command(["token": "QA3-E06-OTHER"]))
        XCTAssertEqual(sut.submit(name), "rejected")
        XCTAssertTrue(pending.isEmpty); XCTAssertTrue(actions.isEmpty)
    }

    func testUnknownFieldsUnknownModesRolesAndBooleanNumbersAreRejected() throws {
        let sut = runner()
        for change: [String: Any] in [["reset": true], ["operation": "trust"], ["role": "W"],
                                     ["version": true], ["expectedPID": true], ["expires": true]] {
            try store(command(change))
            XCTAssertEqual(sut.submit(token + ".json"), "rejected", "\(change.keys)")
        }
        XCTAssertTrue(pending.isEmpty)
    }

    func testExpiredFarFutureOrMissingExpectedPIDIsRejected() throws {
        let sut = runner()
        for expiry in [now, now - 1, now + 301] {
            try store(command(["expires": expiry]))
            XCTAssertEqual(sut.submit(token + ".json"), "rejected")
        }
        var input = command(); input.removeValue(forKey: "expectedPID"); try store(input)
        XCTAssertEqual(sut.submit(token + ".json"), "rejected")
        XCTAssertTrue(pending.isEmpty)
    }

    func testOversizedMalformedAndSymlinkCommandIsRejected() throws {
        let sut = runner(); let file = directory.appendingPathComponent(token + ".json")
        try Data(repeating: 65, count: 8193).write(to: file)
        XCTAssertEqual(sut.submit(file.lastPathComponent), "rejected")
        try Data("{bad JSON".utf8).write(to: file)
        XCTAssertEqual(sut.submit(file.lastPathComponent), "rejected")
        try FileManager.default.removeItem(at: file)
        let other = directory.appendingPathComponent("other.json")
        try JSONSerialization.data(withJSONObject: command()).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertEqual(sut.submit(file.lastPathComponent), "rejected")
        XCTAssertTrue(pending.isEmpty)
    }

    func testRepeatedCommandAndExistingResultNeverDispatchAgain() throws {
        let name = try store(command()); let sut = runner()
        XCTAssertEqual(sut.submit(name), "scheduled")
        XCTAssertEqual(sut.submit(name), "rejected")
        drain(); XCTAssertEqual(actions.count, 1)
        completions[0](.init(stage: .routeAccepted, success: true))
        XCTAssertEqual(runner().submit(name), "rejected")
        XCTAssertEqual(actions.count, 1)
    }

    func testExistingOutputRejectsBeforeAnyReservationOrAction() throws {
        let name = try store(command())
        try Data("preserve".utf8).write(to: directory.appendingPathComponent(token + ".result.json"))
        XCTAssertEqual(runner().submit(name), "rejected")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(token + ".result.json")), Data("preserve".utf8))
    }

    func testRuntimeSnapshotMismatchDeniesNormalAction() throws {
        let invalid: [OMEMOThreeClientDiagnosticSnapshot?] = [
            nil, snapshot(bundle: "xabber.ios.codex-hosted-tests"), snapshot(pid: 201),
            snapshot(owner: "stranger@example.test"), snapshot(sid: 504224164),
            snapshot(fingerprint: String(repeating: "0", count: 64)),
            snapshot(authenticated: false), snapshot(canFlush: false)
        ]
        for (index, bad) in invalid.enumerated() {
            let localToken = "QA3-E06-DENY-\(index)"
            let name = try store(command(["token": localToken]), basename: localToken + ".json")
            identity = bad
            XCTAssertEqual(runner().submit(name), "scheduled")
            drain()
            XCTAssertTrue(actions.isEmpty)
        }
    }

    func testIdentityAndExpiryAreCheckedAtExecutionRatherThanSubmission() throws {
        let name = try store(command()); let sut = runner()
        XCTAssertEqual(sut.submit(name), "scheduled")
        identity = snapshot(sid: 42)
        drain(); XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(try result()["stage"] as? String, "rejected")
    }

    func testQueuedCommandExpiringBeforeExecutionNeverDispatches() throws {
        let name = try store(command()); let sut = runner()
        XCTAssertEqual(sut.submit(name), "scheduled")
        now += 121; drain()
        XCTAssertTrue(actions.isEmpty)
    }

    func testOperationSpecificInputsMustBeCompleteAndCannotExpandScope() throws {
        let invalid: [[String: Any]] = [
            ["fixture": "QA3-image.png"],
            ["operation": "sendAttachment"],
            ["operation": "sendAttachment", "fixture": "../../personal.png"],
            ["operation": "sendAttachment", "fixture": "QA3-image.png", "url": "https://example.test"],
            ["operation": "receiveAttachment", "fixture": "QA3-image.png", "messageID": "F~jFuDwQ"],
            ["operation": "receiveAttachment", "fixture": "QA3-image.png", "messageID": "F-jFuDwQ", "messageToken": token]
        ]
        let sut = runner()
        for fields in invalid {
            try store(command(fields)); XCTAssertEqual(sut.submit(token + ".json"), "rejected")
        }
        XCTAssertTrue(pending.isEmpty)
    }

    func testTargetedRouteAcceptsOnlyTheCompleteBoundedMessagePair() throws {
        for id in ["36c43080-cca4-4605-a303-79910bbd7d54", "F~jFuDwQ"] {
            let data = try JSONSerialization.data(withJSONObject: command(["messageID": id, "messageToken": "QA3-E07-W-PNG01"]))
            XCTAssertNoThrow(try OMEMOThreeClientDiagnosticPolicy.decode(data, basename: token + ".json", now: now))
        }
        for change: [String: Any] in [["messageID": "F~jFuDwQ"], ["messageToken": "QA3-E07-W-PNG01"],
            ["messageID": "not-an-id", "messageToken": "QA3-E07-W-PNG01"],
            ["messageID": "F~jFuDwQ", "messageToken": "personal-message"],
            ["messageID": "F~jFuDwQ", "messageToken": "QA3-E07-W-PNG01", "fixture": "QA3-image.png"],
            ["operation": "sendAttachment", "fixture": "QA3-image.png", "messageID": "F~jFuDwQ", "messageToken": "QA3-E07-W-PNG01"]] {
            let data = try JSONSerialization.data(withJSONObject: command(change))
            XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.decode(data, basename: token + ".json", now: now))
        }
    }

    private func targetedRouteCommand() -> OMEMOThreeClientDiagnosticCommand {
        .init(token: token, operation: .route, role: .tablet, expires: now + 120, expectedPID: 200,
              fixture: nil, messageID: "36c43080-cca4-4605-a303-79910bbd7d54", messageToken: "QA3-E07-W-PNG01")
    }

    private func routeTarget() -> OMEMOThreeClientDiagnosticRouteTarget {
        .init(owner: "test.omemo.igor@dxs.xabber.com", peer: "igor.boldin@redsolution.com",
              conversationType: "urn:xmpp:omemo:2", messageID: targetedRouteCommand().messageID!,
              primary: "exact-local-row", body: "QA3-E07-W-PNG01", outgoing: true,
              deleted: false, locallyHidden: false, hasError: false,
              hasAuthenticationMetadata: false, authenticatedSource: nil)
    }

    private func validateRoute(_ target: OMEMOThreeClientDiagnosticRouteTarget?, count: Int = 1) throws {
        try OMEMOThreeClientDiagnosticPolicy.validateRouteTarget(target, matchingRowCount: count, command: targetedRouteCommand())
    }

    func testTargetedRouteSupportsCurrentNativeLocalOutgoingWithoutInventingSenderMetadata() {
        XCTAssertNoThrow(try validateRoute(routeTarget()))
        var target = routeTarget()
        target.hasAuthenticationMetadata = true
        target.authenticatedSource = .init(owner: target.owner, jid: target.owner,
            sid: OMEMOThreeClientDiagnosticRole.tablet.sid,
            fingerprint: OMEMOThreeClientDiagnosticRole.tablet.fingerprint, trusted: true)
        XCTAssertNoThrow(try validateRoute(target))
    }

    func testTargetedRouteSupportsAuthenticatedIncomingAndKnownOwnWebCarbon() {
        var target = routeTarget()
        target.outgoing = false; target.hasAuthenticationMetadata = true
        target.authenticatedSource = .init(owner: target.owner, jid: target.peer,
            sid: OMEMOThreeClientDiagnosticRole.phone.sid,
            fingerprint: OMEMOThreeClientDiagnosticRole.phone.fingerprint, trusted: true)
        XCTAssertNoThrow(try validateRoute(target))
        target.outgoing = true
        target.authenticatedSource = .init(owner: target.owner, jid: target.owner, sid: 1761201430,
            fingerprint: "868390cb370b3b6ce0e40203807fff0ef0ecbd232a4e3a56ceec64d8ff6c133d", trusted: true)
        XCTAssertNoThrow(try validateRoute(target))
    }

    func testTargetedRouteRejectsMissingDuplicateUnrelatedDeletedHiddenOrErroredRows() {
        XCTAssertThrowsError(try validateRoute(nil))
        XCTAssertThrowsError(try validateRoute(routeTarget(), count: 0))
        XCTAssertThrowsError(try validateRoute(routeTarget(), count: 2))
        let mutations: [(inout OMEMOThreeClientDiagnosticRouteTarget) -> Void] = [
            { $0.owner = "stranger@example.test" }, { $0.peer = "stranger@example.test" },
            { $0.conversationType = "jabber:client" }, { $0.messageID = "F~jFuDwQ" },
            { $0.primary = "" }, { $0.body = "unrelated personal text" },
            { $0.deleted = true }, { $0.locallyHidden = true }, { $0.hasError = true }
        ]
        for mutate in mutations { var target = routeTarget(); mutate(&target); XCTAssertThrowsError(try validateRoute(target)) }
    }

    func testTargetedRouteNeverIgnoresMissingInvalidUnknownOrUntrustedRemoteAuthentication() {
        var target = routeTarget(); target.outgoing = false
        XCTAssertThrowsError(try validateRoute(target))
        target.outgoing = true; target.hasAuthenticationMetadata = true
        XCTAssertThrowsError(try validateRoute(target))
        let phone = OMEMOThreeClientDiagnosticRole.phone
        for source in [
            OMEMOThreeClientDiagnosticRouteTarget.AuthenticatedSource(owner: "stranger@example.test", jid: phone.owner, sid: phone.sid, fingerprint: phone.fingerprint, trusted: true),
            .init(owner: target.owner, jid: phone.owner, sid: phone.sid, fingerprint: phone.fingerprint, trusted: false),
            .init(owner: target.owner, jid: phone.owner, sid: 42, fingerprint: phone.fingerprint, trusted: true),
            .init(owner: target.owner, jid: phone.owner, sid: phone.sid, fingerprint: String(repeating: "0", count: 64), trusted: true),
            .init(owner: target.owner, jid: "stranger@example.test", sid: phone.sid, fingerprint: phone.fingerprint, trusted: true)
        ] {
            target.authenticatedSource = source
            XCTAssertThrowsError(try validateRoute(target))
            target.outgoing = false
            XCTAssertThrowsError(try validateRoute(target))
            target.outgoing = true
        }
    }

    func testNormalAttachmentDispatchReceivesVerifiedPrivateCopyAndEncryptedContext() throws {
        let name = try store(command(["operation": "sendAttachment", "fixture": "QA3-image.png"]))
        let sut = runner(); XCTAssertEqual(sut.submit(name), "scheduled"); drain()
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.command.operation, .sendAttachment)
        XCTAssertEqual(action.command.fixture, .png)
        XCTAssertEqual(action.context.conversationType, .omemo)
        let verified = try XCTUnwrap(action.fixtureURL)
        XCTAssertTrue(verified.path.hasPrefix(directory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: verified), fixtureBytes)
        completions[0](.init(stage: .localAdmission, success: true, messageIDs: ["F~jFuDwQ"]))
        XCTAssertEqual(try result()["messageIDs"] as? [String], ["F~jFuDwQ"])
        XCTAssertEqual(try result()["deliveryProved"] as? Bool, false)
    }

    func testReceiveDispatchBindsExactActualIDAndSeparateFreshMessageToken() throws {
        let name = try store(command(["operation": "receiveAttachment", "fixture": "QA3-image.png",
                                      "messageID": "F~jFuDwQ", "messageToken": "QA3-E06-SENDER-PNG"]))
        XCTAssertEqual(runner().submit(name), "scheduled"); drain()
        XCTAssertEqual(actions.first?.command.messageID, "F~jFuDwQ")
        XCTAssertEqual(actions.first?.command.messageToken, "QA3-E06-SENDER-PNG")
        XCTAssertNil(actions.first?.fixtureURL)
    }

    func testTamperedFixtureNeverReachesNormalSender() throws {
        let name = try store(command(["operation": "sendAttachment", "fixture": "QA3-image.png"]))
        let sut = OMEMOThreeClientDiagnosticRunner(
            directory: directory, now: { self.now }, snapshot: { _ in self.identity },
            schedule: { self.pending.append($0) }, timeout: { self.timeouts.append($0) },
            validateFixture: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            execute: { request, completion in self.actions.append(request); return nil })
        XCTAssertEqual(sut.submit(name), "scheduled"); drain()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(try result()["stage"] as? String, "rejected")
    }

    func testRealFixtureHashAndByteLimitRejectAlteration() throws {
        let hash = SHA256.hash(data: fixtureBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(fixtureBytes, count: fixtureBytes.count, sha256: hash))
        XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(Data("changed".utf8), count: fixtureBytes.count, sha256: hash))
        XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(fixtureBytes, count: fixtureBytes.count, sha256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.validateFixtureBytes(Data(repeating: 1, count: 2_097_153), count: 2_097_153, sha256: hash))
    }

    func testPreparedDiagnosticVoiceRetainsTheExactVerifiedOGGSourceAndBytes() throws {
        let source = directory.appendingPathComponent("QA3-voice.ogg")
        try fixtureBytes.write(to: source)
        let decoded = directory.appendingPathComponent("voice-decoded-cache")
        try Data("decoded playback bytes".utf8).write(to: decoded)
        let reference = try OMEMOThreeClientDiagnosticPolicy.preparedVoiceReference(verifiedSource: source,
            decodedSource: decoded, fixture: .voice, context: voiceContext())
        XCTAssertEqual(reference.localFileUrl, source)
        XCTAssertEqual(reference.decodedUrl, decoded)
        XCTAssertEqual(reference.url, decoded.absoluteString)
        XCTAssertEqual(reference.metadata?["uri"] as? String, decoded.absoluteString)
        XCTAssertEqual(reference.owner, voiceContext().owner)
        XCTAssertEqual(reference.jid, voiceContext().jid)
        XCTAssertEqual(reference.conversationType, .omemo)
        XCTAssertEqual(reference.kind, .voice)
        XCTAssertEqual(reference.metadata?["media-type"] as? String, "audio/ogg")
        XCTAssertEqual(try Data(contentsOf: source), fixtureBytes)
    }

    func testPreparedDiagnosticVoiceCannotAcceptOtherFixturePathsOrRemoteSources() {
        for (source, fixture) in [(directory.appendingPathComponent("QA3-image.png"), OMEMOThreeClientDiagnosticFixture.png),
            (directory.appendingPathComponent("different.ogg"), .voice),
            (URL(string: "https://example.test/QA3-voice.ogg")!, .voice)] {
            XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.preparedVoiceReference(verifiedSource: source,
                decodedSource: directory.appendingPathComponent("voice-decoded-cache"), fixture: fixture, context: voiceContext()))
        }
    }

    func testPreparedDiagnosticVoiceRejectsRemoteEncodedMissingOrNonFilePlaybackURL() throws {
        let source = directory.appendingPathComponent("QA3-voice.ogg")
        let decoded = directory.appendingPathComponent("voice-decoded-cache")
        try Data("decoded playback bytes".utf8).write(to: decoded)
        let link = directory.appendingPathComponent("decoded-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoded)
        for playback in [source, URL(string: "https://example.test/decoded")!,
                         directory.appendingPathComponent("missing"), directory.appendingPathComponent("."), link] {
            XCTAssertThrowsError(try OMEMOThreeClientDiagnosticPolicy.preparedVoiceReference(verifiedSource: source,
                decodedSource: playback, fixture: .voice, context: voiceContext()))
        }
    }

    func testOrdinaryVoiceBuilderStillRepresentsRawRecordingWithoutPreparedFileOverride() {
        let raw = directory.appendingPathComponent("normal-recording.m4a")
        let reference = VoiceMessageReferenceBuilder.make(owner: voiceContext().owner, jid: voiceContext().jid,
            conversationType: .omemo, rawUrl: raw, duration: 1, meteringLevels: [0.25])
        XCTAssertNil(reference.localFileUrl)
        XCTAssertEqual(reference.decodedUrl, raw)
    }

    private func voiceContext() -> ChatAttachmentFlowContext {
        .init(owner: "test.omemo.igor@dxs.xabber.com", jid: "igor.boldin@redsolution.com",
              conversationType: .omemo, forwardedMessageIds: [])
    }

    func testFirstCompletionWinsAndTimeoutDoesNotClaimDelivery() throws {
        let name = try store(command()); XCTAssertEqual(runner().submit(name), "scheduled"); drain()
        completions[0](.init(stage: .routeAccepted, success: true))
        completions[0](.init(stage: .rejected, success: false))
        timeouts[0]()
        XCTAssertEqual(try result()["stage"] as? String, "routeAccepted")
    }

    func testTimeoutRemainsTimeoutIfNormalCompletionArrivesLater() throws {
        let name = try store(command()); XCTAssertEqual(runner().submit(name), "scheduled"); drain()
        timeouts[0](); completions[0](.init(stage: .localAdmission, success: true))
        XCTAssertEqual(try result()["stage"] as? String, "timedOut")
        XCTAssertEqual(try result()["deliveryProved"] as? Bool, false)
    }

    func testReceiverAdmitsOnlyCurrentKnownRemoteDeviceIdentities() {
        let tablet = OMEMOThreeClientDiagnosticRole.tablet
        let phone = OMEMOThreeClientDiagnosticRole.phone
        XCTAssertTrue(OMEMOThreeClientDiagnosticPolicy.validSender(tablet.owner, sid: tablet.sid,
            fingerprint: tablet.fingerprint, role: .phone, outgoing: false))
        XCTAssertTrue(OMEMOThreeClientDiagnosticPolicy.validSender(phone.owner, sid: phone.sid,
            fingerprint: phone.fingerprint, role: .tablet, outgoing: false))
        XCTAssertFalse(OMEMOThreeClientDiagnosticPolicy.validSender(tablet.owner, sid: tablet.sid,
            fingerprint: String(repeating: "0", count: 64), role: .phone, outgoing: false))
        XCTAssertFalse(OMEMOThreeClientDiagnosticPolicy.validSender("stranger@example.test", sid: tablet.sid,
            fingerprint: tablet.fingerprint, role: .phone, outgoing: false))
    }

    func testReceiverSiblingCarbonCannotBeSatisfiedByLocalSenderCache() {
        let tablet = OMEMOThreeClientDiagnosticRole.tablet
        let webFingerprint = "868390cb370b3b6ce0e40203807fff0ef0ecbd232a4e3a56ceec64d8ff6c133d"
        XCTAssertTrue(OMEMOThreeClientDiagnosticPolicy.validSender(tablet.owner, sid: 1761201430,
            fingerprint: webFingerprint, role: .tablet, outgoing: true))
        XCTAssertFalse(OMEMOThreeClientDiagnosticPolicy.validSender(tablet.owner, sid: tablet.sid,
            fingerprint: tablet.fingerprint, role: .tablet, outgoing: true))
        XCTAssertFalse(OMEMOThreeClientDiagnosticPolicy.validSender(tablet.owner, sid: 1761201430,
            fingerprint: webFingerprint, role: .phone, outgoing: true))
    }

    func testLocalAdmissionRequiresAcceptedNormalCallbackExactOutgoingBodyAndProtectedReference() {
        let accepted = OMEMOThreeClientDiagnosticPolicy.acceptsLocalAdmission
        XCTAssertTrue(accepted(true, 1, true, token, token, 1, true, true))
        XCTAssertFalse(accepted(false, 1, true, token, token, 1, true, true))
        XCTAssertFalse(accepted(true, 1, false, token, token, 1, true, true))
        XCTAssertFalse(accepted(true, 1, true, token + "-other", token, 1, true, true))
        XCTAssertFalse(accepted(true, 2, true, token, token, 1, true, true))
        XCTAssertFalse(accepted(true, 1, true, token, token, 2, true, true))
        XCTAssertFalse(accepted(true, 1, true, token, token, 1, false, true))
        XCTAssertFalse(accepted(true, 1, true, token, token, 1, true, false))
    }

    func testRuntimeChangeDuringAsynchronousActionRejectsSuccessfulCompletion() throws {
        let name = try store(command()); XCTAssertEqual(runner().submit(name), "scheduled"); drain()
        identity = snapshot(sid: 42)
        completions[0](.init(stage: .routeAccepted, success: true))
        XCTAssertEqual(try result()["stage"] as? String, "rejected")
        XCTAssertEqual(try result()["success"] as? Bool, false)
    }
}
#endif
