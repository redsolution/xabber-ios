import XCTest
@testable import xabber

#if DEBUG
final class DeviceQADiagnosticsTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent(DeviceQADiagnostics.fileName) }
    private let first = ArchiveConversationKey(owner: "private-owner@example.invalid",
        jid: "private-peer@example.invalid", conversationType: .regular)
    private let second = ArchiveConversationKey(owner: "another-private-owner@example.invalid",
        jid: "another-private-peer@example.invalid", conversationType: .omemo)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceQADiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func rows() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func integer(_ row: [String: Any], _ key: String) -> UInt64? {
        (row[key] as? NSNumber)?.uint64Value
    }

    func testDisabledRecorderDoesNotReadClockCreateFileOrAllocateConversationCodes() throws {
        var clockCalls = 0
        let untouched = directory.appendingPathComponent("off-subdirectory/log.jsonl")
        let recorder = DeviceQADiagnostics(enabled: false, fileURL: untouched) {
            clockCalls += 1; return 1
        }
        let code = recorder.conversationCode(for: first)
        recorder.recordLaunch()
        recorder.recordChatOpen(conversation: first, contextCode: 12)
        recorder.recordArchive(conversationCode: code, executionCode: 13, branch: 14,
            locator: 4, result: 1, proofMessageCount: 100)
        recorder.flush()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(clockCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.deletingLastPathComponent().path))
    }

    func testNumericRowsJoinExactConversationExecutionAndProofWithoutPrivateStrings() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 1234 })
        recorder.recordChatOpen(conversation: first, contextCode: UInt64.max, purposeCode: 3)
        let code = recorder.conversationCode(for: first)
        recorder.recordArchive(conversationCode: code, executionCode: UInt64.max,
            branch: 14, locator: 4, result: 1, proofMessageCount: 100)
        recorder.recordChat(.content, conversation: first, contextCode: UInt64.max, purposeCode: 3)
        recorder.flush()

        let records = try rows()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { integer($0, "seq") }, [1, 2, 3])
        XCTAssertEqual(records.map { integer($0, "event") }, [1, 10, 2])
        XCTAssertEqual(records.map { integer($0, "conversation") }, [1, 1, 1])
        XCTAssertEqual(records.first.flatMap { integer($0, "context") }, UInt64.max)
        XCTAssertEqual(records.dropFirst().first.flatMap { integer($0, "execution") }, UInt64.max)
        XCTAssertEqual(records.dropFirst().first.flatMap { integer($0, "proof_count") }, 100)
        let allowed = Set(["v", "seq", "uptime_ns", "event", "conversation", "context", "purpose",
            "execution", "branch", "locator", "result", "failure_domain", "failure_reason", "proof_count",
            "process", "archive_start", "live_edge", "dropped"])
        XCTAssertTrue(records.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        XCTAssertTrue(records.allSatisfy { $0.values.allSatisfy { $0 is NSNumber } })
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for secret in [first.owner, first.jid, first.conversationTypeRaw, second.owner, second.jid] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testCodesAreStablePerProcessRecorderAndDoNotBorrowAnotherConversation() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 5 })
        XCTAssertEqual(recorder.conversationCode(for: first), 1)
        XCTAssertEqual(recorder.conversationCode(for: second), 2)
        XCTAssertEqual(recorder.conversationCode(for: first), 1)
        recorder.recordChatOpen(conversation: second, contextCode: 20)
        recorder.recordChat(.empty, conversation: first, contextCode: 10)
        recorder.flush()
        let records = try rows()
        XCTAssertEqual(records.map { integer($0, "conversation") }, [2, 1])
        XCTAssertEqual(records.map { integer($0, "seq") }, [1, 2])
    }

    func testLaunchHeaderIsOncePerRunAndOnlyProvenEdgesArePresent() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 9 })
        recorder.recordLaunch()
        recorder.recordLaunch()
        let code = recorder.conversationCode(for: first)
        recorder.recordArchive(conversationCode: code, executionCode: 10, branch: 14,
            locator: 4, result: 1, proofMessageCount: 2, archiveStart: 1, liveEdge: 0)
        recorder.recordArchive(conversationCode: code, executionCode: 11, branch: 14,
            locator: 7, result: 4, proofMessageCount: 1)
        recorder.flush()
        let records = try rows()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { integer($0, "event") }, [0, 10, 10])
        XCTAssertTrue(records.allSatisfy { (integer($0, "process") ?? 0) > 0 })
        XCTAssertEqual(records.dropFirst().first.flatMap { integer($0, "archive_start") }, 1)
        XCTAssertEqual(records.dropFirst().first.flatMap { integer($0, "live_edge") }, 0)
        XCTAssertNil(records.last?["archive_start"])
        XCTAssertNil(records.last?["live_edge"])
    }

    func testSkeletonAndTerminalLifecyclePhasesRetainOneExactContext() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 10 })
        recorder.recordChatOpen(conversation: first, contextCode: 20, purposeCode: 3)
        let phases: [DeviceQADiagnostics.ChatPhase] = [.skeleton, .content, .stable]
        for phase in phases {
            recorder.recordChat(phase, conversation: first, contextCode: 20, purposeCode: 3)
        }
        recorder.flush()
        let records = try rows()
        XCTAssertEqual(records.map { integer($0, "event") }, [1, 5, 2, 4])
        XCTAssertEqual(records.map { integer($0, "context") }, [20, 20, 20, 20])
        XCTAssertEqual(records.map { integer($0, "conversation") }, [1, 1, 1, 1])
    }

    func testNewEnabledRunTruncatesOnlyItsOwnFileAndResetsSequenceAndCodes() throws {
        let sibling = directory.appendingPathComponent("other-evidence.jsonl")
        let old = Data("{\"seq\":999,\"event\":99}\n".utf8)
        try old.write(to: file)
        try Data("keep this evidence".utf8).write(to: sibling)
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 6 })
        recorder.recordChatOpen(conversation: first, contextCode: 11)
        recorder.flush()
        let records = try rows()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first.flatMap { integer($0, "seq") }, 1)
        XCTAssertEqual(records.first.flatMap { integer($0, "conversation") }, 1)
        XCTAssertEqual(records.first.flatMap { integer($0, "event") }, 1)
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep this evidence")
    }

    func testConcurrentActorAndChatEventsKeepUniqueSequenceAndStableConversationCodes() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 8 })
        _ = recorder.conversationCode(for: first)
        _ = recorder.conversationCode(for: second)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let scope = index.isMultiple(of: 2) ? first : second
            recorder.recordArchive(conversationCode: recorder.conversationCode(for: scope),
                executionCode: UInt64(index + 1), branch: 15, locator: 4, result: 1)
        }
        recorder.flush()
        let records = try rows()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.map { integer($0, "seq") }, (1...100).map { Optional(UInt64($0)) })
        XCTAssertEqual(Set(records.compactMap { integer($0, "conversation") }), [1, 2])
        XCTAssertEqual(Set(records.compactMap { integer($0, "execution") }).count, 100)
    }

    func testSavedCacheStagesContainOnlyNumericContextAndRejectionEvidence() throws {
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, clock: { 9 })
        recorder.recordSavedCache(stage: 3, rejectionMask: 128,
            conversation: first, contextCode: UInt64.max, purposeCode: 3)
        recorder.flush()
        let record = try XCTUnwrap(rows().first)
        XCTAssertEqual(integer(record, "event"), 20)
        XCTAssertEqual(integer(record, "branch"), 3)
        XCTAssertEqual(integer(record, "result"), 128)
        XCTAssertEqual(integer(record, "context"), UInt64.max)
        XCTAssertTrue(record.values.allSatisfy { $0 is NSNumber })
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(first.owner))
    }

    func testByteCapIncludesOneExplicitOverflowMarkerAndStopsFurtherRecords() throws {
        let limit = 1024
        let recorder = DeviceQADiagnostics(enabled: true, fileURL: file, maxBytes: limit, clock: { 7 })
        let code = recorder.conversationCode(for: first)
        for execution in 1...100 {
            recorder.recordArchive(conversationCode: code, executionCode: UInt64(execution),
                branch: 14, locator: 4, result: 1, proofMessageCount: 100)
        }
        recorder.flush()
        let records = try rows()
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(records.filter { integer($0, "event") == 99 }.count, 1)
        XCTAssertEqual(records.last.flatMap { integer($0, "event") }, 99)
        XCTAssertEqual(records.last.flatMap { integer($0, "dropped") }, 1,
            "One means at least one omitted record; do not invent an exact total after overflow")
        XCTAssertEqual(records.map { integer($0, "seq") }, records.indices.map { Optional(UInt64($0 + 1)) })
        let before = (try? Data(contentsOf: file)) ?? Data()
        XCTAssertLessThanOrEqual(before.count, limit)
        recorder.recordChatOpen(conversation: second, contextCode: 99)
        recorder.flush()
        XCTAssertEqual(try? Data(contentsOf: file), before)
    }
}
#endif
