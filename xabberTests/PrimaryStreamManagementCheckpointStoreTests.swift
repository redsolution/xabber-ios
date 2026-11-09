import XCTest
@testable import xabber

final class PrimaryStreamManagementCheckpointStoreTests: XCTestCase {
    private var directory: URL!
    private let disconnect = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRecreatedStoreLoadsBothCountersUntilResumeConsumesCheckpoint() throws {
        let owner = identity()
        let expected = checkpoint()
        let previous = store()
        XCTAssertTrue(previous.save(expected, for: owner, generation: previous.begin(for: owner)))

        let relaunched = store()
        let generation = relaunched.begin(for: owner)
        let candidate = try XCTUnwrap(relaunched.load(for: owner, generation: generation))
        XCTAssertEqual(candidate, expected)
        XCTAssertEqual(relaunched.load(for: owner, generation: generation), expected,
                       "A transport attempt before a resume verdict must leave the checkpoint available")
        XCTAssertTrue(relaunched.consume(candidate, for: owner, generation: generation))

        let nextLaunch = store()
        XCTAssertNil(nextLaunch.load(for: owner, generation: nextLaunch.begin(for: owner)))
    }

    func testExpiredCheckpointIsUnavailableToRelaunchedStore() {
        let owner = identity()
        let previous = store()
        XCTAssertTrue(previous.save(checkpoint(), for: owner, generation: previous.begin(for: owner)))

        let relaunched = store(after: 3600)
        XCTAssertNil(relaunched.load(for: owner, generation: relaunched.begin(for: owner)))
    }

    func testLoadedCheckpointCanBeRetiredWhenItExpiresDuringAuthentication() throws {
        let owner = identity()
        var now = disconnect.addingTimeInterval(3599)
        let active = PrimaryStreamManagementCheckpointStore(directory: directory, now: { now })
        let generation = active.begin(for: owner)
        XCTAssertTrue(active.save(checkpoint(), for: owner, generation: generation))
        let candidate = try XCTUnwrap(active.load(for: owner, generation: generation))

        now = disconnect.addingTimeInterval(3600)

        XCTAssertTrue(active.consume(candidate, for: owner, generation: generation))
        XCTAssertNil(active.load(for: owner, generation: generation))
    }

    func testChangedEndpointResourceOrAuthenticationCannotReuseCheckpoint() {
        let owner = identity()
        let previous = store()

        for changed in [identity(host: "other.example.org"), identity(port: 5223),
                        identity(resource: "iPad"), identity(authentication: "replacement-device")] {
            XCTAssertTrue(previous.save(checkpoint(), for: owner, generation: previous.begin(for: owner)))
            let relaunched = store()
            XCTAssertNil(relaunched.load(for: changed, generation: relaunched.begin(for: changed)))
        }
    }

    func testOtherAccountDoesNotReadOrConsumeOwnersCheckpoint() {
        let first = identity()
        let second = identity(owner: "other@example.org")
        let active = store()
        let firstGeneration = active.begin(for: first)
        let secondGeneration = active.begin(for: second)
        let saved = checkpoint()
        XCTAssertTrue(active.save(saved, for: first, generation: firstGeneration))

        XCTAssertNil(active.load(for: second, generation: secondGeneration))
        XCTAssertFalse(active.consume(saved, for: second, generation: secondGeneration))
        XCTAssertEqual(active.load(for: first, generation: firstGeneration), saved)
    }

    func testSupersededOrInvalidatedGenerationCannotPublishCheckpoint() {
        let owner = identity()
        let active = store()
        let previous = active.begin(for: owner)
        let current = active.begin(for: owner)
        let saved = checkpoint()
        XCTAssertFalse(active.save(saved, for: owner, generation: previous))
        XCTAssertTrue(active.save(saved, for: owner, generation: current))

        active.invalidate(forOwner: owner.owner)
        XCTAssertFalse(active.save(saved, for: owner, generation: current))
        XCTAssertNil(active.load(for: owner, generation: active.begin(for: owner)))
    }

    func testDelayedConsumeDoesNotRemoveReplacementCheckpoint() {
        let owner = identity()
        let active = store()
        let generation = active.begin(for: owner)
        let previous = checkpoint()
        let replacement = checkpoint(id: "replacement-id")
        XCTAssertTrue(active.save(previous, for: owner, generation: generation))
        XCTAssertTrue(active.save(replacement, for: owner, generation: generation))

        XCTAssertFalse(active.consume(previous, for: owner, generation: generation))
        XCTAssertEqual(active.load(for: owner, generation: generation), replacement)
    }

    func testRejectsForeignOrUnboundJIDAndOversizedIdentifier() {
        let owner = identity()
        let active = store()
        let generation = active.begin(for: owner)

        XCTAssertFalse(active.save(checkpoint(jid: "other@example.org/iOS"), for: owner, generation: generation))
        XCTAssertFalse(active.save(checkpoint(jid: owner.owner), for: owner, generation: generation))
        XCTAssertFalse(active.save(checkpoint(id: String(repeating: "x", count: 10_000)),
                                   for: owner, generation: generation))
        XCTAssertNil(active.load(for: owner, generation: generation))
    }

    func testUnknownStorageVersionFallsBackAndDiscardsOldRecord() throws {
        let owner = identity()
        let active = store()
        let generation = active.begin(for: owner)
        XCTAssertTrue(active.save(checkpoint(), for: owner, generation: generation))
        let savedFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: savedFile)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        stored["version"] = 99
        try JSONSerialization.data(withJSONObject: stored).write(to: savedFile, options: .atomic)

        XCTAssertNil(active.load(for: owner, generation: generation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedFile.path))
    }

    private func store(after seconds: TimeInterval = 1) -> PrimaryStreamManagementCheckpointStore {
        let now = disconnect.addingTimeInterval(seconds)
        return PrimaryStreamManagementCheckpointStore(directory: directory, now: { now })
    }

    private func identity(owner: String = "account@example.org", host: String? = "example.org",
                          port: UInt16? = 5222, resource: String = "iOS",
                          authentication: String = "device-id") -> PrimaryStreamManagementCheckpointIdentity {
        .init(owner: owner, configuredResource: resource, host: host, port: port,
              authenticationContext: authentication)
    }

    private func checkpoint(jid: String = "account@example.org/iOS-server",
                            id: String = "opaque-id") -> PrimaryStreamManagementCheckpoint {
        .init(boundFullJID: jid, resumptionID: id, timeout: 3600, disconnectedAt: disconnect,
              lastHandledByClient: 41, lastHandledByServer: UInt32.max)
    }
}
